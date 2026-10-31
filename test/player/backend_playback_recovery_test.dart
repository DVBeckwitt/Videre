import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/media_handler.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/backend_recovery.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/states/video_player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/format_stream.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _VideoWithoutAutostart extends VideoPlayerCubit {
  _VideoWithoutAutostart(super.initialState, super.player, super.settings);

  @override
  void onInit() {}
}

class _RetryService extends Service {
  _RetryService({super.httpClient});
  final retriedVideos = <Video>[];
  final visited = <String>[];
  Completer<void>? heldRetry;
  Completer<void>? heldManual;
  final manualStarted = Completer<void>();

  @override
  Future<Video> getVideoForBackend(String videoId, BackendPlayback request,
      {void Function(BackendPlayback request)? onBackendRequest,
      bool Function()? isCurrent}) async {
    onBackendRequest?.call(request);
    if (!manualStarted.isCompleted) manualStarted.complete();
    if (heldManual != null) await heldManual!.future;
    return _video(videoId, request);
  }

  @override
  Future<List<SponsorSegment>> getSponsorSegments(
          String videoId, List<SponsorSegmentType> categories) async =>
      [];
  int? sourceCount;

  @override
  bool useProxy() => true;

  @override
  Future<Video?> retryVideoBackend(Video video,
      {required bool Function() isCurrent,
      void Function(BackendPlayback request)? onRetry}) async {
    retriedVideos.add(video);
    if (!isCurrent()) return null;
    final next = video.backendPlayback?.next();
    if (next == null) return null;
    visited.add(next.label);
    onRetry?.call(next);
    if (heldRetry != null) await heldRetry!.future;
    if (!isCurrent()) return null;
    return _video(video.videoId, next, sources: sourceCount ?? 1);
  }
}

Video _video(String id, BackendPlayback? playback, {int sources = 1}) {
  final backend = playback == null
      ? 'default'
      : playback.server.backendSelector?.selectedValue(playback.server) ??
          'default';
  return Video(
      videoId: id,
      lengthSeconds: 60,
      backendPlayback: playback,
      formatStreams: [
        for (var i = sources; i > 0; i--)
          FormatStream('https://instance.example/$id-$backend-$i.mp4', '$i',
              'video/mp4', 'medium', 'mp4', 'h264', '${i}p', '${i}p', '640x360')
      ]);
}

