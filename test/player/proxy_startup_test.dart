import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/playback_session.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_settings_cubit.dart';

class _GuestService extends Service {
  @override
  Future<List<SponsorSegment>> getSponsorSegments(
          String videoId, List<SponsorSegmentType> categories) async =>
      [];

  @override
  Future<Video> getVideo(String id, {Server? serverOverride}) async =>
      Video(videoId: id, formatStreams: const [], adaptiveFormats: const []);
}

class _StartupPlayer extends PlayerCubit {
  late Future<void> ready;
  int metricsChanges = 0;

  _StartupPlayer(super.initialState, super.settings, {super.resume});

  // Record the real initialization future without replacing its native awaits.
  @override
  Future<void> onReady() => ready = super.onReady();

  @override
  void mapMediaEventToMediaHandler(MediaEvent event) {}

  @override
  void didChangeMetrics() => metricsChanges++;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.ryanheise.audio_session');
  const first = Video(videoId: 'first', formatStreams: [], adaptiveFormats: []);
  const next = Video(videoId: 'next', formatStreams: [], adaptiveFormats: []);
  const fresh = Video(videoId: 'fresh', formatStreams: [], adaptiveFormats: []);
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late Service originalService;
  late bool originalTv;
  _StartupPlayer? player;

  Future<void> saveSession() => db.saveSetting(SettingsValue(
      playbackSessionSetting,
      const PlaybackSession(
          videos: [first, next],
          currentId: 'next',
          seconds: 35,
          played: ['first']).encode()));

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    originalService = service;
    originalTv = app_main.isTv;
    service = _GuestService();
    app_main.isTv = true;
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
  });

  tearDown(() async {
    if (player != null && !player!.isClosed) await player!.close();
    player = null;
    await settings.close();
    await app.close();
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
    await db.close();
    service.httpClient.close();
    service = originalService;
    app_main.isTv = originalTv;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  // AudioSession caches its singleton. Keep cold initialization and the warm
  // recovery/control cases together so randomized test ordering stays safe.
  test('startup honors proxy stop and close while preserving play and resume',
      () async {
    final requested = Completer<void>();
    final reply = Completer<Map<String, dynamic>?>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'getConfiguration') {
        requested.complete();
        return reply.future;
      }
      return null;
    });
    await saveSession();
    final starting = player =
        _StartupPlayer(PlayerState.init([first, next]), settings, resume: true);
    try {
      await requested.future.timeout(const Duration(seconds: 2));
      await NetworkProxy.instance.apply(SocksProxyConfig(enabled: true));
      reply.complete(null);
      await starting.ready.timeout(const Duration(seconds: 2));
      expect(starting.state.currentlyPlaying, isNull);
      expect(starting.state.isHidden, isTrue);
      expect(starting.state.videos, [first, next]);

      await starting.playVideo([fresh]);
      expect(starting.state.currentlyPlaying, fresh);
      expect(starting.state.isHidden, isFalse);
    } finally {
      if (!reply.isCompleted) reply.complete(null);
      await starting.ready;
    }
    await starting.close();

    // Uncancelled TV startup still selects the first video and builds its queue.
    final initial = player = _StartupPlayer(
        PlayerState.init([first, next])
            .copyWith(startAt: const Duration(seconds: 12)),
        settings);
    await initial.ready;
    expect(initial.state.currentlyPlaying, first);
    expect(initial.state.position, const Duration(seconds: 12));
    expect(initial.state.playQueue.toList(), ['next']);
    await initial.close();

    // Automatic resume remains valid when no newer intent cancels startup.
    await saveSession();
    final resumed =
        player = _StartupPlayer(PlayerState.init(null), settings, resume: true);
    await resumed.ready;
    expect(resumed.state.currentlyPlaying?.videoId, 'next');
    expect(resumed.state.position, const Duration(seconds: 35));
    expect(resumed.state.isHidden, isFalse);
    await resumed.close();

    // Even a cached AudioSession.instance yields at the real native await.
    // Closing before it resumes must not register an observer afterward.
    final disposed = player =
        _StartupPlayer(PlayerState.init([first]), settings, resume: true);
    final closing = disposed.close();
    await disposed.ready;
    await closing;
    binding.handleMetricsChanged();
    expect(disposed.metricsChanges, 0);
    expect(disposed.state.currentlyPlaying, isNull);
  });
}
