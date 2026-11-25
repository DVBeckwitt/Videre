import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show SemanticsAction;

import 'package:audio_session/audio_session.dart';
import 'package:auto_route/auto_route.dart';
import 'package:back_button_interceptor/back_button_interceptor.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/download_playback_provenance.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/download_playback_source.dart';
import 'package:clipious/downloads/services/explicit_music_download.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_page.dart';
import 'package:clipious/music/models/music_content_advisory.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_cover_corners.dart';
import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/models/music_lyrics_match.dart';
import 'package:clipious/music/services/music_lyrics_corrections.dart';
import 'package:clipious/music/models/music_player_appearance.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/views/components/music_selection_feedback.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/music_community_cover_preferences.dart';
import 'package:clipious/music/services/music_lyrics_preferences.dart';
import 'package:clipious/music/services/music_passage_bookmarks.dart';
import 'package:clipious/music/services/music_lyrics_reader_preferences.dart';
import 'package:clipious/music/views/components/community_music_artwork.dart';
import 'package:clipious/music/views/components/music_mini_player.dart';
import 'package:clipious/music/views/components/music_playback_artwork.dart';
import 'package:clipious/music/views/components/music_player.dart';
import 'package:clipious/music/views/components/music_player_artwork.dart';
import 'package:clipious/music/views/components/music_sponsor_notice.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/music_audio_quality.dart';
import 'package:clipious/player/models/named_music_queue.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/expanded_player.dart';
import 'package:clipious/player/views/components/player.dart';
import 'package:clipious/player/models/sleep_timer.dart';
import 'package:clipious/player/views/tablet/expanded_player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/router.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/models/theme_palette.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/views/components/selected_server.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/caption.dart';
import 'package:clipious/videos/models/format_stream.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/video_transcript.dart';
import 'package:clipious/videos/views/components/info.dart';
import 'package:clipious/videos/views/components/video_share_button.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/gestures.dart'
    show kDoubleTapMinTime, kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _ArtistCatalog extends MusicCatalogService {
  @override
  Future<MusicArtistPage> getArtist(String id) async => MusicArtistPage(
      artist: MusicArtist(name: 'Featured artist', id: id),
      description: 'Channel $id',
      songs: const [MusicTrack(videoId: 'next', title: 'Artist track')]);
}

class _ReleaseCatalog extends MusicCatalogService {
  final releases = <String>[];
  final Map<String, MusicCollection> collections;

  _ReleaseCatalog([this.collections = const {}]);

  @override
  Future<MusicCollection> getPlaylist(String id) async {
    releases.add(id);
    return collections[id] ??
        MusicCollection(id: id, title: 'Release listing', tracks: const [
          MusicTrack(videoId: 'bonus', title: 'Release bonus track'),
        ]);
  }
}

class _ReleasePlaybackService extends Service {
  final int? lengthSeconds;

  _ReleasePlaybackService({this.lengthSeconds});

  @override
  Future<Video> getMusicVideo(String videoId,
          {Server? serverOverride,
          void Function(BackendPlayback request)? onBackendRequest,
          VideoLoadObserver? loadObserver}) async =>
      Video(
          videoId: videoId,
          lengthSeconds: lengthSeconds,
          formatStreams: [],
          adaptiveFormats: []);

  @override
  Future<List<SponsorSegment>> getSponsorSegments(
          String videoId, List<SponsorSegmentType> categories) async =>
      const [];
}

class _MusicVideoCatalog extends MusicCatalogService {
  final requests = <({
    Video song,
    bool Function() isCurrent,
    Completer<Video?> result,
  })>[];

  @override
  Future<Video?> findMusicVideo(Video song,
      {required bool Function() isCurrent}) {
    final result = Completer<Video?>();
    requests.add((song: song, isCurrent: isCurrent, result: result));
    return result.future;
  }
}

class _Player extends TestPlayerCubit {
  int nextCalls = 0;
  int previousCalls = 0;
  Zone? transportZone;
  Zone? seekZone;
  Zone? enqueueZone;
  Future<void>? switching;
  int playlistRetries = 0;
  final localQueueRequests = <List<LocalMusicTrack>>[];
  final offlineSelections = <List<DownloadedVideo>>[];
  final musicPlayRequests = <List<Video>>[];
  Object? playlistError;
  PlaylistReference? sourcePlaylist;
  String? queueTitle;
  bool? queueComplete;
  Duration? sought;
  ValueNotifier<PlayingMusicContentAdvisory?>? reportedMusicAdvisory;
  IdedVideo? previewMusicEntry;

  _Player(super.initialState, super.settings);

  @override
  ValueListenable<PlayingMusicContentAdvisory?> get musicContentAdvisory =>
      reportedMusicAdvisory ?? super.musicContentAdvisory;

  @override
  IdedVideo? get openingMusicEntry =>
      previewMusicEntry ?? super.openingMusicEntry;

  Future<void> startSongs(List<Video> songs, int index) =>
      super.playVideo(songs, audio: true, startIndex: index);

  Future<void> seed(PlayerState next) async {
    // Start session persistence outside the widget test's fake frame clock.
    await TestWidgetsFlutterBinding.instance.runAsync(() async => emit(next));
  }

  @override
  void playNext({bool userInitiated = true}) {
    nextCalls++;
    transportZone?.run(() => super.playNext(userInitiated: userInitiated));
  }

  @override
  void playPrevious() {
    previousCalls++;
    transportZone?.run(() => super.playPrevious());
  }

  @override
  Future<void> switchToVideo(Video video, {Duration? startAt}) =>
      switching = super.switchToVideo(video, startAt: startAt);

  @override
  Future<void> playVideo(List<Video> videos,
      {bool? audio,
      Duration? startAt,
      bool? playing,
      int? startIndex,
      String? queueTitle,
      PlaylistReference? recommendationSource,
      bool fromMusic = false,
      bool songTap = false}) async {
    musicPlayRequests.add(videos);
    await seed(state.copyWith(
        videos: videos,
        currentlyPlaying: videos[startIndex ?? 0],
        isHidden: false,
        isMini: false,
        isAudio: audio == true));
  }

  @override
  Future<void> playLocalMusic(List<LocalMusicTrack> tracks,
      {int startIndex = 0, String? queueTitle, bool songTap = false}) async {
    localQueueRequests.add(List.of(tracks));
  }

  @override
  Future<bool> enqueueOfflineMusicCopies(List<DownloadedVideo> entries,
          {required bool next}) =>
      (enqueueZone ?? Zone.current)
          .run(() => super.enqueueOfflineMusicCopies(entries, next: next));

  @override
  Future<void> playOfflineMusicSelection(List<DownloadedVideo> entries) async {
    offlineSelections.add(List.of(entries));
  }

  @override
  Future<bool> enqueueMusicSongs(List<Video> selection,
          {required bool next,
          List<DownloadedVideo>? downloads,
          PlaylistReference? recommendationSource}) =>
      (enqueueZone ?? Zone.current).run(() => super.enqueueMusicSongs(selection,
          next: next,
          downloads: downloads,
          recommendationSource: recommendationSource));

  @override
  Object? get playlistLoadingError => playlistError;

  @override
  String? get musicQueueTitle => queueTitle ?? super.musicQueueTitle;

  @override
  PlaylistReference? get playlistReference =>
      sourcePlaylist ?? super.playlistReference;

  @override
  bool get playlistComplete => queueComplete ?? super.playlistComplete;

  @override
  void retryPlaylistLoading() {
    playlistRetries++;
    playlistError = null;
    playlistLoadingRevision.value++;
  }

  @override
  void seek(Duration position) {
    sought = position;
    (seekZone ?? Zone.current).run(() => super.seek(position));
  }
}

class _PendingAudioFocus extends Fake implements AudioSession {
  final activation = Completer<bool>();

  @override
  Future<bool> setActive(bool active,
          {AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
          AndroidAudioFocusGainType? androidAudioFocusGainType,
          AndroidAudioAttributes? androidAudioAttributes,
          bool? androidWillPauseWhenDucked,
          AudioSessionConfiguration fallbackConfiguration =
              const AudioSessionConfiguration.music()}) =>
      active ? activation.future : Future.value(true);
}

class _Settings extends TestSettingsCubit {
  _Settings(super.initialState, super.appCubit);

  @override
  Future<void> saveSetting(SettingsValue value) async {
    emit(state.copyWith(settings: {...state.settings, value.name: value}));
  }
}

class _App extends TestAppCubit {
  _App(super.initialState);

  void profileChanged(String id) => emit(state.copyWith(profileId: id));
}

// A captioned track must never substitute speech recognition for missing lyrics.
class _CaptionService extends Service {
  int requests = 0;

  @override
  Future<String> getPlaybackCaptions(String videoId, Caption caption,
      {required Server server}) async {
    requests++;
    throw StateError('Unexpected caption lookup');
  }

