import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/media_handler.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/backend_recovery.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _ManualService extends Service {
  final requested = <BackendPlayback>[];
  int metadataCalls = 0;
  final started = Completer<void>();
  Completer<void>? hold;
  Object? failure;

  @override
  Future<Video> getVideo(String videoId,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest,
      VideoLoadObserver? loadObserver}) async {
    metadataCalls++;
    final request = BackendPlayback(await db.getCurrentlySelectedServer());
    onBackendRequest?.call(request);
    if (!started.isCompleted) started.complete();
    if (hold != null) await hold!.future;
    if (failure != null) throw failure!;
    return _loaded(videoId, request);
  }

  @override
  Future<Video> getVideoForBackend(String videoId, BackendPlayback request,
      {void Function(BackendPlayback request)? onBackendRequest,
      bool Function()? isCurrent}) async {
    requested.add(request);
    onBackendRequest?.call(request);
    if (!started.isCompleted) started.complete();
    if (hold != null) await hold!.future;
    if (failure != null) throw failure!;
    return _loaded(videoId, request);
  }

  @override
  Future<List<SponsorSegment>> getSponsorSegments(
          String videoId, List<SponsorSegmentType> categories) async =>
      [];

  @override
  Future<bool> isLoggedIn() async => false;
}

class _ManualPlayer extends TestPlayerCubit {
  _ManualPlayer(super.initialState, super.settings);

  void seed(PlayerState value) => emit(value);
}

