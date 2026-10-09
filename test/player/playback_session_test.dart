import 'dart:async';
import 'dart:convert';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/home/views/components/continue_watching.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/playback_session.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/views/components/compact_video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _GuestService extends Service {
  List<SponsorSegmentType>? requestedCategories;

  @override
  Future<List<SponsorSegment>> getSponsorSegments(
      String videoId, List<SponsorSegmentType> categories) async {
    requestedCategories = categories;
    return [];
  }

  @override
  Future<bool> isLoggedIn() async => false;

  @override
  Future<Video> getVideo(String id, {Server? serverOverride}) async =>
      Video(videoId: id);
}

class _SessionPlayer extends TestPlayerCubit {
  _SessionPlayer(super.initialState, super.settings);

  void seedState(PlayerState snapshot) => emit(snapshot);

  void seedVideo(Video video) => emit(state.copyWith(currentlyPlaying: video));

  void seedDownload(DownloadedVideo video) => emit(state.copyWith(
      offlineCurrentlyPlaying: video,
      offlineVideos: [video],
      position: Duration.zero));

  void seedAudioStart(Duration startAt) =>
      emit(state.copyWith(startAt: startAt, isAudio: true));
}

class _AudioStartRecorder extends AudioPlayerCubit {
  _AudioStartRecorder(super.initialState, super.player, super.settings);

  Duration? startedAt;
  bool? startedOffline;

  @override
  void initPlayer() {}

  @override
  Future<void> playVideo(bool offline, {Duration? startAt}) async {
    startedAt = startAt;
    startedOffline = offline;
  }
}

class _RemoteLoadPlayer extends _SessionPlayer {
  _RemoteLoadPlayer(super.initialState, super.settings);

  // Exercise remote intent without creating a native media controller.
  @override
  Future<void> playVideo(List<Video> videos,
          {bool? audio, Duration? startAt, bool? playing}) =>
      super.playVideo([], audio: audio, startAt: startAt, playing: playing);
}

class _DelayedProgressPlayer extends _SessionPlayer {
  _DelayedProgressPlayer(super.initialState, super.settings);

  final savedProgress = <int, Completer<void>>{};

  @override
  Future<void> saveProgress(int timeInSeconds) =>
      savedProgress.putIfAbsent(timeInSeconds, () => Completer<void>()).future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('session keeps queue order and position without expiring stream URLs',
      () {
    const session = PlaybackSession(
        videos: [
          Video(videoId: 'first', title: 'First', dashUrl: 'https://expired'),
          Video(videoId: 'second', title: 'Second'),
        ],
        currentId: 'second',
        seconds: 42,
        audio: true,
        played: ['first'],
        next: []);
    final encoded = session.encode();
    final decoded = PlaybackSession.decode(encoded)!;
    expect(encoded, isNot(contains('https://expired')));
    expect(decoded.videos.map((v) => v.videoId), ['first', 'second']);
    expect(decoded.currentId, 'second');
    expect(decoded.seconds, 42);
    expect(decoded.played, ['first']);
    expect(decoded.audio, isTrue);
  });

  test('invalid or future session data is ignored', () {
    const session = PlaybackSession(
        videos: [Video(videoId: 'a')], currentId: 'a', seconds: 20);
    final json = jsonDecode(session.encode()) as Map<String, dynamic>;
    expect(PlaybackSession.decode('broken'), isNull);
    expect(PlaybackSession.decode(null), isNull);
    expect(PlaybackSession.decode(jsonEncode({...json, 'version': 2})), isNull);
    expect(
        PlaybackSession.decode(jsonEncode({...json, 'seconds': -1})), isNull);
    expect(
        PlaybackSession.decode(jsonEncode({...json, 'currentId': 'missing'})),
        isNull);
  });