  @override
  Future<VideoTranscript> getTranscript(String videoId, Caption caption,
      {Server? serverOverride}) async {
    requests++;
    throw StateError('Unexpected transcript lookup');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _App app;
  late TestSettingsCubit settings;
  late _Player player;
  const song = Video(
      videoId: 'song',
      title: 'Song',
      author: 'Singer',
      lengthSeconds: 180,
      musicMetadata:
          MusicMetadata(title: 'Song', artist: 'Singer', album: 'Album'));
  const next = Video(
      videoId: 'next',
      title: 'Next',
      lengthSeconds: 180,
      musicMetadata: MusicMetadata(title: 'Next', artist: 'Singer'));

  setUp(() async {
    app_main.darkColorScheme = ColorScheme.fromSeed(
        seedColor: Colors.blue, brightness: Brightness.dark);
    db = await SembastSqfDb.createInMemory();
    await db.saveSetting(SettingsValue(
        namedMusicQueuesSetting, NamedMusicQueue.encodeAll(const [])));
    app = _App(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = _Settings(SettingsState.init(), app);
    player = _Player(
        PlayerState.init([song, next]).copyWith(
            currentlyPlaying: song,
            playQueue: ListQueue.of([next.videoId]),
            isAudio: true,
            isMini: false,
            isHidden: false,
            top: 0,
            position: const Duration(seconds: 30),
            mediaEvent: const MediaEvent(state: MediaState.ready)),
        settings);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> pump(WidgetTester tester,
      {Size size = const Size(390, 844),
      double scale = 1,
      bool disableAnimations = false,
      String? fontFamily,
      Widget child = const MusicPlayer()}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<AppCubit>.value(value: app),
          BlocProvider<SettingsCubit>.value(value: settings),
          BlocProvider<PlayerCubit>.value(value: player),
        ],
        child: MaterialApp(
          theme: fontFamily == null ? null : ThemeData(fontFamily: fontFamily),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: disableAnimations),
              child: child!),
          home: Scaffold(body: child),
        )));
    await tester.pump();
  }

  testWidgets('Classic purple colors the open Music player and mini player',
      (tester) async {
    await pump(tester);
    final playButton = find.byKey(const ValueKey('music-player-play'));
    expect(Theme.of(tester.element(playButton)).colorScheme.surface,
        const Color(0xff121212));
    await tester
        .runAsync(() => settings.setThemePalette(ThemePalette.classicPurple));
    await tester.pump();
    expect(Theme.of(tester.element(playButton)).colorScheme,
        ThemePalette.classicDark);
    final style = tester.widget<IconButton>(playButton).style!;
    final fill = style.backgroundColor!.resolve({})!;
    final ink = style.foregroundColor!.resolve({})!;
    expect(fill, ThemePalette.classicDark.primaryContainer);
    expect(ink, ThemePalette.classicDark.onPrimaryContainer);
    expect((ink.computeLuminance() + 0.05) / (fill.computeLuminance() + 0.05),
        greaterThanOrEqualTo(4.5));
    await pump(tester, child: const MusicMiniPlayer());
    final progress = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('music-mini-progress')));
    expect(progress.color, ThemePalette.classicDark.onPrimaryContainer);
  });

  testWidgets(
      'the song player distinguishes a blocked media host from other failures',
      (tester) async {
    await pump(tester);
    final locals =
        AppLocalizations.of(tester.element(find.byType(MusicPlayer)))!;
    player.setEvent(const MediaEvent(
        state: MediaState.error,
        value: PlaybackFailureReason.separateMediaHost));
    await tester.pump();
    await tester.pump();
    expect(find.text(locals.playbackSeparateMediaHost), findsOneWidget);
    expect(find.text(locals.retry), findsOneWidget);
    player.setEvent(const MediaEvent(state: MediaState.error));
    await tester.pump();
    await tester.pump();
    expect(find.text(locals.playbackSeparateMediaHost), findsNothing);
    expect(find.text(locals.musicPlaybackError), findsOneWidget);
  });

  testWidgets('a failed song selection reports above the visible player route',
      (tester) async {
    var actions = 0;
    // A listener mounting after an earlier failure should not replay it.
    player.musicSelectionFailureRevision.value++;
    await pump(tester,
        child: const MusicSelectionFeedback(child: Text('Playing')));
    expect(find.byType(SnackBar), findsNothing);
    final original = player.state.currentlyPlaying;
    final context = tester.element(find.text('Playing'));
    unawaited(Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => Scaffold(
          body: Center(
              child: TextButton(
        onPressed: () => actions++,
        child: const Text('Artist page'),
      ))),
    )));
    await tester.pumpAndSettle();
    for (var i = 1; i <= 2; i++) {
      player.musicSelectionFailureRevision.value++;
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text(AppLocalizations.of(context)!.musicPlaybackError),
          findsOneWidget);
      await tester.tap(find.text('Artist page'));
      expect(actions, i);
      expect(player.state.currentlyPlaying, same(original));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    }
  });

  Future<void> tap(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.tap(target);
    await tester.pump();
    if (key == 'music-player-queue' || key == 'music-player-close-queue') {
      await tester.pumpAndSettle();
    }
  }

  Future<void> pressAndroidBack(WidgetTester tester) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      SystemChannels.navigation.codec
          .encodeMethodCall(const MethodCall('popRoute')),
      null,
    );
    await tester.pumpAndSettle();
  }

  Future<void> skipSponsor(WidgetTester tester) async {
    player.setEvent(const MediaEvent(
        type: MediaEventType.sponsorSkipped, state: MediaState.playing));
    await tester.pump();
    await tester.pump();
  }

  Future<_MusicVideoCatalog> seedVideoSong(WidgetTester tester,
      {bool downloadOnly = false}) async {
    final previous = musicCatalogService;
    final catalog = _MusicVideoCatalog();
    musicCatalogService = catalog;
    addTearDown(() => musicCatalogService = previous);
    await tester.runAsync(() async {
      await db
          .upsertServer(const Server(url: 'https://inv.example', inUse: true));
      await app.initState();
    });
    final source = song.copyWith(
        videoId: 'musicArt001',
        queueEntryId: 'occurrence-1',
        downloadPlaybackOnly: downloadOnly,
        playbackConnection: BackendPlayback(app.state.server!));
    await player.seed(player.state
        .copyWith(videos: [source, next], currentlyPlaying: source));
    return catalog;
  }

  Video clipFor(Video original) => Video(
          videoId: 'musicVid001',
          title: 'Song (Official Video)',
          lengthSeconds: original.lengthSeconds,
          playbackConnection: original.playbackConnection,
          formatStreams: [
            FormatStream('https://inv.example/visual.mp4', '18', 'video/mp4',
                'medium', 'mp4', 'h264', '360p', '360p', '640x360')
          ]);
  const videoToggleKey = 'music-player-video-toggle';
  final videoToggle = find.byKey(const ValueKey(videoToggleKey));
  final videoSurface = find.byKey(const ValueKey('music-player-video'));

  for (final television in [false, true]) {
    testWidgets('music video switches only the artwork (TV: $television)',
        (tester) async {
      final catalog = await seedVideoSong(tester);
      final mountedIds = <String>[];
      await pump(tester,
          size: television ? const Size(960, 640) : const Size(320, 568),
          scale: television ? 1 : 1.8,
          child: MusicPlayer(
              television: television,
              videoSurfaceBuilder: (video, _) {
                mountedIds.add(video.videoId);
                return const SizedBox.expand();
              }));
      expect(videoToggle, findsNothing);
      final request = catalog.requests.single;
      expect(request.song, player.state.currentlyPlaying);
      expect(request.isCurrent(), isTrue);
      final clip = clipFor(request.song);
      request.result.complete(clip);
      await tester.pumpAndSettle();
      final lyrics = find.byKey(const ValueKey('music-player-lyrics'));
      await tester.ensureVisible(videoToggle);
      await tester.pumpAndSettle();
      expect(lyrics.hitTestable(), findsOneWidget);
      expect(videoToggle.hitTestable(), findsOneWidget);
      expect(find.byTooltip('Show music video'), findsOneWidget);
      expect(
          (tester.getCenter(videoToggle) - tester.getCenter(lyrics)).distance,
          lessThan(160));
      if (television) {
        final icon =
            find.descendant(of: videoToggle, matching: find.byType(Icon));
        Focus.of(tester.element(icon)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      } else {
        await tester.tap(videoToggle);
      }
      await tester.pumpAndSettle();
      expect(mountedIds, contains(clip.videoId));
      expect(videoSurface, findsOneWidget);
      expect(tester.getRect(videoSurface),
          tester.getRect(find.byKey(const ValueKey('music-player-artwork'))));
      expect(find.byTooltip('Show cover art'), findsOneWidget);
      final before = player.state;
      const elapsed = Duration(seconds: 42);
      await player.seed(before.copyWith(position: elapsed));
      await tester.pumpAndSettle();
      expect(catalog.requests, hasLength(1));
      expect(videoSurface, findsOneWidget);
      await tap(tester, videoToggleKey);
      expect(videoSurface, findsNothing);
      expect(find.byTooltip('Show music video'), findsOneWidget);
      expect(player.state.currentQueueId, before.currentQueueId);
      expect(player.state.playQueue, orderedEquals(before.playQueue));
      expect(player.state.position, elapsed);
      expect(player.state.isPlaying, before.isPlaying);
      expect(player.musicPlayRequests, isEmpty);
      expect(player.sought, isNull);
      await tap(tester, 'music-player-lyrics');
      await tester.pumpAndSettle();
      expect(find.text('Enable LRCLIB lyrics?'), findsOneWidget);
      await pressAndroidBack(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('resizing between phone and tablet keeps the inline song video',
      (tester) async {
    final catalog = await seedVideoSong(tester);
    await pump(tester,
        size: const Size(960, 640),
        child: MusicPlayer(
            videoSurfaceBuilder: (_, __) => const SizedBox.expand()));
    final lookup = catalog.requests.single;
    lookup.result.complete(clipFor(lookup.song));
    await tester.pumpAndSettle();
    await tap(tester, videoToggleKey);
    final surface = tester.element(videoSurface);
    expect(find.byType(MusicQueue), findsOneWidget);
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(catalog.requests, hasLength(1));
    expect(tester.element(videoSurface), same(surface));
    expect(find.byTooltip('Show cover art'), findsOneWidget);
    tester.view.physicalSize = const Size(960, 640);
    await tester.pumpAndSettle();
    expect(find.byType(MusicQueue), findsOneWidget);
    expect(catalog.requests, hasLength(1));
    expect(tester.element(videoSurface), same(surface));
  });

  testWidgets('music video drops a late match for another queue occurrence',
      (tester) async {
    final catalog = await seedVideoSong(tester);
    await pump(tester);
    final first = catalog.requests.single;
    final second = first.song.copyWith(queueEntryId: 'occurrence-2');
    await player.seed(player.state.copyWith(
        videos: [first.song, second, next], currentlyPlaying: second));
    await tester.pumpAndSettle();
    expect(first.isCurrent(), isFalse);
    expect(catalog.requests, hasLength(2));
    expect(catalog.requests.last.isCurrent(), isTrue);
    first.result.complete(clipFor(first.song));
    await tester.pumpAndSettle();
    expect(videoToggle, findsNothing);
    catalog.requests.last.result.complete(null);
    await tester.pumpAndSettle();
    expect(videoToggle, findsNothing);
    expect(videoSurface, findsNothing);
  });

  testWidgets(
      'new filters retire a cached video on toggle and a song on resume',
      (tester) async {
    final catalog = await seedVideoSong(tester);
    var surfaces = 0;
    await pump(tester, child: MusicPlayer(videoSurfaceBuilder: (_, __) {
      surfaces++;
      return const SizedBox.expand();
    }));
    final request = catalog.requests.single;
    request.result.complete(clipFor(request.song));
    await tester.pumpAndSettle();
    expect(videoToggle, findsOneWidget);
    await tester
        .runAsync(() => db.saveFilter(VideoFilter(value: 'Official Video')));
    await tap(tester, videoToggleKey);
    expect(surfaces, 0);
    expect(videoToggle, findsNothing);

    // A different visual can still accompany the same unfiltered recording.
    final fresh = catalog.requests.last;
    expect(fresh, isNot(request));
    fresh.result
        .complete(clipFor(request.song).copyWith(title: 'Another visual'));
    await tester.pumpAndSettle();
    await tap(tester, videoToggleKey);
    expect(videoSurface, findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    addTearDown(() => tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    await tester
        .runAsync(() => db.saveFilter(VideoFilter(value: request.song.title!)));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(videoToggle, findsNothing);
    expect(videoSurface, findsNothing);
    expect(catalog.requests, hasLength(2));
    expect(player.state.currentQueueId, request.song.queueEntryId);
  });

  testWidgets('a community filter revision retires the current video lookup',
      (tester) async {
    final catalog = await seedVideoSong(tester);
    await pump(tester);
    final stale = catalog.requests.single;
    await tester.runAsync(communityFilters.reloadForProfile);
    expect(stale.isCurrent(), isFalse);
    await tester.pump();
    final current = catalog.requests.last;
    expect(current, isNot(stale));
    stale.result.complete(clipFor(stale.song));
    current.result.complete(null);
    await tester.pumpAndSettle();
    expect(videoToggle, findsNothing);
  });

  testWidgets('music video lookup starts when the playing song is hydrated',
      (tester) async {
    final catalog = await seedVideoSong(tester);
    final hydrated = player.state.currentlyPlaying!;
    final placeholder = hydrated.copyWith(playbackConnection: null);
    await player.seed(player.state.copyWith(currentlyPlaying: placeholder));
    await pump(tester);
    expect(catalog.requests, isEmpty);
    await player.seed(player.state.copyWith(currentlyPlaying: hydrated));
    await tester.pumpAndSettle();
    final request = catalog.requests.single;
    expect(request.song.playbackConnection, hydrated.playbackConnection);
    request.result.complete(clipFor(hydrated));
    await tester.pumpAndSettle();
    expect(videoToggle, findsOneWidget);
  });

  testWidgets('music video failure restores the cover without restarting audio',
      (tester) async {
    final catalog = await seedVideoSong(tester);
    late VoidCallback failVideo;
    await pump(tester, child: MusicPlayer(videoSurfaceBuilder: (_, onFailure) {
      failVideo = onFailure;
      return const SizedBox.expand();
    }));
    final request = catalog.requests.single;
    request.result.complete(clipFor(request.song));
    await tester.pumpAndSettle();
    final before = player.state;
    await tap(tester, videoToggleKey);
    expect(videoSurface, findsOneWidget);
    failVideo();
    await tester.pumpAndSettle();
    expect(videoSurface, findsNothing);
    expect(find.byKey(const ValueKey('music-player-artwork')), findsOneWidget);
    expect(player.state.currentQueueId, before.currentQueueId);
    expect(player.state.playQueue, orderedEquals(before.playQueue));
    expect(player.state.position, before.position);
    expect(player.state.isPlaying, before.isPlaying);
    expect(player.musicPlayRequests, isEmpty);
    expect(player.sought, isNull);
  });

  testWidgets('minimizing the player retires a pending music video lookup',
      (tester) async {
    final catalog = await seedVideoSong(tester);
    await pump(tester);
    final original = catalog.requests.single;
    await player.seed(player.state.copyWith(isMini: true));
    await tester.pumpAndSettle();
    expect(original.isCurrent(), isFalse);
    original.result.complete(clipFor(original.song));
    await tester.pumpAndSettle();
    expect(videoToggle, findsNothing);
    expect(videoSurface, findsNothing);
    expect(catalog.requests, hasLength(1));
    await player.seed(player.state.copyWith(isMini: false));
    await tester.pumpAndSettle();
    final reopened = catalog.requests.last;
    expect(reopened, isNot(original));
    expect(reopened.isCurrent(), isTrue);
    reopened.result.complete(null);
    await tester.pumpAndSettle();
    expect(videoToggle, findsNothing);
  });

  testWidgets('a retired music video cannot interrupt the next song',
      (tester) async {
    final catalog = await seedVideoSong(tester);
    late VoidCallback failCurrent;
    await pump(tester, child: MusicPlayer(videoSurfaceBuilder: (_, onFailure) {
      failCurrent = onFailure;
      return const SizedBox.expand();
    }));
    final first = catalog.requests.single;
    first.result.complete(clipFor(first.song));
    await tester.pumpAndSettle();
    await tap(tester, videoToggleKey);
    final lateFailure = failCurrent;
    final second = next.copyWith(
        videoId: 'musicArt002',
        queueEntryId: 'occurrence-2',
        playbackConnection: first.song.playbackConnection);
    await player.seed(player.state
        .copyWith(videos: [first.song, second], currentlyPlaying: second));
    await tester.pumpAndSettle();
    expect(videoSurface, findsNothing);
    expect(videoToggle, findsNothing);
    final request = catalog.requests.last;
    expect(request.song, second);
    request.result.complete(clipFor(second).copyWith(videoId: 'musicVid002'));
    await tester.pumpAndSettle();
    await tap(tester, videoToggleKey);
    lateFailure();
    await tester.pumpAndSettle();
    expect(videoSurface, findsOneWidget);
    expect(player.state.currentlyPlaying, second);
    expect(player.musicPlayRequests, isEmpty);
  });

  Future<List<LocalMusicTrack>> seedDeviceQueue(WidgetTester tester,
      {String? embeddedArt,
      String? albumKey,
      bool allowRename = false,
      Future<Object?> Function(MethodCall)? readLyrics}) async {
    const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
    const tree =
        'content://com.android.externalstorage.documents/tree/primary%3AMusic';
    final messenger = tester.binding.defaultBinaryMessenger;
    Map<String, String>? folder;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getFolder':
          return folder;
        case 'pickFolder':
          return folder = {'uri': tree, 'name': 'Music'};
        case 'checkFolderAccess':
          return folder != null && call.arguments['treeUri'] == tree;
        case 'listTracks':
          expect(call.arguments['treeUri'], tree);
          return [
            for (final name in ['Intro', 'Finale'])
              {
                'uri': '$tree/document/primary%3AMusic%2F$name.ogg',
                'title': name,
                'artist': 'Device artist',
                'album': 'Device album',
                if (albumKey != null) 'albumKey': albumKey,
                'durationMs': 180000,
                if (allowRename) 'fileName': '$name.ogg',
                if (allowRename) 'canRename': true,
                if (name == 'Finale' && embeddedArt != null)
                  'artPath': embeddedArt,
              }
          ];
        case 'readTrackLyrics':
          return readLyrics?.call(call);
        case 'forgetFolder':
          folder = null;
          return null;
        default:
          throw UnsupportedError(call.method);
      }
    });
    final library = LocalMusicLibrary.instance;
    addTearDown(() async {
      await library.disable();
      messenger.setMockMethodCallHandler(channel, null);
    });
    await tester.runAsync(() async {
      player.enqueueZone = Zone.current;
      await setCommunityCoverArtEnabled(true);
      await setLrclibEnabled(true);
      expect(await library.chooseFolder(), isTrue);
    });
    final tracks = library.tracks;
    expect(tracks.map((track) => track.title), ['Intro', 'Finale']);
    final entries = [
      for (final track in tracks) localMusicPlaybackEntry(track, db.profileId),
    ];
    await player.seed(player.state.copyWith(
        videos: [],
        currentlyPlaying: null,
        offlineVideos: entries,
        offlineCurrentlyPlaying: entries.first,
        playQueue: ListQueue.of([entries.last.videoId])));
    return tracks;
  }

  const songActionsTrack = Video(
      videoId: 'actionSong1',
      indexId: 'source-membership-1',
      title: 'Action song',
      lengthSeconds: 180,
      musicMetadata: MusicMetadata(title: 'Action song', artist: 'Singer'));
  const songActionsNext = Video(
      videoId: 'actionSong2',
      indexId: 'source-membership-2',
      title: 'Following song',
      lengthSeconds: 180,
      musicMetadata: MusicMetadata(title: 'Following song', artist: 'Singer'));
  const songActionsPlaylist = Playlist(
      playlistId: 'local:action-source',
      title: 'Action source',
      author: '',
      videoCount: 2,
      videos: [songActionsTrack, songActionsNext]);
  const songActionsOther = Playlist(
      playlistId: 'local:action-other',
      title: 'Other list',
      author: '',
      videoCount: 0);
  final songActionsButton =
      find.byKey(const ValueKey('music-player-song-actions'));
  final namedRemoval = find.text('Remove from Action source');

  Future<void> storeActionPlaylists(Playlist source, Playlist other) =>
      db.saveSetting(SettingsValue(localPlaylistsSetting,
          jsonEncode([source.toJson(), other.toJson()])));

  Iterable<String> actionPlaylistEntries(Playlist playlist,
          {String? profile}) =>
      service
          .getLocalPlaylists(
              database: profile == null ? db : db.forProfile(profile))
          .singleWhere((saved) => saved.playlistId == playlist.playlistId)
          .videos
          .map((video) => video.videoId);

  Future<void> playActionPlaylist(Playlist playlist) async {
    await player.playPlaylist(playlist.videos,
        reference: PlaylistReference.forPlaylist(playlist, db),
        fromMusic: true,
        audio: true,
        startAt: const Duration(seconds: 25));
    player.setEvent(const MediaEvent(state: MediaState.ready));
    expect(
        player.state.currentlyPlaying?.videoId, playlist.videos.first.videoId);
  }

  Future<void> seedSongActions(WidgetTester tester,
      {Playlist source = songActionsPlaylist,
      Playlist other = songActionsOther,
      int? lengthSeconds}) async {
    final previousService = service;
    service = _ReleasePlaybackService(lengthSeconds: lengthSeconds);
    addTearDown(() => service = previousService);
    await tester.runAsync(() async {
      player.audioSession = await AudioSession.instance;
      await storeActionPlaylists(source, other);
      await playActionPlaylist(source);
    });
    await pump(tester, size: const Size(360, 680));
    await tester.pumpAndSettle();
  }

  Future<void> openSongActions(WidgetTester tester) async {
    expect(songActionsButton.hitTestable(), findsOneWidget);
    expect(find.byTooltip('Song actions'), findsOneWidget);
    await tester.runAsync(() => tester.tap(songActionsButton));
    await tester.pumpAndSettle();
  }

  Future<void> tapSongAction(WidgetTester tester, Finder action) async {
    expect(action.hitTestable(), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(action);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
  }

  Future<void> chooseAndWait(
      WidgetTester tester, Finder action, bool Function() changed) async {
    expect(action.hitTestable(), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(action);
      await tester.pump();
      await Future.doWhile(() async {
        if (changed()) return false;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return true;
      }).timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('Song actions label fits compact phones and scales accessibly',
      (tester) async {
    const family = 'SongActionsTestRoboto';
    // The widget runner's Ahem font has uniform glyph widths. Use the pinned
    // SDK's Android Material font to check whether the user can read the label.
    await tester.runAsync(() async {
      final font = FontLoader(family)
        ..addFont(File('submodules/flutter/bin/cache/artifacts/material_fonts/'
                'Roboto-Regular.ttf')
            .readAsBytes()
            .then(ByteData.sublistView));
      await font.load();
    });
    final label = find.descendant(
        of: songActionsButton, matching: find.text('Song actions'));
    for (final width in [320.0, 360.0]) {
      await pump(tester, size: Size(width, 680), fontFamily: family);
      expect(songActionsButton.hitTestable(), findsOneWidget);
      expect(label, findsOneWidget);
      expect(tester.renderObject<RenderParagraph>(label).didExceedMaxLines,
          isFalse);
    }

    await pump(tester,
        size: const Size(320, 680), scale: 2.5, fontFamily: family);
    expect(label, findsNothing);
    expect(songActionsButton.hitTestable(), findsOneWidget);
    expect(find.byTooltip('Song actions'), findsOneWidget);
    final data = tester.getSemantics(songActionsButton).getSemanticsData();
    expect([data.label, data.tooltip], contains('Song actions'));
  });

  testWidgets(
      'visible Song actions add and remove only the named playlist song',
      (tester) async {
    await seedSongActions(tester);
    final before = player.state;
    await openSongActions(tester);
    for (final label in [
      'Play',
      'Play next',
      'Add to queue',
      'Save song',
      'Download audio',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Open artist'), findsNothing);
    expect(namedRemoval.hitTestable(), findsOneWidget);
    expect(find.text('Remove from Other list'), findsNothing);

    await tapSongAction(tester, find.text('Add to playlist'));
    final dialog = find.byType(AlertDialog);
    final dest = find.descendant(of: dialog, matching: find.text('Other list'));
    await chooseAndWait(
        tester, dest, () => actionPlaylistEntries(songActionsOther).isNotEmpty);

    await openSongActions(tester);
    await chooseAndWait(tester, namedRemoval,
        () => actionPlaylistEntries(songActionsPlaylist).length == 1);
    expect(
        actionPlaylistEntries(songActionsPlaylist), [songActionsNext.videoId]);
    expect(actionPlaylistEntries(songActionsOther), [songActionsTrack.videoId]);
    expect(player.state.currentQueueId, before.currentQueueId);
    expect(player.state.position, before.position);
    expect(player.state.playQueue, orderedEquals(before.playQueue));
    expect(
        player.playlistReference?.playlistId, songActionsPlaylist.playlistId);
    await openSongActions(tester);
    expect(namedRemoval, findsNothing);
  });

  testWidgets('Song actions remove only the playing source copy of a song',
      (tester) async {
    final duplicate = songActionsTrack.copyWith(
        indexId: 'source-membership-3', title: 'Another occurrence');
    await seedSongActions(tester,
        source: songActionsPlaylist.copyWith(videoCount: 3, videos: [
          songActionsTrack,
          duplicate,
          songActionsNext,
        ]));
    final before = player.state;
    await openSongActions(tester);
    expect(namedRemoval.hitTestable(), findsOneWidget);
    await chooseAndWait(tester, namedRemoval,
        () => actionPlaylistEntries(songActionsPlaylist).length == 2);
    final remaining = service.getLocalPlaylists().singleWhere(
        (playlist) => playlist.playlistId == songActionsPlaylist.playlistId);
    expect(remaining.videos.map((video) => video.indexId),
        [duplicate.indexId, songActionsNext.indexId]);
    expect(player.state.currentQueueId, before.currentQueueId);
    expect(player.state.position, before.position);
    await openSongActions(tester);
    expect(namedRemoval, findsNothing);
  });

  testWidgets('an appended copy of the playlist song gains no removal action',
      (tester) async {
    await seedSongActions(tester);
    final sourceOccurrence = player.state.currentQueueId;
    await tester.runAsync(() async {
      expect(await player.enqueueMusicSongs([songActionsTrack], next: true),
          isTrue);
      await player.selectQueueOccurrence(player.state.playQueue.first);
      player.setEvent(const MediaEvent(state: MediaState.ready));
    });
    await tester.pumpAndSettle();
    expect(player.state.currentlyPlaying?.videoId, songActionsTrack.videoId);
    expect(player.state.currentQueueId, isNot(sourceOccurrence));
    expect(
        player.playlistReference?.playlistId, songActionsPlaylist.playlistId);
    await openSongActions(tester);
    expect(namedRemoval, findsNothing);
    expect(find.text('Add to playlist'), findsOneWidget);
  });

  testWidgets('passage bookmark opens the exact duplicate at its timestamp', (
    tester,
  ) async {
    await seedSongActions(
      tester,
      lengthSeconds: 180,
      source: songActionsPlaylist.copyWith(
        videoCount: 3,
        videos: [
          songActionsTrack,
          songActionsTrack.copyWith(indexId: 'source-membership-3'),
          songActionsNext,
        ],
      ),
    );
    const position = Duration(milliseconds: 27139);
    final markedId = player.state.currentQueueId;
    await tester.runAsync(() async {
      player.pause();
      player.seek(position);
    });
    final target = player.captureMusicPassage()!;
    expect(target.position, position);
    final store = MusicPassageBookmarks(db, db.profileId);
    final menu = find.byKey(const ValueKey('music-player-passage-bookmarks'));
    await openSongActions(tester);
    await tapSongAction(tester, menu);
    await tapSongAction(
        tester, find.byKey(const ValueKey('music-passage-bookmark-add')));
    expect(find.text('00:27.139'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('music-passage-bookmark-name')),
      'Verse',
    );
    await chooseAndWait(
      tester,
      find.text('Save'),
      () => store.list(target.recordingId).isNotEmpty,
    );
    expect(find.text('Verse'), findsOneWidget);
    final sheet = find.byKey(const ValueKey('music-passage-bookmarks-sheet'));
    Navigator.of(tester.element(sheet)).pop();
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      final duplicateId = player.state.playQueue.first;
      await player.selectQueueOccurrence(duplicateId);
      player.setEvent(const MediaEvent(state: MediaState.ready));
      expect(player.state.currentQueueId, duplicateId);
      expect(duplicateId, isNot(markedId));
      expect(player.state.currentlyPlaying?.videoId, songActionsTrack.videoId);
      player.pause();
    });
    await tester.pumpAndSettle();
    await openSongActions(tester);
    await tapSongAction(tester, menu);
    await chooseAndWait(
      tester,
      find.text('Verse'),
      () {
        if (player.state.currentQueueId != markedId) return false;
        player.setEvent(const MediaEvent(state: MediaState.ready));
        return true;
      },
    );
    expect(player.state.position, position);
    expect(player.state.isPlaying, isFalse);
    expect(sheet, findsNothing);
  });

  for (final change in [
    'current song',
    'queue',
    'profile',
    'playlist entries',
    'playlist membership',
  ]) {
    testWidgets('a Song actions menu cannot remove after changing $change',
        (tester) async {
      final other = songActionsOther
          .copyWith(videoCount: 1, videos: const [songActionsTrack]);
      await seedSongActions(tester, other: other);
      final origin = db.profileId;
      final current = player.state.currentQueueId;
      await openSongActions(tester);
      expect(namedRemoval.hitTestable(), findsOneWidget);
      await tester.runAsync(() async {
        switch (change) {
          case 'current song':
            await player.selectQueueOccurrence(player.state.playQueue.first);
            player.setEvent(const MediaEvent(state: MediaState.ready));
            expect(player.state.currentQueueId, isNot(current));
          case 'queue':
            await playActionPlaylist(other);
            expect(player.playlistReference?.playlistId, other.playlistId);
            expect(player.state.currentQueueId, current);
          case 'profile':
            final profile = await db.createProfile('Another listener');
            await db.useProfile(profile.id);
            app.profileChanged(profile.id);
          case 'playlist entries':
            await storeActionPlaylists(
                songActionsPlaylist.copyWith(videoCount: 3, videos: const [
                  songActionsTrack,
                  songActionsTrack,
                  songActionsNext,
                ]),
                other);
          case 'playlist membership':
            await service.deleteUserPlaylistVideo(
                songActionsPlaylist.playlistId, songActionsTrack.videoId);
            await service.addVideoToPlaylist(
                songActionsPlaylist.playlistId, songActionsTrack.videoId,
                video: songActionsTrack);
        }
      });
      await tester.pumpAndSettle();
      if (namedRemoval.hitTestable().evaluate().isNotEmpty) {
        await tester.runAsync(() async {
          await tester.tap(namedRemoval);
          await tester.pumpAndSettle();
        });
        await tester.pumpAndSettle();
      }
      expect(actionPlaylistEntries(songActionsPlaylist, profile: origin), [
        if (change != 'playlist membership') songActionsTrack.videoId,
        if (change == 'playlist entries') songActionsTrack.videoId,
        songActionsNext.videoId,
        if (change == 'playlist membership') songActionsTrack.videoId,
      ]);
      expect(actionPlaylistEntries(other, profile: origin),
          [songActionsTrack.videoId]);
    });
  }

  testWidgets(
      'Now Playing source opens its saved playlist and a distinct album without restarting',
      (tester) async {
    const title = 'Evening playlist';
    const bonus = Video(
        videoId: 'playlist-bonus',
        title: 'Playlist bonus track',
        musicMetadata:
            MusicMetadata(title: 'Playlist bonus track', artist: 'Singer'));
    const saved = Playlist(
        playlistId: 'local:evening',
        title: title,
        author: '',
        videoCount: 2,
        videos: [song, bonus]);
    await tester.runAsync(() => db.saveSetting(
        SettingsValue(localPlaylistsSetting, jsonEncode([saved.toJson()]))));
    player.sourcePlaylist = PlaylistReference.forPlaylist(saved, db);
    player.queueTitle = saved.title;
    final previousCatalog = musicCatalogService;
    final catalog = _ReleaseCatalog();
    musicCatalogService = catalog;
    addTearDown(() => musicCatalogService = previousCatalog);
    await pump(tester, size: const Size(360, 680));
    final source = find.byKey(const ValueKey('music-playing-source'));
    expect(source.hitTestable(), findsOneWidget);
    final footer =
        tester.getRect(find.byKey(const ValueKey('music-player-queue')));
    for (final id in ['music-player-sleep', 'music-player-sound']) {
      final utility = find.byKey(ValueKey(id));
      expect(utility.hitTestable(), findsOneWidget);
      expect(tester.getRect(utility).bottom, lessThanOrEqualTo(footer.top));
    }
    final playlistTitle =
        find.descendant(of: source, matching: find.text(title));
    final sourceFocus = Focus.of(tester.element(playlistTitle));
    sourceFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Playlist bonus track'), findsOneWidget);
    expect(find.text('Open playlist'), findsNothing);
    await pressAndroidBack(tester);
    expect(source.hitTestable(), findsOneWidget);
    expect(sourceFocus.hasPrimaryFocus, isTrue);
    expect(player.state.currentlyPlaying, same(song));
    expect(player.state.isMini, isFalse);

    const albumId = 'OLAK5uy_release42';
    final releaseTrack = song.copyWith(
        musicMetadata: const MusicMetadata(
            title: 'Song',
            artist: 'Singer',
            album: 'Release',
            albumPlaylistId: albumId));
    await player.seed(player.state.copyWith(
        videos: [releaseTrack, next], currentlyPlaying: releaseTrack));
    await tester.pumpAndSettle();
    await tester.tap(source);
    await tester.pumpAndSettle();
    expect(find.text('Open playlist'), findsOneWidget);
    expect(find.text('Open album'), findsOneWidget);
    await pressAndroidBack(tester);
    expect(catalog.releases, isEmpty);
    expect(source.hitTestable(), findsOneWidget);
    await tester.tap(source);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open album'));
    await tester.pumpAndSettle();
    expect(catalog.releases, [albumId]);
    final releaseSong = find.text('Release bonus track');
    await tester.scrollUntilVisible(releaseSong, 200,
        scrollable: find.descendant(
            of: find.byType(MusicScreen),
            matching: find.byWidgetPredicate((widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down)));
    expect(releaseSong.hitTestable(), findsOneWidget);
    await pressAndroidBack(tester);
    expect(source.hitTestable(), findsOneWidget);
    expect(player.state.currentlyPlaying, same(releaseTrack));
    expect(player.state.position, const Duration(seconds: 30));
    expect(player.state.playQueue, [next.videoId]);
    expect(player.musicPlayRequests, isEmpty);

    await tester.tap(source);
    await tester.pumpAndSettle();
    await player.seed(player.state.copyWith(currentlyPlaying: next));
    await tester.pumpAndSettle();
    final staleAlbum = find.text('Open album');
    if (staleAlbum.evaluate().isNotEmpty) {
      await tester.tap(staleAlbum);
      await tester.pumpAndSettle();
    }
    expect(catalog.releases, [albumId]);
    expect(find.text('Release bonus track'), findsNothing);
    expect(player.state.currentlyPlaying, same(next));
  });

  testWidgets(
      'Now Playing source keeps a manually queued song album distinct from its public album queue',
      (tester) async {
    const originId = 'OLAK5uy_origin';
    const originTitle = 'Original release';
    const otherId = 'OLAK5uy_other';
    const otherTitle = 'Other release';
    const original = MusicTrack(
        videoId: 'original',
        title: 'Original song',
        albumTitle: originTitle,
        albumPlaylistId: originId);
    const unlinked = MusicTrack(
        videoId: 'unlinked', title: 'Unlinked song', albumTitle: otherTitle);
    const linked = MusicTrack(
        videoId: 'linked',
        title: 'Linked song',
        albumTitle: otherTitle,
        albumPlaylistId: otherId);
    final previousCatalog = musicCatalogService;
    final previousService = service;
    final catalog = _ReleaseCatalog({
      originId: const MusicCollection(
          id: originId, title: originTitle, tracks: [original]),
      otherId: const MusicCollection(
          id: otherId, title: otherTitle, tracks: [unlinked, linked]),
    });
    musicCatalogService = catalog;
    service = _ReleasePlaybackService();
    addTearDown(() {
      musicCatalogService = previousCatalog;
      service = previousService;
    });
    final reference = PlaylistReference(
        kind: PlaylistSourceKind.public,
        playlistId: originId,
        displayTitle: originTitle,
        profileId: db.profileId);
    const ready = MediaEvent(state: MediaState.ready);
    await tester.runAsync(() async {
      player.audioSession = await AudioSession.instance;
      player.enqueueZone = Zone.current;
      await player.playPlaylist([original.toVideo()],
          reference: reference, fromMusic: true, audio: true);
      player.setEvent(ready);
    });
    expect(player.state.currentlyPlaying?.videoId, original.videoId);
    await pump(tester, size: const Size(360, 680));
    final source = find.byKey(const ValueKey('music-playing-source'));
    Finder sourceTitle(String title) =>
        find.descendant(of: source, matching: find.text(title));
    expect(sourceTitle(originTitle).hitTestable(), findsOneWidget);
    expect(tester.widget(source), isA<TextButton>());

    unawaited(Navigator.of(tester.element(source)).push<void>(MaterialPageRoute(
        builder: (_) => const MusicScreen(playlistId: otherId))));
    await tester.pumpAndSettle();
    final collectionScroll = find.descendant(
        of: find.byType(MusicScreen),
        matching: find.byWidgetPredicate((widget) =>
            widget is Scrollable &&
            widget.axisDirection == AxisDirection.down));
    for (final (index, track) in [unlinked, linked].indexed) {
      final row = find.byKey(ValueKey('music-song-$index-${track.videoId}'));
      await tester.scrollUntilVisible(row, 150, scrollable: collectionScroll);
      await tester.longPress(row);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('music-song-add-to-queue')));
      await tester.pumpAndSettle();
    }
    await pressAndroidBack(tester);
    expect(player.playlistReference, reference);
    final appended = player.state.playQueue.toList();
    expect(appended, hasLength(2));

    Future<void> select(String occurrence) async {
      await tester.runAsync(() async {
        await player.selectQueueOccurrence(occurrence);
        player.setEvent(ready);
      });
      await tester.pumpAndSettle();
    }

    await select(appended.first);
    expect(player.state.currentlyPlaying?.videoId, unlinked.videoId);
    expect(
        player.state.currentlyPlaying?.musicMetadata?.albumPlaylistId, isNull);
    expect(sourceTitle(otherTitle), findsNothing,
        reason: 'An unlinked album must never label the queue origin action.');
    expect(find.text(otherTitle).hitTestable(), findsOneWidget);
    expect(sourceTitle(originTitle).hitTestable(), findsOneWidget);
    expect(tester.widget(source), isA<TextButton>());
    final footer =
        tester.getRect(find.byKey(const ValueKey('music-player-queue')));
    for (final id in ['music-player-sleep', 'music-player-sound']) {
      final utility = find.byKey(ValueKey(id));
      expect(utility.hitTestable(), findsOneWidget);
      expect(tester.getRect(utility).bottom, lessThanOrEqualTo(footer.top));
    }
    await tester.tap(source);
    await tester.pumpAndSettle();
    expect(catalog.releases, [otherId, originId]);
    expect(find.byType(MusicScreen), findsOneWidget);
    expect(find.text(originTitle), findsOneWidget);
    await pressAndroidBack(tester);
    expect(player.state.currentQueueId, appended.first);

    await select(appended.last);
    expect(player.state.currentlyPlaying?.videoId, linked.videoId);
    expect(sourceTitle(otherTitle).hitTestable(), findsOneWidget);
    await tester.tap(source);
    await tester.pumpAndSettle();
    expect(find.text('Open playlist'), findsOneWidget);
    expect(find.text(originTitle), findsOneWidget);
    await tester.tap(find.text('Open playlist'));
    await tester.pumpAndSettle();
    expect(catalog.releases, [otherId, originId, originId]);
    await pressAndroidBack(tester);

    await tester.tap(source);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open album'));
    await tester.pumpAndSettle();
    expect(catalog.releases, [otherId, originId, originId, otherId]);
    await pressAndroidBack(tester);
    expect(player.state.currentQueueId, appended.last);
    expect(player.playlistReference, reference);
  });

  testWidgets(
      'Now Playing source ignores an unlinked album and a foreign playlist',
      (tester) async {
    player.queueTitle = 'Previous playlist';
    player.sourcePlaylist = const PlaylistReference(
        kind: PlaylistSourceKind.public,
        playlistId: 'PLother',
        profileId: 'other-profile',
        displayTitle: 'Foreign playlist');
    await pump(tester);
    expect(find.byKey(const ValueKey('music-playing-source')), findsNothing);
    expect(find.text('Album'), findsOneWidget);
    expect(player.musicPlayRequests, isEmpty);
  });

  testWidgets(
      'mini player long press opens the authorized device album and returns to the same song',
      (tester) async {
    final tracks = await seedDeviceQueue(tester, albumKey: 'a' * 64);
    await player.seed(player.state.copyWith(isMini: true));
    await pump(tester,
        child: const Align(
            alignment: Alignment.bottomCenter, child: MusicMiniPlayer()));
    final expand = find.byKey(const ValueKey('music-mini-expand'));
    final playing = player.state.offlineCurrentlyPlaying;
    await tester.longPress(expand);
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text(tracks.last.title), findsOneWidget);
    expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, tracks.first.title))
            .selected,
        isTrue);
    await pressAndroidBack(tester);
    expect(expand.hitTestable(), findsOneWidget);
    expect(player.state.isMini, isTrue);
    expect(player.state.offlineCurrentlyPlaying, same(playing));
    expect(player.state.playQueue, [tracks.last.playbackId]);
    expect(player.localQueueRequests, isEmpty);
  });

  testWidgets(
      'music video lookup skips download-only, offline and device songs',
      (tester) async {
    final catalog = await seedVideoSong(tester, downloadOnly: true);
    await pump(tester);
    expect(catalog.requests, isEmpty);
    expect(videoToggle, findsNothing);
    final source = player.state.currentlyPlaying!;
    final saved = DownloadedVideo(
        videoId: source.videoId,
        title: source.title!,
        lengthSeconds: source.lengthSeconds!,
        quality: 'audio',
        musicMetadata: source.musicMetadata,
        audioOnly: true,
        downloadComplete: true);
    final pinned = source.copyWith(
        downloadPlaybackOnly: false,
        explicitMusicDownload: musicDownloadFingerprint(saved));
    await player.seed(player.state
        .copyWith(videos: [pinned, next], currentlyPlaying: pinned));
    await tester.pumpAndSettle();
    expect(catalog.requests, isEmpty);
    expect(videoToggle, findsNothing);
    await player.seed(player.state.copyWith(
        currentlyPlaying: null,
        offlineCurrentlyPlaying: saved,
        videos: [],
        offlineVideos: [saved]));
    await tester.pumpAndSettle();
    expect(catalog.requests, isEmpty);
    expect(videoToggle, findsNothing);
    await seedDeviceQueue(tester);
    await tester.pumpAndSettle();
    expect(catalog.requests, isEmpty);
    expect(videoToggle, findsNothing);
  });

  const longOpeningTitle = 'Night train across the water and through the city '
      'before the closing reprise';
  for (final queue in [
    [next],
    [
      song,
      next.copyWith(
          musicMetadata: const MusicMetadata(
              title: longOpeningTitle, artist: 'Opening artist')),
    ]
  ]) {
    testWidgets(
        'Back minimizes the selected song from a ${queue.length}-song queue while its source opens',
        (tester) async {
      await player
          .seed(player.state.copyWith(videos: queue, currentlyPlaying: null));
      expect(player.openingSongTitle, isNull);
      final audio = _PendingAudioFocus();
      player.audioSession = audio;
      late Future<void> startup;
      await tester.runAsync(() async {
        startup = player.startSongs(queue, queue.length - 1);
      });
      final long = queue.length > 1;
      await pump(tester,
          size: long ? const Size(320, 568) : const Size(390, 844),
          scale: long ? 2.5 : 1,
          child: Stack(children: [Player(long ? 568 : 844)]));
      final opening = find.byType(MusicPlayerOpening);
      expect(opening, findsOneWidget);
      final title = find.descendant(
          of: opening, matching: find.text(queue.last.musicMetadata!.title));
      expect(title, findsOneWidget);
      if (long) {
        final paragraph = tester.renderObject<RenderParagraph>(title);
        expect(paragraph.didExceedMaxLines, isFalse);
        final first = paragraph.getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 5));
        final last = paragraph.getBoxesForSelection(TextSelection(
            baseOffset: longOpeningTitle.lastIndexOf('reprise'),
            extentOffset: longOpeningTitle.length));
        expect(last.last.top, greaterThan(first.first.top));
        await Scrollable.ensureVisible(tester.element(title), alignment: 1);
        await tester.pump();
        final lastGlyph = paragraph.localToGlobal(last.last.toRect().center);
        expect(tester.getRect(opening).contains(lastGlyph), isTrue);
      }
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(const ValueKey('music-player-play')), findsNothing);

      BackButtonInterceptor.add(player.handleBackButton,
          name: 'miniPlayer', zIndex: 2, ifNotYetIntercepted: true);
      await pressAndroidBack(tester);
      expect(player.state.isMini, isTrue);
      expect(player.state.videos.map((v) => v.videoId),
          queue.map((v) => v.videoId));
      expect(find.byType(MusicPlayerOpening), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        audio.activation.completeError(StateError('Audio focus interrupted'));
        await startup;
      });
      expect(player.openingSongTitle, isNull);
    });
  }

  for (final (tv, useSongActions) in [
    (false, false),
    (true, false),
    (false, true),
  ]) {
    testWidgets(
        'fullscreen artist opens the selected Music channel (TV: $tv, menu: $useSongActions)',
        (tester) async {
      const id = 'UC0123456789012345678901';
      final catalog = musicCatalogService;
      final previousTv = app_main.isTv;
      musicCatalogService = _ArtistCatalog();
      app_main.isTv = tv;
      addTearDown(() {
        musicCatalogService = catalog;
        app_main.isTv = previousTv;
      });
      final linked = const MusicTrack(videoId: 'song', title: 'Song', artists: [
        'First artist',
        'Featured artist',
        'Guest'
      ], artistLinks: [
        MusicArtist(id: 'UCabcdefghijklmnopqrstuv', name: 'First artist'),
        MusicArtist(id: id, name: 'Featured artist'),
      ]).toVideo();
      await player.seed(player.state
          .copyWith(videos: [linked, next], currentlyPlaying: linked));
      final router = RootStackRouter.build(routes: [
        if (tv)
          NamedRouteDef(
              name: 'PlayingRoute',
              path: '/',
              builder: (_, __) =>
                  const Scaffold(body: MusicPlayer(television: true)))
        else
          NamedRouteDef(
              name: MainRoute.name,
              path: '/',
              children: [
                NamedRouteDef(
                    name: 'BrowseRoute',
                    path: '',
                    builder: (_, __) => const Text('Previous page')),
                AutoRoute(page: MusicRoute.page),
              ],
              builder: (context, _) => Scaffold(
                      body: Stack(children: [
                    const AutoRouter(),
                    if (!context.watch<PlayerCubit>().state.isMini)
                      const MusicPlayer(),
                  ]))),
      ]);
      addTearDown(router.dispose);
      await pump(tester, child: Router.withConfig(config: router.config()));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextButton, 'First artist'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Guest'), findsNothing);
      expect(find.text('Guest'), findsOneWidget);
      if (useSongActions) {
        await openSongActions(tester);
        expect(find.text('Open artist: First artist'), findsOneWidget);
        expect(find.text('Open artist: Guest'), findsNothing);
      }
      final link = useSongActions
          ? find.text('Open artist: Featured artist')
          : find.widgetWithText(TextButton, 'Featured artist');
      await tester.ensureVisible(link);
      if (useSongActions) {
        await tapSongAction(tester, link);
      } else {
        await tester.tap(link);
        await tester.pumpAndSettle();
      }
      expect(find.text('Channel $id'), findsOneWidget);
      expect(player.state.currentlyPlaying?.videoId, 'song');
      expect(player.state.playQueue, ['next']);
      expect(player.state.position, const Duration(seconds: 30));
      expect(player.state.isMini, !tv);
      expect(player.musicPlayRequests, isEmpty);
      if (tv) {
        await tester.tap(find.byKey(const ValueKey('music-play-artist-songs')));
        await tester.pumpAndSettle();
        expect(player.musicPlayRequests.single.single.videoId, 'next');
        expect(find.byType(MusicPlayer), findsOneWidget);
      } else {
        final pages = router.innerRouterOf<StackRouter>(MainRoute.name)!;
        expect(router.stack, hasLength(1));
        expect(pages.stack.map((page) => page.name),
            ['BrowseRoute', MusicRoute.name]);
        await pages.maybePop();
        await tester.pumpAndSettle();
        expect(find.text('Previous page'), findsOneWidget);
      }
    });
  }

  testWidgets('device Song actions keep local queue and rename controls',
      (tester) async {
    await seedDeviceQueue(tester, allowRename: true);
    await pump(tester, size: const Size(360, 680));
    await openSongActions(tester);
    for (final label in ['Play', 'Play next', 'Add to queue', 'Rename file']) {
      expect(find.text(label), findsOneWidget);
    }
    for (final label in [
      'Add to playlist',
      'Download audio',
      'Open artist',
      'Save song',
    ]) {
      expect(find.text(label), findsNothing);
    }
  });

  testWidgets(
      'device songs show local artwork placeholders in expanded and mini playback',
      (tester) async {
    await seedDeviceQueue(tester);
    // The full player mounts its native audio decoder behind the Music UI.
    const audio = MethodChannel('com.ryanheise.just_audio.methods');
    final messenger = tester.binding.defaultBinaryMessenger;
    final channels = [audio];
    messenger.setMockMethodCallHandler(audio, (call) async {
      if (call.method == 'init') {
        final id = call.arguments['id'];
        for (final name in ['methods', 'events', 'data']) {
          final channel = MethodChannel('com.ryanheise.just_audio.$name.$id');
          channels.add(channel);
          messenger.setMockMethodCallHandler(
              channel,
              (request) async =>
                  request.method == 'load' ? {'duration': 180000000} : {});
        }
        return null;
      }
      return {};
    });
    addTearDown(() {
      for (final channel in channels) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
    await tester.runAsync(
        () => pump(tester, child: const Stack(children: [Player(844)])));
    final audioBuilder = find.byType(
        BlocBuilder<AudioPlayerCubit, AudioPlayerState>,
        skipOffstage: false);
    final decoder = tester.element(audioBuilder).read<AudioPlayerCubit>();
    try {
      void expectLocalArtwork(String key, IconData icon) {
        final artwork = find.byKey(ValueKey(key));
        expect(find.descendant(of: artwork, matching: find.byIcon(icon)),
            findsOneWidget);
        expect(find.byType(CommunityMusicArtwork, skipOffstage: false),
            findsNothing);
        expect(find.byType(Thumbnail, skipOffstage: false), findsNothing);
      }

      expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('music-player-title')))
              .data,
          'Intro');
      expectLocalArtwork('music-player-artwork', Icons.music_note);
      expect(find.byKey(const ValueKey('music-player-lyrics')), findsOneWidget);
      expect(find.byKey(const ValueKey('music-player-video-toggle')),
          findsNothing);
      expect(find.byKey(const ValueKey('music-player-audio-quality')),
          findsNothing);
      expect(find.byTooltip('Music actions'), findsNothing);
      expect(find.byType(VideoShareButton, skipOffstage: false), findsNothing);
      expect(
          find.byKey(
              ValueKey(('music-player-bookmark', player.state.currentQueueId))),
          findsNothing);
      await player.seed(player.state.copyWith(isMini: true));
      await tester.pump(const Duration(milliseconds: 500));
      expectLocalArtwork('music-mini-artwork', Icons.music_note_rounded);
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('music-mini-player')),
              matching: find.text('Intro')),
          findsOneWidget);
      await tap(tester, 'music-mini-next');
      expect(player.nextCalls, 1);
    } finally {
      await tester.runAsync(() async {
        final closed = decoder.stream.drain<void>();
        await tester.pumpWidget(const SizedBox.shrink());
        await closed.timeout(const Duration(seconds: 2));
      });
    }
  });

  testWidgets('device lyrics use the exact file and seek with the LRC offset',
      (tester) async {
    final calls = <MethodCall>[];
    final tracks = await seedDeviceQueue(tester, readLyrics: (call) async {
      calls.add(call);
      return {
        'sidecar': '[offset:+250]\n[00:01.500]Sidecar line',
        'embedded': 'Embedded fallback',
      };
    });
    await tester.runAsync(() => setLrclibEnabled(false));
    player.seekZone = await tester.runAsync(() async => Zone.current);
    final track = tracks.first;
    final occurrence = localMusicPlaybackEntry(track, db.profileId,
        occurrenceId: '${track.playbackId}#second');
    await player.seed(player.state.copyWith(
        offlineCurrentlyPlaying: occurrence,
        offlineVideos: [occurrence, ...player.state.offlineVideos]));
    var providerCalls = 0;
    await pump(tester, child: MusicPlayer(lyricsLoader: (_, __, ___) async {
      providerCalls++;
      return const MusicLyrics.unavailable();
    }));

    await tap(tester, 'music-player-lyrics');
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(isLrclibEnabled(), isFalse);
    expect(providerCalls, 0);
    expect(calls.single.arguments, {
      'treeUri':
          'content://com.android.externalstorage.documents/tree/primary%3AMusic',
      'selectionId': null,
      'trackUri': track.uri,
      'trackId': track.playbackId,
    });
    expect(find.text('Lyrics file'), findsOneWidget);
    expect(find.text('Embedded fallback'), findsNothing);
    await tester.tap(find.widgetWithText(ListTile, 'Sidecar line'));
    expect(player.sought, const Duration(milliseconds: 1250));
    await pressAndroidBack(tester);
  });

  testWidgets('device lyrics fall back to embedded and reload a missing file',
      (tester) async {
    var reads = 0;
    await seedDeviceQueue(tester, readLyrics: (call) async {
      if (++reads > 1) return null;
      return {'sidecar': '[ti:Metadata only]', 'embedded': 'Embedded line'};
    });
    var providerCalls = 0;
    await pump(tester, child: MusicPlayer(lyricsLoader: (_, __, ___) async {
      providerCalls++;
      return const MusicLyrics.unavailable();
    }));
    await tap(tester, 'music-player-lyrics');
    await tester.pumpAndSettle();
    expect(find.text('Embedded lyrics'), findsOneWidget);
    expect(find.text('Embedded line'), findsOneWidget);
    await pressAndroidBack(tester);

    await tap(tester, 'music-player-lyrics');
    await tester.pumpAndSettle();
    expect(find.text('No lyrics available for this track'), findsOneWidget);
    expect(find.text('Embedded line'), findsNothing);
    expect(providerCalls, 0);
    expect(reads, 2);
    await pressAndroidBack(tester);
  });

  testWidgets('device lyrics discard a pending file read after skipping',
      (tester) async {
    final pending = Completer<Object?>();
    await seedDeviceQueue(tester, readLyrics: (_) => pending.future);
    await pump(tester);
    await tap(tester, 'music-player-lyrics');
    await tester.pump(const Duration(milliseconds: 500));
    await player.seed(player.state
        .copyWith(offlineCurrentlyPlaying: player.state.offlineVideos.last));
    pending.complete({'sidecar': 'Previous track lyrics'});
    await tester.pumpAndSettle();
    expect(find.text('Previous track lyrics'), findsNothing);
    expect(find.text('No lyrics available for this track'), findsOneWidget);
    await pressAndroidBack(tester);
  });

  testWidgets(
      'device queue plays the selected local track and retains speed and pitch',
      (tester) async {
    const art =
        '/data/user/0/com.github.dvbeckwitt.videre/cache/local-music/cover.png';
    final tracks = await seedDeviceQueue(tester, embeddedArt: art);
    await pump(tester);
    await tap(tester, 'music-player-sound');
    await tester.pumpAndSettle();
    await tap(tester, 'playback-speed-increase');
    await tap(tester, 'playback-pitch-increase');
    expect(player.state.speed, 1.05);
    expect(player.state.pitchSemitones, 1);
    Navigator.of(tester
            .element(find.byKey(const ValueKey('playback-pitch-increase'))))
        .pop();
    await tester.pumpAndSettle();

    await tap(tester, 'music-player-queue');
    final second = tracks.last;
    final row = find.byKey(ValueKey('music-queue-${second.playbackId}'));
    expect(find.descendant(of: row, matching: find.text(second.title)),
        findsOneWidget);
    final embeddedImage = find.image(FileImage(File(art)));
    expect(find.descendant(of: row, matching: embeddedImage), findsOneWidget);
    expect(find.byType(CommunityMusicArtwork), findsNothing);
    await tester.longPress(row);
    await tester.pump();
    await tap(tester, 'music-queue-selection-menu');
    await tester.pumpAndSettle();
    expect(find.text('Save to playlist'), findsNothing);
    expect(find.text('Download audio'), findsNothing);
    expect(find.text('Play next'), findsOneWidget);
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    expect(player.localQueueRequests.single.single, same(second));
    expect(player.state.videos, isEmpty);
    final entry = player.state.offlineVideos.last;
    await pump(tester,
        child:
            MusicPlaybackArtwork(music: entry.musicMetadata, offline: entry));
    expect(embeddedImage, findsOneWidget);
    await tester.runAsync(LocalMusicLibrary.instance.disable);
    await tester.pump();
    expect(embeddedImage, findsNothing);
    expect(find.byIcon(Icons.music_note), findsOneWidget);
    expect(find.byType(CommunityMusicArtwork), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Lyrics asks before contacting LRCLIB and looks up the song once',
      (tester) async {
    final calls = <(String, String, int?, String)>[];
    await pump(tester,
        child: MusicPlayer(lyricsLoader: (track, duration, id) async {
      calls.add((track.title, track.artist, duration, id));
      return const MusicLyrics.synced([
        (start: Duration(seconds: 30), text: 'Fixture refrain'),
        (start: Duration(seconds: 33), text: 'Fixture refrain'),
      ], source: 'LRCLIB');
    }));
    expect(isLrclibEnabled(), isFalse);
    expect(calls, isEmpty);
    await tap(tester, 'music-player-lyrics');
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(calls, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(isLrclibEnabled(), isFalse);
    expect(calls, isEmpty);

    await tap(tester, 'music-player-lyrics');
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
    await tester.pumpAndSettle();
    expect(isLrclibEnabled(), isTrue);
    final reader = find.byKey(const ValueKey('music-lyrics-reader'));
    expect(tester.getSize(reader), tester.view.physicalSize);
    expect(find.byType(BottomSheet), findsNothing);
    expect(calls, [
      (
        song.musicMetadata!.title,
        song.musicMetadata!.artist,
        song.lengthSeconds,
        song.videoId
      )
    ]);
    expect(find.text('LRCLIB'), findsOneWidget);
    final lines = find.widgetWithText(ListTile, 'Fixture refrain');
    expect(lines, findsNWidgets(2));
    expect(tester.widget<ListTile>(lines.first).selected, isTrue);
    expect(tester.widget<ListTile>(lines.last).selected, isFalse);
    await tester.tap(lines.last);
    expect(player.sought, const Duration(seconds: 33));
    await player.seed(player.state.copyWith(currentlyPlaying: next));
    await tester.pumpAndSettle();
    expect(lines, findsNothing);
    expect(find.text('No lyrics available for this track'), findsOneWidget);
    await pressAndroidBack(tester);
    expect(player.state.currentlyPlaying?.videoId, next.videoId);
  });

  testWidgets('Timed lyric sharing requires permission for each export', (
    tester,
  ) async {
    const videoId = 'lyricshare1';
    await player.seed(player.state
        .copyWith(currentlyPlaying: song.copyWith(videoId: videoId)));
    await tester.runAsync(() async {
      await setLrclibEnabled(true);
      await MusicLyricsCorrections(db.forProfile(db.profileId)).save(
        videoId,
        const MusicLyricsCorrection(
          MusicLyrics.synced([
            (start: Duration(seconds: 30), text: 'The first selected line'),
            (start: Duration(seconds: 31), text: 'A line to leave out'),
            (start: Duration(seconds: 31), text: 'The second selected line'),
          ], source: 'LRCLIB'),
          edited: true,
        ),
      );
    });
    const channel = MethodChannel('dev.fluttercommunity.plus/share');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final shares = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      shares.add(call);
      return 'fixture-receiver';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await pump(
      tester,
      child: MusicPlayer(
        lyricsLoader: (_, __, ___) async => const MusicLyrics.unavailable(),
      ),
    );
    await tap(tester, 'music-player-lyrics');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Select lines'));
    await tester.pumpAndSettle();
    final shareLines = find.byKey(const ValueKey('music-lyrics-share'));
    final shareText = find.widgetWithText(FilledButton, 'Share text');
    final shareImage = find.widgetWithText(FilledButton, 'Share image');
    final permission = find.widgetWithText(
      CheckboxListTile,
      'I have permission to share these lyrics',
    );
    expect(tester.widget<FilledButton>(shareLines).onPressed, isNull);

    final first = find.widgetWithText(ListTile, 'The first selected line');
    final second = find.widgetWithText(ListTile, 'The second selected line');
    await tester.tap(second);
    await tester.tap(first);
    await tester.pumpAndSettle();
    expect(player.sought, isNull);
    expect(tester.widget<ListTile>(first).selected, isTrue);
    expect(tester.widget<ListTile>(second).selected, isTrue);

    await tester.tap(shareLines);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(shareText).onPressed, isNull);
    expect(tester.widget<FilledButton>(shareImage).onPressed, isNull);
    await pressAndroidBack(tester);
    expect(shares, isEmpty);
    expect(tester.widget<ListTile>(second).selected, isTrue);

    await tester.tap(shareLines);
    await tester.pumpAndSettle();
    await tester.tap(permission);
    await tester.pumpAndSettle();
    await tester.tap(shareText);
    await tester.pumpAndSettle();
    expect(shares.single.method, 'share');
    expect(
      shares.single.arguments['text'],
      'The first selected line\nThe second selected line\n\n'
      '${song.musicMetadata!.title}\n${song.musicMetadata!.artist}\n'
      'Lyrics source: LRCLIB\nUser-edited lyrics',
    );

    await tester.tap(shareLines);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(permission).value, isFalse);
    await tester.tap(permission);
    await tester.pumpAndSettle();
    await tester.runAsync(() => setLrclibEnabled(false));
    await tester.pumpAndSettle();
    await tester.tap(shareText);
    await tester.pumpAndSettle();
    expect(shares, hasLength(1));
    expect(find.text('No lyrics available for this track'), findsOneWidget);
  });

  for (final disableAnimations in [false, true]) {
    testWidgets(
        'Synced lyrics follow playback and yield to scrolling (motion off: $disableAnimations)',
        (tester) async {
      await tester.runAsync(() => setLrclibEnabled(true));
      final cues = [
        for (var i = 0; i < 80; i++)
          (start: Duration(seconds: i * 2), text: 'Lyric line $i'),
      ];
      await pump(tester,
          disableAnimations: disableAnimations,
          child: MusicPlayer(
              lyricsLoader: (_, __, ___) async => MusicLyrics.synced(cues)));
      await tap(tester, 'music-player-lyrics');
      await tester.pumpAndSettle();

      Finder line(int index) =>
          find.widgetWithText(ListTile, 'Lyric line $index');
      final viewport = find.descendant(
          of: find.byKey(const ValueKey('music-lyrics-lines')),
          matching: find.byType(Scrollable));
      final follow = find.widgetWithText(FilterChip, 'Follow lyrics');
      bool following() => tester.widget<FilterChip>(follow).selected;
      expect(line(15).hitTestable(), findsOneWidget);
      final selected = tester.widget<ListTile>(line(15));
      expect(selected.selected, isTrue);
      expect(selected.titleTextStyle?.fontWeight, FontWeight.w700);
      expect(
          tester
              .widget<AnimatedContainer>(find.descendant(
                  of: line(15), matching: find.byType(AnimatedContainer)))
              .duration,
          disableAnimations
              ? Duration.zero
              : const Duration(milliseconds: 180));
      expect(following(), isTrue);

      await player.seed(player.state.copyWith(position: cues[16].start));
      await tester.pumpAndSettle();
      expect(tester.widget<ListTile>(line(16)).selected, isTrue);
      expect(line(16).hitTestable(), findsOneWidget);
      expect(following(), isTrue);

      final rowFocus = Focus.of(tester.element(find.text('Lyric line 16')));
      rowFocus.requestFocus();
      await tester.pumpAndSettle();
      expect(following(), isFalse);
      final followFocus = Focus.of(tester.element(find.text('Follow lyrics')));
      followFocus.requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(following(), isTrue);
      expect(followFocus.hasPrimaryFocus, isTrue);

      await tester.drag(viewport, const Offset(0, 240));
      await tester.pumpAndSettle();
      expect(following(), isFalse);
      final pausedPosition = tester.state<ScrollableState>(viewport).position;
      final pausedOffset = pausedPosition.pixels;
      await player.seed(player.state.copyWith(position: cues[70].start));
      await tester.pumpAndSettle();
      expect(line(70).hitTestable(), findsNothing);
      expect(pausedPosition.pixels, pausedOffset);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(following(), isTrue);
      expect(line(70).hitTestable(), findsOneWidget);
      expect(tester.widget<ListTile>(line(70)).selected, isTrue);

      await tester.tap(follow);
      await tester.pump(const Duration(seconds: 6));
      expect(following(), isFalse);
      await tester.tap(follow);
      await tester.pumpAndSettle();
      expect(following(), isTrue);
      expect(line(70).hitTestable(), findsOneWidget);
      expect(tester.widget<ListTile>(line(70)).selected, isTrue);

      await player.seed(player.state.copyWith(position: Duration.zero));
      await tester.pumpAndSettle();
      expect(line(0).hitTestable(), findsOneWidget);
      expect(tester.widget<ListTile>(line(0)).selected, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Lyrics previews a scrub without seeking until release',
      (tester) async {
    await tester.runAsync(() => setLrclibEnabled(true));
    await pump(tester,
        child: MusicPlayer(
            lyricsLoader: (_, __, ___) async => const MusicLyrics.synced([
                  (start: Duration(seconds: 30), text: 'At playback'),
                  (start: Duration(seconds: 60), text: 'At scrub'),
                ])));
    await tap(tester, 'music-player-lyrics');
    await tester.pumpAndSettle();
    final progress = find.byKey(const ValueKey('music-lyrics-position'));
    final slider = tester.widget<Slider>(progress);
    final preview = find.byKey(const ValueKey('music-lyrics-seek-preview'));
    final target = find.widgetWithText(ListTile, 'At scrub');
    expect(tester.widget<ListTile>(target).selected, isFalse);
    slider.onChangeStart!(30000);
    slider.onChanged!(62000);
    await tester.pumpAndSettle();
    expect(player.sought, isNull);
    expect(tester.widget<Text>(preview).data, contains('At scrub'));
    expect(tester.widget<ListTile>(target).selected, isTrue);
    slider.onChangeEnd!(62000);
    await tester.pumpAndSettle();
    expect(player.sought, const Duration(seconds: 62));
    expect(preview, findsNothing);

    final cancelled = await tester.startGesture(tester.getCenter(progress));
    await cancelled.moveBy(const Offset(24, 0));
    await tester.pump();
    expect(preview, findsOneWidget);
    await cancelled.cancel();
    await tester.pumpAndSettle();
    expect(player.sought, const Duration(seconds: 62));
    expect(preview, findsNothing);

    final portraitSlider = tester.widget<Slider>(progress);
    portraitSlider.onChanged!(68000);
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    portraitSlider.onChangeEnd!(68000);
    expect(player.sought, const Duration(seconds: 62));
    expect(preview, findsNothing);
    expect(progress, findsOneWidget);

    final oldSlider = tester.widget<Slider>(progress);
    oldSlider.onChanged!(69000);
    await player.seed(player.state.copyWith(currentlyPlaying: next));
    await tester.pumpAndSettle();
    oldSlider.onChangeEnd!(69000);
    expect(player.sought, const Duration(seconds: 62));
    expect(progress, findsNothing);
  });

  testWidgets('Lyrics applies the current profile text preferences',
      (tester) async {
    await tester.runAsync(() async {
      await setLrclibEnabled(true);
      final otherProfile = await db.createProfile('Another lyrics reader');
      const preferences = MusicLyricsReaderPreferences(
          size: MusicLyricsTextSize.large,
          alignment: MusicLyricsTextAlignment.center);
      await preferences.save(db);
      final other = MusicLyricsReaderPreferences.forDatabase(
          db.forProfile(otherProfile.id));
      expect(other.size, MusicLyricsTextSize.medium);
      expect(other.alignment, MusicLyricsTextAlignment.start);
    });
    await pump(tester,
        size: const Size(320, 568),
        scale: 1.5,
        child: MusicPlayer(
            lyricsLoader: (_, __, ___) async =>
                const MusicLyrics.plain('First line\nSecond line')));
    await tap(tester, 'music-player-lyrics');
    await tester.pumpAndSettle();
    final text = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(text.style?.fontSize, MusicLyricsTextSize.large.fontSize);
    expect(text.textAlign, TextAlign.center);
    await tap(tester, 'music-lyrics-appearance');
    await tester.pumpAndSettle();
    expect(find.text('Text size'), findsOneWidget);
    expect(find.text('Alignment'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await pressAndroidBack(tester);
    expect(find.byKey(const ValueKey('music-lyrics-reader')), findsOneWidget);
  });

  testWidgets(
      'A lyric database miss on a captioned track never fetches speech text',
      (tester) async {
    final previousService = service;
    final captions = _CaptionService();
    service = captions;
    addTearDown(() => service = previousService);
    await tester.runAsync(() => setLrclibEnabled(true));
    final captioned = song.copyWith(
        captions: [
          Caption('English (auto-generated)', 'en', '/api/v1/captions/song')
        ],
        playbackConnection:
            BackendPlayback(const Server(url: 'https://playing.example')));
    await player.seed(player.state.copyWith(currentlyPlaying: captioned));
    var lookups = 0;
    await pump(tester, child: MusicPlayer(lyricsLoader: (_, __, ___) async {
      lookups++;
      return const MusicLyrics.unavailable();
    }));
    await tap(tester, 'music-player-lyrics');
    await tester.pumpAndSettle();
    expect(find.text('No lyrics available for this track'), findsOneWidget);
    expect(lookups, 1);
    expect(captions.requests, 0);
    await pressAndroidBack(tester);
    expect(player.state.position, const Duration(seconds: 30));
  });

  testWidgets(
      'Lyrics distinguishes plain text, instrumental, and a provider error',
      (tester) async {
    await tester.runAsync(() => setLrclibEnabled(true));
    var calls = 0;
    await pump(tester, child: MusicPlayer(lyricsLoader: (_, __, ___) async {
      calls++;
      if (calls == 1) throw StateError('temporary service failure');
      if (calls == 2) {
        return const MusicLyrics.plain('First line\nSecond line',
            source: 'LRCLIB');
      }
      return const MusicLyrics.instrumental(source: 'LRCLIB');
    }));
    await tap(tester, 'music-player-lyrics');
    await tester.pumpAndSettle();
    expect(find.text('Unable to load lyrics'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(find.text('First line\nSecond line'), findsOneWidget);
    expect(find.byKey(const ValueKey('music-lyrics-lines')), findsNothing);
    await pressAndroidBack(tester);
    await tap(tester, 'music-player-lyrics');
    await tester.pumpAndSettle();
    expect(find.text('Instrumental'), findsOneWidget);
    await pressAndroidBack(tester);
    expect(calls, 3);
  });

  testWidgets('Lyrics drops a late database response after consent is revoked',
      (tester) async {
    await tester.runAsync(() => setLrclibEnabled(true));
    final pending = Completer<MusicLyrics>();
    await pump(tester,
        child: MusicPlayer(lyricsLoader: (_, __, ___) => pending.future));
    await tap(tester, 'music-player-lyrics');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() => setLrclibEnabled(false));
    pending.complete(const MusicLyrics.plain('Stale result'));
    await tester.pumpAndSettle();
    expect(find.text('Stale result'), findsNothing);
    expect(find.text('No lyrics available for this track'), findsOneWidget);
    await pressAndroidBack(tester);
  });

  testWidgets('Lyrics opens a saved correction and invalidates its editor',
      (tester) async {
    const videoId = 'correction1';
    final recording = song.copyWith(videoId: videoId);
    await player.seed(player.state.copyWith(currentlyPlaying: recording));
    await tester.runAsync(() async {
      await setLrclibEnabled(true);
      await MusicLyricsCorrections(db.forProfile(db.profileId)).save(
        videoId,
        const MusicLyricsCorrection(
          MusicLyrics.plain('Saved line', source: 'LRCLIB'),
          edited: true,
        ),
      );
    });
    var automaticLookups = 0;
    await pump(tester, child: MusicPlayer(lyricsLoader: (_, __, ___) async {
      automaticLookups++;
      return const MusicLyrics.unavailable();
    }));

    await tap(tester, 'music-player-lyrics');
    await tester.pumpAndSettle();
    expect(find.text('Saved line'), findsOneWidget);
    expect(find.text('LRCLIB'), findsOneWidget);
    expect(find.text('Edited on this device'), findsOneWidget);
    expect(automaticLookups, 0);
    await tester.tap(find.byTooltip('Correct lyrics match'));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNWidgets(3));

    await player.seed(player.state.copyWith(currentlyPlaying: next));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNothing);
    expect(find.text('Saved line'), findsNothing);
    await pressAndroidBack(tester);
    expect(find.text('No lyrics available for this track'), findsOneWidget);
    await pressAndroidBack(tester);
  });

  testWidgets('the active profile controls cover corners in Now Playing',
      (tester) async {
    await pump(tester);
    final artwork = find.byKey(const ValueKey('music-player-artwork'));
    BorderRadiusGeometry? corners() =>
        (tester.widget<Container>(artwork).decoration! as BoxDecoration)
            .borderRadius;

    expect(corners(), isNot(BorderRadius.zero));
    await tester.runAsync(() async {
      final other = await db.createProfile('Another listener');
      await MusicCoverCorners.square.save(db);
      expect(MusicCoverCorners.forDatabase(db.forProfile(other.id)),
          MusicCoverCorners.rounded);
    });
    await tester.pump();
    expect(corners(), BorderRadius.zero);
    expect(player.state.currentlyPlaying, song);

    await tester.runAsync(() => MusicCoverCorners.rounded.save(db));
    await tester.pump();
    expect(corners(), isNot(BorderRadius.zero));
  });

  testWidgets('Now Playing animates only the painted cover within fixed bounds',
      (tester) async {
    await pump(tester);
    final frame = find.byKey(const ValueKey('music-player-artwork'));
    final pixels =
        find.descendant(of: frame, matching: find.byType(MusicPlaybackArtwork));
    final cover = find.byWidgetPredicate((widget) =>
        widget is Semantics &&
        widget.properties.image == true &&
        widget.properties.label == 'Album');
    final bounds = tester.getRect(frame);
    final paused = tester.getRect(pixels);
    final transport = find.byKey(const ValueKey('music-player-play'));
    final nextQueue = find.byKey(const ValueKey('music-player-queue'));
    final transportBounds = tester.getRect(transport);
    final queueBounds = tester.getRect(nextQueue);

    void expectFixedLayout(String action) {
      expect(tester.getRect(frame), bounds);
      expect(tester.getRect(cover), bounds);
      final node = tester.getSemantics(cover);
      final data = node.getSemanticsData();
      expect(data.label, 'Album');
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      expect(node.hintOverrides?.onTapHint, action);
      expect(tester.getRect(transport), transportBounds);
      expect(tester.getRect(nextQueue), queueBounds);
      final center = tester.getRect(pixels).center;
      expect(center.dx, closeTo(bounds.center.dx, 0.01));
      expect(center.dy, closeTo(bounds.center.dy, 0.01));
      expect(player.state.playQueue, [next.videoId]);
      expect(player.state.currentQueueId, song.videoId);
    }

    expect(paused.width, closeTo(bounds.width * 0.92, 0.01));
    expect(paused.height, closeTo(bounds.height * 0.92, 0.01));
    expectFixedLayout('Play');
    final edge = Offset(bounds.left + 2, bounds.center.dy);
    expect(paused.contains(edge), isFalse);
    await tester.tapAt(edge);
    expect(player.state.mediaCommand?.type, MediaCommandType.play);
    expect(player.state.isPlaying, isFalse);

    await player.seed(player.state.copyWith(isPlaying: true));
    await tester.pump();
    expect(tester.getRect(pixels).width, closeTo(paused.width, 0.01));
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getRect(pixels).width,
        allOf(greaterThan(paused.width), lessThan(bounds.width)));
    expectFixedLayout('Pause');
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.getRect(pixels), bounds);
    expectFixedLayout('Pause');
    await tester.tapAt(edge);
    expect(player.state.mediaCommand?.type, MediaCommandType.pause);
    expect(player.state.isPlaying, isTrue);

    await player.seed(player.state.copyWith(isPlaying: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getRect(pixels).width,
        allOf(greaterThan(paused.width), lessThan(bounds.width)));
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.getRect(pixels).width, closeTo(paused.width, 0.01));
    expectFixedLayout('Play');
  });

  testWidgets('Now Playing snaps cover targets when motion becomes limited',
      (tester) async {
    final motion = ValueNotifier((MotionPreference.system, false));
    addTearDown(motion.dispose);
    await pump(tester,
        child: ValueListenableBuilder(
          valueListenable: motion,
          builder: (context, value, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: value.$2),
            child: MotionScope(preference: value.$1, child: child!),
          ),
          child: const MusicPlayer(),
        ));
    final frame = find.byKey(const ValueKey('music-player-artwork'));
    final pixels =
        find.descendant(of: frame, matching: find.byType(MusicPlaybackArtwork));
    final width = tester.getRect(frame).width;
    final pausedWidth = width * 0.92;

    for (final policy in [
      (MotionPreference.reduced, false),
      (MotionPreference.off, false),
      (MotionPreference.system, true),
    ]) {
      motion.value = (MotionPreference.system, false);
      await tester.pump();
      await player.seed(player.state.copyWith(isPlaying: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.getRect(pixels).width,
          allOf(greaterThan(pausedWidth), lessThan(width)));

      motion.value = policy;
      await tester.pump();
      expect(tester.getRect(pixels).width, closeTo(width, 0.01));
      await player.seed(player.state.copyWith(isPlaying: false));
      await tester.pump();
      expect(tester.getRect(pixels).width, closeTo(pausedWidth, 0.01));
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.getRect(pixels).width, closeTo(pausedWidth, 0.01));
    }
  });

  for (final (size, scale) in [
    (const Size(320, 568), 2.5),
    (const Size(390, 844), 1.0),
    (const Size(680, 320), 1.0),
    (const Size(1024, 720), 2.0),
  ]) {
    testWidgets('music artwork and controls fit $size at text scale $scale',
        (tester) async {
      await pump(tester, size: size, scale: scale);
      final artwork =
          tester.getSize(find.byKey(const ValueKey('music-player-artwork')));
      expect(artwork.width, artwork.height);
      if (size == const Size(390, 844)) {
        expect(artwork.width, greaterThanOrEqualTo(350));
        expect(
            tester
                .getBottomRight(find.byKey(const ValueKey('music-player-play')))
                .dy,
            lessThanOrEqualTo(size.height));
      }
      expect(find.text('Singer'), findsWidgets);
      expect(find.text('Album'), findsOneWidget);
      await tester
          .ensureVisible(find.byKey(const ValueKey('music-player-repeat')));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('short landscape keeps artwork beside reachable transport',
      (tester) async {
    await pump(tester, size: const Size(568, 256));
    final art = find.byKey(const ValueKey('music-player-artwork'));
    final before = tester.getRect(art);
    final play =
        tester.getRect(find.byKey(const ValueKey('music-player-play')));
    expect(play.left, greaterThan(before.right));
    expect(play.bottom, lessThanOrEqualTo(256));
    await tap(tester, 'music-player-queue');
    expect(find.byType(MusicQueue), findsOneWidget);
    await tap(tester, 'music-player-close-queue');
    expect(tester.getRect(art), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Now Playing styles resize the same artwork and keep controls', (
    tester,
  ) async {
    await pump(tester, size: const Size(390, 844));
    final artwork = find.byType(MusicPlayerArtwork);
    final artworkState = tester.state(artwork);
    final classicSize = tester.widget<MusicPlayerArtwork>(artwork).size;

    await tester.runAsync(() => MusicNowPlayingStyle.largeArtwork.save(db));
    await tester.pump();
    expect(
      tester.widget<MusicPlayerArtwork>(artwork).size,
      greaterThan(classicSize),
    );
    expect(tester.state(artwork), same(artworkState));

    await tester.runAsync(() => MusicNowPlayingStyle.compact.save(db));
    await tester.pump();
    expect(
      tester.widget<MusicPlayerArtwork>(artwork).size,
      lessThan(classicSize),
    );
    expect(tester.state(artwork), same(artworkState));
    await tap(tester, 'music-player-queue');
    expect(find.byType(MusicQueue), findsOneWidget);
    await tap(tester, 'music-player-close-queue');

    await tester.runAsync(() => MusicNowPlayingStyle.largeArtwork.save(db));
    await pump(tester, size: const Size(320, 568), scale: 2.5);
    final play = find.byKey(const ValueKey('music-player-play'));
    await tester.ensureVisible(play);
    await tester.pumpAndSettle();
    expect(play.hitTestable(), findsOneWidget);
    await pump(tester, size: const Size(568, 256));
    expect(tester.getRect(artwork).right, lessThan(tester.getRect(play).left));
    expect(tester.state(artwork), same(artworkState));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Solid Now Playing removes only the decorative artwork backdrop',
    (tester) async {
      await pump(tester);
      final backdrop = find.byKey(
        const ValueKey('music-player-artwork-background'),
      );
      final artwork = find.byType(MusicPlayerArtwork);
      final artworkState = tester.state(artwork);
      final play = find.byKey(const ValueKey('music-player-play'));
      final playElement = tester.element(play);

      for (final palette in ThemePalette.values) {
        await tester.runAsync(() => settings.setThemePalette(palette));
        await tester.pump();
        final gradient = tester
            .widgetList<DecoratedBox>(
              find.descendant(
                of: backdrop,
                matching: find.byType(DecoratedBox),
              ),
            )
            .map((box) => (box.decoration as BoxDecoration).gradient)
            .whereType<LinearGradient>()
            .single;
        final colors = Theme.of(tester.element(play)).colorScheme;
        for (final scrim in gradient.colors) {
          final brightest = Color.alphaBlend(scrim, Colors.white);
          expect(
            (colors.onSurfaceVariant.computeLuminance() + 0.05) /
                (brightest.computeLuminance() + 0.05),
            greaterThanOrEqualTo(4.5),
          );
        }
      }

      await tester.runAsync(() => MusicPlayerBackground.solid.save(db));
      await tester.pump();
      expect(backdrop, findsNothing);
      expect(tester.state(artwork), same(artworkState));
      expect(tester.element(play), same(playElement));

      await tester.runAsync(() => MusicPlayerBackground.artwork.save(db));
      await tester.pump();
      expect(backdrop, findsOneWidget);
      expect(tester.state(artwork), same(artworkState));
      expect(tester.element(play), same(playElement));
    },
  );

  testWidgets('narrow Now Playing wraps the complete title with reduced motion',
      (tester) async {
    const fullTitle = 'The Night Train Across the Water and Through the City '
        'with Closing Reprise';
    final longSong = song.copyWith(
        musicMetadata:
            const MusicMetadata(title: fullTitle, artist: 'Long-title artist'));
    await pump(tester,
        size: const Size(320, 568), scale: 2.5, disableAnimations: true);
    await player.seed(player.state.copyWith(currentlyPlaying: longSong));
    await tester.pump();
    final title = find.byKey(const ValueKey('music-player-title'));
    final fade = find.byKey(const ValueKey('music-player-metadata'));
    expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
    expect(tester.widget<Text>(title).data, fullTitle);
    final paragraph = tester.renderObject<RenderParagraph>(title);
    expect(paragraph.didExceedMaxLines, isFalse);
    final first = paragraph.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: 3));
    final last = paragraph.getBoxesForSelection(TextSelection(
        baseOffset: fullTitle.lastIndexOf('Reprise'),
        extentOffset: fullTitle.length));
    expect(last.last.top, greaterThan(first.first.top));
    expect(last.last.bottom, lessThanOrEqualTo(paragraph.size.height));

    final viewport = find.byKey(const ValueKey('music-now-playing-scroll'));
    await Scrollable.ensureVisible(tester.element(title), alignment: 1);
    await tester.pumpAndSettle();
    final endOfTitle = paragraph.localToGlobal(last.last.toRect().center);
    expect(tester.getRect(viewport).contains(endOfTitle), isTrue);
    expect(
        find.descendant(of: fade, matching: find.bySemanticsLabel(fullTitle)),
        findsOneWidget);
    expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
    final play = find.byKey(const ValueKey('music-player-play'));
    await tester.ensureVisible(play);
    await tester.pumpAndSettle();
    expect(play.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  final advisoryBadge =
      find.byKey(const ValueKey('music-player-content-advisory'));

  ValueNotifier<PlayingMusicContentAdvisory?> trackAdvisories() {
    final advisories = ValueNotifier<PlayingMusicContentAdvisory?>(null);
    player.reportedMusicAdvisory = advisories;
    addTearDown(advisories.dispose);
    return advisories;
  }

  PlayingMusicContentAdvisory trackAdvisory(
          IdedVideo entry, MusicContentAdvisory advisory) =>
      (
        queueId: playbackQueueId(entry),
        generation: player.backendPlaybackGeneration,
        advisory: advisory,
      );

  testWidgets('Now Playing reports only the current known music advisory',
      (tester) async {
    final advisories = trackAdvisories();
    final unlabeled = song.copyWith(
        musicMetadata: const MusicMetadata(
            title: 'Singer’s explicit version', artist: 'Singer'));
    await player.seed(player.state.copyWith(currentlyPlaying: unlabeled));
    await pump(tester);
    expect(advisoryBadge, findsNothing);
    expect(find.bySemanticsLabel('Explicit'), findsNothing);

    advisories.value = trackAdvisory(unlabeled, MusicContentAdvisory.explicit);
    await tester.pump();
    expect(find.text('Explicit'), findsOneWidget);
    expect(find.bySemanticsLabel('Explicit'), findsOneWidget);
    final explicit = tester.getSemantics(advisoryBadge);
    expect(explicit.flagsCollection.isLiveRegion, isTrue);
    expect(explicit.label, 'Explicit');

    await player
        .seed(player.state.copyWith(position: const Duration(seconds: 35)));
    advisories.value = trackAdvisory(unlabeled, MusicContentAdvisory.explicit);
    await tester.pump();
    final progressed = tester.getSemantics(advisoryBadge);
    expect(progressed.id, explicit.id);
    expect(progressed.label, 'Explicit');
    expect(find.bySemanticsLabel('Explicit'), findsOneWidget);

    advisories.value = trackAdvisory(unlabeled, MusicContentAdvisory.clean);
    await tester.pump();
    expect(find.text('Explicit'), findsNothing);
    expect(find.text('Clean'), findsOneWidget);
    expect(find.bySemanticsLabel('Clean'), findsOneWidget);
    advisories.value = null;
    await tester.pump();
    expect(advisoryBadge, findsNothing);
    expect(find.bySemanticsLabel('Clean'), findsNothing);
  });

  testWidgets('Now Playing isolates advisories across previews and generations',
      (tester) async {
    final advisories = trackAdvisories();
    final first = song.copyWith(queueEntryId: 'advisory-first');
    final second = song.copyWith(
        queueEntryId: 'advisory-second',
        musicMetadata: const MusicMetadata(
            title: 'Alternate take of the same song', artist: 'Singer'));
    expect(first.videoId, second.videoId);
    expect(playbackQueueId(first), isNot(playbackQueueId(second)));
    await player.seed(player.state
        .copyWith(videos: [first, second], currentlyPlaying: first));
    advisories.value = trackAdvisory(first, MusicContentAdvisory.explicit);
    await pump(tester);
    expect(find.text('Explicit'), findsOneWidget);
    final artwork = find.byKey(const ValueKey('music-player-artwork'));
    final artworkRect = tester.getRect(artwork);

    player.previewMusicEntry = second;
    await player
        .seed(player.state.copyWith(position: const Duration(seconds: 32)));
    // The pending track's indeterminate indicator animates until it mounts.
    // Allow the finite metadata transition to finish while it is still pending.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Alternate take of the same song'), findsOneWidget);
    expect(advisoryBadge, findsNothing);
    expect(tester.getRect(artwork), artworkRect);
    advisories.value = trackAdvisory(second, MusicContentAdvisory.clean);
    await tester.pump();
    expect(advisoryBadge, findsNothing);

    // Cancelling the preview shows the active occurrence again.
    advisories.value = trackAdvisory(first, MusicContentAdvisory.explicit);
    player.previewMusicEntry = null;
    await player
        .seed(player.state.copyWith(position: const Duration(seconds: 33)));
    await tester.pumpAndSettle();
    expect(find.text('Explicit'), findsOneWidget);
    expect(tester.getRect(artwork), artworkRect);

    await player.seed(player.state.copyWith(currentlyPlaying: second));
    await tester.pumpAndSettle();
    expect(advisoryBadge, findsNothing);
    advisories.value = (
      queueId: playbackQueueId(second),
      generation: player.backendPlaybackGeneration - 1,
      advisory: MusicContentAdvisory.explicit,
    );
    await tester.pump();
    expect(advisoryBadge, findsNothing);
    advisories.value = trackAdvisory(second, MusicContentAdvisory.clean);
    await tester.pump();
    expect(find.bySemanticsLabel('Clean'), findsOneWidget);
  });

  testWidgets('an advisory keeps linked artists and transport accessible',
      (tester) async {
    const artist = 'Linked artist with a long name';
    final linked = song.copyWith(
        musicMetadata: const MusicMetadata(
            title: 'The final movement after the long evening performance',
            artist: artist,
            artistCredits: [
          MusicArtistCredit(name: artist, id: 'UCabcdefghijklmnopqrstuv'),
        ]));
    final advisories = trackAdvisories();
    await player.seed(player.state.copyWith(currentlyPlaying: linked));
    await pump(tester,
        size: const Size(320, 568), scale: 2.5, disableAnimations: true);
    final artistButton = find.widgetWithText(TextButton, artist);
    await tester.ensureVisible(artistButton);
    await tester.pumpAndSettle();
    final focus = Focus.of(tester.element(find.text(artist)));
    focus.requestFocus();
    await tester.pump();

    advisories.value = trackAdvisory(linked, MusicContentAdvisory.explicit);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.text(artist))), same(focus));
    expect(focus.hasFocus, isTrue);
    expect(tester.widget<TextButton>(artistButton).onPressed, isNotNull);
    await tester.ensureVisible(advisoryBadge);
    await tester.pumpAndSettle();
    expect(find.text('Explicit').hitTestable(), findsOneWidget);
    final play = find.byKey(const ValueKey('music-player-play'));
    await tester.ensureVisible(play);
    await tester.pumpAndSettle();
    expect(play.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final (source, present, catalogCover, savedCover, savedFrame) in [
    ('admitted download', true, true, false, false),
    ('admitted download', false, true, false, true),
    ('admitted download', true, true, true, true),
    ('explicit download', true, true, false, false),
    ('explicit download', true, false, false, true),
    ('explicit download', true, true, true, true),
    ('pinned download', true, true, true, false),
    ('replaced pinned download', true, true, true, false),
    ('pinned offline', true, true, true, false),
    ('replaced pinned offline', true, true, true, false),
    ('stream', true, false, false, false),
    ('stream', true, true, true, false),
  ]) {
    testWidgets(
        'Music artwork for $source (poster: $present, catalog: $catalogCover, saved: $savedCover, frame: $savedFrame)',
        (tester) async {
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      final messenger = tester.binding.defaultBinaryMessenger;
      final documents = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('videre-music-poster-')))!;
      messenger.setMockMethodCallHandler(
          pathProvider, (_) async => documents.path);
      addTearDown(() async {
        messenger.setMockMethodCallHandler(pathProvider, null);
        await documents.delete(recursive: true);
      });
      late String poster;
      File? coverFile;
      File? frameFile;
      late Server server;
      late DownloadedVideo saved;
      const songId = 'stockSong01';
      final idSong = song.copyWith(videoId: songId);
      final frame = ImageObject(
          'medium', 'https://i.ytimg.com/vi/$songId/mqdefault.jpg', 320, 180);
      final cover = ImageObject(
          null, 'https://lh3.googleusercontent.com/album=w512-h512', 512, 512);
      final music = MusicMetadata(
          title: 'Song',
          artist: 'Singer',
          thumbnails: [frame, if (catalogCover) cover]);
      await tester.runAsync(() async {
        await db.upsertServer(
            const Server(url: 'https://inv.example', inUse: true));
        await app.initState();
        server = app.state.server!;
        final audio = AdaptiveFormat(
            null,
            '128000',
            null,
            'https://inv.example/audio?itag=251',
            '251',
            'audio/webm; codecs="opus"',
            '12345',
            '1700000000000',
            'RECTANGULAR',
            'webm',
            'opus',
            null,
            null);
        final proof = DownloadPlaybackProvenance.create(
            video: idSong.copyWith(adaptiveFormats: [audio]),
            server: server,
            audioOnly: true,
            container: DownloadContainer.webm,
            audio: audio,
            videoFormat: null,
            byteLength: 12345,
            sha256: 'a' * 64)!;
        saved = DownloadedVideo(
            videoId: songId,
            title: 'Saved song',
            accountId: server.accountId,
            downloadComplete: true,
            audioOnly: true,
            container: DownloadContainer.webm,
            quality: 'audio',
            lengthSeconds: 180,
            musicMetadata: music,
            playbackProvenance: proof);
        await db.upsertDownload(saved);
        poster = await saved.thumbnailPath;
        final bytes = base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAACAAAAASCAIAAAC1qksFAAAAKklEQVR4nGP4z8BAEiJNNRlo1IJRC4ajBaTq+P+fgSQ0asGoBaMW/GcAAMouzU/PxmgLAAAAAElFTkSuQmCC');
        if (present) {
          await File(poster).writeAsBytes(bytes);
        }
        if (savedCover) {
          coverFile = (await saved.songCoverFile)!;
          await coverFile!.parent.create(recursive: true);
          await coverFile!.writeAsBytes(bytes);
        }
        if (savedFrame) {
          frameFile = (await saved.stockSongPosterFile)!;
          await frameFile!.parent.create(recursive: true);
          await frameFile!.writeAsBytes(bytes);
        }
      });

      final pin = switch (source) {
        'pinned download' ||
        'pinned offline' =>
          musicDownloadFingerprint(saved),
        'replaced pinned download' ||
        'replaced pinned offline' =>
          musicDownloadFingerprint(saved.copyWith(quality: 'previous')),
        _ => null,
      };
      final queued = idSong.copyWith(
          videoThumbnails: [frame],
          musicMetadata: music,
          explicitMusicDownload: pin);
      final explicit =
          source == 'explicit download' || source.endsWith(' offline');
      final offline = saved.copyWith(explicitMusicDownload: pin);
      final admitted = source == 'admitted download';
      await player.seed(player.state.copyWith(
          videos: explicit ? [] : [queued, next],
          offlineVideos: explicit ? [offline] : [],
          offlineCurrentlyPlaying: explicit ? offline : null,
          currentlyPlaying: explicit
              ? null
              : queued.copyWith(
                  playbackConnection: BackendPlayback(server),
                  playbackSourceId: admitted
                      ? DownloadPlaybackSource('file:///song', null, saved, {})
                      : null,
                  downloadPlaybackOnly: admitted)));
      // Exercise fallback selection without starting the image cache client.
      await pump(tester,
          size: const Size(1024, 720),
          child: const ServerScope(server: null, child: MusicPlayer()));

      final showsLocal = source != 'stream' &&
          !source.startsWith('replaced') &&
          (savedCover || savedFrame);
      final files = find.byWidgetPredicate(
          (widget) => widget is Image && widget.image is FileImage);
      Future<void> finishLocalCoverReads() async {
        final lookups = tester
            .widgetList<FutureBuilder<File?>>(find.byType(FutureBuilder<File?>))
            .map((widget) => widget.future!)
            .toList();
        if (lookups.isEmpty) return;
        var pending = lookups.length;
        for (final lookup in lookups) {
          unawaited(lookup.then<void>((_) {
            pending--;
          }));
        }
        final decoded = find.descendant(
            of: files,
            matching: find.byWidgetPredicate(
                (widget) => widget is RawImage && widget.image != null));
        bool waiting() =>
            pending > 0 ||
            (showsLocal && decoded.evaluate().length < lookups.length);
        await tester.runAsync(() async {
          final clock = Stopwatch()..start();
          while (waiting() && clock.elapsed < const Duration(seconds: 5)) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
            await tester.pump();
          }
        });
        await tester.pump();
        expect(waiting(), isFalse,
            reason: 'The mounted cover reads must finish');
      }

      final proxy = find.byType(Thumbnail);
      const queueKey = 'music-queue-$songId';
      final queue = find.byKey(const ValueKey(queueKey));
      void verifyArtwork(String artworkKey, IconData note) {
        final artwork = find.byKey(ValueKey(artworkKey));
        expect(artwork, findsOneWidget);
        final local = find.descendant(of: artwork, matching: files);
        final coverWidget = find.descendant(of: artwork, matching: proxy);
        if (queued.explicitMusicDownload != null) {
          expect(
              find.descendant(
                  of: artwork, matching: find.byType(CommunityMusicArtwork)),
              findsNothing);
        }
        if (showsLocal) {
          final file = tester.widget<Image>(local).image as FileImage;
          expect(file.file.path, (savedCover ? coverFile! : frameFile!).path);
          expect(file.file.path, isNot(poster));
          expect(coverWidget, findsNothing);
          expect(find.descendant(of: artwork, matching: find.byIcon(note)),
              findsNothing);
        } else if (source == 'stream') {
          expect(local, findsNothing);
          final thumbnail = tester.widget<Thumbnail>(coverWidget);
          expect(thumbnail.useInvidiousProxy, isTrue);
          expect(thumbnail.images!.map((image) => image.url), [
            if (catalogCover) cover.url,
            '/vi/$songId/mqdefault.jpg',
          ]);
        } else {
          expect(local, findsNothing);
          expect(coverWidget, findsNothing);
          expect(find.descendant(of: artwork, matching: find.byIcon(note)),
              findsOneWidget);
        }
      }

      await finishLocalCoverReads();
      verifyArtwork('music-player-artwork', Icons.music_note);
      expect(queue, findsOneWidget);
      verifyArtwork(queueKey, Icons.music_note);
      await pump(tester,
          child: const ServerScope(server: null, child: MusicMiniPlayer()));
      await finishLocalCoverReads();
      verifyArtwork('music-mini-artwork', Icons.music_note_rounded);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('only the active queue occurrence uses the hydrated artwork',
      (tester) async {
    const id = 'stockSong01';
    final queued = song.copyWith(videoId: id, queueEntryId: 'first');
    final second = queued.copyWith(queueEntryId: 'second');
    final frame = ImageObject('high', '/vi/$id/hqdefault.jpg', 480, 360);
    final playing = second.copyWith(
        videoThumbnails: [frame],
        musicMetadata: const MusicMetadata(
            title: 'Song', artist: 'Singer', isArtTrack: true));
    await player.seed(player.state.copyWith(
        videos: [queued, second],
        playedVideos: const ['first'],
        playQueue: ListQueue<String>(),
        currentlyPlaying: playing));
    await pump(tester,
        size: const Size(1024, 720),
        child: const ServerScope(server: null, child: MusicPlayer()));

    MusicPlaybackArtwork artwork(String occurrence) =>
        tester.widget<MusicPlaybackArtwork>(find.descendant(
            of: find.byKey(ValueKey('music-queue-$occurrence')),
            matching: find.byType(MusicPlaybackArtwork)));
    expect(artwork('first').video, same(queued));
    expect(artwork('first').video!.videoThumbnails, isEmpty);
    expect(artwork('second').video, same(playing));
    expect(artwork('second').video!.videoThumbnails.single, frame);
    expect(artwork('second').music!.isArtTrack, isTrue);
  });

  testWidgets(
      'portrait Lyrics and transport are visible with a long song title',
      (tester) async {
    final longSong = song.copyWith(
      musicMetadata: const MusicMetadata(
        title: 'James Brown - People Get Up And Drive That Funky Soul',
        artist: 'Uttkarsh Narayan',
      ),
    );
    await player.seed(player.state.copyWith(currentlyPlaying: longSong));
    await pump(tester,
        size: const Size(360, 720),
        child: const Padding(
          padding: EdgeInsets.only(top: 70, bottom: 24),
          child: MusicPlayer(),
        ));

    // The real player shares the viewport with Android bars and a toolbar.
    // All primary and secondary controls should be reachable without a scroll.
    final rail = find.byKey(const ValueKey('music-player-actions'));
    final footer = find.byKey(const ValueKey('music-player-queue'));
    expect(tester.getRect(rail).bottom,
        lessThanOrEqualTo(tester.getTopLeft(footer).dy));
    for (final control in [
      'play',
      'queue',
      'sleep',
      'sound',
      'audio-quality'
    ]) {
      expect(find.byKey(ValueKey('music-player-$control')).hitTestable(),
          findsOneWidget);
    }
    final lyrics = find.byKey(const ValueKey('music-player-lyrics'));
    expect(lyrics.hitTestable(), findsOneWidget);
    expect(find.descendant(of: lyrics, matching: find.text('Lyrics')),
        findsOneWidget);
    await tester.tap(lyrics);
    await tester.pumpAndSettle();
    expect(find.text('Enable LRCLIB lyrics?'), findsOneWidget);
    await pressAndroidBack(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('secondary music actions remain reachable with large text',
      (tester) async {
    player.sleep(const SleepTimer(duration: Duration(minutes: 5)));
    await pump(tester, size: const Size(320, 568), scale: 1.8);
    await tap(tester, 'music-player-sleep');
    expect(player.state.hasTimer, isFalse);
    await tap(tester, 'music-player-sound');
    await tester.pumpAndSettle();
    final increase = find.byKey(const ValueKey('playback-speed-increase'));
    await tester.ensureVisible(increase);
    await tester.tap(increase);
    await tester.pump();
    expect(player.state.speed, 1.05);
    Navigator.of(tester.element(increase)).pop();
    await tester.pumpAndSettle();
    await tap(tester, 'music-player-queue');
    expect(find.byType(MusicQueue), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Android Back closes both Music quality dialogs before the player',
      (tester) async {
    await pump(tester);
    BackButtonInterceptor.add(player.handleBackButton,
        name: 'miniPlayer', zIndex: 2, ifNotYetIntercepted: true);
    await tap(tester, 'music-player-audio-quality');
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await pressAndroidBack(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(player.state.isMini, isFalse);

    const quality = (itag: '140', bitrate: 128000, codec: 'AAC', trackId: null);
    player.musicAudioQuality = MusicAudioQualityMenu(
        videoId: song.videoId,
        choices: [quality],
        selected: null,
        effective: quality,
        saved: false,
        select: (_) async => fail('Dismissing must preserve the rendition'));
    await tap(tester, 'music-player-audio-quality');
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsOneWidget);
    await pressAndroidBack(tester);
    expect(find.byType(SimpleDialog), findsNothing);
    expect(player.state.isMini, isFalse);
    await pressAndroidBack(tester);
    expect(player.state.isMini, isTrue);
  });

  testWidgets('Android Back unwinds Music queue popup, selection and player',
      (tester) async {
    await pump(tester);
    BackButtonInterceptor.add(player.handleBackButton,
        name: 'miniPlayer', zIndex: 2, ifNotYetIntercepted: true);
    final originalInterceptors = BackButtonInterceptor.describe();

    await openSongActions(tester);
    expect(find.text('Save song'), findsOneWidget);
    await pressAndroidBack(tester);
    expect(find.text('Save song'), findsNothing);
    expect(player.state.isMini, isFalse);

    await tap(tester, 'music-player-queue');
    expect(find.byType(MusicQueue), findsOneWidget);

    await tap(tester, 'music-queue-menu-${next.videoId}');
    await tester.pumpAndSettle();
    expect(find.text('Remove from queue'), findsOneWidget);
    await pressAndroidBack(tester);
    expect(find.text('Remove from queue'), findsNothing);
    expect(find.byType(MusicQueue), findsOneWidget);
    expect(player.state.isMini, isFalse);

    await tap(tester, 'music-queue-select-mode');
    await tester.tap(find.byTooltip('Select all'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await tap(tester, 'music-queue-selection-menu');
    await tester.pumpAndSettle();
    expect(find.text('Play next'), findsOneWidget);

    await pressAndroidBack(tester);
    expect(find.text('Play next'), findsNothing);
    expect(find.text('2 selected'), findsOneWidget);
    expect(player.state.isMini, isFalse);

    await pressAndroidBack(tester);
    expect(find.text('2 selected'), findsNothing);
    expect(find.byType(MusicQueue), findsOneWidget);
    expect(player.state.isMini, isFalse);

    await pressAndroidBack(tester);
    expect(find.byType(MusicQueue), findsNothing);
    expect(player.state.isMini, isFalse);
    expect(BackButtonInterceptor.describe(), originalInterceptors);
    await pressAndroidBack(tester);
    expect(player.state.isMini, isTrue);
    expect(tester.takeException(), isNull);
  });

  Finder queueFooterText(String text) => find.descendant(
      of: find.byKey(const ValueKey('music-player-queue')),
      matching: find.textContaining(text, findRichText: true));

  testWidgets(
      'phone queue previews the next occurrence while paused and locked',
      (tester) async {
    const title = 'Alternate take of the same song';
    const artist = 'Guest artist';
    final songs = assignPlaybackQueueIds([
      song,
      next,
      song.copyWith(
          musicMetadata: const MusicMetadata(title: title, artist: artist)),
    ]);
    await settings.saveSetting(SettingsValue(playerShuffle, 'true'));
    await player.seed(player.state.copyWith(
        videos: songs,
        currentlyPlaying: songs.first,
        playQueue: ListQueue.of([playbackQueueId(songs.last), next.videoId])));
    await pump(tester);
    final footer = find.byKey(const ValueKey('music-player-queue'));
    expect(settings.state.playerShuffleMode, isTrue);
    expect(player.state.isPlaying, isFalse);
    expect(queueFooterText('Next in queue'), findsWidgets);
    expect(queueFooterText(title), findsWidgets);
    expect(queueFooterText(artist), findsWidgets);
    final label = tester.semantics.find(footer).label;
    expect(label, contains('Queue'));
    expect(label, contains(title));
    expect(label, contains(artist));

    await tap(tester, 'music-player-queue');
    expect(find.byType(MusicQueue), findsOneWidget);
    await tap(tester, 'music-queue-lock');
    expect(find.text('Queue editing locked'), findsOneWidget);
    await pressAndroidBack(tester);
    expect(queueFooterText(title), findsWidgets);
    expect(tester.widget<TextButton>(footer).focusNode!.hasFocus, isTrue);
    expect(player.state.currentQueueId, playbackQueueId(songs.first));
    expect(player.nextCalls, 0);

    // A changed traversal may retain both the original source list and song.
    await player.seed(player.state.copyWith(
        playQueue: ListQueue.of([next.videoId, playbackQueueId(songs.last)])));
    await tester.pump();
    expect(queueFooterText(title), findsNothing);
    expect(queueFooterText('Singer'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone queue handles repeat modes and the end of a loaded page',
      (tester) async {
    player.queueComplete = false;
    await player.seed(player.state.copyWith(
        currentlyPlaying: next,
        playedVideos: [song.videoId],
        playQueue: ListQueue<String>()));
    await pump(tester);
    expect(queueFooterText('Queue'), findsWidgets);
    expect(queueFooterText('Next in queue'), findsNothing);

    await tester.runAsync(() => settings.setRepeatMode(PlayerRepeat.repeatAll));
    await tester.pump();
    expect(queueFooterText('Next in queue'), findsNothing);
    player.queueComplete = true;
    player.playlistLoadingRevision.value++;
    await tester.pump();
    expect(queueFooterText('Song'), findsWidgets);
    expect(queueFooterText('Singer'), findsWidgets);
    await tester.runAsync(() => settings.setRepeatMode(PlayerRepeat.repeatOne));
    await tester.pump();
    expect(queueFooterText('Next in queue'), findsNothing);
    await player.seed(player.state.copyWith(
        currentlyPlaying: song,
        playedVideos: [],
        playQueue: ListQueue.of([next.videoId])));
    await tester.pump();
    expect(queueFooterText('Next in queue'), findsWidgets);
    expect(queueFooterText('Singer'), findsWidgets);
  });

  testWidgets('phone queue previews local track tags after changing source',
      (tester) async {
    await pump(tester);
    expect(queueFooterText('Singer'), findsWidgets);
    await seedDeviceQueue(tester);
    await tester.pumpAndSettle();
    expect(queueFooterText('Finale'), findsWidgets);
    expect(queueFooterText('Device artist'), findsWidgets);
    expect(queueFooterText('Singer'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow RTL queue preview keeps the full next song accessible',
      (tester) async {
    const title = 'الأغنية التالية من التسجيل الحي للحفلة الطويلة في المدينة';
    const artist = 'فرقة موسيقية مع ضيوف الحفل';
    final longSong = next.copyWith(
        musicMetadata: const MusicMetadata(title: title, artist: artist));
    await player.seed(player.state.copyWith(videos: [song, longSong]));
    await pump(tester,
        size: const Size(320, 568),
        scale: 2.1,
        child: const Directionality(
            textDirection: TextDirection.rtl, child: MusicPlayer()));
    final preview = find.byKey(const ValueKey('music-queue-next-preview'));
    final footer = find.byKey(const ValueKey('music-player-queue'));
    final paragraph = tester.renderObject<RenderParagraph>(preview);
    expect(paragraph.textDirection, TextDirection.rtl);
    expect(paragraph.didExceedMaxLines, isTrue);
    expect(footer.hitTestable(), findsOneWidget);
    expect(tester.getRect(footer).contains(tester.getCenter(preview)), isTrue);
    final label = tester.semantics.find(footer).label;
    expect(label, contains('Next in queue'));
    expect(label, contains(title));
    expect(label, contains(artist));
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone queue follows a pull, cancels and closes with Back',
      (tester) async {
    await pump(tester);
    BackButtonInterceptor.add(player.handleBackButton,
        zIndex: 2, ifNotYetIntercepted: true);
    addTearDown(() => BackButtonInterceptor.remove(player.handleBackButton));
    final entry = player.state.currentlyPlaying;
    final position = player.state.position;
    final footer = find.byKey(const ValueKey('music-player-queue'));
    final header = find.byKey(const ValueKey('music-queue-drag-header'));

    final cancelled = await tester.startGesture(tester.getCenter(footer));
    await cancelled.moveBy(const Offset(0, -36));
    await cancelled.moveBy(const Offset(0, -60));
    await tester.pump();
    final start = tester.getTopLeft(header).dy;
    await cancelled.moveBy(const Offset(0, -50));
    await tester.pump();
    expect(tester.getTopLeft(header).dy, closeTo(start - 50, 1));
    await cancelled.moveBy(const Offset(0, -430));
    await tester.pump();
    await cancelled.cancel();
    await tester.pumpAndSettle();
    expect(find.byType(MusicQueue), findsNothing);

    await tester.fling(footer, const Offset(0, -180), 1250);
    await tester.pumpAndSettle();
    expect(find.byType(MusicQueue), findsOneWidget);
    expect(header.hitTestable(), findsOneWidget);
    await tester.fling(header, const Offset(0, 180), 1250);
    await tester.pumpAndSettle();
    expect(find.byType(MusicQueue), findsNothing);
    expect(footer.hitTestable(), findsOneWidget);

    final holding = await tester.startGesture(tester.getCenter(footer));
    await holding.moveBy(const Offset(0, -35));
    await holding.moveBy(const Offset(0, -450));
    await tester.pump();
    await pressAndroidBack(tester);
    await holding.up();
    await tester.pumpAndSettle();
    expect(player.state.isMini, isFalse);
    expect(find.byType(MusicQueue), findsNothing);

    await tap(tester, 'music-player-queue');
    await pressAndroidBack(tester);
    expect(find.byType(MusicQueue), findsNothing);
    expect(player.state.isMini, isFalse);
    expect(player.state.currentlyPlaying, same(entry));
    expect(player.state.position, position);
    await pressAndroidBack(tester);
    expect(player.state.isMini, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final initiallyOpen in [false, true]) {
    testWidgets('resizing during a queue drag restores open=$initiallyOpen',
        (tester) async {
      await pump(tester);
      final footer = find.byKey(const ValueKey('music-player-queue'));
      final header = find.byKey(const ValueKey('music-queue-drag-header'));
      if (initiallyOpen) await tap(tester, 'music-player-queue');
      final handle = initiallyOpen ? header : footer;
      final originalY = tester.getTopLeft(handle).dy;
      final drag = await tester.startGesture(tester.getCenter(handle));
      final direction = initiallyOpen ? 1.0 : -1.0;
      await drag.moveBy(Offset(0, direction * 40));
      await drag.moveBy(Offset(0, direction * 260));
      await tester.pump();
      expect(tester.getTopLeft(header).dy, isNot(closeTo(originalY, 2)));

      tester.view.physicalSize = const Size(960, 640);
      await tester.pumpAndSettle();
      expect(header, findsNothing);
      await drag.up();
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();

      expect(handle.hitTestable(), findsOneWidget);
      expect(tester.getTopLeft(handle).dy, closeTo(originalY, 1));
      expect(find.byType(MusicQueue),
          initiallyOpen ? findsOneWidget : findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('phone queue contains keyboard focus above the browsing page',
      (tester) async {
    final browsingFocus = FocusNode(debugLabel: 'Covered Music search');
    addTearDown(browsingFocus.dispose);
    await pump(tester,
        child: Stack(children: [
          Center(child: TextField(focusNode: browsingFocus)),
          const MusicPlayer(),
        ]));
    await tap(tester, 'music-player-queue');
    await tester.pumpAndSettle();
    for (final key in [
      ...List.filled(32, LogicalKeyboardKey.tab),
      ...List.filled(12, LogicalKeyboardKey.arrowDown),
      ...List.filled(12, LogicalKeyboardKey.arrowUp),
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
      expect(browsingFocus.hasFocus, isFalse,
          reason: 'Queue traversal must not focus the covered search field');
    }
    await pressAndroidBack(tester);
    expect(find.byType(MusicQueue), findsNothing);
    final queueButton = tester
        .widget<TextButton>(find.byKey(const ValueKey('music-player-queue')));
    expect(queueButton.focusNode!.hasFocus, isTrue);
    final sound = find.byKey(const ValueKey('music-player-sound'));
    final soundIcon = find.descendant(of: sound, matching: find.byType(Icon));
    final soundFocus = Focus.of(tester.element(soundIcon));
    for (var index = 0; index < 24 && !soundFocus.hasFocus; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(soundFocus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-sound-scroll')), findsOneWidget,
        reason: 'Closing the queue restores access to the Sound modal');
    expect(tester.takeException(), isNull);
  });

  testWidgets('queue lock and selection keep duplicate occurrences independent',
      (tester) async {
    final songs = assignPlaybackQueueIds([song, song, next]);
    await player.seed(player.state.copyWith(
      videos: songs,
      currentlyPlaying: songs.first,
      playQueue: ListQueue.of(songs.skip(1).map(playbackQueueId)),
    ));
    await pump(tester);
    await tap(tester, 'music-player-queue');
    final duplicateId = playbackQueueId(songs[1]);
    final activeId = playbackQueueId(songs.first);
    final drag = find.byKey(ValueKey('music-queue-drag-$duplicateId'));
    expect(drag, findsOneWidget);
    await tap(tester, 'music-queue-lock');
    expect(drag, findsNothing);
    expect(find.text('Queue editing locked'), findsOneWidget);
    await tap(tester, 'music-queue-lock');
    expect(drag, findsOneWidget);
    expect(find.text('Queue editing locked'), findsNothing);

    final duplicateRow = find.byKey(ValueKey('music-queue-$duplicateId'));
    await tester.drag(duplicateRow, const Offset(340, 0));
    await tester.pumpAndSettle();
    await tester.drag(duplicateRow, const Offset(-340, 0));
    await tester.pumpAndSettle();
    expect(
        player.state.videos.map(playbackQueueId), songs.map(playbackQueueId));
    expect(
        find.byKey(ValueKey('music-queue-select-$duplicateId')), findsNothing);

    await tester.longPress(find.byKey(ValueKey('music-queue-$duplicateId')));
    await tester.pumpAndSettle();
    bool checked(String id) => tester
        .widget<Checkbox>(find.byKey(ValueKey('music-queue-select-$id')))
        .value!;
    expect(checked(duplicateId), isTrue);
    expect(checked(activeId), isFalse);
    await tap(tester, 'music-queue-selection-menu');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove selected from queue'));
    await tester.pumpAndSettle();
    expect(player.state.videos.map(playbackQueueId), [activeId, next.videoId]);
    expect(player.state.currentQueueId, activeId);
  });

  testWidgets('long-pressing next seeks without changing tracks',
      (tester) async {
    await pump(tester);
    final nextButton = find.byKey(const ValueKey('music-player-next'));
    await tester.ensureVisible(nextButton);
    await tester.longPress(nextButton);
    expect(player.sought, Duration(seconds: 30 + settings.state.skipStep));
    expect(player.nextCalls, 0);
    expect(player.state.currentQueueId, playbackQueueId(song));
  });

  testWidgets(
      'full-player cover seeks use the configured step and clamp within the song',
      (tester) async {
    // Each seek checkpoints to SQLite while the test advances the frame clock.
    player.seekZone = await tester.runAsync(() async => Zone.current);
    await settings.saveSetting(SettingsValue(skipStepSettingName, '15'));
    await settings.saveSetting(
        SettingsValue(musicArtworkDoubleTapSeekSettingName, 'true'));
    final short = song.copyWith(lengthSeconds: 40);
    await player.seed(
        player.state.copyWith(videos: [short, next], currentlyPlaying: short));
    await pump(tester);
    final cover =
        tester.getRect(find.byKey(const ValueKey('music-player-artwork')));
    final right = Offset(cover.right - 2, cover.center.dy);
    final left = Offset(cover.left + 2, cover.center.dy);
    Future<void> doubleTap(Offset point) async {
      await tester.tapAt(point);
      await tester.pump(kDoubleTapMinTime + const Duration(milliseconds: 10));
      await tester.tapAt(point);
      await tester.pump(kDoubleTapTimeout);
    }

    await doubleTap(right);
    expect(player.sought, const Duration(seconds: 40));
    await doubleTap(left);
    expect(player.sought, const Duration(seconds: 25));
    await doubleTap(left);
    expect(player.sought, const Duration(seconds: 10));
    await doubleTap(left);
    expect(player.sought, Duration.zero);
    expect(player.state.currentQueueId, playbackQueueId(song));
    expect(player.state.isPlaying, isFalse);
    expect(player.nextCalls, 0);
    expect(player.previousCalls, 0);
  });

  testWidgets(
      'music controls use shared transport seek shuffle repeat and queue',
      (tester) async {
    await pump(tester);
    await tap(tester, 'music-player-play');
    expect(player.state.mediaCommand!.type, MediaCommandType.play);
    await tap(tester, 'music-player-next');
    await tap(tester, 'music-player-previous');
    expect(player.nextCalls, 1);
    expect(player.previousCalls, 1);

    final slider = tester
        .widget<Slider>(find.byKey(const ValueKey('music-player-progress')));
    slider.onChanged!(45000);
    slider.onChangeEnd!(45000);
    await tester.pump();
    expect(player.sought, const Duration(seconds: 45));
    await tap(tester, 'music-player-shuffle');
    expect(settings.state.playerShuffleMode, isTrue);
    final repeatButton = find.byKey(const ValueKey('music-player-repeat'));
    await tester.ensureVisible(repeatButton);
    await tester.pump();
    await tester.runAsync(() async {
      final committed = settings.stream.firstWhere(
          (state) => state.playerRepeatMode == PlayerRepeat.repeatAll);
      await tester.tap(repeatButton);
      await committed.timeout(const Duration(seconds: 5));
    });
    await tester.pump();
    expect(settings.state.playerRepeatMode, PlayerRepeat.repeatAll);
    expect(db.getSettings(playerRepeat)?.value,
        PlayerRepeat.repeatAll.index.toString());
    await tap(tester, 'music-player-queue');
    expect(find.byType(MusicQueue), findsOneWidget);
    await tap(tester, 'music-player-close-queue');
    expect(find.byKey(const ValueKey('music-player-title')), findsOneWidget);
  });

  testWidgets('expanded phone and tablet music avoid video information tabs',
      (tester) async {
    for (final widget in [
      const ExpandedPlayer(),
      const TabletExpandedPlayer()
    ]) {
      await pump(tester, child: widget);
      expect(find.byType(MusicPlayer), findsOneWidget);
      expect(find.byType(VideoInfo), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('unknown duration and live music cannot seek to a fabricated end',
      (tester) async {
    await tester.runAsync(() => setLrclibEnabled(true));
    await settings.saveSetting(
        SettingsValue(musicArtworkDoubleTapSeekSettingName, 'true'));
    for (final track in [
      song.copyWith(lengthSeconds: null),
      song.copyWith(liveNow: true)
    ]) {
      await player.seed(player.state.copyWith(currentlyPlaying: track));
      await pump(tester,
          child: MusicPlayer(
              lyricsLoader: (_, __, ___) async => const MusicLyrics.synced(
                  [(start: Duration(seconds: 10), text: 'Fixture line')])));
      final slider = tester
          .widget<Slider>(find.byKey(const ValueKey('music-player-progress')));
      expect(slider.onChanged, isNull);
      expect(slider.onChangeEnd, isNull);
      expect(slider.value.isFinite, isTrue);
      final bounds =
          tester.getRect(find.byKey(const ValueKey('music-player-artwork')));
      final edge = bounds.center + Offset(bounds.width / 4, 0);
      await tester.tapAt(edge);
      expect(player.state.mediaCommand?.type, MediaCommandType.play);
      await tester.pump(kDoubleTapMinTime + const Duration(milliseconds: 10));
      await tester.tapAt(edge);
      await tester.pump(kDoubleTapTimeout);
      expect(player.sought, isNull);
      await tap(tester, 'music-player-lyrics');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('music-lyrics-lines')), findsNothing);
      expect(find.text('Fixture line'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Fixture line'), findsNothing);
      await tester.tap(find.text('Fixture line'));
      expect(player.sought, isNull);
      await pressAndroidBack(tester);
      expect(tester.takeException(), isNull);
    }
  });

  for (final mini in [false, true]) {
    testWidgets(
        '${mini ? "Mini player" : "Artwork"} swipes immediately show the selected song while audio focus is pending',
        (tester) async {
      final following = mini
          ? next
          : const MusicTrack(
                  videoId: 'next',
                  title: 'Next',
                  artists: ['Next artist'],
                  artistLinks: [
                    MusicArtist(
                        id: 'UC0123456789012345678901', name: 'Next artist'),
                  ],
                  albumTitle: 'Next album',
                  albumPlaylistId: 'OLAK5uy_next')
              .toVideo();
      final last = mini
          ? next.copyWith(
              videoId: 'third',
              musicMetadata:
                  const MusicMetadata(title: 'Third', artist: 'Singer'))
          : const MusicTrack(
                  videoId: 'third',
                  title: 'Third',
                  artists: ['Third artist'],
                  artistLinks: [
                    MusicArtist(
                        id: 'UCabcdefghijklmnopqrstuv', name: 'Third artist'),
                  ],
                  albumTitle: 'Third album',
                  albumPlaylistId: 'OLAK5uy_third')
              .toVideo();
      if (!mini) {
        const queueName = 'Opening test playlist';
        player.sourcePlaylist = PlaylistReference(
            kind: PlaylistSourceKind.local,
            playlistId: 'local:opening-test',
            displayTitle: queueName,
            profileId: db.profileId);
        player.queueTitle = queueName;
      }
      await player.seed(player.state.copyWith(
          videos: [song, following, last],
          playQueue: ListQueue.of([following.videoId, last.videoId]),
          isMini: mini));
      final audio = _PendingAudioFocus();
      player.audioSession = audio;
      player.transportZone = await tester.runAsync(() async => Zone.current);
      await pump(tester,
          child: mini
              ? const Align(
                  alignment: Alignment.bottomCenter, child: MusicMiniPlayer())
              : const MusicPlayer());
      final swipe = find
          .byKey(ValueKey(mini ? 'music-mini-expand' : 'music-player-artwork'));
      final center = tester.getCenter(swipe);
      final metadata = find.byKey(const ValueKey('music-player-metadata'));
      final source = find.byKey(const ValueKey('music-playing-source'));
      Finder label(String text) =>
          find.descendant(of: metadata, matching: find.text(text));
      void expectOpeningLabels(
          Video opening, String artist, String album, String oldArtist) {
        expect(playbackQueueId(player.openingMusicEntry!),
            playbackQueueId(opening));
        expect(label(artist), findsOneWidget);
        expect(label(album), findsOneWidget);
        expect(label(oldArtist), findsNothing);
        expect(label('Opening test playlist'), findsOneWidget);
        expect(source.hitTestable(), findsNothing);
        expect(find.bySemanticsLabel(artist), findsOneWidget);
      }

      Future<void> renderTransport() async {
        // Let the real player deliver its state stream before the first frame.
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }

      // There is no earlier occurrence at the beginning of the queue.
      final blocked = await tester.startGesture(center);
      await blocked.moveBy(const Offset(110, 0));
      await tester.pump();
      expect(tester.getCenter(swipe), center);
      await blocked.up();
      expect(player.previousCalls, 0);
      if (!mini) {
        final canceled = await tester.startGesture(center);
        await canceled.moveBy(const Offset(-110, 0));
        await tester.pump();
        expect(label('Song'), findsOneWidget);
        expect(label('Next artist'), findsNothing);
        expect(tester.widget<FadeTransition>(metadata).opacity.value, 1);
        await canceled.cancel();
        await tester.pumpAndSettle();
        expect(player.openingMusicEntry, isNull);
        expect(source.hitTestable(), findsOneWidget);
        expect(label('Song'), findsOneWidget);
      }

      // A short deliberate fling is enough. The selected artwork and text
      // must be centered in the first frame, before the old decoder changes.
      await tester.fling(swipe, const Offset(-50, 0), 1200);
      await renderTransport();
      expect(player.nextCalls, 1);
      expect(player.state.currentlyPlaying, song);
      expect(player.openingMusicEntry?.videoId, 'next');
      expect(find.text('Next'), findsOneWidget);
      expect(find.text('Song'), findsNothing);
      expect(tester.getCenter(swipe), center);
      if (mini) {
        final progress = tester.widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('music-mini-progress')));
        expect(progress.value, isNull);
      } else {
        expectOpeningLabels(following, 'Next artist', 'Next album', 'Singer');
        expect(tester.widget<FadeTransition>(metadata).opacity.value,
            closeTo(0.78, 0.01));
        await tester.pump(const Duration(milliseconds: 45));
        expect(tester.widget<FadeTransition>(metadata).opacity.value,
            allOf(greaterThan(0.78), lessThan(1)));
        final progress = tester.widget<Slider>(
            find.byKey(const ValueKey('music-player-progress')));
        expect(progress.value, 0);
        expect(progress.onChanged, isNull);
        expect(
            find.byKey(const ValueKey('music-player-queue')), findsOneWidget);
      }
      await tester.drag(swipe, const Offset(-150, 0));
      await renderTransport();
      expect(find.text('Third'), findsOneWidget);
      if (!mini) {
        expectOpeningLabels(last, 'Third artist', 'Third album', 'Next artist');
        expect(find.bySemanticsLabel('Next artist'), findsNothing);
      }
      expect(tester.getCenter(swipe), center);
      await tester.drag(swipe, const Offset(-150, 0));
      await tester.pump();
      expect(player.nextCalls, 2);
      expect(find.text('Third'), findsOneWidget);
      await tester.drag(swipe, const Offset(150, 0));
      await renderTransport();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Next'), findsOneWidget);
      expect(tester.getCenter(swipe), center);
      expect(player.previousCalls, 1);
      expect(player.sought, isNull);
      expect(player.state.currentlyPlaying, song);
      if (!mini) {
        expectOpeningLabels(
            following, 'Next artist', 'Next album', 'Third artist');
        // The loading indicator keeps animating until the pending decoder opens.
        Future<void> finishMenuAnimation() async {
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
        }

        expect(player.openingMusicEntry?.videoId, next.videoId);
        await tester.tap(find.byKey(const ValueKey('music-player-queue')));
        await finishMenuAnimation();
        for (final protected in [song, next]) {
          await tap(tester, 'music-queue-menu-${playbackQueueId(protected)}');
          await finishMenuAnimation();
          expect(find.text('Save to playlist'), findsOneWidget);
          expect(find.text('Remove from queue'), findsNothing);
          expect(find.text('Move up'), findsNothing);
          expect(find.text('Move down'), findsNothing);
          Navigator.of(tester.element(find.text('Save to playlist'))).pop();
          await finishMenuAnimation();
        }
        await tester
            .longPress(find.byKey(ValueKey('music-queue-${song.videoId}')));
        await finishMenuAnimation();
        await tester.tap(find.byKey(ValueKey('music-queue-${next.videoId}')));
        await finishMenuAnimation();
        expect(find.text('2 selected'), findsOneWidget);
        await tap(tester, 'music-queue-selection-menu');
        await finishMenuAnimation();
        expect(find.text('Remove selected from queue'), findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        audio.activation.completeError(StateError('Audio focus interrupted'));
        await player.switching;
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('held artwork swipe retires when a duplicate occurrence changes',
      (tester) async {
    const firstAlbum = 'OLAK5uy_first_duplicate';
    const secondAlbum = 'OLAK5uy_second_duplicate';
    final songs = assignPlaybackQueueIds([
      const MusicTrack(
        videoId: 'song',
        title: 'First copy',
        artists: ['First copy artist'],
        artistLinks: [
          MusicArtist(
              id: 'UC0123456789012345678901', name: 'First copy artist'),
        ],
        albumTitle: 'First copy album',
        albumPlaylistId: firstAlbum,
      ).toVideo(),
      const MusicTrack(
        videoId: 'song',
        title: 'Second copy',
        artists: ['Second copy artist'],
        artistLinks: [
          MusicArtist(
              id: 'UCabcdefghijklmnopqrstuv', name: 'Second copy artist'),
        ],
        albumTitle: 'Second copy album',
        albumPlaylistId: secondAlbum,
      ).toVideo(),
    ]);
    expect(songs.first.videoId, songs.last.videoId);
    expect(playbackQueueId(songs.first), isNot(playbackQueueId(songs.last)));
    final previousCatalog = musicCatalogService;
    final catalog = _ReleaseCatalog();
    musicCatalogService = catalog;
    addTearDown(() => musicCatalogService = previousCatalog);
    await player.seed(player.state.copyWith(
        videos: songs,
        currentlyPlaying: songs.first,
        playQueue: ListQueue.of([playbackQueueId(songs.last)])));
    await pump(tester);
    final metadata = find.byKey(const ValueKey('music-player-metadata'));
    final source = find.byKey(const ValueKey('music-playing-source'));
    Finder header(String text) =>
        find.descendant(of: metadata, matching: find.text(text));
    final oldArtist = tester
        .widget<TextButton>(
            find.widgetWithText(TextButton, 'First copy artist'))
        .onPressed!;
    expect(find.descendant(of: source, matching: find.text('First copy album')),
        findsOneWidget);
    final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('music-player-artwork'))));
    await gesture.moveBy(const Offset(-140, 0));
    await tester.pump();
    expect(header('First copy'), findsOneWidget);
    expect(header('Second copy'), findsNothing);
    await player.seed(player.state.copyWith(
        currentlyPlaying: songs.last, playQueue: ListQueue<String>()));
    await tester.pump();
    expect(header('First copy'), findsNothing);
    expect(find.bySemanticsLabel('First copy artist'), findsNothing);
    expect(header('Second copy'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(
                find.widgetWithText(TextButton, 'Second copy artist'))
            .onPressed,
        isNotNull);
    expect(
        find.descendant(of: source, matching: find.text('Second copy album')),
        findsOneWidget);
    oldArtist();
    await tester.pump();
    expect(tester.takeException(), isNull);
    await gesture.up();
    await tester.pump();
    expect(player.nextCalls, 0);
    expect(player.previousCalls, 0);
    await tester.ensureVisible(source);
    await tester.tap(source);
    await tester.pumpAndSettle();
    expect(catalog.releases, [secondAlbum]);
    await pressAndroidBack(tester);
    expect(player.state.currentQueueId, playbackQueueId(songs.last));

    final artistLabel = header('Second copy artist');
    final focus = Focus.of(tester.element(artistLabel));
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasPrimaryFocus, isTrue);
    final original = songs.last.musicMetadata!;
    final refreshed = songs.last.copyWith(
        musicMetadata: MusicMetadata(
      title: 'Second copy remaster',
      artist: original.artist,
      artistCredits: original.artistCredits,
      album: original.album,
      albumPlaylistId: original.albumPlaylistId,
    ));
    await player.seed(player.state.copyWith(currentlyPlaying: refreshed));
    await tester.pump();
    expect(header('Second copy remaster'), findsOneWidget);
    expect(tester.widget<FadeTransition>(metadata).opacity.value, 1);
    expect(Focus.of(tester.element(artistLabel)), same(focus));
    expect(focus.hasPrimaryFocus, isTrue);
  });

  testWidgets('queue menu moves an occurrence without changing the active song',
      (tester) async {
    final songs = assignPlaybackQueueIds([song, next, song]);
    await player.seed(player.state.copyWith(
        videos: songs,
        currentlyPlaying: songs.first,
        playQueue: ListQueue.of(songs.skip(1).map(playbackQueueId))));
    await pump(tester, size: const Size(1024, 720));
    await tester.tap(find
        .byKey(ValueKey('music-queue-menu-${playbackQueueId(songs.last)}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move up'));
    await tester.pumpAndSettle();
    expect(player.state.videos.map(playbackQueueId), [
      playbackQueueId(songs.first),
      playbackQueueId(songs.last),
      playbackQueueId(songs[1]),
    ]);
    expect(player.state.currentQueueId, playbackQueueId(songs.first));
    expect(player.state.currentlyPlaying, songs.first);
    expect(player.state.playQueue.toList(),
        [playbackQueueId(songs.last), playbackQueueId(songs[1])]);
    expect(player.sought, isNull);
  });

  testWidgets('queue row requests stay separate and can be removed',
      (tester) async {
    await player.seed(player.state.copyWith(
        currentlyPlaying: next, playQueue: ListQueue.of([song.videoId])));
    await pump(tester, size: const Size(1024, 720), child: const MusicQueue());
    final current = player.state.currentQueueId;
    final upcoming = player.state.playQueue.toList();
    await tester.runAsync(() => tester.tap(
        find.byKey(ValueKey('music-queue-menu-${playbackQueueId(song)}'))));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('Add to requests')));
    await tester.pumpAndSettle();

    expect(player.state.currentQueueId, current);
    expect(player.state.playQueue.toList(), upcoming);
    expect(player.musicRequests.single.videoId, song.videoId);
    await tester.tap(find.byKey(const ValueKey('music-queue-requests')));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(find.descendant(of: dialog, matching: find.text('Play requests')),
        findsOneWidget);
    await tester.runAsync(() => tester.tap(
        find.byTooltip('Remove request for ${song.musicMetadata!.title}')));
    await tester.pumpAndSettle();
    expect(player.musicRequests, isEmpty);
    expect(find.text('No pending requests'), findsOneWidget);
  });

  for (final (option, indexes) in [
    ('Title (A–Z)', [4, 5, 3, 2]),
    ('Title (Z–A)', [2, 5, 3, 4]),
    ('Artist (A–Z)', [2, 4, 5, 3]),
    ('Artist (Z–A)', [5, 3, 4, 2]),
  ]) {
    testWidgets('Sort upcoming applies $option in the shuffled queue',
        (tester) async {
      const zulu = Video(
          videoId: 'zulu',
          musicMetadata: MusicMetadata(title: 'Zulu', artist: 'Alpha'));
      const repeated = Video(
          videoId: 'repeat',
          musicMetadata: MusicMetadata(title: 'Beta', artist: 'Echo'));
      const alpha = Video(
          videoId: 'alpha',
          musicMetadata: MusicMetadata(title: 'Alpha', artist: 'Charlie'));
      final songs =
          assignPlaybackQueueIds([next, song, zulu, repeated, alpha, repeated]);
      final ids = songs.map(playbackQueueId).toList();
      await settings.setShuffle(true);
      await player.seed(player.state.copyWith(
          videos: songs,
          currentlyPlaying: songs[1],
          playedVideos: [ids.first],
          playQueue: ListQueue.of([ids[5], ids[2], ids[3], ids[4]])));
      final before = player.state;
      await pump(tester);
      await tap(tester, 'music-player-queue');
      expect(find.byTooltip('Sort upcoming').hitTestable(), findsOneWidget);
      await tap(tester, 'music-queue-sort-upcoming');
      await tester.pumpAndSettle();
      await tester.tap(find.text(option));
      await tester.pumpAndSettle();

      final expected = indexes.map((index) => ids[index]).toList();
      expect(player.state.playQueue, expected);
      expect(player.state.videos.map(playbackQueueId), ids);
      expect(player.state.playedVideos, before.playedVideos);
      expect(player.state.currentlyPlaying, same(before.currentlyPlaying));
      expect(player.state.position, before.position);
      expect(player.state.mediaCommand, same(before.mediaCommand));
      expect(settings.state.playerShuffleMode, isTrue);
      double rowY(String id) =>
          tester.getTopLeft(find.byKey(ValueKey('music-queue-$id'))).dy;
      final rowPositions = expected.map(rowY).toList();
      expect(rowPositions, [...rowPositions]..sort());
      expect(rowPositions.toSet(), hasLength(expected.length));
    });
  }

  testWidgets('Sort upcoming is reachable with large text on a narrow phone',
      (tester) async {
    final alpha = next.copyWith(
        videoId: 'alpha',
        musicMetadata: const MusicMetadata(title: 'Alpha', artist: 'Singer'));
    player.queueTitle = 'A very long name for a music playlist';
    await player.seed(player.state.copyWith(
        videos: [song, next, alpha],
        playQueue: ListQueue.of([next.videoId, alpha.videoId])));
    await pump(tester, size: const Size(320, 568), scale: 2);
    await tap(tester, 'music-player-queue');
    expect(find.text(player.queueTitle!), findsOneWidget);
    expect(find.byTooltip('Sort upcoming').hitTestable(), findsOneWidget);
    await tap(tester, 'music-queue-sort-upcoming');
    await tester.pumpAndSettle();
    final option = find.text('Title (A–Z)');
    expect(option.hitTestable(), findsOneWidget);
    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(player.state.playQueue, [alpha.videoId, next.videoId]);
    await tap(tester, 'music-queue-lock');
    expect(find.text('Queue editing locked'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Sort upcoming respects a queue lock applied while its menu is open',
      (tester) async {
    final songs = [
      song,
      next,
      next.copyWith(
          videoId: 'alpha',
          musicMetadata: const MusicMetadata(title: 'Alpha', artist: 'Singer'))
    ];
    final order = songs.skip(1).map(playbackQueueId).toList();
    await player.seed(
        player.state.copyWith(videos: songs, playQueue: ListQueue.of(order)));
    await pump(tester, child: const MusicQueue());
    await tap(tester, 'music-queue-sort-upcoming');
    await tester.pumpAndSettle();
    final option = find.text('Title (A–Z)');
    expect(option.hitTestable(), findsOneWidget);

    await settings.saveSetting(SettingsValue('music-queue-locked', 'true'));
    await tester.pumpAndSettle();
    if (option.hitTestable().evaluate().isNotEmpty) {
      await tester.tap(option);
      await tester.pumpAndSettle();
    }
    expect(player.state.playQueue, order);
    expect(find.text('Queue editing locked'), findsOneWidget);
    await tap(tester, 'music-queue-sort-upcoming');
    await tester.pumpAndSettle();
    expect(option, findsNothing);
    await tap(tester, 'music-queue-lock');
    await tap(tester, 'music-queue-sort-upcoming');
    await tester.pumpAndSettle();
    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(player.state.playQueue, order.reversed);
  });

  testWidgets(
      'current and locked queue rows keep their playback and library actions',
      (tester) async {
    await tester.runAsync(() async => player.enqueueZone = Zone.current);
    await player.seed(player.state.copyWith(
        isPlaying: true,
        mediaEvent: const MediaEvent(state: MediaState.playing)));
    await pump(tester, child: const MusicQueue());
    final current = find.byTooltip('Queue actions for Song');
    expect(current.hitTestable(), findsOneWidget);
    await tester.tap(current);
    await tester.pumpAndSettle();
    expect(find.text('Play next'), findsOneWidget);
    expect(find.text('Add to queue'), findsOneWidget);
    expect(find.text('Save to playlist'), findsOneWidget);
    expect(find.text('Download audio'), findsOneWidget);
    expect(find.text('Remove from queue'), findsNothing);
    await tester.tap(find.text('Pause'));
    await tester.pumpAndSettle();
    expect(player.state.mediaCommand?.type, MediaCommandType.pause);
    expect(player.state.currentQueueId, playbackQueueId(song));

    final upcoming = find.byTooltip('Queue actions for Next');
    await tester.tap(upcoming);
    await tester.pumpAndSettle();
    await settings.saveSetting(SettingsValue('music-queue-locked', 'true'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move up'));
    await tester.pumpAndSettle();
    expect(player.state.playQueue, [playbackQueueId(next)]);
    expect(player.state.playedVideos, isEmpty);

    expect(upcoming.hitTestable(), findsOneWidget);
    await tester.tap(upcoming);
    await tester.pumpAndSettle();
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Save to playlist'), findsOneWidget);
    expect(find.text('Move up'), findsNothing);
    expect(find.text('Move down'), findsNothing);
    expect(find.text('Remove from queue'), findsNothing);
    await tester.tap(find.text('Play next'));
    await tester.pumpAndSettle();
    final order = player.state.playQueue.toList();
    expect(order, hasLength(2));
    expect(order.last, playbackQueueId(next));
    expect(order.first, isNot(order.last));
    expect(
        player.state.videos
            .singleWhere((entry) => playbackQueueId(entry) == order.first)
            .videoId,
        next.videoId);
    expect(player.state.currentQueueId, playbackQueueId(song));
  });

  testWidgets('saved queue menus copy each selected occurrence in place',
      (tester) async {
    final files = [
      for (final track in [song, next])
        DownloadedVideo(
            videoId: track.videoId,
            title: track.title!,
            lengthSeconds: track.lengthSeconds!,
            quality: 'audio',
            downloadComplete: true,
            audioOnly: true,
            musicMetadata: track.musicMetadata),
    ];
    await tester.runAsync(() async {
      player.enqueueZone = Zone.current;
      for (final file in files) {
        await db.upsertDownload(file);
      }
    });
    await player.seed(player.state.copyWith(
        videos: [],
        currentlyPlaying: null,
        offlineVideos: files,
        offlineCurrentlyPlaying: files.first,
        playQueue: ListQueue.of([next.videoId])));
    final position = player.state.position;
    final command = player.state.mediaCommand;
    await pump(tester, child: const MusicQueue());
    await tap(tester, 'music-queue-menu-${song.videoId}');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play next'));
    await tester.pumpAndSettle();
    final firstCopy = player.state.playQueue.first;
    expect(firstCopy, isNot(song.videoId));
    expect(player.state.playQueue, [firstCopy, next.videoId]);

    // Queue persistence emits from the real clock. Deliver its Bloc stream
    // notification before rendering and selecting the new row.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.longPress(find.byKey(ValueKey('music-queue-$firstCopy')));
    await tester.pumpAndSettle();
    await tap(tester, 'music-queue-${song.videoId}');
    await tap(tester, 'music-queue-selection-menu');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to queue'));
    await tester.pumpAndSettle();

    final queue = player.state.offlineVideos;
    expect(queue.map((file) => file.videoId),
        [song.videoId, song.videoId, next.videoId, song.videoId, song.videoId]);
    expect(queue.map(playbackQueueId).toSet(), hasLength(queue.length));
    expect(player.state.playQueue, queue.skip(1).map(playbackQueueId));
    expect(player.state.offlineCurrentlyPlaying, same(files.first));
    expect(player.state.position, position);
    expect(player.state.mediaCommand, same(command));
  });

  testWidgets(
      'queue copies the pinned occurrence when the same song also streams',
      (tester) async {
    final file = DownloadedVideo(
        videoId: song.videoId,
        title: song.title!,
        lengthSeconds: 180,
        quality: 'audio',
        audioOnly: true,
        downloadComplete: true,
        musicMetadata: song.musicMetadata);
    await tester.runAsync(() async {
      player.enqueueZone = Zone.current;
      await db.upsertDownload(file);
    });
    final pin = musicDownloadFingerprint(file);
    final entries = assignPlaybackQueueIds(
        [song, song.copyWith(explicitMusicDownload: pin)]);
    final pinnedId = playbackQueueId(entries.last);
    await player.seed(player.state.copyWith(
        videos: entries,
        currentlyPlaying: entries.first,
        playQueue: ListQueue.of([pinnedId])));
    await pump(tester, child: const MusicQueue());
    await tap(tester, 'music-queue-menu-$pinnedId');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play next'));
    await tester.pumpAndSettle();
    final copyId = player.state.playQueue.first;
    final copy = player.state.videos
        .singleWhere((video) => playbackQueueId(video) == copyId);
    expect(copyId, isNot(pinnedId));
    expect(copy.explicitMusicDownload, pin);
    expect(player.state.currentlyPlaying?.explicitMusicDownload, isNull);
  });

  for (final deviceFirst in [true, false]) {
    testWidgets(
        'mixed offline queue plays and copies both sources (device first: $deviceFirst)',
        (tester) async {
      await seedDeviceQueue(tester);
      final device = player.state.offlineVideos.first;
      final saved = DownloadedVideo(
          videoId: next.videoId,
          title: next.title!,
          musicMetadata: next.musicMetadata,
          lengthSeconds: 150,
          quality: 'audio',
          audioOnly: true,
          downloadComplete: true);
      await tester.runAsync(() => db.upsertDownload(saved));
      final entries = deviceFirst ? [device, saved] : [saved, device];
      await player.seed(player.state.copyWith(
          offlineVideos: entries,
          offlineCurrentlyPlaying: entries.first,
          playQueue: ListQueue.of([playbackQueueId(entries.last)])));
      await pump(tester, child: const MusicQueue());
      Future<void> openMenu() async {
        await tester.longPress(find
            .byKey(ValueKey('music-queue-${playbackQueueId(entries.last)}')));
        await tester.pumpAndSettle();
        await tap(tester, 'music-queue-${playbackQueueId(entries.first)}');
        await tap(tester, 'music-queue-selection-menu');
        await tester.pumpAndSettle();
        expect(find.text('Save to playlist'), findsNothing);
      }

      await openMenu();
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      expect(player.offlineSelections.single, entries);
      expect(player.localQueueRequests, isEmpty);
      await openMenu();
      await tester.tap(find.text('Play next'));
      await tester.pumpAndSettle();
      final queue = player.state.offlineVideos;
      expect(queue, hasLength(4));
      expect(
          queue.sublist(1, 3).map((entry) => localMusicTrackId(entry.videoId)),
          entries.map((entry) => entry.videoId));
      expect(queue.map(playbackQueueId).toSet(), hasLength(4));
      expect(player.state.playQueue, queue.skip(1).map(playbackQueueId));
      expect(player.state.offlineCurrentlyPlaying, same(entries.first));
    });
  }

  testWidgets('Select all toggles back to an empty queue selection',
      (tester) async {
    await pump(tester, child: const MusicQueue());
    await tap(tester, 'music-queue-select-mode');
    await tester.tap(find.byTooltip('Select all'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    final clear = find.byTooltip('Deselect all');
    expect(clear.hitTestable(), findsOneWidget);
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);
    expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .map((box) => box.value),
        [false, false]);
    expect(find.byTooltip('Select all').hitTestable(), findsOneWidget);
  });

  for (final playNext in [true, false]) {
    final action = playNext ? 'Play next' : 'Add to queue';
    testWidgets(
        'device queue $action copies selections in their displayed order',
        (tester) async {
      await seedDeviceQueue(tester);
      final originals = List.of(player.state.offlineVideos);
      final playing = player.state.offlineCurrentlyPlaying;
      // Playback order differs from the source list and selection order.
      await player.seed(
          player.state.copyWith(offlineVideos: originals.reversed.toList()));
      await pump(tester, child: const MusicQueue());
      Finder row(DownloadedVideo video) =>
          find.byKey(ValueKey('music-queue-${playbackQueueId(video)}'));
      expect(tester.getTopLeft(row(originals.first)).dy,
          lessThan(tester.getTopLeft(row(originals.last)).dy));
      await tester.longPress(row(originals.last));
      await tester.pumpAndSettle();
      await tester.tap(row(originals.first));
      await tester.pumpAndSettle();
      await tap(tester, 'music-queue-selection-menu');
      await tester.pumpAndSettle();
      expect(find.text(action).hitTestable(), findsOneWidget);
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();

      final entries = player.state.offlineVideos;
      final originalIds = originals.map(playbackQueueId).toSet();
      final copies = {
        for (final entry in entries)
          if (!originalIds.contains(playbackQueueId(entry)))
            playbackQueueId(entry):
                localMusicTrackForPlayback(entry.videoId)?.playbackId,
      };
      expect(copies.length, 2);
      final upcoming = player.state.playQueue.toList();
      expect(upcoming, hasLength(3));
      expect(playNext ? upcoming.last : upcoming.first,
          playbackQueueId(originals.last));
      final copiedIds = playNext ? upcoming.take(2) : upcoming.skip(1);
      expect(copiedIds.map((id) => copies[id]),
          originals.map((entry) => entry.videoId));
      expect(player.state.offlineCurrentlyPlaying, same(playing));
    });
  }

  testWidgets('drag handle moves a repeat occurrence in playback order',
      (tester) async {
    final songs = assignPlaybackQueueIds([song, next, song]);
    final repeat = playbackQueueId(songs.last);
    await player.seed(player.state.copyWith(
        videos: songs,
        currentlyPlaying: songs.first,
        playQueue: ListQueue.of([next.videoId, repeat])));
    await pump(tester, size: const Size(1024, 720));
    final row = find.byKey(ValueKey('music-queue-$repeat'));
    final rowHeight = tester.getSize(row).height;
    final handle = find.byKey(ValueKey('music-queue-drag-$repeat'));

    await tester.drag(handle, Offset(0, -rowHeight * 0.9));
    await tester.pumpAndSettle();

    expect(player.state.playQueue.toList(), [repeat, next.videoId]);
    expect(player.state.currentQueueId, playbackQueueId(songs.first));
    expect(player.sought, isNull);
  });

  testWidgets('dragging a previous song across the current song queues it next',
      (tester) async {
    final earlier = next.copyWith(videoId: 'earlier');
    final tail = next.copyWith(videoId: 'tail');
    final duplicate = song.copyWith(queueEntryId: 'previous');
    final previous = playbackQueueId(duplicate);
    final current = player.state.currentlyPlaying!;
    final currentId = playbackQueueId(current);
    final position = player.state.position;
    await player.seed(player.state.copyWith(
      videos: [earlier, duplicate, current, next, tail],
      playedVideos: [earlier.videoId, previous],
      playQueue: ListQueue.of([next.videoId, tail.videoId]),
    ));
    await pump(tester, size: const Size(1024, 720));
    final handle = find.byKey(ValueKey('music-queue-drag-$previous'));
    expect(handle.hitTestable(), findsOneWidget);
    expect(find.byKey(ValueKey('music-queue-drag-$currentId')), findsNothing);

    await tap(tester, 'music-queue-lock');
    expect(handle, findsNothing);
    await tap(tester, 'music-queue-lock');

    final row = find.byKey(ValueKey('music-queue-$previous'));
    await tester.drag(handle, Offset(0, tester.getSize(row).height * 0.9));
    await tester.pumpAndSettle();

    expect(player.state.playedVideos, [earlier.videoId]);
    expect(player.state.playQueue.toList(),
        [previous, next.videoId, tail.videoId]);
    expect(player.state.currentQueueId, currentId);
    expect(player.state.currentlyPlaying, same(current));
    expect(player.state.position, position);
    expect(player.sought, isNull);
  });

  testWidgets('queue summary shows its source and the entire listening order',
      (tester) async {
    final longTrack = song.copyWith(lengthSeconds: 45000);
    final songs = assignPlaybackQueueIds(
        [longTrack, next.copyWith(lengthSeconds: 1), longTrack]);
    player.queueTitle = 'A very long name for a music playlist';
    await player.seed(player.state.copyWith(
      videos: songs,
      playedVideos: [playbackQueueId(songs.first)],
      currentlyPlaying: songs[1],
      playQueue: ListQueue.of([playbackQueueId(songs.last)]),
    ));
    await pump(tester, size: const Size(320, 568), scale: 2);
    await tap(tester, 'music-player-queue');
    expect(find.text(player.queueTitle!), findsOneWidget);
    expect(find.text('3 songs'), findsOneWidget);
    expect(find.text('Total duration 25:00:01'), findsOneWidget);
    await tap(tester, 'music-queue-lock');
    expect(find.text('Queue editing locked'), findsOneWidget);
    expect(find.text('3 songs'), findsOneWidget);
    await tap(tester, 'music-queue-select-mode');
    expect(find.text('0 selected'), findsOneWidget);
    expect(find.text(player.queueTitle!), findsNothing);
    await pressAndroidBack(tester);
    expect(find.text(player.queueTitle!), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'queue summary distinguishes partial, total and unavailable duration',
      (tester) async {
    player.queueComplete = false;
    await pump(tester, child: const MusicQueue());
    expect(find.text('2 songs'), findsOneWidget);
    expect(find.text('Known duration 06:00'), findsOneWidget);
    expect(find.text('Queue'), findsNothing);
    player.queueComplete = true;
    player.playlistLoadingRevision.value++;
    await tester.pump();
    expect(find.text('Total duration 06:00'), findsOneWidget);
    final live = next.copyWith(liveNow: true);
    final upcoming = next.copyWith(videoId: 'upcoming', isUpcoming: true);
    await player.seed(player.state.copyWith(videos: [song, live, upcoming]));
    await tester.pump();
    expect(find.text('Known duration 03:00'), findsOneWidget);
    final unknown = song.copyWith(lengthSeconds: 0);
    await player.seed(player.state.copyWith(
        videos: [unknown, live, upcoming], currentlyPlaying: unknown));
    await tester.pump();
    expect(find.text('Duration unavailable'), findsOneWidget);
  });

  testWidgets('queue summary identifies downloaded and device-file queues',
      (tester) async {
    const downloaded = DownloadedVideo(
        videoId: 'offline-audio',
        title: 'Offline song',
        lengthSeconds: 83,
        quality: 'audio',
        audioOnly: true,
        downloadComplete: true);
    await player.seed(player.state.copyWith(
        videos: [],
        currentlyPlaying: null,
        offlineVideos: [downloaded],
        offlineCurrentlyPlaying: downloaded));
    await pump(tester, child: const MusicQueue());
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.text('1 song'), findsOneWidget);
    expect(find.text('Total duration 01:23'), findsOneWidget);
    await tap(tester, 'music-queue-menu-${downloaded.videoId}');
    await tester.pumpAndSettle();
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Download audio'), findsNothing);
    expect(find.text('Play next'), findsNothing);
    expect(find.text('Add to queue'), findsNothing);
    await pressAndroidBack(tester);
    await seedDeviceQueue(tester);
    await tester.pumpAndSettle();
    expect(find.text('On this device'), findsOneWidget);
    expect(find.text('Downloads'), findsNothing);
    expect(find.text('Total duration 06:00'), findsOneWidget);
  });

  testWidgets('wide touch keeps Now Playing and the ordered queue side by side',
      (tester) async {
    final songs = assignPlaybackQueueIds([song, next, song]);
    final repeat = playbackQueueId(songs.last);
    await player.seed(player.state.copyWith(
        videos: songs,
        currentlyPlaying: songs.first,
        playQueue: ListQueue.of([repeat, next.videoId])));
    await pump(tester, size: const Size(1024, 720));
    expect(find.bySemanticsLabel('Now playing'), findsOneWidget);
    expect(find.bySemanticsLabel('Queue'), findsOneWidget);
    final repeatedRow = find.byKey(ValueKey('music-queue-$repeat'));
    final nextRow = find.byKey(ValueKey('music-queue-${next.videoId}'));
    expect(tester.getTopLeft(repeatedRow).dy,
        lessThan(tester.getTopLeft(nextRow).dy));
    final indicator = find.byKey(const ValueKey('music-queue-active'));
    expect(tester.widget<Icon>(indicator).icon, Icons.play_arrow_rounded);
    await player.seed(player.state.copyWith(
        isPlaying: true,
        mediaEvent: const MediaEvent(state: MediaState.playing)));
    await tester.pump();
    expect(tester.widget<Icon>(indicator).icon, Icons.equalizer);
    expect(find.byType(MusicQueue), findsOneWidget);
    expect(
        find.byKey(const ValueKey('music-player-close-queue')), findsNothing);
    expect(find.byKey(const ValueKey('music-player-queue')), findsNothing);
    final playback =
        tester.getRect(find.byKey(const ValueKey('music-now-playing-scroll')));
    final queue = tester.getRect(find.byType(MusicQueue));
    expect(playback.right, lessThanOrEqualTo(queue.left));
    expect(playback.width, closeTo(queue.width, 1));
    expect(
        tester.getRect(find.byKey(const ValueKey('music-player-play'))).bottom,
        lessThanOrEqualTo(playback.bottom));
    expect(find.byKey(const ValueKey('music-queue-shuffle')).hitTestable(),
        findsOneWidget);
    expect(player.state.currentlyPlaying, songs.first);
  });

  testWidgets(
      'opening a long queue and Jump to current reveal its active occurrence',
      (tester) async {
    final history =
        List.generate(30, (index) => next.copyWith(videoId: 'earlier-$index'));
    await player.seed(player.state.copyWith(
      videos: [song, next, ...history],
      playedVideos: history.map(playbackQueueId).toList(),
      playQueue: ListQueue.of([next.videoId]),
    ));
    await pump(tester);
    await tap(tester, 'music-player-queue');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-queue-active')).hitTestable(),
        findsOneWidget);
    expect(find.byKey(const ValueKey('music-queue-earlier-0')).hitTestable(),
        findsNothing);

    final scroller = find.descendant(
        of: find.byType(MusicQueue), matching: find.byType(Scrollable));
    tester.state<ScrollableState>(scroller).position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-queue-active')).hitTestable(),
        findsNothing);
    final jump = find.byKey(const ValueKey('music-queue-jump-current'));
    expect(jump.hitTestable(), findsOneWidget);
    await tester.tap(jump);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-queue-active')).hitTestable(),
        findsOneWidget);
  });

  Future<void> advanceQueue(
      WidgetTester tester, List<Video> songs, int index) async {
    await player.seed(player.state.copyWith(
      videos: songs,
      currentlyPlaying: songs[index],
      playedVideos: songs.take(index).map(playbackQueueId).toList(),
      playQueue: ListQueue.of(songs.skip(index + 1).map(playbackQueueId)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'queue advancement keeps a visible row still and reveals a clipped or offscreen occurrence',
      (tester) async {
    final songs = assignPlaybackQueueIds(List.generate(
        40,
        (i) => i == 12 || i == 13 || i == 32
            ? song
            : next.copyWith(videoId: 'track-$i')));
    Finder row(int i) =>
        find.byKey(ValueKey('music-queue-${playbackQueueId(songs[i])}'));
    await advanceQueue(tester, songs, 12);
    await pump(tester, child: const MusicQueue());
    await tester.pumpAndSettle();
    final scroll = find.byType(Scrollable);
    final bounds = tester.getRect(scroll);
    final position = tester.state<ScrollableState>(scroll).position;
    // Put the following row fully in view near the bottom and clip its successor.
    position.jumpTo(
        position.pixels + tester.getRect(row(13)).bottom - bounds.bottom + 10);
    await tester.pumpAndSettle();
    final before = position.pixels;
    expect(tester.getRect(row(13)).bottom, closeTo(bounds.bottom - 10, 1));
    await advanceQueue(tester, songs, 13);
    expect(position.pixels, before);
    expect(tester.widget<ListTile>(row(13)).selected, isTrue);

    final clipped = tester.getRect(row(14));
    expect(clipped.top, lessThan(bounds.bottom));
    expect(clipped.bottom, greaterThan(bounds.bottom));
    await advanceQueue(tester, songs, 14);
    expect(tester.getRect(row(14)).bottom, lessThanOrEqualTo(bounds.bottom));
    expect(tester.getRect(row(14)).top, greaterThanOrEqualTo(bounds.top));

    expect(row(32).hitTestable(), findsNothing);
    await advanceQueue(tester, songs, 32);
    expect(row(32).hitTestable(), findsOneWidget);
    expect(tester.widget<ListTile>(row(32)).selected, isTrue);
    expect(tester.getRect(row(32)).bottom, lessThanOrEqualTo(bounds.bottom));
    expect(tester.getRect(row(32)).top, greaterThanOrEqualTo(bounds.top));
  });

  for (final cancel in [false, true]) {
    testWidgets(
        'queue advancement waits for a held scroll to ${cancel ? 'cancel' : 'end'} before revealing the current occurrence',
        (tester) async {
      final songs = assignPlaybackQueueIds(List.generate(
          32,
          (i) => i == 0 || i == 16 || i == 31
              ? song
              : next.copyWith(videoId: 'track-$i')));
      Finder row(int i) =>
          find.byKey(ValueKey('music-queue-${playbackQueueId(songs[i])}'));
      await advanceQueue(tester, songs, 0);
      await pump(tester, child: const MusicQueue());
      final scroll = find.byType(Scrollable);
      final position = tester.state<ScrollableState>(scroll).position;
      final gesture = await tester.startGesture(tester.getCenter(scroll));
      await gesture.moveBy(const Offset(0, -130));
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 250));
      final heldOffset = position.pixels;
      expect(heldOffset, greaterThan(0));

      await advanceQueue(tester, songs, 31);
      expect(position.pixels, heldOffset);
      expect(row(31).hitTestable(), findsNothing);

      if (cancel) {
        // A second skip supersedes the pending reveal while the finger is down.
        await advanceQueue(tester, songs, 16);
        expect(position.pixels, heldOffset);
        expect(row(16).hitTestable(), findsNothing);
        await gesture.cancel();
      } else {
        await gesture.up();
      }
      await tester.pumpAndSettle();
      final target = row(cancel ? 16 : 31);
      expect(target.hitTestable(), findsOneWidget);
      expect(tester.widget<ListTile>(target).selected, isTrue);
      if (cancel) expect(row(31).hitTestable(), findsNothing);
    });
  }

  testWidgets('remote focus keeps the selected Music queue row visible',
      (tester) async {
    final upcoming = List.generate(
        30,
        (index) => next.copyWith(
            videoId: 'upcoming-$index',
            musicMetadata:
                MusicMetadata(title: 'Upcoming $index', artist: 'Singer')));
    await player.seed(player.state.copyWith(
      videos: [song, ...upcoming],
      playQueue: ListQueue.of(upcoming.map(playbackQueueId)),
    ));
    await pump(tester,
        size: const Size(1024, 720), child: const MusicQueue(television: true));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('music-queue-upcoming-6'));
    expect(row.hitTestable(), findsOneWidget);
    Focus.of(tester.element(find.text('Upcoming 6'))).requestFocus();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(row.hitTestable(), findsOneWidget,
        reason: 'Focusing a row must reveal that row, not the whole sliver');
    final viewport = tester.getRect(find.byType(Scrollable));
    expect(tester.getRect(row).center.dy, closeTo(viewport.center.dy, 1));
  });

  testWidgets('queue reorder accepts accessibility moves without a drag',
      (tester) async {
    final songs = assignPlaybackQueueIds([song, next, song]);
    final initialOrder = songs.skip(1).map(playbackQueueId).toList();
    await player.seed(player.state.copyWith(
        videos: songs,
        currentlyPlaying: songs.first,
        playQueue: ListQueue.of(initialOrder)));
    await pump(tester, size: const Size(1024, 720));

    // Flutter's custom semantics actions invoke this callback directly.
    final list =
        tester.widget<ReorderableListView>(find.byType(ReorderableListView));
    list.onReorder(2, 1);
    expect(player.state.playQueue.toList(), initialOrder.reversed.toList());
    expect(player.state.currentlyPlaying, songs.first);
  });

  testWidgets('a queue order change retires a pending indexed drag',
      (tester) async {
    final songs = assignPlaybackQueueIds([song, next, song]);
    final initialOrder = songs.skip(1).map(playbackQueueId).toList();
    await player.seed(player.state.copyWith(
        videos: songs,
        currentlyPlaying: songs.first,
        playQueue: ListQueue.of(initialOrder)));
    await pump(tester, size: const Size(1024, 720));
    ReorderableListView list() =>
        tester.widget<ReorderableListView>(find.byType(ReorderableListView));
    list().onReorderStart!(1);
    final newOrder = initialOrder.reversed.toList();
    await player.seed(player.state.copyWith(playQueue: ListQueue.of(newOrder)));
    await tester.pump();
    list().onReorder(1, 3);
    expect(player.state.playQueue.toList(), newOrder);
    expect(player.state.currentlyPlaying, songs.first);
  });

  testWidgets('appending to the queue retires a pending indexed drag',
      (tester) async {
    final appended = next.copyWith(videoId: 'appended');
    final songs = assignPlaybackQueueIds([song, next, song]);
    final initialOrder = songs.skip(1).map(playbackQueueId).toList();
    await player.seed(player.state.copyWith(
        videos: songs,
        currentlyPlaying: songs.first,
        playQueue: ListQueue.of(initialOrder)));
    await pump(tester, size: const Size(1024, 720));
    ReorderableListView list() =>
        tester.widget<ReorderableListView>(find.byType(ReorderableListView));
    list().onReorderStart!(2);
    final newOrder = [...initialOrder, appended.videoId];
    await player.seed(player.state.copyWith(
        videos: [...songs, appended], playQueue: ListQueue.of(newOrder)));
    await tester.pump();

    list().onReorder(2, 1);
    expect(player.state.playQueue.toList(), newOrder);
    expect(player.state.currentlyPlaying, songs.first);
  });

  testWidgets('completed song forwards Play to the shared audio decoder',
      (tester) async {
    await player.seed(player.state.copyWith(
        position: const Duration(seconds: 180),
        mediaEvent: const MediaEvent(state: MediaState.completed)));
    await pump(tester);
    await tap(tester, 'music-player-play');
    expect(player.sought, isNull);
    expect(player.state.mediaCommand!.type, MediaCommandType.play);
  });

  testWidgets('a stale seek gesture cannot move a replacement song',
      (tester) async {
    await pump(tester);
    final oldSlider = tester
        .widget<Slider>(find.byKey(const ValueKey('music-player-progress')));
    oldSlider.onChanged!(120000);
    await player.seed(
        player.state.copyWith(currentlyPlaying: next, position: Duration.zero));
    await tester.pump();
    oldSlider.onChangeEnd!(120000);
    await tester.pump();
    expect(player.sought, isNull);
    expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('music-player-progress')))
            .value,
        0);
  });

  testWidgets('rotation cancels an unfinished seek without moving the song',
      (tester) async {
    await pump(tester);
    final oldSlider = tester
        .widget<Slider>(find.byKey(const ValueKey('music-player-progress')));
    oldSlider.onChanged!(120000);
    await tester.pump();
    await pump(tester, size: const Size(680, 256));
    oldSlider.onChangeEnd!(120000);
    await tester.pump();
    expect(player.sought, isNull);
    expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('music-player-progress')))
            .value,
        30000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing Now Playing composition retires the Wave seek owner', (
    tester,
  ) async {
    await tester.runAsync(() => MusicScrubberStyle.wave.save(db));
    await pump(tester);
    final progress = find.byKey(const ValueKey('music-player-progress'));
    await tester.ensureVisible(progress);
    final gesture = await tester.startGesture(tester.getCenter(progress));
    await gesture.moveBy(const Offset(50, 0));
    await tester.pump();
    expect(tester.widget<Slider>(progress).value, isNot(30000));

    await tester.runAsync(() => MusicNowPlayingStyle.compact.save(db));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(player.sought, isNull);
    expect(tester.widget<Slider>(progress).value, 30000);

    await tester.ensureVisible(progress);
    await tester.tap(progress);
    await tester.pump();
    expect(player.sought, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an active pointer seek cannot carry into the next song',
      (tester) async {
    await pump(tester);
    final progress = find.byKey(const ValueKey('music-player-progress'));
    await tester.ensureVisible(progress);
    final rect = tester.getRect(progress);
    final gesture = await tester.startGesture(rect.center);
    await gesture.moveBy(const Offset(50, 0));
    await tester.pump();
    expect(player.sought, isNull);
    await player.seed(
        player.state.copyWith(currentlyPlaying: next, position: Duration.zero));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(player.sought, isNull);
    expect(tester.widget<Slider>(progress).value, 0);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(390, 844), const Size(1024, 720)]) {
    testWidgets('Music skip feedback stays visible with its queue at $size',
        (tester) async {
      await pump(tester, size: size);
      await skipSponsor(tester);
      expect(find.text('Sponsor skipped'), findsOneWidget);
      expect(
          find.byWidgetPredicate((widget) =>
              widget is Semantics && widget.properties.liveRegion == true),
          findsOneWidget);
      if (find.byType(MusicQueue).evaluate().isEmpty) {
        await tap(tester, 'music-player-queue');
      }
      expect(find.byType(MusicQueue), findsOneWidget);
      final notice = tester.getRect(find.text('Sponsor skipped'));
      expect(notice.top, greaterThanOrEqualTo(0));
      expect(notice.bottom, lessThan(size.height));
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Sponsor skipped'), findsNothing);
    });
  }

  testWidgets('skip feedback persists through events and restarts its timeout',
      (tester) async {
    await pump(tester);
    await skipSponsor(tester);
    await tester.pump(const Duration(seconds: 2));
    player.setEvent(const MediaEvent(state: MediaState.playing));
    await tester.pump();
    expect(find.text('Sponsor skipped'), findsOneWidget);
    await skipSponsor(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Sponsor skipped'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Sponsor skipped'), findsNothing);
  });

  testWidgets('skip feedback clears for duplicate queue entries and disposal',
      (tester) async {
    final songs = assignPlaybackQueueIds([song, song]);
    await player.seed(
        player.state.copyWith(videos: songs, currentlyPlaying: songs.first));
    await pump(tester);
    await skipSponsor(tester);
    expect(find.text('Sponsor skipped'), findsOneWidget);
    await player.seed(player.state.copyWith(currentlyPlaying: songs.last));
    await tester.pump();
    expect(find.text('Sponsor skipped'), findsNothing);
    player.setEvent(const MediaEvent(state: MediaState.playing));
    await skipSponsor(tester);
    expect(find.text('Sponsor skipped'), findsOneWidget);
    expect(find.byType(MusicSponsorNotice), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'duplicate song occurrences have separate selection and seek ownership',
      (tester) async {
    final songs = assignPlaybackQueueIds([song, next, song]);
    await player.seed(
        player.state.copyWith(videos: songs, currentlyPlaying: songs.first));
    await pump(tester, size: const Size(1024, 720));
    final oldSlider = tester
        .widget<Slider>(find.byKey(const ValueKey('music-player-progress')));
    oldSlider.onChanged!(120000);
    await player.seed(player.state
        .copyWith(currentlyPlaying: songs.last, position: Duration.zero));
    await tester.pump();
    oldSlider.onChangeEnd!(120000);
    expect(player.sought, isNull);
    final rows = tester
        .widgetList<ListTile>(find.descendant(
            of: find.byType(MusicQueue), matching: find.byType(ListTile)))
        .toList();
    expect(rows.where((row) => row.selected), hasLength(1));
    expect(rows.singleWhere((row) => row.selected).key,
        ValueKey('music-queue-${playbackQueueId(songs.last)}'));
    await tester.runAsync(
        () async => player.removeVideoFromQueue(playbackQueueId(songs.first)));
    await tester.pump();
    expect(player.state.videos.map(playbackQueueId),
        [playbackQueueId(songs[1]), playbackQueueId(songs.last)]);
    expect(player.state.currentlyPlaying, songs.last);
  });

  testWidgets('music can cancel its existing sleep timer', (tester) async {
    player.sleep(const SleepTimer(duration: Duration(minutes: 5)));
    await pump(tester);
    expect(player.state.hasTimer, isTrue);
    await tap(tester, 'music-player-sleep');
    expect(player.state.hasTimer, isFalse);
    expect(find.text('Cancel sleep timer'), findsNothing);
  });

  testWidgets('Music can set and cancel a track count sleep timer',
      (tester) async {
    await pump(tester);
    await tap(tester, 'music-player-sleep');
    await tester.pumpAndSettle();
    await tap(tester, 'music-sleep-stop-after-tracks');
    await tester.pumpAndSettle();
    expect(
        find.text(
            'Each finished play counts, including repeats. Skips carry the count forward.'),
        findsOneWidget);
    final slider = tester
        .widget<Slider>(find.byKey(const ValueKey('music-sleep-track-count')));
    expect(slider.semanticFormatterCallback!(1), '1 track');
    slider.onChanged!(2);
    await tester.pump();
    await tester.tap(find.text('Set timer'));
    await tester.pumpAndSettle();
    expect(player.state.sleepTracksRemaining, 2);
    expect(find.text('2 tracks left'), findsOneWidget);

    await tester.runAsync(() async {
      player.setEvent(const MediaEvent(state: MediaState.completed));
    });
    expect(player.state.sleepTracksRemaining, 1);
    await tester.pump();
    await tester.pump();
    expect(find.text('1 track left'), findsOneWidget);
    await tap(tester, 'music-player-sleep');
    expect(player.state.sleepTracksRemaining, isNull);
    expect(player.state.hasTimer, isFalse);
    // Let the decoder's real-time stream notifications finish before painting.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('1 track left'), findsNothing);
  });

  testWidgets(
      'sleep dialog Back preserves playback and End of song stops autoplay',
      (tester) async {
    await pump(tester);
    BackButtonInterceptor.add(player.handleBackButton,
        name: 'miniPlayer', zIndex: 2, ifNotYetIntercepted: true);
    await tap(tester, 'music-player-sleep');
    await tester.pumpAndSettle();
    final slider = tester
        .widget<Slider>(find.byKey(const ValueKey('music-sleep-duration')));
    expect((slider.min, slider.max, slider.divisions, slider.value),
        (5.0, 120.0, 23, 30.0));
    await pressAndroidBack(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(player.state.isMini, isFalse);
    expect(player.state.hasTimer, isFalse);

    await tap(tester, 'music-player-sleep');
    await tester.pumpAndSettle();
    await tap(tester, 'music-sleep-end-of-song');
    await tester.pumpAndSettle();
    expect(player.state.hasTimer, isTrue);
    player.setEvent(const MediaEvent(state: MediaState.completed));
    await tester.pump();
    expect(player.state.hasTimer, isFalse);
    expect(player.state.mediaCommand?.type, MediaCommandType.pause);
    expect(player.nextCalls, 0);
    expect(player.state.currentQueueId, playbackQueueId(song));
  });

  testWidgets('minimizing and expanding music keeps the mounted audio decoder',
      (tester) async {
    final queued = song.copyWith(
        videoThumbnails: [
          ImageObject('medium', '/vi/song/mqdefault.jpg', 320, 180)
        ],
        deArrowThumbnailUrl:
            'https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=song');
    await player.seed(player.state
        .copyWith(currentlyPlaying: queued, videos: [queued, next]));
    await tester.runAsync(
        () => pump(tester, child: const Stack(children: [Player(844)])));
    final audioBuilder = find.byType(
        BlocBuilder<AudioPlayerCubit, AudioPlayerState>,
        skipOffstage: false);
    final decoder = tester.element(audioBuilder).read<AudioPlayerCubit>();
    final native = decoder.audioPlayer;
    for (final mini in [true, false, true, false]) {
      await player.seed(player.state.copyWith(isMini: mini));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
          tester.element(audioBuilder).read<AudioPlayerCubit>(), same(decoder));
      expect(decoder.audioPlayer, same(native));
      expect(decoder.isClosed, isFalse);
      expect(
          find.descendant(
              of: audioBuilder,
              matching: find.byType(Thumbnail, skipOffstage: false),
              skipOffstage: false),
          findsNothing,
          reason: 'The hidden decoder must not fetch video or DeArrow artwork');
    }
    await tester.runAsync(() async {
      final closed = decoder.stream.drain<void>();
      await tester.pumpWidget(const SizedBox.shrink());
      await closed.timeout(const Duration(seconds: 2));
    });
    expect(decoder.isClosed, isTrue);
  });

  testWidgets('a held queue pull can be cancelled after the player closes',
      (tester) async {
    await pump(tester);
    final footer = find.byKey(const ValueKey('music-player-queue'));
    final drag = await tester.startGesture(tester.getCenter(footer));
    await drag.moveBy(const Offset(0, -35));
    await drag.moveBy(const Offset(0, -160));
    await tester.pump();
    expect(find.byType(MusicQueue), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await drag.cancel();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the app player preserves the open queue across device layouts',
      (tester) async {
    await tester.runAsync(() async {
      await db.upsertServer(
          const Server(url: 'https://instance.example', inUse: true));
      await app.initState();
    });
    final surface = LayoutBuilder(
        builder: (context, constraints) => Stack(children: [
              Player(constraints.maxHeight),
            ]));
    await tester.runAsync(() => pump(tester, child: surface));
    await tester.pumpAndSettle();
    await tap(tester, 'music-player-queue');
    final music = find.byType(MusicPlayer);
    final original = tester.state(music);
    final header = find.byKey(const ValueKey('music-queue-drag-header'));
    final drag = await tester.startGesture(tester.getCenter(header));
    await drag.moveBy(const Offset(0, 35));
    await drag.moveBy(const Offset(0, 130));
    await tester.pump();

    tester.view.physicalSize = const Size(1280, 720);
    await player
        .seed(player.state.copyWith(orientation: Orientation.landscape));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Now playing'), findsOneWidget);
    await drag.cancel();

    tester.view.physicalSize = const Size(390, 844);
    await player.seed(player.state.copyWith(orientation: Orientation.portrait));
    await tester.pumpAndSettle();
    expect(tester.state(music), same(original));
    expect(header.hitTestable(), findsOneWidget);
    expect(find.byType(MusicQueue), findsOneWidget);
    expect(player.state.currentlyPlaying, song);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded Music keeps keyboard focus across viewport changes',
      (tester) async {
    BackButtonInterceptor.add(player.handleBackButton,
        zIndex: 2, ifNotYetIntercepted: true);
    addTearDown(() => BackButtonInterceptor.remove(player.handleBackButton));
    await tester.runAsync(() async {
      await db.upsertServer(
          const Server(url: 'https://instance.example', inUse: true));
      await app.initState();
    });
    final browsingFocus = FocusNode(debugLabel: 'Covered browsing search');
    addTearDown(browsingFocus.dispose);
    final surface = LayoutBuilder(
        builder: (context, constraints) => Stack(children: [
              Center(child: TextField(focusNode: browsingFocus)),
              Player(constraints.maxHeight),
            ]));
    await tester.runAsync(() => pump(tester, child: surface));
    final audioBuilder = find.byType(
        BlocBuilder<AudioPlayerCubit, AudioPlayerState>,
        skipOffstage: false);
    final decoder = tester.element(audioBuilder).read<AudioPlayerCubit>();
    try {
      for (final size in [
        const Size(390, 844),
        const Size(1280, 720),
        const Size(390, 844),
      ]) {
        await pump(tester, size: size, child: surface);
        await tester.pumpAndSettle();
        expect(tester.element(audioBuilder).read<AudioPlayerCubit>(),
            same(decoder));
        for (var index = 0; index < 32; index++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
          expect(browsingFocus.hasFocus, isFalse,
              reason: 'Expanded playback covers the browsing field at $size');
        }
        final shareIcon = find.byIcon(Icons.share);
        expect(shareIcon, findsOneWidget);
        Focus.of(tester.element(shareIcon)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.text('Share Invidious link'), findsOneWidget);
        await pressAndroidBack(tester);
        final wide = size.width == 1280;
        if (wide) {
          final selectQueue = find.byIcon(Icons.checklist_rounded);
          expect(selectQueue.hitTestable(), findsOneWidget);
          Focus.of(tester.element(selectQueue)).requestFocus();
          await tester.pump();
        } else {
          await tap(tester, 'music-player-queue');
          await tester.pumpAndSettle();
        }
        for (var index = 0; index < 12; index++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pumpAndSettle();
          expect(browsingFocus.hasFocus, isFalse);
        }
        await pressAndroidBack(tester);
        if (wide) {
          expect(player.state.isMini, isTrue,
              reason: 'The persistent queue must not consume Android Back');
          player.showBigPlayer();
          await tester.pumpAndSettle();
          expect(player.state.isMini, isFalse);
        } else {
          expect(find.byType(MusicQueue), findsNothing);
        }
      }
      final minimize = find.byIcon(Icons.expand_more);
      Focus.of(tester.element(minimize)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(player.state.isMini, isTrue);
      browsingFocus.requestFocus();
      await tester.pump();
      expect(browsingFocus.hasFocus, isTrue,
          reason: 'Mini playback must release the browsing page');
      expect(
          tester.element(audioBuilder).read<AudioPlayerCubit>(), same(decoder));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.runAsync(() async {
        final closed = decoder.stream.drain<void>();
        await tester.pumpWidget(const SizedBox.shrink());
        await closed.timeout(const Duration(seconds: 2));
      });
    }
  });

  testWidgets(
      'TV Music handles Select and queue Back without replacing its decoder',
      (tester) async {
    player.playlistError = StateError('next playlist page unavailable');
    // The parent supplies the displayed track. Leave the initial decoder input
    // empty so this UI test does not attempt to open a native media source.
    await tester.runAsync(() => pump(tester,
        size: const Size(1280, 720),
        child: Shortcuts(
          shortcuts: {
            LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
          },
          child: MusicScreen.tvAudio(),
        )));
    await tester.pump();
    final audioBuilder =
        find.byType(BlocBuilder<AudioPlayerCubit, AudioPlayerState>);
    final decoder = tester.element(audioBuilder).read<AudioPlayerCubit>();
    final native = decoder.audioPlayer;
    expect(tester.widget<MusicPlayer>(find.byType(MusicPlayer)).television,
        isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(player.state.mediaCommand?.type, MediaCommandType.play);

    await tap(tester, 'music-player-queue');
    await tester.pumpAndSettle();
    expect(
        find.text('Could not load the rest of this playlist.'), findsOneWidget);
    final retry = find.text('Retry');
    expect(retry, findsOneWidget);
    await tester.ensureVisible(retry);
    await tester.pump();
    expect(tester.getRect(retry).bottom, lessThan(720));

    await tester.tap(retry);
    await tester.pump();
    expect(player.playlistRetries, 1);
    expect(retry, findsNothing);
    await pressAndroidBack(tester);
    expect(find.byType(MusicQueue), findsNothing);
    expect(find.byTooltip('Next song'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(MusicQueue), findsOneWidget,
        reason: 'Back returns remote focus to the queue button');
    await pressAndroidBack(tester);
    expect(
        tester.element(audioBuilder).read<AudioPlayerCubit>(), same(decoder));
    expect(decoder.audioPlayer, same(native));
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final closed = decoder.stream.drain<void>();
      await tester.pumpWidget(const SizedBox.shrink());
      await closed.timeout(const Duration(seconds: 2));
    });
    expect(decoder.isClosed, isTrue);
  });
}
