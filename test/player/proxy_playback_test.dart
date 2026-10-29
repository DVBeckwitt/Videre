import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/media_handler.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/states/video_player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/format_stream.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _HeldServerDb extends IDbClient {
  final IDbClient delegate;
  final requested = Completer<void>();
  final server = Completer<Server>();

  _HeldServerDb(this.delegate);

  @override
  Future<Server> getCurrentlySelectedServer() {
    requested.complete();
    return server.future;
  }

  @override
  double getVideoProgress(String videoId) => delegate.getVideoProgress(videoId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _VideoWithoutNative extends VideoPlayerCubit {
  _VideoWithoutNative(super.initialState, super.player, super.settings);

  @override
  void onInit() {}

  @override
  void disposeControllers() => videoController = null;
}

class _HeldAudioPlayer implements AudioPlayer {
  final sourceRequested = Completer<void>();
  final source = Completer<Duration?>();
  final disposal = Completer<void>();
  AudioSource? requestedSource;

  @override
  Future<Duration?> setAudioSource(AudioSource audioSource,
      {bool preload = true, int? initialIndex, Duration? initialPosition}) {
    requestedSource = audioSource;
    sourceRequested.complete();
    return source.future;
  }

  @override
  Future<void> dispose() => disposal.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AudioWithoutNative extends AudioPlayerCubit {
  final _HeldAudioPlayer native;
  int playCalls = 0;

  _AudioWithoutNative(
      super.initialState, super.player, super.settings, this.native);

  @override
  void onInit() {}

  @override
  void initPlayer() => audioPlayer ??= native;

  @override
  void play() => playCalls++;
}

class _QueuedMetadataService extends Service {
  final _requested = <String, Completer<void>>{};
  final _results = <String, Completer<Video>>{};

  Future<void> requested(String id) =>
      _requested.putIfAbsent(id, Completer<void>.new).future;

  Completer<Video> result(String id) =>
      _results.putIfAbsent(id, Completer<Video>.new);

  @override
  Future<Video> getVideo(String videoId, {Server? serverOverride}) {
    _requested.putIfAbsent(videoId, Completer<void>.new).complete();
    return result(videoId).future;
  }

  @override
  Future<List<SponsorSegment>> getSponsorSegments(
          String videoId, List<SponsorSegmentType> categories) async =>
      [];

  @override
  Future<bool> isLoggedIn() async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late IDbClient database;
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;
  late Service originalService;

  const first = Video(videoId: 'first', formatStreams: [], adaptiveFormats: []);
  const pending = Video(videoId: 'pending');
  const completedPending =
      Video(videoId: 'pending', formatStreams: [], adaptiveFormats: []);
  const fresh = Video(videoId: 'fresh', formatStreams: [], adaptiveFormats: []);
  const freshNext =
      Video(videoId: 'fresh-next', formatStreams: [], adaptiveFormats: []);

  Future<_QueuedMetadataService> startQueuedPlayer() async {
    final metadata = _QueuedMetadataService();
    service = metadata;
    player.audioSession = await AudioSession.instance;
    app_main.mediaHandler = MediaHandler(player);
    await player.playVideo([first, pending, fresh]);
    return metadata;
  }

  setUp(() async {
    EasyThrottle.cancel(skipToVideoThrottleName);
    originalService = service;
    db = database = await SembastSqfDb.createInMemory();
    const server = Server(url: 'https://instance.example');
    await db.upsertServer(server);
    await db.useServer(server);
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    // AppCubit also starts initState in its constructor. Finish initialization
    // while the real DB is installed before a test holds a later server lookup.
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = TestPlayerCubit(PlayerState.init(null), settings);
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
  });

  tearDown(() async {
    EasyThrottle.cancel(skipToVideoThrottleName);
    db = database;
    if (!player.isClosed) await player.close();
    await settings.close();
    await app.close();
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
    await database.close();
    if (!identical(service, originalService)) service.httpClient.close();
    service = originalService;
  });

  test('proxy stop prevents late queued metadata from recreating a source',
      () async {
    final metadata = await startQueuedPlayer();
    final consumer = _VideoWithoutNative(
        VideoPlayerState(
            colors: ColorScheme.fromSeed(seedColor: Colors.blue),
            overFlowTextColor: Colors.white,
            key: GlobalKey(),
            video: first),
        player,
        settings);
    try {
      final switching = player.switchToVideo(pending);
      await metadata.requested(pending.videoId);
      await NetworkProxy.instance.apply(SocksProxyConfig(enabled: true));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(player.state.currentlyPlaying, isNull);
      metadata.result(pending.videoId).complete(completedPending);
      await switching;
      expect(player.state.currentlyPlaying, isNull);
      expect(player.state.isHidden, isTrue);
      expect(player.state.videos, isEmpty);
    } finally {
      await consumer.close();
    }
  });

  test('proxy stop invalidates initial metadata before a decoder mounts',
      () async {
    final metadata = _QueuedMetadataService();
    service = metadata;
    player.audioSession = await AudioSession.instance;
    app_main.mediaHandler = MediaHandler(player);
    final loading = player.playVideo([pending]);
    await metadata.requested(pending.videoId);
    await NetworkProxy.instance.apply(SocksProxyConfig(enabled: true));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    metadata.result(pending.videoId).complete(completedPending);
    await loading;
    expect(player.state.currentlyPlaying, isNull);
    expect(player.state.isHidden, isTrue);
    expect(player.state.videos, isEmpty);
  });

  test('proxy stop preserves an idle restored queue before audio session init',
      () async {
    await player.close();
    player = TestPlayerCubit(PlayerState.init([first, pending]), settings);
    final idle = player.state;
    // A dormant restored queue has neither a decoder nor an AudioSession yet.
    await NetworkProxy.instance.apply(SocksProxyConfig(enabled: true));
    expect(player.state, idle);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(player.state, idle);
  });

  test('a pending remote intent cannot start playback after proxy stop',
      () async {
    final metadata = await startQueuedPlayer();
    final remote = player.playRemoteVideo(pending.videoId, 10, true);
    await metadata.requested(pending.videoId);
    await NetworkProxy.instance.apply(SocksProxyConfig(enabled: true));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    metadata.result(pending.videoId).complete(completedPending);
    await remote;
    expect(player.state.currentlyPlaying, isNull);
    expect(player.state.isHidden, isTrue);
    expect(player.state.videos, isEmpty);
  });

  test('late previous-video metadata cannot overwrite a replacement queue',
      () async {
    final metadata = await startQueuedPlayer();
    await player.switchToVideo(fresh);
    player.skipToVideo(2);
    player.playPrevious();
    await metadata.requested(pending.videoId);
    await player.playVideo([fresh, freshNext]);
    metadata.result(pending.videoId).complete(completedPending);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(player.state.currentlyPlaying, fresh);
    expect(player.state.playQueue, [freshNext.videoId]);
    expect(player.state.playedVideos, isEmpty);
  });

  test('a stopped metadata failure cannot skip or change a replacement queue',
      () async {
    final metadata = await startQueuedPlayer();
    final switching = player.switchToVideo(pending);
    await metadata.requested(pending.videoId);
    player.hide();
    await player.playVideo([fresh, freshNext]);
    metadata.result(pending.videoId).completeError(StateError('Old request'));
    await switching;
    await Future<void>.delayed(Duration.zero);
    expect(player.state.currentlyPlaying, fresh);
    expect(player.state.videos, [fresh, freshNext]);
    expect(player.state.playQueue, [freshNext.videoId]);
    expect(player.state.playedVideos, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(player.state.currentlyPlaying, fresh);
    expect(player.state.isHidden, isFalse);
    expect(player.state.isClosing, isFalse);
  });

  test('a newer video switch wins over an older metadata result', () async {
    final metadata = await startQueuedPlayer();
    final switching = player.switchToVideo(pending);
    await metadata.requested(pending.videoId);
    await player.switchToVideo(fresh);
    final currentCommand = player.state.mediaCommand;
    metadata.result(pending.videoId).complete(completedPending);
    await switching;
    expect(player.state.currentlyPlaying, fresh);
    expect(player.state.mediaCommand, currentCommand);
  });

  test('closing the player invalidates pending initial metadata', () async {
    final metadata = _QueuedMetadataService();
    service = metadata;
    player.audioSession = await AudioSession.instance;
    app_main.mediaHandler = MediaHandler(player);
    final loading = player.playVideo([pending]);
    await metadata.requested(pending.videoId);
    await player.close();
    metadata.result(pending.videoId).complete(completedPending);
    await loading;
    expect(player.state.currentlyPlaying, isNull);
  });

  test('changing decoder mode keeps the pending video switch valid', () async {
    final metadata = await startQueuedPlayer();
    final switching = player.switchToVideo(pending);
    await metadata.requested(pending.videoId);
    player.switchAudio(true);
    metadata.result(pending.videoId).complete(completedPending);
    await switching;
    expect(player.state.currentlyPlaying, completedPending);
    expect(player.state.isAudio, isTrue);
  });

  test('proxy stop invalidates video waiting for its server', () async {
    final delayedDb = _HeldServerDb(database);
    final cubit = _VideoWithoutNative(
        VideoPlayerState(
            colors: ColorScheme.fromSeed(seedColor: Colors.blue),
            overFlowTextColor: Colors.white,
            key: GlobalKey(),
            video: const Video(videoId: 'pending')),
        player,
        settings);
    db = delayedDb;
    final loading = cubit.playVideo(false);
    await delayedDb.requested.future;
    await cubit.stopForProxyChange();
    delayedDb.server.complete(const Server(url: 'https://instance.example'));
    await loading;
    expect(cubit.videoController, isNull);
    db = database;
    await cubit.close();
  });

  test('proxy stop waits for audio disposal and prevents pending autoplay',
      () async {
    await settings.setUseProxy(true);
    final audioPlayer = TestPlayerCubit(
        PlayerState.init(null).copyWith(isAudio: true), settings);
    final native = _HeldAudioPlayer();
    final cubit = _AudioWithoutNative(
        AudioPlayerState(
            video: Video(videoId: 'audio', lengthSeconds: 60, formatStreams: [
          FormatStream('https://instance.example/audio', '18', 'audio/mp4',
              'medium', null, null, null, null, null),
          FormatStream('https://instance.example/retired', '22', 'video/mp4',
              'hd720', null, null, null, null, null),
        ])),
        audioPlayer,
        settings,
        native);
    final loading = cubit.playVideo(false);
    await native.sourceRequested.future;
    expect((native.requestedSource as UriAudioSource).uri.toString(),
        'https://instance.example/audio');
    var stopped = false;
    final stopping = cubit.stopForProxyChange().then((_) => stopped = true);
    await Future<void>.delayed(Duration.zero);
    expect(cubit.audioPlayer, isNull);
    expect(stopped, isFalse);
    native.source.complete(const Duration(seconds: 60));
    await loading;
    expect(cubit.playCalls, 0);
    native.disposal.complete();
    await stopping;
    expect(stopped, isTrue);
    await cubit.close();
    await audioPlayer.close();
  });
}