  group('restoration', () {
    late _SessionPlayer player;
    late TestSettingsCubit settings;
    late TestAppCubit app;

    setUp(() async {
      db = await SembastSqfDb.createInMemory();
      service = _GuestService();
      app = TestAppCubit(AppState(0, null, HomeLayout()));
      settings = TestSettingsCubit(SettingsState.init(), app);
      player = _SessionPlayer(PlayerState.init(null), settings);
    });

    tearDown(() async {
      if (!player.isClosed) await player.close();
      await settings.close();
      await db.close();
    });

    test('SponsorBlock loads sponsors by default and respects saved choices',
        () async {
      final guest = service as _GuestService;
      player.seedVideo(const Video(videoId: 'sponsor-test'));
      await player.setSponsorBlock();
      expect(guest.requestedCategories, [SponsorSegmentType.sponsor]);

      await settings.saveSetting(
          SettingsValue(SponsorSegmentType.sponsor.settingsName(), 'false'));
      guest.requestedCategories = null;
      await player.setSponsorBlock();
      expect(guest.requestedCategories, isNull);

      await settings.saveSetting(
          SettingsValue(SponsorSegmentType.intro.settingsName(), 'true'));
      await player.setSponsorBlock();
      expect(guest.requestedCategories, [SponsorSegmentType.intro]);
    });

    test('automatic PiP follows visible video playback, including downloads',
        () async {
      const channel = MethodChannel('videre/pip');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final playing = player.state.copyWith(
        currentlyPlaying: const Video(videoId: 'pip'),
        isPlaying: true,
        isHidden: false,
      );
      player.seedState(playing);
      await Future<void>.delayed(Duration.zero);
      expect(calls.last.arguments['enabled'], isTrue);

      for (final ineligible in [
        playing.copyWith(isPlaying: false),
        playing.copyWith(isAudio: true),
        playing.copyWith(isHidden: true),
        playing.copyWith(isClosing: true),
        playing.copyWith(currentlyPlaying: null),
      ]) {
        player.seedState(ineligible);
        await Future<void>.delayed(Duration.zero);
        expect(calls.last.arguments['enabled'], isFalse);
        player.seedState(playing);
      }
      player.seedState(playing.copyWith(
        currentlyPlaying: null,
        offlineCurrentlyPlaying: const DownloadedVideo(
            videoId: 'offline',
            title: 'Offline',
            lengthSeconds: 60,
            quality: '720p'),
        aspectRatio: 0.1,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(calls.last.arguments['enabled'], isTrue);
      expect(
          calls.last.arguments['aspectRatio'], greaterThanOrEqualTo(1 / 2.39));
      player.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(calls.last.arguments['enabled'], isTrue);
      await player.close();
      expect(calls.last.arguments['enabled'], isFalse);
    });

    test('PiP callbacks preserve playback, position, and the previous layout',
        () async {
      const channel = MethodChannel('puntito.simple_pip_mode');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final offline in [false, true]) {
        final playing = player.state.copyWith(
          currentlyPlaying: offline ? null : const Video(videoId: 'pip'),
          offlineCurrentlyPlaying: offline
              ? const DownloadedVideo(
                  videoId: 'offline',
                  title: 'Offline',
                  lengthSeconds: 60,
                  quality: '720p')
              : null,
          isPlaying: true,
          isHidden: false,
          isMini: true,
          position: const Duration(seconds: 23),
        );
        player.seedState(playing);
        for (final active in [true, false]) {
          await messenger.handlePlatformMessage(
              channel.name,
              channel.codec.encodeMethodCall(
                  MethodCall(active ? 'onPipEntered' : 'onPipExited')),
              (_) {});
          expect(player.state, playing.copyWith(isPip: active));
        }
      }
    });

    test('denied PiP does not change layout or playback', () async {
      const channel = MethodChannel('puntito.simple_pip_mode');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          channel, (call) async => call.method == 'isPipAvailable');
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      player.seedState(player.state.copyWith(
          currentlyPlaying: const Video(videoId: 'pip'),
          isPlaying: true,
          isHidden: false));
      final before = player.state;
      await player.enterPip();
      expect(player.state, before);
      messenger.setMockMethodCallHandler(
          channel, (call) async => throw PlatformException(code: 'denied'));
      await player.enterPip();
      expect(player.state, before);
    });

    test('resizing into PiP preserves the expanded portrait layout', () async {
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
      view.devicePixelRatio = 1;
      view.physicalSize = const Size(390, 844);
      addTearDown(view.resetDevicePixelRatio);
      addTearDown(view.resetPhysicalSize);
      player.seedState(player.state.copyWith(
        currentlyPlaying: const Video(videoId: 'pip'),
        isHidden: false,
        isMini: false,
        orientation: Orientation.portrait,
      ));
      const channel = MethodChannel('puntito.simple_pip_mode');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(const MethodCall('onPipEntered')),
          (_) {});
      view.physicalSize = const Size(320, 180);
      player.didChangeMetrics();
      expect(player.state.fullScreenState, FullScreenState.notFullScreen);
      expect(player.state.mediaCommand, isNull);

      await messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(const MethodCall('onPipExited')),
          (_) {});
      view.physicalSize = const Size(390, 844);
      player.didChangeMetrics();
      expect(player.state.fullScreenState, FullScreenState.notFullScreen);
      expect(player.state.isMini, isFalse);

      // A real rotation still enters fullscreen after returning to the app.
      view.physicalSize = const Size(844, 390);
      player.didChangeMetrics();
      expect(player.state.fullScreenState, FullScreenState.fullScreen);
    });

