import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:back_button_interceptor/back_button_interceptor.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/downloads/models/music_offline_policy.dart';
import 'package:clipious/downloads/views/components/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/components/music_playback_artwork.dart';
import 'package:clipious/music/views/components/music_recommendation_collection.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/states/compact_video.dart';
import 'package:clipious/videos/views/components/compact_video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

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
  final firstSaved = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> addVideoToPlaylist(String playlistId, String videoId,
      {Video? video}) async {
    await super.addVideoToPlaylist(playlistId, videoId, video: video);
    if (!firstSaved.isCompleted) {
      firstSaved.complete();
      await release.future;
    }
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

  final calls = <({List<Video> videos, bool? audio, int? startIndex})>[];
  final offlineCalls = <List<DownloadedVideo>>[];
  int queueReplacements = 0;
  Zone? enqueueZone;

  @override
  int get playlistGeneration => super.playlistGeneration + queueReplacements;

  @override
  Future<bool> enqueueMusicSongs(List<Video> selection,
          {required bool next, List<DownloadedVideo>? downloads}) =>
      (enqueueZone ?? Zone.current).run(() =>
          super.enqueueMusicSongs(selection, next: next, downloads: downloads));

  @override
  Future<void> playVideo(List<Video> videos,
      {bool? audio,
      Duration? startAt,
      bool? playing,
      int? startIndex,
      String? queueTitle,
      bool fromMusic = false}) async {
    calls.add((videos: List.of(videos), audio: audio, startIndex: startIndex));
  }

  @override
  Future<void> playOfflineVideos(List<DownloadedVideo> videos,
      {int startIndex = 0, bool fromMusic = false}) async {
    offlineCalls.add(List.of(videos));
  }
}

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
    await expectLater(session.removeFromPlaylist('PLpublic', first.videoId),
        throwsArgumentError);
    final next = await db.createProfile('Another person');
    await db.useProfile(next.id);
    app.profileChanged(next.id);
    await expectLater(session.removeFromPlaylist(playlistId, first.videoId),
        throwsStateError);
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

  test('profile switch stops a collection save before touching another library',
      () async {
    final originalProfile = db.profileId;
    final paused = _PausedLibrary();
    service = paused;
    final saving = MusicLibrarySession(app)
        .saveToPlaylist(localWatchLaterId, [first, second]);
    final failed = expectLater(saving, throwsStateError);
    await paused.firstSaved.future;
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
            .videos
            .map((video) => video.videoId),
        [first.videoId]);
  });

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

  Widget songRow(Video video, {Future<void> Function()? onPlay}) => Builder(
        builder: (context) => ListTile(
          key: const ValueKey('song-long-press-row'),
          title: Text(video.musicMetadata!.title),
          onTap: onPlay ?? () => MusicScreen.playTracks(context, [video]),
          onLongPress: () =>
              MusicLibraryActions.showSongMenu(context, video, onPlay: onPlay),
          trailing: MusicLibraryActions(videos: [video]),
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

  PlayerState playingPlaylist() => PlayerState.init(null).copyWith(
        isAudio: true,
        isHidden: false,
        isPlaying: true,
        currentlyPlaying: first,
        videos: [first, second],
        playQueue: ListQueue.of([second.videoId]),
        position: const Duration(seconds: 37),
      );

  testWidgets('playlist selection Play next inserts every occurrence in order',
      (tester) async {
    var completed = 0;
    final current = await showSongActions(tester,
        initial: playingPlaylist(),
        body: (_) => MusicPlaylistSelectionActions(
            videos: const [second, first, second],
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
      final current = await showSongActions(tester, initial: initial);
      await openSongMenu(tester);
      await tester.tap(find.byKey(
          ValueKey(next ? 'music-song-play-next' : 'music-song-add-to-queue')));
      await tester.pumpAndSettle();
      expect(current.calls, hasLength(1));
      expect(current.calls.single.videos, [first]);
      expect(current.calls.single.audio, isTrue);
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
      'holding a recommendation collection sliver row opens song actions',
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
    final firstId = playlists
        .singleWhere((playlist) => playlist.title == 'First list')
        .playlistId;
    final secondId = playlists
        .singleWhere((playlist) => playlist.title == 'Second list')
        .playlistId;
    final target = ValueNotifier((playlistId: firstId, video: first));
    addTearDown(target.dispose);
    await show(tester,
        body: ValueListenableBuilder<({String playlistId, Video video})>(
            valueListenable: target,
            builder: (context, value, _) => MusicLibraryActions(
                videos: [value.video], localPlaylistId: value.playlistId)));
    await tester.tap(find.byTooltip('Music actions'));
    await tester.pumpAndSettle();
    target.value = (playlistId: secondId, video: second);
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

  testWidgets(
      'collection destination stays enabled when only its first song is saved',
      (tester) async {
    await tester.runAsync(() => service
        .addVideoToPlaylist(localWatchLaterId, first.videoId, video: first));
    await show(tester);
    await tester.tap(find.text('Save to playlist'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Watch Later'));
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return service.getLocalPlaylists().first.videos.length != 2;
      }).timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
    expect(
        service.getLocalPlaylists().first.videos.map((video) => video.videoId),
        [first.videoId, second.videoId]);
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

  for (final action in ['Save to playlist', 'Download audio']) {
    testWidgets('Android Back cancels $action before the player queue',
        (tester) async {
      final downloads = _Downloads();
      await show(tester,
          body: BlocProvider<DownloadManagerCubit>.value(
            value: downloads,
            child: const MusicLibraryActions(
                videos: [first, second], compact: false, inPlayer: true),
          ));
      var queueBacks = 0;
      bool queueBack(bool stopped, RouteInfo info) {
        queueBacks++;
        return true;
      }

      BackButtonInterceptor.add(queueBack,
          zIndex: 4, ifNotYetIntercepted: true);
      addTearDown(() => BackButtonInterceptor.remove(queueBack));
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      final options = action == 'Save to playlist'
          ? find.text('Watch Later')
          : find.byType(DropdownButton<int>);
      expect(options.hitTestable(), findsOneWidget);
      Future<void> back() async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          SystemChannels.navigation.name,
          SystemChannels.navigation.codec
              .encodeMethodCall(const MethodCall('popRoute')),
          null,
        );
        await tester.pumpAndSettle();
      }

      if (action == 'Download audio') {
        await tester.tap(options.hitTestable());
        await tester.pumpAndSettle();
        final format = find.text('M4A (AAC)').hitTestable();
        expect(format, findsOneWidget);
        await back();
        expect(format, findsNothing);
        expect(options.hitTestable(), findsOneWidget);
        expect(queueBacks, 0);
      }
      await back();
      expect(options, findsNothing);
      expect(find.text(action).hitTestable(), findsOneWidget);
      expect(queueBacks, 0);
      expect(service.getLocalPlaylists().first.videos, isEmpty);
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
