import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/playback_pitch.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/states/video_player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river_player/river_player.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _VideoWithoutNative extends VideoPlayerCubit {
  double nativeSpeed = 1;

  _VideoWithoutNative(super.initialState, super.player, super.settings);

  @override
  void onInit() {}

  @override
  void disposeControllers() => videoController = null;

  @override
  double getSpeed() => nativeSpeed;
}

class _AudioWithoutSource extends AudioPlayerCubit {
  _AudioWithoutSource(super.initialState, super.player, super.settings);

  @override
  void onInit() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = TestPlayerCubit(PlayerState.init(null), settings);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  void reportSpeed(Object? value) => player.setEvent(MediaEvent(
      state: MediaState.ready,
      type: MediaEventType.speedChanged,
      value: value));

  test('current speed accepts valid native values without starting playback',
      () {
    reportSpeed(1.37);
    expect(player.state.speed, 1.37);
    expect(player.state.isPlaying, isFalse);
    expect(player.state.mediaCommand, isNull);

    reportSpeed(2);
    expect(player.state.speed, 2);
    reportSpeed(1.0);
    expect(player.state.speed, 1);
    expect(player.state.isPlaying, isFalse);
  });

  test('invalid native speed events preserve the last valid speed', () {
    reportSpeed(1.25);
    for (final invalid in [null, 0, -1, double.nan, double.infinity, '2']) {
      reportSpeed(invalid);
      expect(player.state.speed, 1.25, reason: 'Invalid speed: $invalid');
    }
  });

  test('video speed events and new decoder initialization update the shortcut',
      () async {
    final video = _VideoWithoutNative(
        VideoPlayerState(
          colors: ColorScheme.fromSeed(seedColor: Colors.blue),
          overFlowTextColor: Colors.white,
          key: GlobalKey(),
        ),
        player,
        settings);
    try {
      video.forwardEvent(BetterPlayerEvent(BetterPlayerEventType.setSpeed,
          parameters: {'speed': 1.75}));
      expect(player.state.speed, 1.75);
      expect(player.state.isPlaying, isFalse);

      video.nativeSpeed = 1;
      video.forwardEvent(BetterPlayerEvent(BetterPlayerEventType.initialized));
      expect(player.state.speed, 1);

      video.nativeSpeed = 2.5;
      video.forwardEvent(BetterPlayerEvent(BetterPlayerEventType.initialized));
      expect(player.state.speed, 2.5);
      expect(player.state.isPlaying, isFalse);
    } finally {
      await video.close();
    }
  });

  test('audio speed stream follows changes and resets with a new decoder',
      () async {
    final audio =
        _AudioWithoutSource(const AudioPlayerState(), player, settings);
    try {
      audio.initPlayer();
      await Future<void>.delayed(Duration.zero);
      final firstDecoder = audio.audioPlayer!;
      await firstDecoder.setSpeed(1.75);
      await Future<void>.delayed(Duration.zero);
      expect(player.state.speed, 1.75);
      expect(player.state.isPlaying, isFalse);

      await audio.stopForProxyChange();
      audio.initPlayer();
      await Future<void>.delayed(Duration.zero);
      expect(player.state.speed, 1);
      await firstDecoder.setSpeed(3);
      await Future<void>.delayed(Duration.zero);
      expect(player.state.speed, 1);

      await audio.audioPlayer!.setSpeed(2.25);
      await Future<void>.delayed(Duration.zero);
      expect(player.state.speed, 2.25);
      expect(player.state.isPlaying, isFalse);
    } finally {
      await audio.close();
    }
  });

  test('pitch semitones map to independent frequency ratios', () {
    expect(pitchFactorForSemitones(-12), 0.5);
    expect(pitchFactorForSemitones(0), 1);
    expect(pitchFactorForSemitones(12), 2);
    expect(pitchFactorForSemitones(7), closeTo(1.4983070769, 0.000000001));
    for (var semitones = -12; semitones <= 12; semitones++) {
      expect(semitonesForPitchFactor(pitchFactorForSemitones(semitones)),
          semitones);
    }
    for (final invalid in [null, 0, -1, double.nan, double.infinity, '2', 3]) {
      expect(semitonesForPitchFactor(invalid), isNull);
    }
  });

  test('pitch command clamps and new-video reset is independent of speed', () {
    reportSpeed(1.75);
    expect(player.pitchForVideo('first'), 0);
    player.setPitchSemitones(7);
    expect(player.state.pitchSemitones, 7);
    expect(player.state.speed, 1.75);
    expect(player.state.mediaCommand?.type, MediaCommandType.pitch);
    expect(player.state.mediaCommand?.value, 7);
    expect(player.pitchForVideo('first'), 7);
    expect(player.pitchForVideo('second'), 0);
    expect(player.state.speed, 1.75);
    player.setPitchSemitones(-100);
    expect(player.state.pitchSemitones, -12);
    player.setPitchSemitones(100);
    expect(player.state.pitchSemitones, 12);
  });

  test('invalid native pitch events do not alter valid pitch or speed', () {
    reportSpeed(1.75);
    player.setPitchSemitones(3);
    for (final invalid in [
      null,
      13,
      -13,
      double.nan,
      double.infinity,
      '2',
      2.5
    ]) {
      player.setEvent(MediaEvent(
          state: MediaState.ready,
          type: MediaEventType.pitchChanged,
          value: invalid));
      expect(player.state.pitchSemitones, 3);
      expect(player.state.speed, 1.75);
    }
  });
}