    test('restores a queue and timestamp without issuing playback commands',
        () async {
      const session = PlaybackSession(
          videos: [Video(videoId: 'a'), Video(videoId: 'b')],
          currentId: 'a',
          seconds: 17,
          next: ['b']);
      await db
          .saveSetting(SettingsValue(playbackSessionSetting, session.encode()));
      player.restoreSession();
      expect(player.state.videos.map((v) => v.videoId), ['a', 'b']);
      expect(player.state.playQueue, ['b']);
      expect(player.state.startAt, const Duration(seconds: 17));
      expect(player.state.isHidden, isTrue);
      expect(player.state.hasVideo, isFalse);
      expect(player.state.isPlaying, isFalse);
      expect(player.state.mediaCommand, isNull);
    });

    test('ignores deleted or unfinished downloads when restoring', () async {
      await db.upsertDownload(const DownloadedVideo(
          videoId: 'a',
          title: 'A',
          lengthSeconds: 100,
          quality: 'audio',
          downloadComplete: true));
      await db.upsertDownload(const DownloadedVideo(
          videoId: 'b', title: 'B', lengthSeconds: 100, quality: 'audio'));
      const session = PlaybackSession(
          offlineIds: ['a', 'b', 'deleted'],
          currentId: 'a',
          seconds: 17,
          next: ['b', 'deleted']);
      await db
          .saveSetting(SettingsValue(playbackSessionSetting, session.encode()));
      player.restoreSession();
      expect(player.state.offlineVideos.map((v) => v.videoId), ['a']);
      expect(player.state.playQueue, isEmpty);
      expect(player.state.hasVideo, isFalse);
    });

    test('offline progress is available to resume after restarting', () async {
      player.seedDownload(const DownloadedVideo(
          videoId: 'a', title: 'A', lengthSeconds: 100, quality: 'audio'));
      await player.saveProgress(35);
      expect(db.getVideoProgress('a'), 0.35);
      await player.saveProgress(99);
      expect(db.getVideoProgress('a'), 1);
    });