Future<void> _flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('better_player_channel');
  const events = MethodChannel('better_player_channel/videoEvents1');
  const wakelock =
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;
  late _RetryService retryService;
  late Service previousService;
  late Server preferred;
  late List<Map<dynamic, dynamic>> sources;
  late Map<String, bool> failedUrls;
  late Map<String, Completer<void>> heldSources;
  late List<int> seeks;
  late List<double> speeds;
  late List<double> pitches;
  late int playCalls;
  late bool rejectPlay;
  late bool nativePlaying;
  late int nativePosition;

  Future<void> error({required bool retryable}) =>
      messenger.handlePlatformMessage(
          events.name,
          const StandardMethodCodec().encodeErrorEnvelope(
              code: 'VideoError',
              message: 'Playback failed',
              details: {'backendRetryable': retryable}),
          (_) {});

  setUp(() async {
    previousService = service;
    service = retryService = _RetryService();
    db = await SembastSqfDb.createInMemory();
    final selector = BackendSelector(
        'backend',
        const [
          BackendOption('a', 'Backend A'),
          BackendOption('b', 'Backend B'),
          BackendOption('c', 'Backend C'),
        ],
        automaticFallback: true);
    preferred = selector.withSelection(
        Server(url: 'https://instance.example', backendSelector: selector),
        'a');
    await db.upsertServer(preferred);
    await db.useServer(preferred);
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    await settings.setUseDash(false);
    player = TestPlayerCubit(PlayerState.init(null), settings);
    sources = [];
    failedUrls = {};
    heldSources = {};
    seeks = [];
    speeds = [];
    pitches = [];
    playCalls = 0;
    rejectPlay = false;
    nativePlaying = false;
    nativePosition = 0;
    messenger.setMockMessageHandler(
        wakelock,
        (_) async =>
            const StandardMessageCodec().encodeMessage(<Object?>[null]));
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'create':
          return {'textureId': 1};
        case 'position':
          return nativePosition;
        case 'seekTo':
          nativePosition = call.arguments['location'] as int;
          seeks.add(nativePosition);
        case 'setPitch':
          pitches.add((call.arguments['pitch'] as num).toDouble());
        case 'setSpeed':
          speeds.add((call.arguments['speed'] as num).toDouble());
        case 'play':
          if (rejectPlay) throw PlatformException(code: 'PlayUnavailable');
          playCalls++;
          nativePlaying = true;
        case 'pause':
          nativePlaying = false;
        case 'setDataSource':
          final source = Map<dynamic, dynamic>.of(call.arguments['dataSource']);
          sources.add(source);
          final held = heldSources[source['uri']];
          if (held != null) await held.future;
          final retryable = failedUrls[source['uri']];
          if (retryable != null) {
            await error(retryable: retryable);
          } else {
            await messenger.handlePlatformMessage(
                events.name,
                const StandardMethodCodec().encodeSuccessEnvelope({
                  'event': 'initialized',
                  'duration': 60000,
                  'width': 640,
                  'height': 360,
                  'isLiveStream': false,
                }),
                (_) {});
          }
      }
      return null;
    });
  });

  tearDown(() async {
    EasyThrottle.cancel('video-player-progress');
    EasyThrottle.cancel('video-buffering');
    await _flush();
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    retryService.httpClient.close();
    service = previousService;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(events, null);
    messenger.setMockMessageHandler(wakelock, null);
  });

  _VideoWithoutAutostart cubit({int count = 1, bool session = true}) {
    final current = _video('video', session ? BackendPlayback(preferred) : null,
        sources: count);
    player.emit(player.state.copyWith(currentlyPlaying: current));
    return _VideoWithoutAutostart(
        VideoPlayerState(
            video: current,
            colors: ColorScheme.fromSeed(seedColor: Colors.blue),
            overFlowTextColor: Colors.white,
            key: GlobalKey()),
        player,
        settings);
  }

  for (final change in ['headers', 'instance', 'proxy']) {
    test('direct video admission rejects a stale $change snapshot', () async {
      final video = cubit();
      try {
        if (change == 'proxy') {
          await NetworkProxy.instance
              .initialize(saved: '{}', configureNative: false);
        } else {
          final updated = change == 'instance'
              ? preferred.copyWith(url: 'https://other.example')
              : preferred
                  .copyWith(customHeaders: {'Cookie': 'backend=a; login=new'});
          await db.upsertServer(updated);
          await db.useServer(updated);
        }
        await video.playVideo(false);
        await _flush();
        expect(sources, isEmpty);
        expect(retryService.retriedVideos, isEmpty);
        expect(player.state.mediaEvent.state, MediaState.error);
      } finally {
        await video.close();
      }
    });
  }

  test('ordinary startup still plays without requesting another backend',
      () async {
    final video = cubit();
    try {
      await video.playVideo(false);
      await _flush();
      expect(nativePlaying, isTrue);
      expect(playCalls, 1);
      expect(retryService.retriedVideos, isEmpty);
      expect(player.state.requestedBackend?.label, 'Backend A');
    } finally {
      await video.close();
    }
  });

  test('early seeks wait for initialization and retain the latest position',
      () async {
    final held = heldSources['https://instance.example/video-a-1.mp4'] =
        Completer<void>();
    final video = cubit();
    final loading = video.playVideo(false);
    try {
      await _flush();
      await video.seek(const Duration(seconds: 10));
      await video.seek(const Duration(seconds: 25));
      video.pause();
      expect(seeks, isEmpty);
      held.complete();
      await loading;
      await _flush();
      expect(seeks.last, 25000);
      expect(nativePlaying, isFalse);
    } finally {
      if (!held.isCompleted) held.complete();
      await loading;
      await video.close();
    }
  });

  test('new video discards a seek queued during backend recovery', () async {
    final video = cubit();
    final held = retryService.heldRetry = Completer<void>();
    try {
      await video.playVideo(false);
      await error(retryable: true);
      await _flush();
      await video.seek(const Duration(seconds: 25));
      video.switchVideo(_video('replacement', BackendPlayback(preferred)));
      await _flush();
      held.complete();
      await _flush();
      expect(
          sources.last['uri'], 'https://instance.example/replacement-a-1.mp4');
      expect(seeks, isNot(contains(25000)));
    } finally {
      if (!held.isCompleted) held.complete();
      await video.close();
    }
  });

  test('native play failure stays terminal without an unhandled setup future',
      () async {
    rejectPlay = true;
    final video = cubit();
    try {
      await video.playVideo(false);
      await _flush();
      expect(retryService.retriedVideos, isEmpty);
      expect(player.state.mediaEvent.state, MediaState.error);
    } finally {
      await video.close();
    }
  });

  test('exhausts formats before retrying with the effective server headers',
      () async {
    failedUrls['https://instance.example/video-a-1.mp4'] = true;
    failedUrls['https://instance.example/video-a-2.mp4'] = true;
    final video = cubit(count: 2);
    try {
      await video.playVideo(false);
      await _flush();
      expect(sources.map((source) => source['uri']), [
        'https://instance.example/video-a-1.mp4',
        'https://instance.example/video-a-2.mp4',
        'https://instance.example/video-b-1.mp4',
      ]);
      expect(retryService.visited, ['Backend B']);
      expect((sources.last['headers'] as Map)['Cookie'], 'backend=b');
      expect((await db.getCurrentlySelectedServer()).customHeaders,
          preferred.customHeaders);
      expect(nativePlaying, isTrue);
    } finally {
      await video.close();
    }
  });

  test('recovered metadata survives a decoder remount', () async {
    failedUrls['https://instance.example/video-a-1.mp4'] = true;
    final video = cubit();
    _VideoWithoutAutostart? replacement;
    try {
      await video.playVideo(false);
      await _flush();
      expect(retryService.visited, ['Backend B']);
      final recovered = video.state.video!;
      expect(player.state.currentlyPlaying, same(recovered));
      await video.close();
      player.switchAudio(true);
      player.switchAudio(false);
      replacement = _VideoWithoutAutostart(
          VideoPlayerState(
              video: player.state.currentlyPlaying,
              colors: ColorScheme.fromSeed(seedColor: Colors.blue),
              overFlowTextColor: Colors.white,
              key: GlobalKey()),
          player,
          settings);
      await replacement.playVideo(false);
      await _flush();
      expect(sources.last['uri'], 'https://instance.example/video-b-1.mp4');
      expect(retryService.visited, ['Backend B']);
    } finally {
      if (!video.isClosed) await video.close();
      await replacement?.close();
    }
  });

  test('empty native buffering ranges reset progress without throwing',
      () async {
    final video = cubit();
    try {
      await video.playVideo(false);
      await _flush();
      for (final ranges in <List<List<int>>>[
        [
          [0, 20000],
          [0, 10000]
        ],
        [],
      ]) {
        EasyThrottle.cancel('video-buffering');
        await messenger.handlePlatformMessage(
            events.name,
            const StandardMethodCodec().encodeSuccessEnvelope({
              'event': 'bufferingUpdate',
              'values': ranges,
            }),
            (_) {});
        await _flush();
        expect(video.state.bufferPosition,
            ranges.isEmpty ? Duration.zero : const Duration(seconds: 20));
      }
    } finally {
      await video.close();
    }
  });

  test('typed manifest failure can recover before a native source is installed',
      () async {
    retryService.httpClient.close();
    service =
        retryService = _RetryService(httpClient: MockClient((request) async {
      expect(request.headers['Cookie'], 'backend=a');
      return http.Response('Unavailable', 503);
    }));
    final video = cubit();
    try {
      video.switchVideo(_video('dash-video', BackendPlayback(preferred))
          .copyWith(
              formatStreams: [],
              dashUrl: 'https://instance.example/manifest.mpd'));
      await _flush();
      expect(retryService.visited, ['Backend B']);
      expect(
          sources.single['uri'], 'https://instance.example/dash-video-b-1.mp4');
      expect(nativePlaying, isTrue);
    } finally {
      await video.close();
    }
  });

  test('generic decoder errors and videos without a session do not retry',
      () async {
    for (final withSession in [true, false]) {
      sources.clear();
      failedUrls[withSession
          ? 'https://instance.example/video-a-1.mp4'
          : 'https://instance.example/video-default-1.mp4'] = !withSession;
      final video = cubit(session: withSession);
      try {
        await video.playVideo(false);
        await _flush();
        expect(retryService.retriedVideos, isEmpty);
        expect(player.state.mediaEvent.state, MediaState.error);
      } finally {
        await video.close();
      }
    }
  });

  test('a later codec failure does not inherit earlier transport eligibility',
      () async {
    failedUrls['https://instance.example/video-a-1.mp4'] = true;
    final video = cubit();
    try {
      await video.playVideo(false);
      await _flush();
      expect(retryService.visited, ['Backend B']);
      await error(retryable: false);
      await _flush();
      expect(retryService.visited, ['Backend B']);
      expect(retryService.retriedVideos, hasLength(1));
      expect(player.state.mediaEvent.state, MediaState.error);
    } finally {
      await video.close();
    }
  });

  test('paused midstream recovery preserves position and current speed',
      () async {
    final video = cubit();
    try {
      await video.playVideo(false);
      await video.videoController!.setSpeed(1.75);
      video.setPitchSemitones(-12);
      video.seek(const Duration(seconds: 23));
      video.pause();
      await _flush();
      final previousPlayCalls = playCalls;
      await error(retryable: true);
      await _flush();
      expect(retryService.visited, ['Backend B']);
      expect(seeks.last, 23000);
      expect(speeds.last, 1.75);
      expect(pitches.last, 0.5);
      expect(nativePlaying, isFalse);
      expect(playCalls, previousPlayCalls);
      expect(video.state.video!.backendPlayback!.label, 'Backend B');
    } finally {
      await video.close();
    }
  });

  test('paused quality change retains position, speed and paused intent',
      () async {
    final video = cubit(count: 2);
    try {
      await video.playVideo(false);
      await video.videoController!.setSpeed(1.75);
      video.seek(const Duration(seconds: 12));
      video.pause();
      await _flush();
      final previousPlayCalls = playCalls;
      video.selectVideoTrack(0);
      await _flush();
      expect(sources.last['uri'], 'https://instance.example/video-a-2.mp4');
      expect(seeks.last, 12000);
      expect(speeds.last, 1.75);
      expect(nativePlaying, isFalse);
      expect(playCalls, previousPlayCalls);
    } finally {
      await video.close();
    }
  });

  test('pause during a failed source survives ordinary format fallback',
      () async {
    const first = 'https://instance.example/video-a-1.mp4';
    failedUrls[first] = false;
    final held = heldSources[first] = Completer<void>();
    final video = cubit(count: 2);
    try {
      final loading = video.playVideo(false);
      await _flush();
      video.pause();
      held.complete();
      await loading;
      await _flush();
      expect(sources, hasLength(2));
      expect(retryService.retriedVideos, isEmpty);
      expect(nativePlaying, isFalse);
      expect(playCalls, 0);
    } finally {
      await video.close();
    }
  });

  test('a pause while retry metadata is pending prevents autoplay', () async {
    final video = cubit();
    try {
      await video.playVideo(false);
      retryService.heldRetry = Completer<void>();
      await error(retryable: true);
      await _flush();
      expect(retryService.visited, ['Backend B']);
      expect(player.state.requestedBackend?.label, 'Backend B');
      expect(player.state.mediaEvent.value, 'Backend B');
      video.pause();
      final previousPlayCalls = playCalls;
      retryService.heldRetry!.complete();
      await _flush();
      expect(sources, hasLength(2));
      expect(nativePlaying, isFalse);
      expect(playCalls, previousPlayCalls);
      expect(player.state.requestedBackend?.label, 'Backend B');
    } finally {
      await video.close();
    }
  });

  test('stopping invalidates pending metadata and duplicate native failures',
      () async {
    final video = cubit();
    await video.playVideo(false);
    retryService.heldRetry = Completer<void>();
    await error(retryable: true);
    await error(retryable: true);
    await _flush();
    expect(retryService.visited, ['Backend B']);
    await video.stopForProxyChange();
    retryService.heldRetry!.complete();
    await _flush();
    expect(sources, hasLength(1));
    expect(video.videoController, isNull);
    await video.close();
  });

  test('new video supersedes an older backend response', () async {
    final video = cubit();
    try {
      await video.playVideo(false);
      retryService.heldRetry = Completer<void>();
      await error(retryable: true);
      await _flush();
      video.switchVideo(_video('new-video', BackendPlayback(preferred)));
      await _flush();
      retryService.heldRetry!.complete();
      await _flush();
      expect(video.state.video!.videoId, 'new-video');
      expect(sources.map((source) => source['uri']), [
        'https://instance.example/video-a-1.mp4',
        'https://instance.example/new-video-a-1.mp4',
      ]);
    } finally {
      await video.close();
    }
  });

  test('manual metadata supersedes an in-flight automatic native recovery',
      () async {
    player.audioSession = await AudioSession.instance;
    app_main.mediaHandler = MediaHandler(player);
    final video = cubit();
    try {
      await video.playVideo(false);
      retryService.heldRetry = Completer<void>();
      await error(retryable: true);
      await _flush();
      expect(retryService.visited, ['Backend B']);
      final automaticRequest = player.state.requestedBackend!;
      final originalGeneration = player.backendPlaybackGeneration;
      retryService.heldManual = Completer<void>();
      final selecting = player.selectBackend('c',
          expectedVideoId: 'video', expectedRequest: automaticRequest);
      await retryService.manualStarted.future;
      final manualRequest = player.state.requestedBackend!;
      expect(player.backendPlaybackGeneration, greaterThan(originalGeneration));
      expect(manualRequest.label, 'Backend C');
      expect(player.state.backendRecovery!.phase, BackendRecoveryPhase.trying);

      // The old recovery result and its decoder errors must not install B,
      // fail C, or replace C's progress message while its metadata is pending.
      retryService.heldRetry!.complete();
      await error(retryable: false);
      await _flush();
      expect(sources, hasLength(1));
      expect(player.state.requestedBackend, same(manualRequest));
      expect(player.state.backendRecovery!.phase, BackendRecoveryPhase.trying);

      retryService.heldManual!.complete();
      await selecting;
      video.handleCommand(player.state.mediaCommand!);
      await _flush();
      expect(sources.map((source) => source['uri']), [
        'https://instance.example/video-a-1.mp4',
        'https://instance.example/video-c-1.mp4',
      ]);
      expect(video.state.video!.backendPlayback, same(manualRequest));
      expect(player.state.requestedBackend, same(manualRequest));
      expect(retryService.visited, ['Backend B']);
    } finally {
      if (retryService.heldRetry?.isCompleted == false) {
        retryService.heldRetry!.complete();
      }
      if (retryService.heldManual?.isCompleted == false) {
        retryService.heldManual!.complete();
      }
      await _flush();
      await video.close();
    }
  });

  test('repeated backend failures share the two-alternative budget', () async {
    for (final backend in ['a', 'b', 'c']) {
      failedUrls['https://instance.example/video-$backend-1.mp4'] = true;
    }
    final video = cubit();
    try {
      await video.playVideo(false);
      await _flush();
      expect(retryService.visited, ['Backend B', 'Backend C']);
      expect(sources, hasLength(3));
      expect(player.state.mediaEvent.state, MediaState.error);
      expect(nativePlaying, isFalse);
    } finally {
      await video.close();
    }
  });
}
