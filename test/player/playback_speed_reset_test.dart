import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/models/playback_pitch.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/states/video_player.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/format_stream.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:river_player/river_player.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _VideoWithoutAutostart extends VideoPlayerCubit {
  _VideoWithoutAutostart(super.initialState, super.player, super.settings);

  @override
  void onInit() {}
}

class _RetainedAudioPlayer implements AudioPlayer {
  double nativeSpeed = 1;
  double nativePitch = 1;
  final pitchesAtPlay = <double>[];
  final speedCalls = <double>[];
  final speedsAtPlay = <double>[];
  final sources = <AudioSource>[];
  Completer<Duration?>? heldSource;

  @override
  double get speed => nativeSpeed;

  @override
  Future<Duration?> setAudioSource(AudioSource source,
      {bool preload = true,
      int? initialIndex,
      Duration? initialPosition}) async {
    sources.add(source);
    if (heldSource != null) return heldSource!.future;
    return const Duration(minutes: 1);
  }

  @override
  Future<void> setSpeed(double speed) async {
    nativeSpeed = speed;
    speedCalls.add(speed);
  }

  @override
  Future<void> setPitch(double pitch) async => nativePitch = pitch;

  @override
  double get pitch => nativePitch;

  @override
  Future<void> play() async {
    speedsAtPlay.add(nativeSpeed);
    pitchesAtPlay.add(nativePitch);
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AudioWithoutAutostart extends AudioPlayerCubit {
  final _RetainedAudioPlayer native;

  _AudioWithoutAutostart(
      super.initialState, super.player, super.settings, this.native);

  @override
  void onInit() {}

  @override
  void initPlayer() => audioPlayer ??= native;
}

Video _video(String id) => Video(
      videoId: id,
      lengthSeconds: 60,
      adaptiveFormats: [],
      formatStreams: [
        FormatStream('https://instance.example/$id-360.mp4', '18', 'video/mp4',
            'medium', 'mp4', null, '360p', '360p', '640x360'),
        FormatStream('https://instance.example/$id-144.mp4', '17', 'video/mp4',
            'small', 'mp4', null, '144p', '144p', '256x144'),
      ],
    );

Future<void> _flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const nativeChannel = MethodChannel('better_player_channel');
  const events = MethodChannel('better_player_channel/videoEvents1');
  const wakelockChannel =
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;
  late double nativeVideoSpeed;
  late double nativeVideoPitch;
  late int videoPitchCalls;
  late List<double> videoSpeedCalls;
  late List<String> videoSources;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    const server = Server(url: 'https://instance.example');
    await db.upsertServer(server);
    await db.useServer(server);
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    await settings.setUseDash(false);
    // Use combined streams for audio as well, without any network requests.
    await settings.setUseProxy(true);
    player = TestPlayerCubit(PlayerState.init(null), settings);
    nativeVideoSpeed = 1;
    nativeVideoPitch = 1;
    videoPitchCalls = 0;
    videoSpeedCalls = [];
    videoSources = [];
    messenger.setMockMessageHandler(
        wakelockChannel,
        (_) async =>
            const StandardMessageCodec().encodeMessage(<Object?>[null]));
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      if (call.method == 'create') return {'textureId': 1};
      if (call.method == 'position') return 0;
      if (call.method == 'setPitch') {
        videoPitchCalls++;
        nativeVideoPitch = (call.arguments['pitch'] as num).toDouble();
      }
      if (call.method == 'setSpeed') {
        nativeVideoSpeed = (call.arguments['speed'] as num).toDouble();
        videoSpeedCalls.add(nativeVideoSpeed);
      }
      if (call.method == 'setDataSource') {
        videoSources.add(call.arguments['dataSource']['uri'] as String);
        // Native players retain their rate across sources. The Dart wrapper
        // independently resets its value to 1, so asserting the UI is not enough.
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
      return null;
    });
  });

  tearDown(() async {
    await _flush();
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    messenger.setMockMethodCallHandler(nativeChannel, null);
    messenger.setMockMethodCallHandler(events, null);
    messenger.setMockMessageHandler(wakelockChannel, null);
  });

  _VideoWithoutAutostart videoCubit() => _VideoWithoutAutostart(
        VideoPlayerState(
            video: _video('first'),
            colors: ColorScheme.fromSeed(seedColor: Colors.blue),
            overFlowTextColor: Colors.white,
            key: GlobalKey()),
        player,
        settings,
      );

  for (final remember in [false, true]) {
    test('video new source applies native rate with remember=$remember',
        () async {
      await settings.setRememberPlayBackSpeed(remember);
      final video = videoCubit();
      try {
        await video.playVideo(false);
        await video.videoController!.setSpeed(2);
        await _flush();
        expect(nativeVideoSpeed, 2);
        expect(settings.state.lastSpeed, 2);
        video.setPitchSemitones(7);
        await _flush();
        expect(nativeVideoPitch, closeTo(pitchFactorForSemitones(7), 0.000001));
        expect(nativeVideoSpeed, 2);

        final initialized = video.stream
            .firstWhere((state) => state.video?.videoId == 'second');
        video.switchVideo(_video('second'));
        await initialized;
        await _flush();

        expect(videoSources.last, contains('second'));
        expect(nativeVideoSpeed, remember ? 2 : 1);
        expect(player.state.speed, remember ? 2 : 1);
        expect(videoSpeedCalls.last, remember ? 2 : 1);
        expect(nativeVideoPitch, 1);
        expect(player.state.pitchSemitones, 0);
        expect(video.getPitchSemitones(), 0);
      } finally {
        await video.close();
      }
    });
  }

  test(
      'video pause/resume and same-video source changes retain the chosen rate',
      () async {
    await settings.setRememberPlayBackSpeed(true);
    final video = videoCubit();
    try {
      await video.playVideo(false);
      await video.videoController!.setSpeed(1.75);
      video.setPitchSemitones(-5);
      await _flush();
      await video.videoController!.pause();
      // A stored preference must not override the current video's rate on resume.
      await settings.setLastSpeed(2.5);
      await video.videoController!.play();
      await _flush();
      expect(nativeVideoSpeed, 1.75);

      await video.videoController!.pause();
      await video.videoController!.setSpeed(1.75);
      expect(video.isPlaying(), isFalse);
      await video.videoController!.play();
      await video.selectVideoTrack(1);
      await _flush();
      expect(nativeVideoSpeed, 1.75);
      expect(video.getSpeed(), 1.75);
      expect(video.isPlaying(), isTrue);
      expect(nativeVideoPitch, closeTo(pitchFactorForSemitones(-5), 0.000001));
      expect(player.state.pitchSemitones, -5);

      await video.playVideo(false);
      await _flush();
      expect(nativeVideoSpeed, 1.75);
      expect(video.getSpeed(), 1.75);
    } finally {
      await video.close();
    }
  });

  for (final remember in [false, true]) {
    test('audio new source applies rate before play with remember=$remember',
        () async {
      await settings.setRememberPlayBackSpeed(remember);
      await player.close();
      player = TestPlayerCubit(
          PlayerState.init(null).copyWith(isAudio: true), settings);
      final native = _RetainedAudioPlayer();
      final audio = _AudioWithoutAutostart(
          AudioPlayerState(video: _video('first')), player, settings, native);
      try {
        await audio.playVideo(false);
        audio.setSpeed(2);
        audio.setPitchSemitones(-12);
        await _flush();
        expect(native.nativePitch, 0.5);
        expect(native.nativeSpeed, 2);
        audio.switchVideo(_video('second'));
        await _flush();
        expect(native.sources, hasLength(2));
        expect(native.nativeSpeed, remember ? 2 : 1);
        expect(native.speedsAtPlay.last, remember ? 2 : 1);
        expect(native.nativePitch, 1);
        expect(native.pitchesAtPlay.last, 1);
        expect(player.state.pitchSemitones, 0);
      } finally {
        await audio.close();
      }
    });
  }

  for (final newVideo in [false, true]) {
    test('audio honors a speed change while loading with newVideo=$newVideo',
        () async {
      await player.close();
      player = TestPlayerCubit(
          PlayerState.init(null).copyWith(isAudio: true), settings);
      final native = _RetainedAudioPlayer();
      final audio = _AudioWithoutAutostart(
          AudioPlayerState(video: _video('first')), player, settings, native);
      try {
        await audio.playVideo(false);
        audio.setSpeed(1.75);
        await _flush();

        final held = native.heldSource = Completer<Duration?>();
        if (newVideo) {
          audio.switchVideo(_video('second'));
        } else {
          unawaited(audio.playVideo(false));
        }
        await _flush();
        expect(native.sources, hasLength(2));
        expect(native.speedsAtPlay, hasLength(1));
        audio.setSpeed(2.25);
        audio.setPitchSemitones(12);
        held.complete(const Duration(minutes: 1));
        await _flush();

        expect(native.nativeSpeed, 2.25);
        expect(native.speedsAtPlay, [1, 2.25]);
        expect(native.nativePitch, 2);
        expect(native.pitchesAtPlay, [1, 2]);
      } finally {
        await audio.close();
      }
    });
  }
  test(
      'audio resume and same-video reload preserve speed; cancelled load cannot reset it',
      () async {
    await player.close();
    player = TestPlayerCubit(
        PlayerState.init(null).copyWith(isAudio: true), settings);
    final native = _RetainedAudioPlayer();
    final audio = _AudioWithoutAutostart(
        AudioPlayerState(video: _video('first')), player, settings, native);
    try {
      await audio.playVideo(false);
      audio.setSpeed(1.75);
      await _flush();
      audio.pause();
      audio.play();
      await audio.playVideo(false);
      expect(native.nativeSpeed, 1.75);
      expect(native.speedsAtPlay.last, 1.75);

      final held = native.heldSource = Completer<Duration?>();
      audio.switchVideo(_video('second'));
      await _flush();
      final callsBeforeStop = native.speedCalls.length;
      await audio.stopForProxyChange();
      held.complete(const Duration(minutes: 1));
      await _flush();
      expect(native.speedCalls, hasLength(callsBeforeStop));
      expect(native.nativeSpeed, 1.75);
    } finally {
      await audio.close();
    }
  });

  for (final remember in [false, true]) {
    test('speed follows video/audio mode changes with remember=$remember',
        () async {
      await settings.setRememberPlayBackSpeed(remember);
      final video = videoCubit();
      final native = _RetainedAudioPlayer();
      AudioPlayerCubit? audio;
      VideoPlayerCubit? replacement;
      try {
        await video.playVideo(false);
        await video.videoController!.setSpeed(1.25);
        await _flush();
        await video.close();
        player.setAudio(true);
        audio = _AudioWithoutAutostart(
            AudioPlayerState(video: _video('first')), player, settings, native);
        await audio.playVideo(false);
        expect(native.nativeSpeed, 1.25);
        expect(player.state.speed, 1.25);

        audio.setSpeed(1.75);
        await _flush();
        await audio.close();
        player.setAudio(false);
        replacement = videoCubit();
        await replacement.playVideo(false);
        await _flush();
        expect(nativeVideoSpeed, 1.75);
        expect(player.state.speed, 1.75);

        replacement.switchVideo(_video('second'));
        await _flush();
        expect(nativeVideoSpeed, remember ? 1.75 : 1);
        expect(player.state.speed, remember ? 1.75 : 1);
      } finally {
        if (!video.isClosed) await video.close();
        if (audio != null && !audio.isClosed) await audio.close();
        await replacement?.close();
      }
    });
  }

  test('speed chosen before native creation survives a mode change', () async {
    final video = videoCubit();
    final native = _RetainedAudioPlayer();
    AudioPlayerCubit? audio;
    try {
      player.speedForVideo('first');
      video.setSpeed(1.5);
      expect(videoSpeedCalls, isEmpty);
      expect(player.state.speed, 1.5);
      await video.close();
      player.setAudio(true);
      audio = _AudioWithoutAutostart(
          AudioPlayerState(video: _video('first')), player, settings, native);
      await audio.playVideo(false);
      expect(native.nativeSpeed, 1.5);
      expect(player.state.speed, 1.5);
    } finally {
      if (!video.isClosed) await video.close();
      await audio?.close();
    }
  });

  test('pitch follows video/audio mode changes for the same video', () async {
    final video = videoCubit();
    final native = _RetainedAudioPlayer();
    AudioPlayerCubit? audio;
    VideoPlayerCubit? replacement;
    try {
      await video.playVideo(false);
      video.setPitchSemitones(7);
      await _flush();
      await video.close();
      player.setAudio(true);
      audio = _AudioWithoutAutostart(
          AudioPlayerState(video: _video('first')), player, settings, native);
      await audio.playVideo(false);
      expect(native.nativePitch, closeTo(pitchFactorForSemitones(7), 0.000001));
      expect(audio.getPitchSemitones(), 7);

      audio.setPitchSemitones(-5);
      await _flush();
      await audio.close();
      player.setAudio(false);
      replacement = videoCubit();
      await replacement.playVideo(false);
      await _flush();
      expect(nativeVideoPitch, closeTo(pitchFactorForSemitones(-5), 0.000001));
      expect(replacement.getPitchSemitones(), -5);
      expect(player.state.pitchSemitones, -5);
    } finally {
      if (!video.isClosed) await video.close();
      if (audio != null && !audio.isClosed) await audio.close();
      await replacement?.close();
    }
  });

  test('unsupported platforms load video without calling the pitch bridge',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final video = videoCubit();
    try {
      await video.playVideo(false);
      video.setPitchSemitones(12);
      await _flush();
      expect(videoSources, isNotEmpty);
      expect(videoPitchCalls, 0);
      expect(video.getPitchSemitones(), 0);
      expect(player.state.pitchSemitones, 0);
    } finally {
      await video.close();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('pitch selected before decoder creation is applied when video loads',
      () async {
    final video = videoCubit();
    video.videoController = BetterPlayerController(
        const BetterPlayerConfiguration(allowedScreenSleep: true));
    try {
      player.pitchForVideo('first');
      video.setPitchSemitones(12);
      await _flush();
      expect(videoPitchCalls, 0);
      expect(player.state.pitchSemitones, 12);
      await video.playVideo(false);
      await _flush();
      expect(nativeVideoPitch, 2);
      expect(video.getPitchSemitones(), 12);
    } finally {
      await video.close();
    }
  });
}