    test('pause saves the exact position between periodic checkpoints',
        () async {
      player.seedDownload(const DownloadedVideo(
          videoId: 'a', title: 'A', lengthSeconds: 100, quality: 'audio'));
      await player.onProgress(const Duration(seconds: 35));
      await player.onProgress(const Duration(seconds: 38));
      player.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.pause));
      await Future<void>.delayed(Duration.zero);
      expect(player.savedSession?.seconds, 38);
    });

    test('backgrounding saves the exact position without closing the player',
        () async {
      player.seedDownload(const DownloadedVideo(
          videoId: 'a', title: 'A', lengthSeconds: 100, quality: 'audio'));
      for (final lifecycle in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.detached,
      ]) {
        await player.onProgress(const Duration(seconds: 35));
        await player.onProgress(const Duration(seconds: 38));
        player.didChangeAppLifecycleState(lifecycle);
        await Future<void>.delayed(Duration.zero);
        expect(player.savedSession?.seconds, 38, reason: lifecycle.name);
      }
    });

    test('a newer pause wins over delayed remote autoplay events', () async {
      final remote = _RemoteLoadPlayer(PlayerState.init(null), settings);
      addTearDown(remote.close);
      await remote.playRemoteVideo('dQw4w9WgXcQ', 123, true);
      remote.pause();
      remote.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.pause));
      final firstPause = remote.state.mediaCommand;
      remote.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
      expect(remote.state.isPlaying, isFalse);
      expect(remote.state.mediaCommand?.type, MediaCommandType.pause);
      expect(remote.state.mediaCommand, isNot(same(firstPause)));
      final secondPause = remote.state.mediaCommand;
      remote.setEvent(const MediaEvent(
          state: MediaState.playing, type: MediaEventType.play));
      expect(remote.state.mediaCommand, isNot(same(secondPause)));
      expect(remote.state.isPlaying, isFalse);
    });

    test('a newer play overrides paused remote-load intent', () async {
      final remote = _RemoteLoadPlayer(PlayerState.init(null), settings);
      addTearDown(remote.close);
      await remote.playRemoteVideo('dQw4w9WgXcQ', 123, false);
      remote.play();
      for (var event = 0; event < 2; event++) {
        remote.setEvent(const MediaEvent(
            state: MediaState.playing, type: MediaEventType.play));
        expect(remote.state.isPlaying, isTrue);
        expect(remote.state.mediaCommand?.type, MediaCommandType.play);
      }
    });

    test('starting local playback clears previous remote pause intent',
        () async {
      final remote = _RemoteLoadPlayer(PlayerState.init(null), settings);
      addTearDown(remote.close);
      for (final start in <Future<void> Function()>[
        () => remote.playVideo([]),
        () => remote.playOfflineVideos([]),
        remote.resumeSession,
      ]) {
        await remote.playRemoteVideo('dQw4w9WgXcQ', 123, false);
        await start();
        remote.setEvent(const MediaEvent(
            state: MediaState.playing, type: MediaEventType.play));
        expect(remote.state.isPlaying, isTrue);
      }
    });

    test('delayed progress cannot replace a newer video session timestamp',
        () async {
      final delayed = _DelayedProgressPlayer(PlayerState.init(null), settings);
      addTearDown(delayed.close);
      delayed.seedDownload(const DownloadedVideo(
          videoId: 'old', title: 'Old', lengthSeconds: 100, quality: 'audio'));
      final progress = delayed.onProgress(const Duration(seconds: 75));
      delayed.seedDownload(const DownloadedVideo(
          videoId: 'new', title: 'New', lengthSeconds: 100, quality: 'audio'));
      delayed.savedProgress[75]!.complete();
      await progress;
      expect(delayed.state.position, Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(delayed.savedSession?.currentId, 'new');
      expect(delayed.savedSession?.seconds, 0);
    });

    test('delayed progress safely finishes after closing the player', () async {
      final delayed = _DelayedProgressPlayer(PlayerState.init(null), settings);
      delayed.seedDownload(const DownloadedVideo(
          videoId: 'a', title: 'A', lengthSeconds: 100, quality: 'audio'));
      final progress = delayed.onProgress(const Duration(seconds: 75));
      await delayed.close();
      delayed.savedProgress[75]!.complete();
      await progress;
      expect(delayed.savedSession?.seconds, 75);
    });

    test('pause and background save position while progress storage is pending',
        () async {
      Future<void> waitForSavedPosition(int seconds) async {
        final database = db as SembastSqfDb;
        await database.settingsStore
            .record(playbackSessionSetting)
            .onSnapshot(database.db)
            .firstWhere((record) =>
                PlaybackSession.decode(record?.value['value'] as String?)
                    ?.seconds ==
                seconds)
            .timeout(const Duration(seconds: 5));
      }

      for (final pause in [true, false]) {
        final delayed =
            _DelayedProgressPlayer(PlayerState.init(null), settings);
        addTearDown(() async {
          if (!delayed.isClosed) await delayed.close();
        });
        delayed.seedDownload(const DownloadedVideo(
            videoId: 'a', title: 'A', lengthSeconds: 100, quality: 'audio'));
        final checkpointSaved = waitForSavedPosition(35);
        delayed.seek(const Duration(seconds: 35));
        await checkpointSaved;
        final pausedPositionSaved = waitForSavedPosition(38);
        final progress = delayed.onProgress(const Duration(seconds: 38));
        if (pause) {
          delayed.setEvent(const MediaEvent(
              state: MediaState.playing, type: MediaEventType.pause));
        } else {
          delayed.didChangeAppLifecycleState(AppLifecycleState.paused);
        }
        await pausedPositionSaved;
        expect(delayed.state.position, const Duration(seconds: 38));
        expect(delayed.savedSession?.seconds, 38);
        delayed.savedProgress[38]!.complete();
        await progress;
        await delayed.close();
      }
    });

    test('out-of-order progress writes do not move playback backwards',
        () async {
      final delayed = _DelayedProgressPlayer(PlayerState.init(null), settings);
      addTearDown(delayed.close);
      delayed.seedDownload(const DownloadedVideo(
          videoId: 'a', title: 'A', lengthSeconds: 100, quality: 'audio'));
      final older = delayed.onProgress(const Duration(seconds: 35));
      final newer = delayed.onProgress(const Duration(seconds: 38));
      delayed.savedProgress[38]!.complete();
      await newer;
      delayed.savedProgress[35]!.complete();
      await older;
      expect(delayed.state.position, const Duration(seconds: 38));
    });

    testWidgets(
        'Continue Watching honors hidden and masked cached-video filters',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final videos = [
        HistoryVideoCache('title', 'spoiler', 'Author', ''),
        HistoryVideoCache('channel', 'Channel video', 'Author', '',
            authorId: 'blocked-channel'),
        HistoryVideoCache('length', 'Long video', 'Author', '',
            lengthSeconds: 700),
      ];
      final filters = [
        VideoFilter(value: 'spoiler'),
        VideoFilter(value: '', channelId: 'blocked-channel')..filterAll = true,
        VideoFilter(value: '600')
          ..type = FilterType.length
          ..operation = FilterOperation.higherThan,
      ];
      // Sembast schedules real async work; keep it outside the widget clock.
      await tester.runAsync(() async {
        for (final video in videos) {
          await db.upsertHistoryVideo(video);
          await db.saveProgress(Progress(0.5, video.videoId));
        }
        for (final filter in filters) {
          filter.hideFromFeed = true;
          await db.saveFilter(filter);
        }
      });
      final legacy = HistoryVideoCache.fromJson({
        'videoId': 'old',
        'title': 'Old',
        'author': null,
        'thumbnail': '',
        'created': '2026-01-01T00:00:00.000',
      });
      expect(legacy.toVideo().authorId, isNull);
      expect(legacy.toVideo().lengthSeconds, isNull);
      await tester.pumpWidget(BlocProvider<PlayerCubit>.value(
          value: player,
          child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(body: ContinueWatching()))));
      await tester.pumpAndSettle();
      expect(find.byType(CompactVideo), findsNothing);
      await tester.runAsync(() async {
        for (final filter in filters) {
          filter.hideFromFeed = false;
          await db.saveFilter(filter);
        }
      });
      playbackHistoryRevision.value++;
      await tester.pumpAndSettle();
      expect(find.byType(CompactVideo), findsNWidgets(3));
      expect(find.text('**********'), findsNWidgets(3));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    test(
        'fresh audio uses exact session time even after progress rounds to watched',
        () async {
      await db.saveProgress(Progress(1, 'a'));
      player.seedAudioStart(const Duration(seconds: 95));
      for (final offline in [false, true]) {
        final audio = _AudioStartRecorder(
            AudioPlayerState(
                video: offline
                    ? null
                    : const Video(videoId: 'a', lengthSeconds: 100),
                offlineVideo: offline
                    ? const DownloadedVideo(
                        videoId: 'a',
                        title: 'A',
                        lengthSeconds: 100,
                        quality: 'audio')
                    : null),
            player,
            settings);
        expect(audio.startedAt, const Duration(seconds: 95));
        expect(audio.startedOffline, offline);
        expect(db.getVideoProgress('a'), 1);
        await audio.close();
      }
    });

    test('closing an older player cannot replace the newer saved session',
        () async {
      player.seedDownload(const DownloadedVideo(
          videoId: 'old', title: 'Old', lengthSeconds: 100, quality: 'audio'));
      final next = _SessionPlayer(PlayerState.init(null), settings);
      next.seedDownload(const DownloadedVideo(
          videoId: 'new', title: 'New', lengthSeconds: 100, quality: 'audio'));
      await player.close();
      expect(next.savedSession?.currentId, 'new');
      await next.close();
      expect(
          PlaybackSession.decode(db.getSettings(playbackSessionSetting)?.value)
              ?.currentId,
          'new');
    });
  });
}