Video _loaded(String id, BackendPlayback request) => Video(
    videoId: id,
    title: id,
    lengthSeconds: 120,
    formatStreams: [],
    adaptiveFormats: [],
    backendPlayback: request);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory documents;
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _ManualPlayer player;
  late _ManualService manualService;
  late Service previousService;
  late Server preferred;
  late BackendPlayback initial;

  setUp(() async {
    previousService = service;
    service = manualService = _ManualService();
    documents = await Directory.systemTemp.createTemp('videre-player-backend-');
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documents.path);
    db = await SembastSqfDb.createInMemory();
    final selector = BackendSelector(
      'COMPANION_ID',
      const [BackendOption('a', 'Backend A'), BackendOption('b', 'Backend B')],
      automaticFallback: true,
    );
    preferred = selector.withSelection(
        Server(
            url: 'https://instance.example',
            backendSelector: selector,
            sidCookie: 'SID=test-session',
            authToken: 'test-token',
            customHeaders: {
              'Cookie': 'PREFS=keep; other=keep',
              'X-Custom': 'keep'
            }),
        'a');
    await db.upsertServer(preferred);
    await db.useServer(preferred);
    preferred = await db.getCurrentlySelectedServer();
    await fileDb.useServer(preferred);
    app = TestAppCubit(AppState(0, preferred, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    initial = BackendPlayback(preferred);
    final video = _loaded('video', initial).copyWith(queueEntryId: 'entry-1');
    player = _ManualPlayer(
        PlayerState.init([video]).copyWith(
            currentlyPlaying: video,
            requestedBackend: initial,
            position: const Duration(seconds: 42),
            speed: 1.5,
            isHidden: false,
            isMini: false,
            isPlaying: true),
        settings);
    player.audioSession = await AudioSession.instance;
    app_main.mediaHandler = MediaHandler(player);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    manualService.httpClient.close();
    service = previousService;
    messenger.setMockMethodCallHandler(pathProvider, null);
    await documents.delete(recursive: true);
  });

  test(
      'manual choice retries current position without changing saved preference',
      () async {
    await player.selectBackend('b',
        expectedVideoId: 'video', expectedRequest: initial);
    final request = manualService.requested.single;
    expect(request.server.backendSelector!.selectedValue(request.server), 'b');
    expect(request.matches(await db.getCurrentlySelectedServer()), isTrue);
    expect((await db.getCurrentlySelectedServer()).customHeaders,
        preferred.customHeaders);
    expect((await fileDb.getCurrentlySelectedServer()).customHeaders,
        preferred.customHeaders);
    expect(player.state.currentlyPlaying!.videoId, 'video');
    expect(player.state.position, const Duration(seconds: 42));
    expect(player.state.speed, 1.5);
    expect(player.state.mediaCommand!.type, MediaCommandType.switchVideo);
    final command = player.state.mediaCommand!.value as SwitchVideoValue;
    expect(command.startAt, const Duration(seconds: 42));
    expect(command.video.backendPlayback, same(request));
    expect(player.state.backendRecovery!.phase, BackendRecoveryPhase.trying);
    expect(player.state.backendRecovery!.alternativeIndex, 0);
  });

  test(
      'save as preferred updates both stores without replacing login or other headers',
      () async {
    await player.selectBackend('b',
        saveAsPreferred: true,
        expectedVideoId: 'video',
        expectedRequest: initial);
    final saved = await db.getCurrentlySelectedServer();
    expect(saved.backendSelector!.selectedValue(saved), 'b');
    expect(saved.sidCookie, preferred.sidCookie);
    expect(saved.authToken, preferred.authToken);
    expect(saved.customHeaders['X-Custom'], 'keep');
    expect(saved.customHeaders['Cookie'], contains('PREFS=keep'));
    expect(saved.customHeaders['Cookie'], contains('other=keep'));
    expect(saved.backendSelector!.automaticFallback, isTrue);
    expect(await fileDb.getCurrentlySelectedServer(), saved);
    expect(app.state.server, saved);
    expect(manualService.requested.single.matches(saved), isTrue);
  });

  test(
      'manual retry preserves a paused video and does not announce success at metadata',
      () async {
    player.pause();
    player.seed(player.state.copyWith(isPlaying: false));
    await player.selectBackend('b');
    expect(player.state.isPlaying, isFalse);
    expect(player.state.backendRecovery!.phase, BackendRecoveryPhase.trying);
    player.setEvent(
        const MediaEvent(state: MediaState.playing, type: MediaEventType.play));
    expect(player.state.isPlaying, isFalse);
    expect(player.state.mediaCommand!.type, MediaCommandType.pause);
  });

  test('manual metadata failure stays visible with the requested backend',
      () async {
    manualService.failure = const SocketException('Fixture transport failure');
    await player.selectBackend('b');
    expect(player.state.isClosing, isFalse);
    expect(player.state.isHidden, isFalse);
    expect(player.state.currentlyPlaying!.videoId, 'video');
    expect(player.state.backendRecovery!.phase, BackendRecoveryPhase.failed);
    expect(player.state.requestedBackend!.label, 'Backend B');
    expect(player.state.mediaEvent.state, MediaState.error);
  });

  test('stale picker or changed saved credentials cannot apply a choice',
      () async {
    await expectLater(
        player.selectBackend('b', expectedVideoId: 'other'), throwsStateError);
    await expectLater(
        player.selectBackend('b', expectedRequest: BackendPlayback(preferred)),
        throwsStateError);
    await db.upsertServer(preferred.copyWith(authToken: 'updated-token'));
    await expectLater(
        player.selectBackend('b', expectedRequest: initial), throwsStateError);
    expect(manualService.requested, isEmpty);
    expect(
        (await db.getCurrentlySelectedServer())
            .backendSelector!
            .selectedValue(await db.getCurrentlySelectedServer()),
        'a');
  });

  test('changing video discards a pending manual result and its status',
      () async {
    manualService.hold = Completer<void>();
    final choosing = player.selectBackend('b');
    await manualService.started.future;
    final replacement = _loaded('other', BackendPlayback(preferred));
    await player.playVideo([replacement]);
    manualService.hold!.complete();
    await choosing;
    expect(player.state.currentlyPlaying!.videoId, 'other');
    expect(player.state.requestedBackend, same(replacement.backendPlayback));
    expect(player.state.backendRecovery, isNull);
  });

  test('repeated Retry shares fresh metadata and retains position and entry',
      () async {
    manualService.hold = Completer<void>();
    player.seed(player.state.copyWith(
        isPlaying: false,
        mediaEvent: const MediaEvent(state: MediaState.error)));
    final first = player.retryCurrentVideo();
    final second = player.retryCurrentVideo();
    expect(second, same(first));
    await manualService.started.future;
    expect(manualService.metadataCalls, 1);
    expect(player.state.mediaEvent.state, MediaState.loading);
    manualService.hold!.complete();
    await first;
    final command = player.state.mediaCommand!.value as SwitchVideoValue;
    expect(command.startAt, const Duration(seconds: 42));
    expect(command.video.queueEntryId, 'entry-1');
    expect(player.state.currentQueueId, 'entry-1');
    expect(player.state.position, const Duration(seconds: 42));
    expect(player.state.speed, 1.5);
    expect(player.shouldStartPlayback, isTrue);
  });

  for (final withNext in [false, true]) {
    test('failed Retry retains current item with next entry $withNext',
        () async {
      final current = player.state.currentlyPlaying!;
      final next = _loaded('next', initial).copyWith(queueEntryId: 'entry-2');
      player.seed(player.state.copyWith(
          videos: [current, if (withNext) next],
          playQueue: ListQueue.of([if (withNext) 'entry-2']),
          playedVideos: ['earlier'],
          mediaEvent: const MediaEvent(state: MediaState.error)));
      final queue = player.state.videos;
      manualService.failure = StateError('Metadata unavailable');
      await player.retryCurrentVideo();
      expect(manualService.metadataCalls, 1);
      expect(player.state.videos, queue);
      expect(player.state.playQueue.toList(), [if (withNext) 'entry-2']);
      expect(player.state.playedVideos, ['earlier']);
      expect(player.state.currentQueueId, 'entry-1');
      expect(player.state.position, const Duration(seconds: 42));
      expect(player.state.mediaEvent.state, MediaState.error);
      expect(player.state.isClosing, isFalse);
      expect(player.state.isHidden, isFalse);
      expect(player.state.isPlaying, isFalse);

      manualService.failure = null;
      await player.retryCurrentVideo();
      expect(manualService.metadataCalls, 2);
      expect(player.state.currentQueueId, 'entry-1');
      expect(player.state.position, const Duration(seconds: 42));
    });
  }

  test('Pause during manual Retry prevents resumed autoplay', () async {
    manualService.hold = Completer<void>();
    player.seed(player.state.copyWith(isPlaying: false));
    final retry = player.retryCurrentVideo();
    await manualService.started.future;
    player.pause();
    manualService.hold!.complete();
    await retry;
    expect(player.shouldStartPlayback, isFalse);
    player.setEvent(
        const MediaEvent(state: MediaState.playing, type: MediaEventType.play));
    expect(player.state.isPlaying, isFalse);
    expect(player.state.mediaCommand!.type, MediaCommandType.pause);
  });

  test('Retry retains a per-video manual backend with a fresh bounded budget',
      () async {
    final manual = BackendPlayback.manual(preferred, 'b');
    player.seed(player.state.copyWith(
        currentlyPlaying:
            player.state.currentlyPlaying!.copyWith(backendPlayback: manual),
        requestedBackend: manual,
        mediaEvent: const MediaEvent(state: MediaState.error)));
    await player.retryCurrentVideo();
    final request = manualService.requested.single;
    expect(request, isNot(same(manual)));
    expect(request.manualSelection, isTrue);
    expect(request.server.backendSelector!.selectedValue(request.server), 'b');
    expect(request.retryIndex, 0);
    expect(request.retries, 0);
    expect(request.next()!.next(), isNull);
    expect(manualService.metadataCalls, 0);
    expect(player.state.currentQueueId, 'entry-1');
    expect(player.state.position, const Duration(seconds: 42));
    expect((await db.getCurrentlySelectedServer()).customHeaders,
        preferred.customHeaders);
  });

  test('Retry uses fresh account metadata after its manual snapshot changes',
      () async {
    final manual = BackendPlayback.manual(preferred, 'b');
    player.seed(player.state.copyWith(
        currentlyPlaying:
            player.state.currentlyPlaying!.copyWith(backendPlayback: manual),
        requestedBackend: manual));
    await db.upsertServer(preferred.copyWith(authToken: 'updated-token'));
    await player.retryCurrentVideo();
    expect(manualService.requested, isEmpty);
    expect(manualService.metadataCalls, 1);
    expect(player.state.currentlyPlaying!.backendPlayback!.server.authToken,
        'updated-token');
  });

  test('manual Retry preserves a seek made while metadata is pending',
      () async {
    manualService.hold = Completer<void>();
    final retry = player.retryCurrentVideo();
    await manualService.started.future;
    player.seek(const Duration(seconds: 73));
    manualService.hold!.complete();
    await retry;
    final command = player.state.mediaCommand!.value as SwitchVideoValue;
    expect(command.startAt, const Duration(seconds: 73));
    expect(player.state.position, const Duration(seconds: 73));
  });

  test('another selection invalidates a pending Retry result', () async {
    manualService.hold = Completer<void>();
    final retry = player.retryCurrentVideo();
    await manualService.started.future;
    final next = _loaded('next', initial).copyWith(queueEntryId: 'entry-2');
    await player.playVideo([next]);
    manualService.hold!.complete();
    await retry;
    expect(player.state.currentlyPlaying!.videoId, 'next');
    expect(player.state.mediaEvent.state, isNot(MediaState.error));
    expect(manualService.metadataCalls, 1);
  });

  test('offline Retry keeps position without fetching online metadata',
      () async {
    const downloaded = DownloadedVideo(
        videoId: 'saved',
        title: 'Saved video',
        lengthSeconds: 120,
        quality: '720p');
    player.seed(player.state.copyWith(
        currentlyPlaying: null,
        videos: [],
        offlineCurrentlyPlaying: downloaded,
        offlineVideos: [downloaded],
        mediaEvent: const MediaEvent(state: MediaState.error)));
    await player.retryCurrentVideo();
    expect(manualService.metadataCalls, 0);
    expect(player.state.offlineCurrentlyPlaying, downloaded);
    expect(
        player.state.mediaCommand!.type, MediaCommandType.switchToOfflineVideo);
    expect(player.state.startAt, const Duration(seconds: 42));
    expect(player.state.position, const Duration(seconds: 42));
  });
}
