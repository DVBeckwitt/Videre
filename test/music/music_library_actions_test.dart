import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:back_button_interceptor/back_button_interceptor.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/downloads/models/music_offline_policy.dart';
import 'package:clipious/downloads/services/explicit_music_download.dart';
import 'package:clipious/downloads/views/components/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_listening_history.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/components/music_playback_artwork.dart';
import 'package:clipious/music/views/components/music_recommendation_collection.dart';
import 'package:clipious/music/views/components/music_song_selection_bar.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/music/views/screens/music_automatic_collections.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/models/named_music_queue.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/states/compact_video.dart';
import 'package:clipious/videos/views/components/compact_video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _App extends AppCubit {
  _App() : super(AppState(0, null, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  onReady() {}

  @override
  initState() {}

  void profileChanged(String id) => emit(state.copyWith(profileId: id));
}

class _PausedLibrary extends Service {
  final appendStarted = Completer<void>();
  final release = Completer<void>();

  @override
  Future<int> appendLocalPlaylistEntries(
    String playlistId,
    List<Video> videos, {
    bool allowDuplicates = false,
    IDbClient? database,
    bool Function()? isCurrent,
  }) async {
    appendStarted.complete();
    await release.future;
    return super.appendLocalPlaylistEntries(
      playlistId,
      videos,
      allowDuplicates: allowDuplicates,
      database: database,
      isCurrent: isCurrent,
    );
  }
}

class _Downloads implements DownloadManagerCubit {
  _Downloads(
      {this.state = const DownloadManagerState(),
      this.destinationPicker,
      this.destinationReady = true});

  final Future<bool>? destinationPicker;
  final bool destinationReady;
  int destinationRequests = 0;

  @override
  Future<bool> prepareMusicDownloads() async {
    destinationRequests++;
    if (destinationPicker case final picker?) return picker;
    return destinationReady;
  }

  @override
  final DownloadManagerState state;

  final calls = <({
    String id,
    bool audioOnly,
    String quality,
    MusicOfflinePolicy? musicPolicy,
    DownloadContainer? container,
    Video? video
  })>[];

  @override
  Stream<DownloadManagerState> get stream => const Stream.empty();

  @override
  Future<bool> addDownload(String videoId,
      {String quality = '720p',
      bool audioOnly = false,
      MusicOfflinePolicy? musicPolicy,
      Video? video,
      DownloadContainer? container,
      String? audioTrackId,
      String? captionLabel}) async {
    calls.add((
      id: videoId,
      audioOnly: audioOnly,
      quality: quality,
      musicPolicy: musicPolicy,
      container: container,
      video: video
    ));
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _PlaybackPlayer extends TestPlayerCubit {
  _PlaybackPlayer(super.initialState, super.settings);

  final calls = <({
    List<Video> videos,
    bool? audio,
    int? startIndex,
    Duration? startAt,
    bool fromMusic,
  })>[];
  final offlineCalls = <List<DownloadedVideo>>[];
  int queueReplacements = 0;
  Zone? enqueueZone;
  PlaylistReference? enqueuedRecommendationSource;
  PlaylistReference? playedRecommendationSource;
  bool acknowledgePause = false;

  @override
  void pause() {
    super.pause();
    if (acknowledgePause) emit(state.copyWith(isPlaying: false));
  }

  @override
  int get playlistGeneration => super.playlistGeneration + queueReplacements;

  @override
  Future<bool> enqueueMusicSongs(List<Video> selection,
      {required bool next,
      List<DownloadedVideo>? downloads,
      PlaylistReference? recommendationSource}) {
    enqueuedRecommendationSource = recommendationSource;
    return (enqueueZone ?? Zone.current).run(() => super.enqueueMusicSongs(
        selection,
        next: next,
        downloads: downloads,
        recommendationSource: recommendationSource));
  }

  @override
  Future<void> playVideo(List<Video> videos,
      {bool? audio,
      Duration? startAt,
      bool? playing,
      int? startIndex,
      String? queueTitle,
      bool fromMusic = false,
      bool songTap = false,
      bool collectionDetail = false,
      PlaylistReference? recommendationSource}) async {
    playedRecommendationSource = recommendationSource;
    calls.add((
      videos: List.of(videos),
      audio: audio,
      startIndex: startIndex,
      startAt: startAt,
      fromMusic: fromMusic,
    ));
  }

  @override
  Future<void> playOfflineVideos(List<DownloadedVideo> videos,
      {int startIndex = 0,
      bool fromMusic = false,
      bool songTap = false}) async {
    offlineCalls.add(List.of(videos));
  }
}

class _SongOperationCatalog extends MusicCatalogService {
  final previews = <({
    String id,
    Completer<MusicTrack> result,
    VideoLoadObserver observer,
  })>[];
  final related = Completer<List<MusicTrack>>();
  bool Function()? radioIsCurrent;
  List<String>? seeds;

  @override
  Future<MusicTrack> getSong(String videoId,
      {VideoLoadObserver? loadObserver}) {
    final result = Completer<MusicTrack>();
    previews.add((id: videoId, result: result, observer: loadObserver!));
    return result.future;
  }

  @override
  Future<List<MusicTrack>> getRelatedSongs(Iterable<String> seedIds,
      {bool Function()? isCurrent}) {
    seeds = seedIds.toList();
    radioIsCurrent = isCurrent;
    return related.future;
  }
}

class _PreviewPlatform extends JustAudioPlatform {
  final disposing = Completer<void>();
  final release = Completer<void>();
  late final _PreviewDecoder decoder;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async =>
      decoder = _PreviewDecoder(request.id);

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
          DisposeAllPlayersRequest request) async =>
      DisposeAllPlayersResponse();

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    if (!disposing.isCompleted) disposing.complete();
    await release.future;
    await decoder.events.close();
    return DisposePlayerResponse();
  }
}

class _PreviewDecoder extends AudioPlayerPlatform {
  _PreviewDecoder(super.id);

  final events = StreamController<PlaybackEventMessage>.broadcast();

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    const duration = Duration(seconds: 15);
    events.add(PlaybackEventMessage(
      processingState: ProcessingStateMessage.ready,
      updateTime: DateTime.now(),
      updatePosition: Duration.zero,
      bufferedPosition: Duration.zero,
      duration: duration,
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
    return LoadResponse(duration: duration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();
  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();
  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();
  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();
  @override
  Future<SetShuffleModeResponse> setShuffleMode(
          SetShuffleModeRequest request) async =>
      SetShuffleModeResponse();
}

enum _HandoffOutcome { play, profileChanged, cancelled }

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const first = Video(
      videoId: 'firstsong01',
      title: 'First song',
      musicMetadata:
          MusicMetadata(title: 'First song', artist: 'Artist', album: 'Album'));
  const second = Video(
      videoId: 'secondsong2',
      title: 'Second song',
      musicMetadata: MusicMetadata(
          title: 'Second song', artist: 'Artist', album: 'Album'));
  late Service previousService;
  late bool previousTv;
  late _App app;
  TestSettingsCubit? settings;
  _PlaybackPlayer? player;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('videre/recommendations'),
            (_) async => throw MissingPluginException());
    previousService = service;
    previousTv = app_globals.isTv;
    app_globals.isTv = false;
    service = Service();
    db = await SembastSqfDb.createInMemory();
    // Run the profile's queue setup on the real database clock.
    await db.saveSetting(SettingsValue(
        namedMusicQueuesSetting, NamedMusicQueue.encodeAll(const [])));
    app = _App();
    settings = null;
    player = null;
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('videre/recommendations'), null);
    await player?.close();
    await settings?.close();
    await app.close();
    await db.close();
    service = previousService;
    app_globals.isTv = previousTv;
  });

  test('explicit song saves learn while bulk saves and paused learning do not',
      () async {
    final events = <Map>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('videre/recommendations'),
            (call) async {
      final args = call.arguments as Map;
      events.addAll((args['events'] as List).cast<Map>());
      return {
        'state': <String, Object?>{},
        'ranked': <Object?>[],
        'summary': <String, Object?>{}
      };
    });
    await MusicLibrarySession(app)
        .setBookmark(MusicLibraryEntry.song(first), saved: true);
    await RecommendationService.flushPending();
    expect(events.map((event) => event['type']), ['save']);
    await MusicLibrarySession(app)
        .saveToPlaylist(localWatchLaterId, [first, second]);
    await RecommendationService.flushPending();
    expect(events, hasLength(1));
    await RecommendationService.forProfile(db, db.profileId)
        .setLearningEnabled(RecommendationDomain.music, false);
    await MusicLibrarySession(app)
        .setBookmark(MusicLibraryEntry.song(second), saved: true);
    await RecommendationService.flushPending();
    expect(events, hasLength(1));
    expect(
        MusicLibraryService.forProfile(db, db.profileId).entries, hasLength(2));
  });

  test('collection save preserves order, metadata and deduplicates all songs',
      () async {
    await service.addVideoToPlaylist(localWatchLaterId, first.videoId,
        video: first);
    await MusicLibrarySession(app)
        .saveToPlaylist(localWatchLaterId, [first, second, first]);
    final saved = service.getLocalPlaylists().first.videos;
    expect(
        saved.map((video) => video.videoId), [first.videoId, second.videoId]);
    expect(saved.map((video) => video.musicMetadata?.toJson()),
        [first.musicMetadata!.toJson(), second.musicMetadata!.toJson()]);
  });

  test('creating a local playlist saves the complete collection', () async {
    await MusicLibrarySession(app).createPlaylist('Album', [first, second]);
    final created = service
        .getLocalPlaylists()
        .singleWhere((playlist) => playlist.title == 'Album');
    expect(created.isLocal, isTrue);
    expect(created.videos.map((video) => video.videoId),
        [first.videoId, second.videoId]);
  });

  test('playlist removal rejects remote destinations and stale profiles',
      () async {
    await MusicLibrarySession(app).createPlaylist('Music', [first, second]);
    final originalProfile = db.profileId;
    final playlistId = service
        .getLocalPlaylists()
        .singleWhere((playlist) => playlist.title == 'Music')
        .playlistId;
    final session = MusicLibrarySession(app);
    await expectLater(
        session.removeFromPlaylist('PLpublic', first), throwsArgumentError);
    final next = await db.createProfile('Another person');
    await db.useProfile(next.id);
    app.profileChanged(next.id);
    await expectLater(
        session.removeFromPlaylist(playlistId, first), throwsStateError);
    expect(service.getLocalPlaylists().single.videos, isEmpty);
    expect(
        service
            .getLocalPlaylists(database: db.forProfile(originalProfile))
            .singleWhere((playlist) => playlist.playlistId == playlistId)
            .videos
            .map((video) => video.videoId),
        [first.videoId, second.videoId]);
  });

  test(
      'collection downloads retain track order and metadata as unique audio jobs',
      () async {
    final downloads = _Downloads();
    const policy = MusicOfflinePolicy(
        quality: MusicOfflineQuality.balanced, wifiOnly: true);
    final count = await MusicLibrarySession(app)
        .download(downloads, [first, second, first], policy: policy);
    expect(count, 2);
    expect(downloads.destinationRequests, 1);
    expect(downloads.calls.map((call) => call.id),
        [first.videoId, second.videoId]);
    expect(downloads.calls.every((call) => call.audioOnly), isTrue);
    expect(downloads.calls.map((call) => call.quality),
        everyElement(highestAudioDownloadQuality));
    expect(
        downloads.calls.map((call) => call.musicPolicy), everyElement(policy));
    expect(downloads.calls.map((call) => call.container), everyElement(isNull));
    expect(downloads.calls.map((call) => call.video), [first, second]);
  });

  test('cancelling the Music folder picker stops the entire collection',
      () async {
    final downloads = _Downloads(destinationReady: false);
    expect(
        await MusicLibrarySession(app).download(downloads, [first, second]), 0);
    expect(downloads.destinationRequests, 1);
    expect(downloads.calls, isEmpty);
  });

  test('a single selected download rechecks its source after folder access',
      () async {
    final picker = Completer<bool>();
    final downloads = _Downloads(destinationPicker: picker.future);
    var current = true;
    final result = MusicLibrarySession(app)
        .download(downloads, [first], canStart: () => current);
    expect(downloads.destinationRequests, 1);
    expect(downloads.calls, isEmpty);
    current = false;
    picker.complete(true);
    expect(await result, 0);
    expect(downloads.calls, isEmpty);
  });

  test(
    'profile switch prevents a pending save from writing a partial batch',
    () async {
      final originalProfile = db.profileId;
      final paused = _PausedLibrary();
      service = paused;
      final saving = MusicLibrarySession(
        app,
      ).saveToPlaylist(localWatchLaterId, [first, second]);
      final failed = expectLater(saving, throwsStateError);
      await paused.appendStarted.future;
      final next = await db.createProfile('Another person');
      await db.useProfile(next.id);
      app.profileChanged(next.id);
      paused.release.complete();
      await failed;
      expect(service.getLocalPlaylists().first.videos, isEmpty);
      expect(
        service
            .getLocalPlaylists(database: db.forProfile(originalProfile))
            .first
            .videos,
        isEmpty,
      );
    },
  );

  Future<void> show(WidgetTester tester,
      {bool compact = false, Widget? body}) async {
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
      value: app,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: body ??
              MusicLibraryActions(
                  videos: const [first, second], compact: compact),
        ),
      ),
    ));
  }

  Widget songRow(Video video,
          {Future<void> Function()? onPlay,
          MusicSongRecommendation? recommendation,
          PlaylistReference? recommendationSource}) =>
      Builder(
        builder: (context) => ListTile(
          key: const ValueKey('song-long-press-row'),
          title: Text(video.musicMetadata!.title),
          onTap: onPlay ?? () => MusicScreen.playTracks(context, [video]),
          onLongPress: () => MusicLibraryActions.showSongMenu(context, video,
              onPlay: onPlay,
              recommendation: recommendation,
              recommendationSource: recommendationSource),
          trailing: MusicLibraryActions(
              videos: [video], recommendationSource: recommendationSource),
        ),
      );

  Future<_PlaybackPlayer> showSongActions(WidgetTester tester,
      {PlayerState? initial,
      Widget Function(_PlaybackPlayer player)? body}) async {
    settings = TestSettingsCubit(SettingsState.init(), app);
    final current =
        player = _PlaybackPlayer(initial ?? PlayerState.init(null), settings!);
    await show(tester,
        body: BlocProvider<PlayerCubit>.value(
          value: current,
          child: body?.call(current) ?? songRow(first),
        ));
    await tester.pumpAndSettle();
    return current;
  }

  Future<void> openSongMenu(WidgetTester tester) async {
    await tester.longPress(find.byKey(const ValueKey('song-long-press-row')));
    await tester.pumpAndSettle();
  }

  testWidgets('a remote catalog song has no ringtone action', (tester) async {
    await showSongActions(tester);
    await openSongMenu(tester);
    expect(find.text('Share song link'), findsOneWidget);
    expect(find.text('Set as ringtone'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a catalog song shares a watch link from its row menu',
      (tester) async {
    const server = Server(url: 'https://selected.example/invidious/');
    await tester.runAsync(() => db.useServer(server));
    const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
    final messenger = tester.binding.defaultBinaryMessenger;
    final shared = <MethodCall>[];
    messenger.setMockMethodCallHandler(shareChannel, (call) async {
      shared.add(call);
      return 'dev.fluttercommunity.plus/share/unavailable';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(shareChannel, null));

    await showSongActions(tester);
    await openSongMenu(tester);
    expect(find.text('Share audio file'), findsNothing);
    await tester.tap(find.text('Share song link'));
    await tester.pumpAndSettle();
    expect(find.text('Share Invidious link'), findsOneWidget);
    expect(find.text('Share YouTube link'), findsOneWidget);
    expect(find.text('Add timestamp'), findsNothing);
    expect(shared, isEmpty);

    await tester.tap(find.text('Share Invidious link'));
    await tester.pumpAndSettle();
    expect(shared.single.arguments, {
      'text': 'https://selected.example/invidious/watch?v=${first.videoId}',
    });
  });

  testWidgets('a noncatalog song row cannot share a watch link',
      (tester) async {
    final song = first.copyWith(videoId: 'unverified-catalog-recording');
    await showSongActions(tester, body: (_) => songRow(song));
    await openSongMenu(tester);

    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Share song link'), findsNothing);
    expect(find.text('Share audio file'), findsNothing);
  });

  testWidgets(
      'download sharing offers both actions and rechecks a removed file',
      (tester) async {
    final saved = DownloadedVideo(
        videoId: first.videoId,
        title: first.title ?? 'Saved file',
        profileId: db.profileId,
        lengthSeconds: 60,
        quality: 'best',
        downloadComplete: true,
        audioOnly: true,
        musicMetadata: first.musicMetadata);
    DownloadedVideo? current = saved;
    var resolutions = 0;
    await showSongActions(tester,
        body: (_) => Builder(builder: (context) {
              return TextButton(
                  onPressed: () => MusicLibraryActions.showSongMenu(
                          context, first, downloads: [saved],
                          resolveDownload: () {
                        resolutions++;
                        return current;
                      }),
                  child: const Text('Song actions'));
            }));
    await tester.tap(find.text('Song actions'));
    await tester.pumpAndSettle();
    expect(find.text('Share song link'), findsOneWidget);
    expect(find.text('Share audio file'), findsOneWidget);

    current = null;
    final beforeSelection = resolutions;
    await tester.tap(find.text('Share audio file'));
    await tester.pumpAndSettle();
    expect(resolutions, beforeSelection + 1);
    expect(find.text('Share Invidious link'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
      'sharing a managed song and setting its ringtone use the same file',
      (tester) async {
    const folder =
        'content://com.android.externalstorage.documents/tree/primary%3AMusic';
    const uri = '$folder/document/primary%3AMusic%2Fsong.m4a';
    final saved = DownloadedVideo(
        videoId: first.videoId,
        title: 'Saved song',
        profileId: db.profileId,
        lengthSeconds: 60,
        quality: 'best',
        downloadComplete: true,
        audioOnly: true,
        musicFormat: MusicDownloadFormat.m4a,
        musicMetadata: first.musicMetadata,
        storageUri: uri,
        folderUri: folder);
    await tester.runAsync(() => db.upsertDownload(saved));

    const storageChannel = MethodChannel('videre/download_storage');
    const linkChannel = MethodChannel('dev.fluttercommunity.plus/share');
    final messenger = tester.binding.defaultBinaryMessenger;
    final files = <MethodCall>[];
    final links = <MethodCall>[];
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      files.add(call);
      return call.method == 'setMusicRingtone' ? 'set' : true;
    });
    messenger.setMockMethodCallHandler(linkChannel, (call) async {
      links.add(call);
      return 'dev.fluttercommunity.plus/share/unavailable';
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(storageChannel, null);
      messenger.setMockMethodCallHandler(linkChannel, null);
    });

    await showSongActions(tester,
        body: (_) => Builder(builder: (context) {
              return Column(mainAxisSize: MainAxisSize.min, children: [
                TextButton(
                    onPressed: () => MusicLibraryActions.showSongMenu(
                        context, first,
                        downloads: [saved],
                        resolveDownload: () =>
                            db.getDownloadByVideoId(saved.videoId)),
                    child: const Text('Song actions')),
                MusicLibraryActions(
                    videos: [first.copyWith(downloadPlaybackOnly: true)]),
              ]);
            }));
    await tester.tap(find.text('Song actions'));
    await tester.pumpAndSettle();
    expect(find.text('Set as ringtone'), findsOneWidget);
    await tester.tap(find.text('Share audio file'));
    await tester.pumpAndSettle();

    final call = files.singleWhere((call) => call.method == 'shareMusicFile');
    expect(
        call.arguments,
        allOf(
          containsPair('profileId', saved.profileId),
          containsPair('videoId', first.videoId),
          containsPair('uri', uri),
          containsPair('folderUri', folder),
          containsPair('mime', 'audio/mp4'),
        ));
    expect(links, isEmpty);
    expect(find.text('Share Invidious link'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);

    await tester.tap(find.byTooltip('Music actions'));
    await tester.pumpAndSettle();
    final ringtoneAction = find.ancestor(
      of: find.text('Set as ringtone'),
      matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
    );
    await tester.ensureVisible(ringtoneAction);
    await tester.pumpAndSettle();
    expect(ringtoneAction.hitTestable(), findsOneWidget);
    await tester.tap(ringtoneAction.hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Phone ringtone updated.'), findsOneWidget);
    final ringtone =
        files.singleWhere((call) => call.method == 'setMusicRingtone');
    expect(ringtone.arguments, {
      ...call.arguments as Map,
      'title': saved.title,
    });
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  PlayerState playingPlaylist() => PlayerState.init(null).copyWith(
        isAudio: true,
        isHidden: false,
        isPlaying: true,
        currentlyPlaying: first,
        videos: [first, second],
        playQueue: ListQueue.of([second.videoId]),
        position: const Duration(seconds: 37),
      );

  PlayerState mountedRadioPlaylist({bool playing = true}) {
    final mounted = first.copyWith(
      queueEntryId: '${first.videoId}#1',
      playbackSourceId: Object(),
      lengthSeconds: 120,
    );
    return playingPlaylist().copyWith(
      isPlaying: playing,
      isMini: false,
      currentlyPlaying: mounted,
      videos: [first, mounted, second],
      playedVideos: [playbackQueueId(first)],
      mediaEvent: const MediaEvent(state: MediaState.ready),
    );
  }

  _SongOperationCatalog useSongOperationCatalog() {
    final previous = musicCatalogService;
    final next = _SongOperationCatalog();
    musicCatalogService = next;
    addTearDown(() => musicCatalogService = previous);
    return next;
  }

  Future<void> openPreview(WidgetTester tester, {bool menuOpen = false}) async {
    if (!menuOpen) await openSongMenu(tester);
    await tester.tap(find.text('Preview song'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> openRadio(WidgetTester tester, {bool menuOpen = false}) async {
    if (!menuOpen) await openSongMenu(tester);
    await tester.tap(find.text('Start related radio'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> waitForBookmark(
      WidgetTester tester, MusicLibraryService library, String id) {
    return Future.doWhile(() async {
      await tester.pump();
      if (library.savedSong(id) != null) return false;
      await Future<void>.delayed(const Duration(milliseconds: 1));
      return true;
    }).timeout(const Duration(seconds: 5));
  }

  testWidgets('preview Save follows navigation and bookmarks the sample once',
      (tester) async {
    final catalog = useSongOperationCatalog();
    final library = MusicLibraryService.forProfile(db, db.profileId);
    final current = await showSongActions(tester, initial: playingPlaylist());
    await openPreview(tester);
    final seed = catalog.previews.single;
    catalog.related.complete(const [
      MusicTrack(
          videoId: 'secondsong2', title: 'Second sample', artists: ['Artist']),
    ]);
    await tester.pump();

    final save = find.widgetWithText(TextButton, 'Save song');
    final staleSave = tester.widget<TextButton>(save).onPressed!;
    final next = find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == 'Next preview');
    tester.widget<IconButton>(next).onPressed!();
    staleSave();
    await tester.pump();
    staleSave();
    expect(find.text('Second sample'), findsOneWidget);
    expect(library.entries, isEmpty);
    expect(seed.observer.isCurrent(), isFalse);
    final observer = catalog.previews.last.observer;

    await tester.runAsync(() async {
      var changes = 0;
      void onChange() => changes++;

      library.changes.addListener(onChange);
      try {
        await tester.tap(save);
        await tester.tap(save);
        await waitForBookmark(tester, library, second.videoId);
        expect(changes, 1);
      } finally {
        library.changes.removeListener(onChange);
      }
    });
    await tester.pump();
    expect(library.savedSong(second.videoId)?.title, 'Second sample');
    expect(library.entries, hasLength(1));
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Saved'))
            .onPressed,
        isNull);
    expect(observer.isCurrent(), isTrue);
    expect(current.state.currentlyPlaying, first);
    expect(current.state.playQueue.toList(), [second.videoId]);
    expect(current.calls, isEmpty);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(observer.isCurrent(), isFalse);
  });

  testWidgets('saving keeps the preview current after its discovery row leaves',
      (tester) async {
    final catalog = useSongOperationCatalog();
    final library = MusicLibraryService.forProfile(db, db.profileId);
    bool visible() => library.savedSong(first.videoId) == null;
    await showSongActions(tester,
        body: (_) => ListenableBuilder(
            listenable: library.changes,
            builder: (context, _) => visible()
                ? songRow(first,
                    recommendation: MusicSongRecommendation(
                        reason: 'Related artist',
                        onFeedback: (_) {},
                        isCurrent: visible))
                : const SizedBox.shrink()));
    await openPreview(tester);
    final observer = catalog.previews.single.observer;

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, 'Save song'));
      await waitForBookmark(tester, library, first.videoId);
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('song-long-press-row')), findsNothing);
    expect(find.widgetWithText(TextButton, 'Saved'), findsOneWidget);
    expect(observer.isCurrent(), isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(observer.isCurrent(), isFalse);
  });

  testWidgets('a preview save error leaves Save available and preview current',
      (tester) async {
    final catalog = useSongOperationCatalog();
    const invalid = Video(
        videoId: 'firstsong01',
        title: 'First song',
        musicMetadata: MusicMetadata(title: ' ', artist: 'Artist'));
    await showSongActions(tester, body: (_) => songRow(invalid));
    await openPreview(tester);

    final save = find.widgetWithText(TextButton, 'Save song');
    await tester.tap(save);
    await tester.pump();
    expect(find.text('Could not update your music library. Try again.'),
        findsOneWidget);
    expect(tester.widget<TextButton>(save).onPressed, isNotNull);
    expect(MusicLibraryService.forProfile(db, db.profileId).entries, isEmpty);
    expect(catalog.previews.single.observer.isCurrent(), isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  });

  testWidgets('a stale preview cannot save into either profile',
      (tester) async {
    final catalog = useSongOperationCatalog();
    final original = db.profileId;
    final next =
        (await tester.runAsync(() => db.createProfile('Another person')))!;
    await showSongActions(tester);
    await openPreview(tester);
    final staleSave = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Save song'))
        .onPressed!;

    await tester.runAsync(() async {
      await db.useProfile(next.id);
      app.profileChanged(next.id);
      staleSave();
    });
    await tester.pumpAndSettle();
    expect(MusicLibraryService.forProfile(db, original).entries, isEmpty);
    expect(MusicLibraryService.forProfile(db, next.id).entries, isEmpty);
    expect(catalog.previews.single.observer.isCurrent(), isFalse);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('Back cancels a loading preview and preserves the active queue',
      (tester) async {
    final catalog = useSongOperationCatalog();
    final current = await showSongActions(tester, initial: playingPlaylist());
    await openPreview(tester);
    final request = catalog.previews.single;
    expect(request.observer.isCurrent(), isTrue);
    expect(catalog.radioIsCurrent!(), isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(request.observer.isCurrent(), isFalse);
    expect(catalog.radioIsCurrent!(), isFalse);
    request.result.complete(
        const MusicTrack(videoId: 'firstsong01', title: 'First song'));
    catalog.related.complete(
        const [MusicTrack(videoId: 'secondsong2', title: 'Second song')]);
    await tester.pumpAndSettle();
    expect(current.state.currentlyPlaying, first);
    expect(current.state.playQueue.toList(), [second.videoId]);
    expect(current.state.position, const Duration(seconds: 37));
    expect(current.state.isPlaying, isTrue);
    expect(current.calls, isEmpty);
  });

  testWidgets('preview swipes and buttons supersede stale song requests',
      (tester) async {
    final catalog = useSongOperationCatalog();
    final current = await showSongActions(tester, initial: playingPlaylist());
    await openPreview(tester);
    final seed = catalog.previews.single;
    const related = MusicTrack(
        videoId: 'secondsong2', title: 'Related song', artists: ['Artist']);
    catalog.related.complete(const [
      MusicTrack(videoId: 'firstsong01', title: 'Duplicate seed'),
      MusicTrack(videoId: 'not-online', title: 'Ineligible'),
      related,
      related,
    ]);
    await tester.pump();

    final previous = find.byWidgetPredicate((widget) =>
        widget is IconButton && widget.tooltip == 'Previous preview');
    final next = find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == 'Next preview');
    expect(tester.widget<IconButton>(previous).onPressed, isNull);
    await tester.drag(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.text('First song')),
        const Offset(-160, 0));
    await tester.pump();
    expect(find.text('Related song'), findsOneWidget);
    expect(tester.widget<IconButton>(next).onPressed, isNull);
    final abandoned = catalog.previews.last;
    expect(abandoned.id, related.videoId);
    expect(seed.observer.isCurrent(), isFalse);
    expect(abandoned.observer.isCurrent(), isTrue);

    // A late failure from the first selection must leave the new one loading.
    seed.result.completeError(StateError('Obsolete request'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(previous);
    await tester.pump();
    expect(abandoned.observer.isCurrent(), isFalse);
    expect(catalog.previews.last.id, first.videoId);
    await tester.tap(next);
    await tester.pump();
    expect(catalog.previews.map((request) => request.id),
        [first.videoId, related.videoId, first.videoId, related.videoId]);

    final selected = catalog.previews.last;
    expect(selected.observer.isCurrent(), isTrue);
    selected.result.completeError(StateError('Current request failed'));
    await tester.pumpAndSettle();
    expect(find.text('This song couldn’t be previewed.'), findsOneWidget);
    expect(tester.widget<IconButton>(previous).onPressed, isNotNull);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(current.calls, isEmpty);
    expect(current.state.currentlyPlaying, first);
  });

  testWidgets('an external pause supersedes the preview operation',
      (tester) async {
    final catalog = useSongOperationCatalog();
    final current = await showSongActions(tester, initial: playingPlaylist());
    await openPreview(tester);

    current.pause();
    await tester.pumpAndSettle();
    expect(catalog.previews.single.observer.isCurrent(), isFalse);
    expect(catalog.radioIsCurrent!(), isFalse);
    expect(find.byType(AlertDialog), findsNothing);
    expect(current.requestedPlaying, isFalse);
    expect(current.state.playQueue.toList(), [second.videoId]);
  });

  testWidgets('related radio starts a different occurrence of the same song',
      (tester) async {
    final catalog = useSongOperationCatalog();
    final initial = mountedRadioPlaylist();
    final current = await showSongActions(tester, initial: initial);
    await openRadio(tester);
    expect(catalog.seeds, [first.videoId]);
    expect(catalog.radioIsCurrent!(), isTrue);
    final matches = List.generate(
        9,
        (index) => MusicTrack(
            videoId: 'related000$index',
            title: 'Related $index',
            artists: const ['Artist']));
    catalog.related.complete([
      const MusicTrack(videoId: 'firstsong01', title: 'Seed'),
      matches.first,
      ...matches,
    ]);
    await tester.pumpAndSettle();
    expect(current.calls.single.audio, isTrue);
    expect(current.calls.single.fromMusic, isTrue);
    expect(current.calls.single.startAt, Duration.zero);
    expect(playbackQueueId(current.calls.single.videos.first),
        playbackQueueId(first));
    expect(current.calls.single.videos.map((video) => video.videoId),
        [first.videoId, ...matches.take(6).map((track) => track.videoId)]);
  });

  for (final playing in [true, false]) {
    testWidgets('Now Playing starts radio with playing=$playing at 37 seconds',
        (tester) async {
      final catalog = useSongOperationCatalog();
      final initial = mountedRadioPlaylist(playing: playing);
      final mounted = initial.currentlyPlaying!;
      final current = await showSongActions(tester,
          initial: initial,
          body: (_) => Builder(
              builder: (context) => TextButton(
                  onPressed: () => MusicLibraryActions.showPlayingSongMenu(
                      context, mounted,
                      television: false),
                  child: const Text('Now Playing actions'))));
      final occurrence = current.playbackOccurrenceRevision;
      final positionGeneration = current.playbackPositionGeneration;
      await tester.tap(find.text('Now Playing actions'));
      await tester.pumpAndSettle();
      await openRadio(tester, menuOpen: true);
      expect(catalog.seeds, [mounted.videoId]);
      expect(current.state, same(initial));

      const related = MusicTrack(videoId: 'related0001', title: 'Related');
      catalog.related.complete(const [related]);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(current.calls, isEmpty);
      expect(current.state.currentlyPlaying, same(mounted));
      expect(current.state.currentQueueId, playbackQueueId(mounted));
      expect(current.playbackOccurrenceRevision, occurrence);
      expect(current.playbackPositionGeneration, positionGeneration);
      expect(current.state.position, initial.position);
      expect(current.state.isPlaying, playing);
      expect(current.requestedPlaying, playing);
      expect(current.state.mediaCommand, same(initial.mediaCommand));
      expect(current.state.videos.map(playbackQueueId),
          [playbackQueueId(mounted), related.videoId]);
      expect(current.state.playedVideos, isEmpty);
      expect(current.state.playQueue, [related.videoId]);
      expect(current.musicQueueTitle, 'Radio · First song');
    });
  }

  testWidgets('cancelling related lookup leaves the queue intact',
      (tester) async {
    final catalog = useSongOperationCatalog();
    final initial = mountedRadioPlaylist();
    final current = await showSongActions(tester,
        initial: initial, body: (_) => songRow(initial.currentlyPlaying!));
    await openRadio(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(catalog.radioIsCurrent!(), isFalse);
    catalog.related
        .complete(const [MusicTrack(videoId: 'secondsong2', title: 'Related')]);
    await tester.pumpAndSettle();
    expect(current.calls, isEmpty);
    expect(current.state, same(initial));
  });

  testWidgets('a queue edit prevents the current radio lookup from applying',
      (tester) async {
    final catalog = useSongOperationCatalog();
    final initial = mountedRadioPlaylist();
    final current = await showSongActions(tester,
        initial: initial, body: (_) => songRow(initial.currentlyPlaying!));
    await openRadio(tester);
    expect(catalog.radioIsCurrent!(), isTrue);
    final playlistGeneration = current.playlistGeneration;
    current.playVideoNext(const Video(videoId: 'queuedafter', title: 'Queued'));
    final edited = current.state;
    expect(edited.playQueue, ['queuedafter', second.videoId]);
    expect(current.playlistGeneration, playlistGeneration);

    catalog.related
        .complete(const [MusicTrack(videoId: 'related0001', title: 'Related')]);
    await tester.pumpAndSettle();
    expect(catalog.radioIsCurrent!(), isFalse);
    expect(current.calls, isEmpty);
    expect(current.state, same(edited));
  });

  testWidgets(
      'a profile switch prevents the current radio lookup from applying',
      (tester) async {
    final catalog = useSongOperationCatalog();
    final next =
        (await tester.runAsync(() => db.createProfile('Another person')))!;
    final initial = mountedRadioPlaylist();
    final current = await showSongActions(tester,
        initial: initial, body: (_) => songRow(initial.currentlyPlaying!));
    await openRadio(tester);
    expect(catalog.radioIsCurrent!(), isTrue);

    await tester.runAsync(() async {
      await db.useProfile(next.id);
      app.profileChanged(next.id);
    });
    catalog.related
        .complete(const [MusicTrack(videoId: 'related0001', title: 'Related')]);
    await tester.pumpAndSettle();
    expect(catalog.radioIsCurrent!(), isFalse);
    expect(find.byType(AlertDialog), findsNothing);
    expect(current.calls, isEmpty);
    expect(current.state, same(initial));
  });

  for (final failed in [false, true]) {
    testWidgets(
        'an ${failed ? 'unsuccessful' : 'empty'} current radio lookup '
        'leaves playback alone', (tester) async {
      final catalog = useSongOperationCatalog();
      final initial = mountedRadioPlaylist(playing: false);
      final current = await showSongActions(tester,
          initial: initial, body: (_) => songRow(initial.currentlyPlaying!));
      await openRadio(tester);

      if (failed) {
        catalog.related.completeError(StateError('Lookup unavailable'));
      } else {
        catalog.related.complete(const []);
      }
      await tester.pumpAndSettle();
      expect(
          find.text(failed
              ? 'Related songs couldn’t be loaded.'
              : 'No related songs are available for this song.'),
          findsOneWidget);
      expect(current.calls, isEmpty);
      expect(current.state, same(initial));
    });
  }

  testWidgets('Play full song cancels preview loading and starts Music at zero',
      (tester) async {
    final catalog = useSongOperationCatalog();
    final current = await showSongActions(tester, initial: playingPlaylist());
    await openPreview(tester);

    await tester.tap(find.text('Play full song'));
    await tester.pumpAndSettle();
    final preview = catalog.previews.single;
    expect(preview.observer.isCurrent(), isFalse);
    expect(current.calls.single.videos, [first]);
    expect(current.calls.single.fromMusic, isTrue);
    expect(current.calls.single.audio, isTrue);
    expect(current.calls.single.startAt, Duration.zero);

    preview.result.complete(MusicTrack(
        videoId: first.videoId,
        title: first.musicMetadata!.title,
        playbackVideo: first));
    await tester.pumpAndSettle();
    expect(current.calls, hasLength(1));
  });

  Future<void> verifyPreviewHandoff(
      WidgetTester tester, _HandoffOutcome outcome) async {
    const server = Server(url: 'https://preview.example');
    await tester.runAsync(() async {
      await db.upsertServer(server);
      await db.useServer(server);
    });
    final originalPlatform = JustAudioPlatform.instance;
    final platform = JustAudioPlatform.instance = _PreviewPlatform();
    addTearDown(() {
      if (!platform.release.isCompleted) platform.release.complete();
      JustAudioPlatform.instance = originalPlatform;
    });
    final catalog = useSongOperationCatalog();
    final current = await showSongActions(tester, initial: playingPlaylist());
    current.acknowledgePause = true;
    final originalTransport = current.transportIntentRevision;
    await openPreview(tester);
    catalog.previews.single.result.complete(MusicTrack(
      videoId: first.videoId,
      title: first.musicMetadata!.title,
      playbackVideo: first.copyWith(
        lengthSeconds: 60,
        adaptiveFormats: [
          AdaptiveFormat.fromJson({
            'url': '${server.url}/videoplayback',
            'itag': '140',
            'type': 'audio/mp4',
            'clen': '300000',
            'lmt': '1',
            'projectionType': 'RECTANGULAR',
          }),
        ],
      ),
    ));
    Future<void> pumpUntil(bool Function() condition) async {
      const interval = Duration(milliseconds: 20);
      for (var attempt = 0; attempt < 25 && !condition(); attempt++) {
        await tester.runAsync(() => Future<void>.delayed(interval));
        await tester.pump(interval);
      }
    }

    final playing = find.textContaining('Playing up to 15 seconds');
    await pumpUntil(() => playing.evaluate().isNotEmpty);
    expect(playing, findsOneWidget);
    expect(current.state.isPlaying, isFalse);
    expect(current.transportIntentRevision, originalTransport + 1);

    await tester.tap(find.text('Play full song'));
    await pumpUntil(() => platform.disposing.isCompleted);
    expect(platform.disposing.isCompleted, isTrue);
    expect(current.calls, isEmpty);
    switch (outcome) {
      case _HandoffOutcome.play:
        break;
      case _HandoffOutcome.profileChanged:
        app.profileChanged('other-profile');
      case _HandoffOutcome.cancelled:
        await tester.binding.handlePopRoute();
    }
    await tester.pump();
    platform.release.complete();
    final dialog = find.byType(AlertDialog);
    await pumpUntil(() => dialog.evaluate().isEmpty);
    expect(dialog, findsNothing);
    await tester.pumpAndSettle();
    if (outcome == _HandoffOutcome.play) {
      expect(current.calls.single.videos, [first]);
    } else {
      expect(current.calls, isEmpty);
      expect(current.state.playQueue.toList(), [second.videoId]);
    }
    final cancelled = outcome == _HandoffOutcome.cancelled;
    expect(current.transportIntentRevision,
        originalTransport + (cancelled ? 2 : 1));
    expect(current.requestedPlaying, cancelled);
  }

  testWidgets('Play full song waits for the preview decoder to shut down',
      (tester) => verifyPreviewHandoff(tester, _HandoffOutcome.play));

  testWidgets('Play full song cancels the handoff when the profile changes',
      (tester) => verifyPreviewHandoff(tester, _HandoffOutcome.profileChanged));

  testWidgets('Back cancels Play full song and restores the previous track',
      (tester) => verifyPreviewHandoff(tester, _HandoffOutcome.cancelled));

  testWidgets('Play full song preserves the original row playback queue',
      (tester) async {
    useSongOperationCatalog();
    final current = await showSongActions(tester,
        body: (player) => songRow(second,
            onPlay: () => player.playVideo([first, second],
                startIndex: 1, audio: true, fromMusic: true)));
    await openPreview(tester);

    await tester.tap(find.text('Play full song'));
    await tester.pumpAndSettle();
    expect(current.calls.single.videos, [first, second]);
    expect(current.calls.single.startIndex, 1);
  });

  testWidgets('Play full song opens the selected preview recording',
      (tester) async {
    final catalog = useSongOperationCatalog();
    final current = await showSongActions(tester,
        body: (player) => songRow(first,
            onPlay: () => player.playVideo([first], fromMusic: true)));
    await openPreview(tester);

    catalog.related.complete([
      MusicTrack(
        videoId: second.videoId,
        title: first.musicMetadata!.title,
        artists: const ['Alternate recording'],
      )
    ]);
    await tester.pump();
    await tester.tap(find.byTooltip('Next preview'));
    await tester.pump();
    expect(find.text('Alternate recording'), findsOneWidget);

    await tester.tap(find.text('Play full song'));
    await tester.pumpAndSettle();
    final selected = current.calls.single.videos.single;
    expect(selected.videoId, second.videoId);
    expect(selected.musicMetadata!.artist, 'Alternate recording');
    expect(current.calls.single.startAt, Duration.zero);
  });

  testWidgets('Play full song from Now Playing keeps the active queue',
      (tester) async {
    useSongOperationCatalog();
    final current = await showSongActions(tester,
        initial: playingPlaylist().copyWith(isMini: false),
        body: (_) => Builder(
            builder: (context) => TextButton(
                onPressed: () => MusicLibraryActions.showPlayingSongMenu(
                    context, first,
                    television: false),
                child: const Text('Now Playing actions'))));
    await tester.tap(find.text('Now Playing actions'));
    await tester.pumpAndSettle();
    await openPreview(tester, menuOpen: true);

    await tester.tap(find.text('Play full song'));
    await tester.pumpAndSettle();
    expect(current.calls, isEmpty);
    expect(current.state.position, Duration.zero);
    expect(current.state.currentlyPlaying, first);
    expect(current.state.playQueue.toList(), [second.videoId]);
  });

  testWidgets('playlist selection Play next inserts every occurrence in order',
      (tester) async {
    var completed = 0;
    final source = PlaylistReference(
        kind: PlaylistSourceKind.local,
        playlistId: 'local:selected',
        profileId: db.profileId);
    final current = await showSongActions(tester,
        initial: playingPlaylist(),
        body: (_) => MusicPlaylistSelectionActions(
            videos: const [second, first, second],
            recommendationSource: source,
            onPlay: (_) async => fail('Play next must retain the decoder'),
            onCompleted: () => completed++,
            isCurrent: () => true));
    // Let the real queue checkpoint finish on the database's clock.
    current.enqueueZone = await tester.runAsync(() async => Zone.current);
    await tester.tap(find.byTooltip('Actions for selected songs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play next'));
    await tester.pumpAndSettle();
    // The enqueue result also returns from that zone to the popup callback.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    final state = current.state;
    expect(completed, 1);
    expect(current.enqueuedRecommendationSource, source);
    expect(state.currentlyPlaying, same(first));
    expect(state.position, const Duration(seconds: 37));
    expect(state.isPlaying, isTrue);
    expect(current.calls, isEmpty);
    expect(state.videos.map((song) => song.videoId), [
      first.videoId,
      second.videoId,
      first.videoId,
      second.videoId,
      second.videoId,
    ]);
    expect(state.videos.map(playbackQueueId).toSet(), hasLength(5));
    expect(state.playQueue.toList(), [
      ...state.videos.skip(1).take(3).map(playbackQueueId),
      second.videoId,
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final change in [
    'source selection',
    'queue generation',
    'player owner'
  ]) {
    testWidgets('open playlist Play next rejects a changed $change',
        (tester) async {
      var valid = true;
      var completed = 0;
      final replaced = ValueNotifier(false);
      addTearDown(replaced.dispose);
      late _PlaybackPlayer replacement;
      final current = await showSongActions(tester, initial: playingPlaylist(),
          body: (original) {
        replacement = _PlaybackPlayer(playingPlaylist(), settings!);
        addTearDown(replacement.close);
        return ValueListenableBuilder<bool>(
            valueListenable: replaced,
            builder: (_, switched, child) => BlocProvider<PlayerCubit>.value(
                value: switched ? replacement : original, child: child!),
            child: MusicPlaylistSelectionActions(
                videos: const [second],
                onPlay: (_) async => fail('A stale menu cannot start playback'),
                onCompleted: () => completed++,
                isCurrent: () => valid));
      });
      await tester.tap(find.byTooltip('Actions for selected songs'));
      await tester.pumpAndSettle();
      switch (change) {
        case 'source selection':
          valid = false;
        case 'queue generation':
          // A new queue may contain exactly the same songs and position.
          current.queueReplacements++;
        case 'player owner':
          replaced.value = true;
      }
      await tester.pump();
      await tester.tap(find.text('Play next'));
      await tester.pumpAndSettle();
      expect(completed, 0);
      for (final destination in [current, replacement]) {
        expect(destination.state.videos, [first, second]);
        expect(destination.state.playQueue.toList(), [second.videoId]);
        expect(destination.state.currentlyPlaying, same(first));
        expect(destination.state.position, const Duration(seconds: 37));
        expect(destination.calls, isEmpty);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  Future<_PlaybackPlayer> showDownloadedSong(
      WidgetTester tester, DownloadedVideo video,
      {bool saveSongCover = false}) async {
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = tester.binding.defaultBinaryMessenger;
    final documents = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('videre-download-song-menu-')))!;
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documents.path);
    final thumbnailPath = (await tester.runAsync(() => video.thumbnailPath))!;
    final thumbnailImage = FileImage(File(thumbnailPath));
    FileImage? songCoverImage;

    // File and codec work runs on the real clock. Their UI callbacks still
    // need test frames to show the decoded image or finish a file lookup.
    Future<void> waitForFixture(bool Function() ready, String reason) async {
      await tester.runAsync(() async {
        final elapsed = Stopwatch()..start();
        while (!ready() && elapsed.elapsed < const Duration(seconds: 5)) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          await tester.pump(const Duration(milliseconds: 16));
        }
      });
      expect(ready(), isTrue, reason: reason);
    }

    Future<void> waitForImage(FileImage image) {
      final decoded = find.descendant(
          of: find.image(image),
          matching: find.byWidgetPredicate(
              (widget) => widget is RawImage && widget.image != null));
      return waitForFixture(() => decoded.evaluate().isNotEmpty,
          'The download row must render ${image.file.path}.');
    }

    addTearDown(() async {
      // The visible thumbnail owns a separate file lookup from CompactVideo's
      // cubit. Finish that lookup before disposing the row and its image cache.
      final lookups = tester.widgetList<FutureBuilder<String?>>(
        find.descendant(
          of: find.byType(DownloadedVideoView),
          matching: find.byType(FutureBuilder<String?>),
        ),
      );
      var pending = 0;
      for (final lookup in lookups) {
        if (lookup.future == null) continue;
        pending++;
        unawaited(lookup.future!.then<void>((_) {
          pending--;
        }));
      }
      if (pending != 0) {
        await waitForFixture(() => pending == 0, 'Poster lookups must finish.');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await thumbnailImage.evict();
        await songCoverImage?.evict();
        await documents.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(pathProvider, null);
    });
    await tester.runAsync(() async {
      final image = File('assets/icon.png');
      await image.copy(thumbnailPath);
      if (saveSongCover) {
        final cover = (await video.songCoverFile)!;
        await cover.parent.create(recursive: true);
        await image.copy(cover.path);
        songCoverImage = FileImage(cover);
      }
    });
    final downloads = _Downloads(state: DownloadManagerState(videos: [video]));
    final current = await showSongActions(tester,
        body: (_) => BlocProvider<DownloadManagerCubit>.value(
              value: downloads,
              child: DownloadedVideoView(video: video),
            ));
    final thumbnail = tester
        .element(find.byType(BlocBuilder<CompactVideoCubit, CompactVideoState>))
        .read<CompactVideoCubit>();
    if (video.musicMetadata != null) {
      final artwork = find.byType(MusicPlaybackArtwork);
      expect(artwork, findsOneWidget);
      final lookup = tester.widget<FutureBuilder<File?>>(find.descendant(
          of: artwork, matching: find.byType(FutureBuilder<File?>)));
      var pending = true;
      unawaited(lookup.future!.then<void>((_) {
        pending = false;
      }));
      await waitForFixture(() => !pending, 'Song cover lookup must finish.');
      await tester.pumpAndSettle();
      expect(thumbnail.state.offlineVideoThumbnailPath, isNull);
      expect(find.image(thumbnailImage), findsNothing);
      final cover = songCoverImage;
      if (cover == null) {
        expect(
            find.descendant(
                of: artwork, matching: find.byIcon(Icons.music_note)),
            findsOneWidget);
      } else {
        await waitForImage(cover);
      }
      return current;
    }
    await waitForFixture(
        () => thumbnail.state.offlineVideoThumbnailPath != null,
        'The ordinary video row must resolve its poster.');
    await waitForImage(thumbnailImage);
    return current;
  }

  testWidgets('holding a song offers Play, Play next and Add to queue',
      (tester) async {
    final current = await showSongActions(tester);
    final before = current.state;
    await openSongMenu(tester);
    expect(current.calls, isEmpty,
        reason: 'Holding must open the menu without executing the tap action.');
    expect(current.state.currentQueueId, before.currentQueueId);
    expect(current.state.videos, before.videos);
    expect(current.state.playQueue.toList(), before.playQueue.toList());
    expect(current.state.position, before.position);
    for (final action in ['play', 'play-next', 'add-to-queue']) {
      expect(find.byKey(ValueKey('music-song-$action')), findsOneWidget);
    }
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Play next'), findsOneWidget);
    expect(find.text('Add to queue'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('music-song-play')));
    await tester.pumpAndSettle();
    expect(current.calls, hasLength(1));
    expect(current.calls.single.videos, [first]);
    expect(current.calls.single.audio, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('song menu Likes and Saves stay independent', (tester) async {
    final library = MusicLibraryService.forProfile(db, db.profileId);
    await tester.runAsync(() => library.save(MusicLibraryEntry.song(first)));
    await show(tester, body: const MusicLibraryActions(videos: [first]));
    final menus = find.byTooltip('Music actions');
    await tester.tap(menus);
    await tester.pumpAndSettle();
    final like = find.byKey(const ValueKey('music-song-like'));
    expect(find.text('Like song'), findsOneWidget);
    expect(find.text('Remove saved song'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(like);
      await tester.pumpAndSettle();
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return !library.isLiked(first.videoId);
      }).timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
    await tester.tap(menus);
    await tester.pumpAndSettle();
    expect(find.text('Unlike song'), findsOneWidget);
    expect(find.text('Remove saved song'), findsOneWidget);
  });

  testWidgets('automatic collections use Likes and only Music history',
      (tester) async {
    final session = MusicLibrarySession(app);
    await tester.runAsync(() async {
      await session.setSongLiked(MusicLibraryEntry.song(first), liked: true);
      await session.library.save(MusicLibraryEntry.song(second));
      await db.recordPlaybackHistory(PlaybackHistoryOrigin.music,
          HistoryVideoCache(second.videoId, 'Recent song', 'Artist', ''));
      MusicListeningEvent listen(
              String id, String track, String title, int day) =>
          MusicListeningEvent(
            id: id,
            source: MusicListeningSource.catalog,
            entry: HistoryVideoCache(track, title, 'Artist', '')
              ..created = DateTime.utc(2026, 9, day),
          );
      await MusicListeningHistory.forProfile(db, db.profileId).merge([
        listen('older-play', first.videoId, 'First song', 1),
        listen('another-play', first.videoId, 'First song', 2),
        listen('newest-play', 'thirdsong03', 'Newest event', 3),
      ]);
      await db.recordPlaybackHistory(PlaybackHistoryOrigin.video,
          HistoryVideoCache('watchonly12', 'Video history', 'Artist', ''));
    });
    await show(tester, body: MusicAutomaticCollectionsPage(session: session));
    await tester.tap(find.text('Liked songs'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-automatic-track-firstsong01')),
        findsOneWidget);
    expect(find.text('Second song'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recently played'));
    await tester.pumpAndSettle();
    expect(find.text('Recent song'), findsOneWidget);
    expect(find.text('Video history'), findsNothing);
    expect(find.text('First song'), findsOneWidget);
    expect(find.text('Newest event'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Most played'));
    await tester.pumpAndSettle();
    expect(find.text('Recent song'), findsNothing);
    expect(tester.getTopLeft(find.text('First song')).dy,
        lessThan(tester.getTopLeft(find.text('Newest event')).dy));
  });

  testWidgets('held Play retains the original collection playback callback',
      (tester) async {
    final replacement = ValueNotifier(false);
    addTearDown(replacement.dispose);
    final current = await showSongActions(tester,
        body: (playback) => ValueListenableBuilder<bool>(
              valueListenable: replacement,
              builder: (context, changed, _) => songRow(
                changed ? second : first,
                onPlay: () => playback.playVideo(
                  changed ? [second, first] : [first, second],
                  audio: true,
                  startIndex: 0,
                ),
              ),
            ));
    await openSongMenu(tester);
    replacement.value = true;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-song-play')));
    await tester.pumpAndSettle();
    expect(current.calls, hasLength(1));
    expect(current.calls.single.videos, [first, second]);
    expect(current.calls.single.audio, isTrue);
    expect(current.calls.single.startIndex, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final audio in [true, false]) {
    for (final next in [true, false]) {
      testWidgets(
          'held ${next ? 'Play next' : 'Add to queue'} preserves current occurrence and duplicates in ${audio ? 'audio' : 'video'} mode',
          (tester) async {
        final entries = assignPlaybackQueueIds([first, second, first]);
        final originalIds = entries.map(playbackQueueId).toList();
        final upcoming = originalIds.skip(1).toList();
        const position = Duration(seconds: 37);
        final replacement = ValueNotifier(false);
        addTearDown(replacement.dispose);
        final current = await showSongActions(tester,
            initial: PlayerState.init(null).copyWith(
              isAudio: audio,
              isHidden: false,
              isPlaying: true,
              currentlyPlaying: entries.first,
              videos: entries,
              playQueue: ListQueue.of(upcoming),
              position: position,
            ),
            body: (_) => ValueListenableBuilder<bool>(
                  valueListenable: replacement,
                  builder: (context, changed, _) =>
                      songRow(changed ? second : first),
                ));
        await openSongMenu(tester);
        expect(current.calls, isEmpty,
            reason: 'A long press must not interrupt the active recording.');
        expect(current.state.currentQueueId, originalIds.first);
        expect(current.state.videos, entries);
        expect(current.state.playQueue.toList(), upcoming);
        expect(current.state.position, position);
        expect(current.state.isPlaying, isTrue);
        expect(current.state.isAudio, audio);
        replacement.value = true;
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey(
            next ? 'music-song-play-next' : 'music-song-add-to-queue')));
        await tester.pumpAndSettle();

        final state = current.state;
        final inserted = state.videos.singleWhere(
            (video) => !originalIds.contains(playbackQueueId(video)));
        expect(current.calls, isEmpty);
        expect(inserted.videoId, first.videoId);
        expect(state.videos.map(playbackQueueId).toSet(), hasLength(4));
        expect(state.videos.where((video) => video.videoId == first.videoId),
            hasLength(3));
        expect(state.currentQueueId, originalIds.first);
        expect(state.currentlyPlaying, same(entries.first));
        expect(state.position, position);
        expect(state.isPlaying, isTrue);
        expect(state.isAudio, audio);
        expect(
            state.playQueue.toList(),
            next
                ? [playbackQueueId(inserted), ...upcoming]
                : [...upcoming, playbackQueueId(inserted)]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final next in [true, false]) {
    testWidgets(
        'held ${next ? 'Play next' : 'Add to queue'} starts audio when playback is idle',
        (tester) async {
      final initial = PlayerState.init(null);
      final source = PlaylistReference(
          kind: PlaylistSourceKind.public,
          playlistId: 'PLpublic',
          profileId: db.profileId);
      final current = await showSongActions(tester,
          initial: initial,
          body: (_) => songRow(first, recommendationSource: source));
      await openSongMenu(tester);
      await tester.tap(find.byKey(
          ValueKey(next ? 'music-song-play-next' : 'music-song-add-to-queue')));
      await tester.pumpAndSettle();
      expect(current.calls, hasLength(1));
      expect(current.calls.single.videos, [first]);
      expect(current.calls.single.audio, isTrue);
      expect(current.playedRecommendationSource, source);
      // The fake only records a fresh launch. An idle queue has no active
      // decoder or occurrence that needs to be retained.
      expect(current.state.videos, initial.videos);
      expect(current.state.offlineVideos, initial.offlineVideos);
      expect(current.state.position, initial.position);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final next in [true, false]) {
    for (final active in [false, true]) {
      final label = next ? 'Play next' : 'Add to queue';
      testWidgets(
          'download $label resolves a removed or replaced file with ${active ? 'an offline queue' : 'an idle player'}',
          (tester) async {
        final saved = DownloadedVideo(
            videoId: first.videoId,
            title: 'Saved file',
            profileId: db.profileId,
            lengthSeconds: 60,
            quality: 'best',
            downloadComplete: true,
            audioOnly: true,
            musicMetadata: first.musicMetadata,
            storageUri: 'content://music/original');
        final replacement = saved.copyWith(storageUri: 'content://music/new');
        final playing = saved.copyWith(videoId: second.videoId);
        final tail = saved.copyWith(videoId: 'later-file');
        await tester.runAsync(() => db.upsertDownload(saved));
        final initial = PlayerState.init(null);
        final current = await showSongActions(tester,
            initial: active
                ? initial.copyWith(
                    isAudio: true,
                    isHidden: false,
                    isPlaying: true,
                    offlineCurrentlyPlaying: playing,
                    offlineVideos: [playing, tail],
                    playQueue: ListQueue.of([tail.videoId]),
                    position: const Duration(seconds: 21))
                : initial,
            body: (_) => Builder(builder: (context) {
                  return TextButton(
                      onPressed: () => MusicLibraryActions.showSongMenu(
                          context, first,
                          downloads: [saved],
                          resolveDownload: () =>
                              db.getDownloadByVideoId(first.videoId)),
                      child: const Text('Song actions'));
                }));
        if (active) {
          current.enqueueZone = await tester.runAsync(() async => Zone.current);
        }
        Future<void> open() async {
          await tester.tap(find.text('Song actions'));
          await tester.pumpAndSettle();
        }

        await open();
        await tester.runAsync(() => db.deleteDownload(saved));
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(current.offlineCalls, isEmpty);
        expect(current.state.offlineVideos, active ? [playing, tail] : isEmpty);

        await tester.runAsync(() => db.upsertDownload(saved));
        await open();
        await tester.runAsync(() => db.upsertDownload(replacement));
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(current.calls, isEmpty);
        if (active) {
          expect(current.offlineCalls, isEmpty);
          final offline = current.state.offlineVideos;
          expect(
              offline.map((v) => v.videoId),
              next
                  ? [playing.videoId, replacement.videoId, tail.videoId]
                  : [playing.videoId, tail.videoId, replacement.videoId]);
          expect(offline[next ? 1 : 2].storageUri, replacement.storageUri);
          expect(current.state.offlineCurrentlyPlaying, same(playing));
          expect(current.state.position, const Duration(seconds: 21));
        } else {
          final selected = current.offlineCalls.single.single;
          expect(selected.videoId, replacement.videoId);
          expect(selected.storageUri, replacement.storageUri);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final dismissal in ['Back', 'outside']) {
    testWidgets('held song menu $dismissal dismissal preserves playback',
        (tester) async {
      const position = Duration(seconds: 41);
      final before = PlayerState.init(null).copyWith(
        isAudio: true,
        isHidden: false,
        isPlaying: true,
        currentlyPlaying: second,
        videos: [second, first],
        playQueue: ListQueue.of([first.videoId]),
        position: position,
      );
      final current = await showSongActions(tester, initial: before);
      await openSongMenu(tester);
      expect(find.byKey(const ValueKey('music-song-play')), findsOneWidget);
      expect(current.calls, isEmpty);
      expect(current.state.currentQueueId, second.videoId);
      expect(current.state.videos, before.videos);
      expect(current.state.playQueue.toList(), [first.videoId]);
      expect(current.state.position, position);

      if (dismissal == 'Back') {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tapAt(
            tester.getBottomRight(find.byType(Scaffold)) - const Offset(2, 2));
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('music-song-play')), findsNothing);
      expect(current.calls, isEmpty);
      expect(current.state.currentQueueId, second.videoId);
      expect(current.state.currentlyPlaying, same(second));
      expect(current.state.videos, before.videos);
      expect(current.state.playQueue.toList(), [first.videoId]);
      expect(current.state.position, position);
      expect(current.state.isPlaying, isTrue);
      expect(current.state.isAudio, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
      'recommendation row hold selects and overflow still opens song actions',
      (tester) async {
    const tracks = [
      MusicTrack(
          videoId: 'firstsong01', title: 'First song', artists: ['Artist']),
      MusicTrack(
          videoId: 'secondsong2', title: 'Second song', artists: ['Artist']),
    ];
    final changes = ValueNotifier(0);
    addTearDown(changes.dispose);
    const position = Duration(seconds: 17);
    final current = await showSongActions(tester,
        initial: PlayerState.init(null).copyWith(
          isAudio: true,
          isHidden: false,
          currentlyPlaying: first,
          videos: [first],
          position: position,
        ),
        body: (_) => MusicRecommendationCollection(
              title: 'Recommended collection',
              tracks: tracks,
              isCurrent: () => true,
              eligible: (songs) => songs.toList(),
              changes: changes,
            ));
    final row = find.byKey(const ValueKey('music-collection-secondsong2'));
    await tester.ensureVisible(row);
    await tester.longPress(row);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('1 selected'), findsOneWidget);
    expect(current.calls, isEmpty);
    expect(current.state.position, position);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('Music actions')));
    await tester.pumpAndSettle();
    for (final action in ['play', 'play-next', 'add-to-queue']) {
      expect(find.byKey(ValueKey('music-song-$action')), findsOneWidget);
    }
    expect(current.calls, isEmpty);
    expect(current.offlineCalls, isEmpty);
    expect(current.state.currentlyPlaying, same(first));
    expect(current.state.videos, [first]);
    expect(current.state.position, position);

    await tester.tap(find.byKey(const ValueKey('music-song-play')));
    await tester.pumpAndSettle();
    expect(current.calls, hasLength(1));
    expect(current.calls.single.videos.map((song) => song.videoId),
        tracks.map((track) => track.videoId));
    expect(current.calls.single.audio, isTrue);
    expect(current.calls.single.startIndex, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final withMetadata in [false, true]) {
    testWidgets(
        'downloaded audio hold opens song actions without playing, metadata: $withMetadata',
        (tester) async {
      final saved = DownloadedVideo(
          videoId: 'saved-audio',
          title: 'Saved audio',
          author: 'Saved artist',
          lengthSeconds: 180,
          quality: 'audio',
          audioOnly: true,
          downloadComplete: true,
          storageUri: 'content://fixture/saved-audio',
          musicMetadata: withMetadata
              ? const MusicMetadata(
                  title: 'Saved audio', artist: 'Saved artist')
              : null);
      final current = await showDownloadedSong(tester, saved);
      final row = find.byType(CompactVideo);
      expect(tester.widget<CompactVideo>(row).onLongPress, isNotNull);
      await tester.longPress(row);
      await tester.pumpAndSettle();
      for (final action in ['play', 'play-next', 'add-to-queue']) {
        expect(find.byKey(ValueKey('music-song-$action')), findsOneWidget);
      }
      expect(current.calls, isEmpty);
      expect(current.offlineCalls, isEmpty,
          reason: 'Holding the saved row must not execute its normal tap.');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      // Download management remains reachable separately from song playback.
      await tester.tap(find.byTooltip('Downloads'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Delete'), findsOneWidget);
      expect(current.offlineCalls, isEmpty);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await tester.longPress(row);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('music-song-play')));
      await tester.pumpAndSettle();
      expect(current.calls, isEmpty);
      expect(current.offlineCalls, hasLength(1));
      expect(current.offlineCalls.single, [saved]);
      expect(current.offlineCalls.single.single, same(saved));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a completed Music download displays its local song cover',
      (tester) async {
    await showDownloadedSong(
        tester,
        DownloadedVideo(
            videoId: 'saved-audio',
            title: 'Saved audio',
            accountId: 'catalog-account',
            lengthSeconds: 180,
            quality: 'audio',
            audioOnly: true,
            downloadComplete: true,
            musicMetadata:
                MusicMetadata(title: 'Song', artist: 'Artist', thumbnails: [
              ImageObject(
                  null, 'https://lh3.googleusercontent.com/cover', 512, 512),
            ])),
        saveSongCover: true);
  });

  for (final (complete, audioOnly) in [
    (false, true),
    (true, false),
    (false, false),
  ]) {
    testWidgets(
        'download row retains its existing hold behavior, complete: $complete, audio: $audioOnly',
        (tester) async {
      final saved = DownloadedVideo(
          videoId: 'ordinary-download',
          title: 'Ordinary download',
          lengthSeconds: 180,
          quality: '720p',
          audioOnly: audioOnly,
          downloadComplete: complete,
          storageUri: 'content://fixture/ordinary-download');
      final current = await showDownloadedSong(tester, saved);
      expect(tester.widget<CompactVideo>(find.byType(CompactVideo)).onLongPress,
          isNull);
      expect(find.byKey(const ValueKey('music-song-play')), findsNothing);
      expect(current.calls, isEmpty);
      expect(current.offlineCalls, isEmpty);
      await tester.tap(find.byTooltip('Downloads'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Delete'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('mounted song actions update after another control saves it',
      (tester) async {
    final library = MusicLibraryService.forProfile(db, db.profileId);
    await show(tester,
        body: const Column(children: [
          MusicLibraryActions(videos: [first], compact: false),
          MusicLibraryActions(videos: [first], compact: false),
        ]));
    expect(find.text('Save song'), findsNWidgets(2));
    await tester.runAsync(() async {
      await tester.tap(find.text('Save song').first);
      await Future.doWhile(() async {
        await tester.pump();
        if (library.contains(MusicLibraryKind.song, first.videoId)) {
          return false;
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return true;
      }).timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
    expect(find.text('Save song'), findsNothing);
    expect(find.text('Remove saved song'), findsNWidgets(2));
  });

  for (final initiallySaved in [false, true]) {
    testWidgets(
        'open song menu preserves its displayed action when saved state changes '
        '(initially saved: $initiallySaved)', (tester) async {
      final library = MusicLibraryService.forProfile(db, db.profileId);
      final entry = MusicLibraryEntry.song(first);
      if (initiallySaved) {
        await tester.runAsync(() => library.save(entry));
      }
      await show(tester, body: const MusicLibraryActions(videos: [first]));
      await tester.tap(find.byTooltip('Music actions'));
      await tester.pumpAndSettle();
      final action = initiallySaved ? 'Remove saved song' : 'Save song';
      expect(find.text(action), findsOneWidget);

      // Another screen can change the same bookmark while this menu is open.
      await tester.runAsync(() => initiallySaved
          ? library.remove(entry.kind, entry.id)
          : library.save(entry));
      await tester.pumpAndSettle();
      expect(find.text(action), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
        await Future.doWhile(() async {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          await tester.pump();
          final button = tester.widget<PopupMenuButton<dynamic>>(
              find.byWidgetPredicate((widget) => widget is PopupMenuButton));
          return !button.enabled;
        }).timeout(const Duration(seconds: 5));
      });
      await tester.pumpAndSettle();
      expect(library.contains(entry.kind, entry.id), !initiallySaved);
    });
  }

  for (final action in ['Save song', 'Save to playlist', 'Download audio']) {
    testWidgets('open $action menu keeps the track it was opened for',
        (tester) async {
      final videos = ValueNotifier<List<Video>>([first]);
      addTearDown(videos.dispose);
      final downloads = _Downloads();
      final library = MusicLibraryService.forProfile(db, db.profileId);
      if (action == 'Download audio') {
        await tester.runAsync(() => MusicDownloadFormat.opus.save(db));
      }
      await show(tester,
          body: BlocProvider<DownloadManagerCubit>.value(
            value: downloads,
            child: ValueListenableBuilder<List<Video>>(
              valueListenable: videos,
              builder: (context, value, _) =>
                  MusicLibraryActions(videos: value),
            ),
          ));
      await tester.tap(find.byTooltip('Music actions'));
      await tester.pumpAndSettle();

      // A media notification or incoming link can change the player track.
      videos.value = [second];
      await tester.pumpAndSettle();
      expect(find.text(action), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
        if (action == 'Save to playlist') {
          expect(find.text('Watch Later'), findsOneWidget);
          await tester.tap(find.text('Watch Later'));
        }
        if (action == 'Download audio') {
          await tester.tap(find.byType(DropdownButton<MusicOfflineQuality>));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Data saver').hitTestable().last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Download on Wi-Fi only'));
          await tester.pumpAndSettle();
          await tester.tap(find.byType(DropdownButton<int>));
          await tester.pumpAndSettle();
          await tester.tap(find.text('M4A (AAC)').hitTestable().last);
          await tester.pumpAndSettle();
          expect(find.text('Save as Opus'), findsOneWidget);
          await tester.tap(find.text('Download'));
          await tester.pumpAndSettle();
        }
        await Future.doWhile(() async {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          await tester.pump();
          final button = tester.widget<PopupMenuButton<dynamic>>(
              find.byWidgetPredicate((widget) => widget is PopupMenuButton));
          return !button.enabled;
        }).timeout(const Duration(seconds: 5));
      });
      await tester.pumpAndSettle();

      if (action == 'Save song') {
        expect(library.entries.map((entry) => entry.id), [first.videoId]);
      } else if (action == 'Save to playlist') {
        expect(
            service
                .getLocalPlaylists()
                .first
                .videos
                .map((video) => video.videoId),
            [first.videoId]);
      } else {
        expect(downloads.calls.map((call) => call.id), [first.videoId]);
        expect(downloads.calls.single.container, DownloadContainer.mp4);
        expect(downloads.calls.single.quality, highestAudioDownloadQuality);
        expect(
            downloads.calls.single.musicPolicy,
            const MusicOfflinePolicy(
                quality: MusicOfflineQuality.dataSaver, wifiOnly: true));
      }
    });
  }

  testWidgets('open remove menu keeps its original local playlist and song',
      (tester) async {
    await tester.runAsync(() async {
      final session = MusicLibrarySession(app);
      await session.createPlaylist('First list', [first, second]);
      await session.createPlaylist('Second list', [first, second]);
    });
    final playlists = service.getLocalPlaylists();
    final firstList =
        playlists.singleWhere((playlist) => playlist.title == 'First list');
    final secondList =
        playlists.singleWhere((playlist) => playlist.title == 'Second list');
    final firstId = firstList.playlistId;
    final secondId = secondList.playlistId;
    final target =
        ValueNotifier((playlistId: firstId, video: firstList.videos.first));
    addTearDown(target.dispose);
    await show(tester,
        body: ValueListenableBuilder<({String playlistId, Video video})>(
            valueListenable: target,
            builder: (context, value, _) => MusicLibraryActions(
                videos: [value.video], localPlaylistId: value.playlistId)));
    await tester.tap(find.byTooltip('Music actions'));
    await tester.pumpAndSettle();
    target.value = (playlistId: secondId, video: secondList.videos.last);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Remove from playlist'));
      await tester.pumpAndSettle();
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return service
                .getLocalPlaylists()
                .singleWhere(
                  (playlist) => playlist.playlistId == firstId,
                )
                .videos
                .length !=
            1;
      }).timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
    final remaining = service.getLocalPlaylists();
    expect(
        remaining
            .singleWhere((playlist) => playlist.playlistId == firstId)
            .videos
            .map((video) => video.videoId),
        [second.videoId]);
    expect(
        remaining
            .singleWhere((playlist) => playlist.playlistId == secondId)
            .videos
            .map((video) => video.videoId),
        [first.videoId, second.videoId]);
  });

  Future<void> waitForSaveFlow(
    WidgetTester tester,
    bool Function() ready,
    String description,
  ) async {
    const timeout = Duration(seconds: 5);
    final elapsed = Stopwatch()..start();
    // Let the real database queue progress between fake-clock frames.
    while (!ready() && elapsed.elapsed < timeout) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)));
    }
    expect(ready(), isTrue, reason: '$description did not finish in $timeout');
  }

  Future<void> saveAndWait(
      WidgetTester tester, Finder choice, bool Function() saved) async {
    const timeout = Duration(seconds: 5);
    final dialog = find.byType(AlertDialog);
    await tester.runAsync(() => tester.tap(choice));
    await waitForSaveFlow(
        tester, () => saved() && dialog.evaluate().isEmpty, 'Playlist save');
    expect(dialog, findsNothing);
    await tester.pumpAndSettle(const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate, timeout);
  }

  Playlist storedPlaylist(String id) =>
      service.getLocalPlaylists().singleWhere((item) => item.playlistId == id);

  Finder membershipRow(String id) =>
      find.byKey(ValueKey(('music-playlist-membership', id)));

  testWidgets(
      'adding selected downloads pins the exact file in a catalog queue',
      (tester) async {
    final file = DownloadedVideo(
        videoId: second.videoId,
        title: second.title!,
        profileId: db.profileId,
        lengthSeconds: 90,
        quality: 'best',
        downloadComplete: true,
        audioOnly: true,
        musicMetadata: second.musicMetadata);
    await tester.runAsync(() => db.upsertDownload(file));
    final fingerprint = musicDownloadFileFingerprint(file, 'a0' * 32)!;
    var completed = 0;
    final current = await showSongActions(tester,
        initial: playingPlaylist(),
        body: (_) => MusicSongSelectionBar(
            selected: [second.copyWith(explicitMusicDownload: fingerprint)],
            allSelected: false,
            onToggleAll: null,
            onClose: () => completed++,
            isCurrent: () => true,
            resolveDownloads: (_) => [file]));
    current.enqueueZone = await tester.runAsync(() async => Zone.current);
    final actions = find.byTooltip('Actions for selected songs');
    await tester.tap(actions);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to queue'));
    await waitForSaveFlow(tester, () => completed == 1, 'Queue insertion');
    final state = current.state;
    expect(state.videos, hasLength(3));
    final added = state.videos.last;
    expect(added.videoId, second.videoId);
    expect(added.explicitMusicDownload, fingerprint);
    expect(state.playQueue, [second.videoId, playbackQueueId(added)]);
    expect(state.currentlyPlaying, same(first));
    expect(state.position, const Duration(seconds: 37));
    expect(current.calls, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Future<void> openMembershipEditor(WidgetTester tester) async {
    await showSongActions(tester);
    await openSongMenu(tester);
    await tester.tap(find.text('Manage song playlists'));
    await tester.pumpAndSettle();
  }

  Future<void> applyMemberships(WidgetTester tester, String message) async {
    await tester.runAsync(() async {
      await tester.tap(find.text('Apply changes'));
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        await tester.pump();
        return find.text(message).evaluate().isEmpty;
      }).timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
    expect(find.text(message), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  }

  testWidgets(
      'song actions edit several memberships and preserve unselected copies',
      (tester) async {
    final ids = (await tester.runAsync(() async => (
          remove: (await service.createLocalPlaylistWithEntries(
              'Remove from here', [first, second, first]))!,
          add: (await service
              .createLocalPlaylistWithEntries('Add here', [second]))!,
          keep: (await service
              .createLocalPlaylistWithEntries('Leave as is', [first, first]))!,
        )))!;
    final removeBefore = storedPlaylist(ids.remove);
    final addBefore = storedPlaylist(ids.add);
    final keepBefore = storedPlaylist(ids.keep);
    await openMembershipEditor(tester);

    expect(find.text('3 songs · 2 copies of this song'), findsOneWidget);
    expect(find.text('1 song · No copies of this song'), findsOneWidget);
    expect(
      find.text(
          'Checking a playlist adds one copy. Unchecking it removes every copy of this song.'),
      findsOneWidget,
    );
    expect(
        tester.widget<CheckboxListTile>(membershipRow(ids.remove)).value, true);
    expect(
        tester.widget<CheckboxListTile>(membershipRow(ids.add)).value, false);

    await tester.tap(membershipRow(ids.keep));
    await tester.pumpAndSettle();
    await tester.tap(membershipRow(ids.keep));
    await tester.pumpAndSettle();
    final apply = find.widgetWithText(FilledButton, 'Apply changes');
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);

    await tester.tap(membershipRow(ids.remove));
    await tester.pumpAndSettle();
    await tester.tap(membershipRow(ids.add));
    await tester.pumpAndSettle();
    await applyMemberships(tester, 'Updated 2 playlists.');

    final removed = storedPlaylist(ids.remove);
    expect(jsonEncode(removed.videos), jsonEncode([removeBefore.videos[1]]));
    expect(removed.videoCount, 1);
    final added = storedPlaylist(ids.add);
    expect(added.videos.map((video) => video.videoId),
        [second.videoId, first.videoId]);
    expect(jsonEncode(added.videos.first), jsonEncode(addBefore.videos.single));
    expect(added.videos.last.indexId, isNotNull);
    expect(added.videoCount, 2);
    expect(jsonEncode(storedPlaylist(ids.keep)), jsonEncode(keepBefore));
  });

  testWidgets('membership apply reports playlists locked or deleted meanwhile',
      (tester) async {
    final ids = (await tester.runAsync(() async => (
          locked: (await service
              .createLocalPlaylistWithEntries('Could be locked', [first]))!,
          deleted: (await service
              .createLocalPlaylistWithEntries('Could be deleted', []))!,
          available: (await service
              .createLocalPlaylistWithEntries('Available list', [second]))!,
        )))!;
    final availableBefore = storedPlaylist(ids.available);
    await openMembershipEditor(tester);
    for (final id in [ids.locked, ids.deleted, ids.available]) {
      await tester.tap(membershipRow(id));
      await tester.pumpAndSettle();
    }

    await tester.runAsync(() async {
      final locked =
          PlaylistReference.forPlaylist(storedPlaylist(ids.locked), db);
      expect(
          await service.setLocalPlaylistEditLocked(locked,
              locked: true, isCurrent: () => true),
          isTrue);
      await service.deleteUserPlaylist(ids.deleted);
    });
    final lockedBefore = storedPlaylist(ids.locked);

    await applyMemberships(
        tester,
        'Updated 1 playlist.\n'
        'Could not update 2 playlists because they were locked or unavailable.');

    expect(jsonEncode(storedPlaylist(ids.locked)), jsonEncode(lockedBefore));
    expect(service.getLocalPlaylists().map((playlist) => playlist.playlistId),
        isNot(contains(ids.deleted)));
    final available = storedPlaylist(ids.available);
    expect(jsonEncode(available.videos.first),
        jsonEncode(availableBefore.videos.single));
    expect(available.videos.last.videoId, first.videoId);
  });

  testWidgets('profile switch discards a drafted song membership',
      (tester) async {
    final profileId = db.profileId;
    await openMembershipEditor(tester);
    await tester.tap(membershipRow(localWatchLaterId));
    await tester.pumpAndSettle();
    final next =
        (await tester.runAsync(() => db.createProfile('Another person')))!;
    await tester.runAsync(() => db.useProfile(next.id));
    app.profileChanged(next.id);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(storedPlaylist(localWatchLaterId).videos, isEmpty);
    expect(
        service
            .getLocalPlaylists(database: db.forProfile(profileId))
            .single
            .videos,
        isEmpty);
  });

  testWidgets(
    'skip duplicates appends only new songs to a partly matching destination',
    (tester) async {
      await tester.runAsync(
        () => service.addVideoToPlaylist(
          localWatchLaterId,
          first.videoId,
          video: first,
        ),
      );
      await show(tester);
      await tester.tap(find.text('Save to playlist'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('Watch Later')));
      await tester.pumpAndSettle();
      expect(find.text('Duplicate songs'), findsOneWidget);
      await saveAndWait(tester, find.text('Skip duplicates'),
          () => service.getLocalPlaylists().first.videos.length == 2);
      expect(
        service.getLocalPlaylists().first.videos.map((video) => video.videoId),
        [first.videoId, second.videoId],
      );
    },
  );

  testWidgets(
    'destinations show song counts and move latest edits to the top',
    (tester) async {
      const older = Playlist(
        title: 'Older list',
        playlistId: 'local:older',
        author: '',
        videoCount: 1,
        updated: 12,
        videos: [first],
      );
      const newer = Playlist(
        title: 'Newer list',
        playlistId: 'local:newer',
        author: '',
        videoCount: 2,
        updated: 24,
        videos: [first, second],
      );
      await tester.runAsync(
        () => db.saveSetting(
          SettingsValue(
            localPlaylistsSetting,
            jsonEncode([older.toJson(), newer.toJson()]),
          ),
        ),
      );
      await show(tester,
          body: const MusicLibraryActions(videos: [second], compact: false));
      final save = find.text('Save to playlist');
      final olderTitle = find.text('Older list');
      final newerTitle = find.text('Newer list');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('0 songs'), findsOneWidget);
      expect(find.text('1 song'), findsOneWidget);
      expect(find.text('2 songs'), findsOneWidget);
      expect(
        tester.getTopLeft(newerTitle).dy,
        lessThan(tester.getTopLeft(olderTitle).dy),
      );

      await saveAndWait(
        tester,
        olderTitle,
        () =>
            service
                .getLocalPlaylists()
                .singleWhere(
                    (playlist) => playlist.playlistId == older.playlistId)
                .videos
                .length ==
            2,
      );
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('2 songs'), findsNWidgets(2));
      expect(
        tester.getTopLeft(olderTitle).dy,
        lessThan(tester.getTopLeft(newerTitle).dy),
      );
    },
  );

  testWidgets(
    'an all-duplicate selection can cancel, skip or add a new entry',
    (tester) async {
      await tester.runAsync(
        () => service.addVideoToPlaylist(
          localWatchLaterId,
          first.videoId,
          video: first,
        ),
      );
      Playlist watchLater() => service.getLocalPlaylists().first;
      final original = watchLater();
      final storedPlaylists = db.getSettings(localPlaylistsSetting)?.value;
      await show(tester,
          body: const MusicLibraryActions(videos: [first], compact: false));
      final save = find.text('Save to playlist');
      final destination = find.text('Watch Later');
      final destinationRow =
          find.ancestor(of: destination, matching: find.byType(ListTile));

      Future<void> chooseDestination() async {
        await tester.runAsync(() => tester.tap(destination));
        await tester.pumpAndSettle();
        expect(find.text('Duplicate songs').hitTestable(), findsOneWidget);
      }

      await tester.tap(save);
      await tester.pumpAndSettle();
      await chooseDestination();
      await tester.tap(find.text('Cancel').hitTestable());
      await waitForSaveFlow(
          tester,
          () => tester
              .widgetList<ListTile>(destinationRow)
              .any((row) => row.enabled),
          'Duplicate confirmation cancellation');
      await tester.pumpAndSettle();
      expect(destination.hitTestable(), findsOneWidget);
      expect(db.getSettings(localPlaylistsSetting)?.value, storedPlaylists);

      await chooseDestination();
      final unchangedMessage = find.text('No songs added');
      await saveAndWait(tester, find.text('Skip duplicates'),
          () => unchangedMessage.evaluate().isNotEmpty);
      expect(unchangedMessage, findsOneWidget);
      expect(db.getSettings(localPlaylistsSetting)?.value, storedPlaylists);

      await tester.tap(save);
      await tester.pumpAndSettle();
      await chooseDestination();
      await saveAndWait(tester, find.text('Add anyway'),
          () => watchLater().videos.length == 2);
      final entries = watchLater().videos;
      expect(entries.map((video) => video.videoId), [
        first.videoId,
        first.videoId,
      ]);
      expect(jsonEncode(entries.first), jsonEncode(original.videos.single));
      expect(playbackQueueId(entries.first),
          playbackQueueId(original.videos.single));
      expect(entries.last.indexId, isNotEmpty);
      expect(entries.last.indexId, isNot(entries.first.indexId));
    },
  );

  testWidgets(
    'playlist picker sorts by track count and recent update with stable ties',
    (tester) async {
      const largest = Playlist(
        title: 'Larger list',
        playlistId: 'local:larger',
        author: '',
        videoCount: 2,
        updated: 12,
        videos: [first, second],
      );
      const newest = Playlist(
        title: 'Recent list',
        playlistId: 'local:recent',
        author: '',
        videoCount: 1,
        updated: 24,
        videos: [first],
      );
      final locked = largest.copyWith(
        title: 'Locked list',
        playlistId: 'local:locked',
        updated: newest.updated,
        localEditLocked: true,
      );
      await tester.runAsync(
        () => db.saveSetting(
          SettingsValue(
            localPlaylistsSetting,
            jsonEncode([largest.toJson(), newest.toJson(), locked.toJson()]),
          ),
        ),
      );
      await show(
        tester,
        body: const MusicLibraryActions(videos: [second], compact: false),
      );
      await tester.tap(find.text('Save to playlist'));
      await tester.pumpAndSettle();

      final recentSort = find.widgetWithText(ChoiceChip, 'Recently updated');
      final countSort = find.widgetWithText(ChoiceChip, 'Track count');
      final rows = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(ListTile),
      );
      Iterable<String?> titles() => tester
          .widgetList<ListTile>(rows)
          .map((tile) => (tile.title as Text).data);

      expect(tester.widget<ChoiceChip>(recentSort).selected, isTrue);
      expect(titles(),
          ['Recent list', 'Locked list', 'Larger list', 'Watch Later']);

      await tester.tap(countSort);
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(countSort).selected, isTrue);
      expect(titles(),
          ['Larger list', 'Locked list', 'Recent list', 'Watch Later']);
      expect(find.widgetWithText(ListTile, '2 songs'), findsOneWidget);
      expect(find.widgetWithText(ListTile, '1 song'), findsOneWidget);
      expect(find.widgetWithText(ListTile, '0 songs'), findsOneWidget);
      final lockedRow = find.widgetWithText(ListTile, 'Locked list');
      expect(tester.widget<ListTile>(lockedRow).enabled, isFalse);
      await tester.tap(lockedRow);
      await tester.pumpAndSettle();
      expect(find.text('Duplicate songs'), findsNothing);

      await tester.tap(find.text('Larger list'));
      await tester.pumpAndSettle();
      expect(find.text('Duplicate songs'), findsOneWidget);
      await tester.tap(find.text('Cancel').hitTestable());
      await waitForSaveFlow(
        tester,
        () => tester
            .widgetList<ChoiceChip>(recentSort)
            .any((chip) => chip.onSelected != null),
        'Playlist destination sort after duplicate review',
      );
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(countSort).selected, isTrue);

      await tester.tap(recentSort.hitTestable());
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(recentSort).selected, isTrue);
      expect(titles(),
          ['Recent list', 'Locked list', 'Larger list', 'Watch Later']);
    },
  );

  testWidgets('new destinations can keep repeated songs in selection order', (
    tester,
  ) async {
    await show(
      tester,
      body: const MusicLibraryActions(
          videos: [second, first, second], compact: false),
    );
    await tester.tap(find.text('Save to playlist'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create new playlist'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Repeated songs');
    final add = find.widgetWithText(TextButton, 'Add');
    await tester.runAsync(() => tester.tap(add));
    await tester.pumpAndSettle();
    expect(find.text('Duplicate songs').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Cancel').hitTestable());
    await waitForSaveFlow(
        tester,
        () =>
            tester.widgetList<TextButton>(add).any((button) => button.enabled),
        'Duplicate confirmation cancellation');
    await tester.pumpAndSettle();
    expect(find.text('Repeated songs'), findsOneWidget);
    expect(service.getLocalPlaylists(), hasLength(1));

    await tester.runAsync(() => tester.tap(add));
    await tester.pumpAndSettle();
    expect(find.text('Duplicate songs').hitTestable(), findsOneWidget);
    Playlist? created() => service
        .getLocalPlaylists()
        .where((playlist) => playlist.title == 'Repeated songs')
        .firstOrNull;
    await saveAndWait(
        tester, find.text('Add anyway'), () => created()?.videos.length == 3);
    final entries = created()!.videos;
    expect(entries.map((video) => video.videoId), [
      second.videoId,
      first.videoId,
      second.videoId,
    ]);
    expect(entries.map((video) => video.indexId).toSet(), hasLength(3));
  });

  testWidgets('switching profiles dismisses both save and duplicate dialogs', (
    tester,
  ) async {
    final original = db.profileId;
    await tester.runAsync(
      () => service.addVideoToPlaylist(
        localWatchLaterId,
        first.videoId,
        video: first,
      ),
    );
    await show(tester);
    await tester.tap(find.text('Save to playlist'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Watch Later'));
    await tester.pumpAndSettle();
    expect(find.text('Duplicate songs'), findsOneWidget);
    final next = (await tester.runAsync(
      () => db.createProfile('Another person'),
    ))!;
    await tester.runAsync(() => db.useProfile(next.id));
    app.profileChanged(next.id);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(service.getLocalPlaylists().first.videos, isEmpty);
    expect(
      service
          .getLocalPlaylists(database: db.forProfile(original))
          .first
          .videos
          .single
          .videoId,
      first.videoId,
    );
  });

  testWidgets('media Save picker shows and saves the captured Music song',
      (tester) async {
    await show(tester,
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => MusicLibraryActions.savePlaybackEntry(
                context, first,
                deviceTrack: null, isCurrent: () => true),
            child: const Text('Open picker'),
          ),
        ));
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    expect(find.text('First song'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Watch Later'));
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return service.getLocalPlaylists().first.videos.isEmpty;
      }).timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
    expect(
        service.getLocalPlaylists().first.videos.single.videoId, first.videoId);
  });

  testWidgets('profile switch dismisses owned save and create controls',
      (tester) async {
    await show(tester);
    await tester.tap(find.text('Save to playlist'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create new playlist'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Old profile album');
    final next =
        (await tester.runAsync(() => db.createProfile('Another person')))!;
    await tester.runAsync(() => db.useProfile(next.id));
    app.profileChanged(next.id);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(service.getLocalPlaylists(), hasLength(1));
    expect(service.getLocalPlaylists().first.videos, isEmpty);
  });

  for (final action in [
    'Save to playlist',
    'Manage song playlists',
    'Download audio'
  ]) {
    testWidgets('Android Back cancels $action before the player queue', (
      tester,
    ) async {
      final downloads = _Downloads();
      final saving = action == 'Save to playlist';
      if (saving) {
        await tester.runAsync(
          () => service.addVideoToPlaylist(
            localWatchLaterId,
            first.videoId,
            video: first,
          ),
        );
      }
      await show(
        tester,
        body: BlocProvider<DownloadManagerCubit>.value(
          value: downloads,
          child: MusicLibraryActions(
            videos:
                action == 'Manage song playlists' ? [first] : [first, second],
            compact: false,
            inPlayer: true,
          ),
        ),
      );
      var queueBacks = 0;
      bool queueBack(bool stopped, RouteInfo info) {
        queueBacks++;
        return true;
      }

      BackButtonInterceptor.add(
        queueBack,
        zIndex: 4,
        ifNotYetIntercepted: true,
      );
      addTearDown(() => BackButtonInterceptor.remove(queueBack));
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      final options = action == 'Download audio'
          ? find.byType(DropdownButton<int>)
          : find.text('Watch Later');
      expect(options.hitTestable(), findsOneWidget);
      Future<void> back() async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          SystemChannels.navigation.name,
          SystemChannels.navigation.codec.encodeMethodCall(
            const MethodCall('popRoute'),
          ),
          null,
        );
        await tester.pumpAndSettle();
      }

      if (action != 'Manage song playlists') {
        await tester.tap(options.hitTestable());
        await tester.pumpAndSettle();
        final choices =
            find.text(saving ? 'Duplicate songs' : 'M4A (AAC)').hitTestable();
        expect(choices, findsOneWidget);
        await back();
        expect(choices, findsNothing);
        expect(options.hitTestable(), findsOneWidget);
        expect(queueBacks, 0);
      }
      await back();
      expect(options, findsNothing);
      expect(find.text(action).hitTestable(), findsOneWidget);
      expect(queueBacks, 0);
      expect(
        service.getLocalPlaylists().first.videos,
        hasLength(saving ? 1 : 0),
      );
      expect(downloads.calls, isEmpty);
    });
  }

  testWidgets(
      'TV hides audio downloads and does not require a download manager',
      (tester) async {
    app_globals.isTv = true;
    await show(tester);
    expect(find.text('Download audio'), findsNothing);
    final context = tester.element(find.byType(MusicLibraryActions));
    expect(await MusicLibraryActions.download(context, [first]), 0);
  });

  testWidgets(
      'a menu opened before a profile switch cannot save into the new profile',
      (tester) async {
    await show(tester, compact: true);
    await tester.tap(find.byTooltip('Music actions'));
    await tester.pumpAndSettle();
    final next =
        (await tester.runAsync(() => db.createProfile('Another person')))!;
    await tester.runAsync(() => db.useProfile(next.id));
    app.profileChanged(next.id);
    await tester.pumpAndSettle();
    expect(find.text('Save to playlist'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(service.getLocalPlaylists().first.videos, isEmpty);
  });
}
