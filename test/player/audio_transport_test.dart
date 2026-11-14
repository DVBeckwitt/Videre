import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _AudioWithoutAutostart extends AudioPlayerCubit {
  _AudioWithoutAutostart(super.initialState, super.player, super.settings);

  @override
  void onInit() {}
}

class _TransportPlatform extends JustAudioPlatform {
  _TransportPlayer? player;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async =>
      player = _TransportPlayer(request.id);

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
          DisposeAllPlayersRequest request) async =>
      DisposeAllPlayersResponse();

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    await player?.events.close();
    return DisposePlayerResponse();
  }
}

class _TransportPlayer extends AudioPlayerPlatform {
  final events = StreamController<PlaybackEventMessage>.broadcast();
  final loads = <LoadRequest>[];

  _TransportPlayer(super.id);

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    loads.add(request);
    events.add(PlaybackEventMessage(
      processingState: ProcessingStateMessage.ready,
      updateTime: DateTime.now(),
      updatePosition: Duration.zero,
      bufferedPosition: Duration.zero,
      duration: const Duration(seconds: 30),
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
    return LoadResponse(duration: const Duration(seconds: 30));
  }

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
  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
          SetShuffleOrderRequest request) async =>
      SetShuffleOrderResponse();
  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
          SetAndroidAudioAttributesRequest request) async =>
      SetAndroidAudioAttributesResponse();
}

Iterable<Map<dynamic, dynamic>> _uriSources(Object? value) sync* {
  if (value is Map) {
    if (value['uri'] is String) yield value;
    for (final child in value.values) {
      yield* _uriSources(child);
    }
  } else if (value is Iterable) {
    for (final child in value) {
      yield* _uriSources(child);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android audio retains instance URI and headers at the native boundary',
      () async {
    final originalTarget = debugDefaultTargetPlatformOverride;
    final originalPlatform = JustAudioPlatform.instance;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final platform = _TransportPlatform();
    JustAudioPlatform.instance = platform;
    db = await SembastSqfDb.createInMemory();
    final app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    final settings = TestSettingsCubit(SettingsState.init(), app);
    final player = TestPlayerCubit(PlayerState.init(null), settings);
    final audio =
        _AudioWithoutAutostart(const AudioPlayerState(), player, settings);
    try {
      audio.initPlayer();
      const source = 'https://instance.example/videoplayback?itag=140';
      const headers = {
        'X-Instance-Key': 'test-only',
        'Authorization': 'Bearer test-only',
      };
      await audio.audioPlayer!
          .setAudioSource(AudioSource.uri(Uri.parse(source), headers: headers));

      final sent =
          _uriSources(platform.player!.loads.single.audioSourceMessage.toMap())
              .single;
      expect(sent['uri'], source);
      expect(sent['headers'], headers);
    } finally {
      await audio.close();
      await player.close();
      await settings.close();
      await app.close();
      await db.close();
      JustAudioPlatform.instance = originalPlatform;
      debugDefaultTargetPlatformOverride = originalTarget;
    }
  });
}
