import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

class _AudioPlatform extends JustAudioPlatform {
  PlatformException? loadError;
  _Player? player;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async =>
      player = _Player(request.id, loadError);

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

class _Player extends AudioPlayerPlatform {
  final PlatformException? loadError;
  final events = StreamController<PlaybackEventMessage>.broadcast();

  _Player(super.id, this.loadError);

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => events.stream;

  PlaybackEventMessage event({int? errorCode, String? errorMessage}) =>
      PlaybackEventMessage(
        processingState: errorCode == null
            ? ProcessingStateMessage.ready
            : ProcessingStateMessage.idle,
        updateTime: DateTime.now(),
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        duration: const Duration(seconds: 30),
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
        errorCode: errorCode,
        errorMessage: errorMessage,
      );

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    if (loadError != null) throw loadError!;
    events.add(event());
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _AudioPlatform platform;
  late JustAudioPlatform originalPlatform;
  late AudioPlayer player;

  setUp(() {
    originalPlatform = JustAudioPlatform.instance;
    platform = _AudioPlatform();
    JustAudioPlatform.instance = platform;
    player = AudioPlayer(
      handleInterruptions: false,
      androidApplyAudioAttributes: false,
      handleAudioSessionActivation: false,
    );
  });

  tearDown(() async {
    await player.dispose();
    JustAudioPlatform.instance = originalPlatform;
  });

  test('existing exception constructor defaults to no backend retry', () {
    expect(PlayerException(0, 'Source error', 0).backendRetryable, isFalse);
  });

  for (final detail in [true, false, 'true', null]) {
    test('load exception preserves retry detail $detail', () async {
      platform.loadError = PlatformException(
        code: '0',
        message: 'Source error',
        details: {'index': 0, 'backendRetryable': detail},
      );
      await expectLater(
        player.setAudioSource(AudioSource.uri(
          Uri.parse('https://example.com/audio.webm'),
        )),
        throwsA(isA<PlayerException>()
            .having((error) => error.code, 'code', 0)
            .having((error) => error.index, 'index', 0)
            .having((error) => error.backendRetryable, 'backendRetryable',
                detail == true)),
      );
    });
  }

  test(
      'runtime errors emit once with native detail and clear it after recovery',
      () async {
    await player.setAudioSource(AudioSource.uri(
      Uri.parse('https://example.com/audio.webm'),
    ));
    final native = platform.player!;
    final errors = <PlayerException>[];
    final subscription = player.errorStream.listen(errors.add);
    final retryable = player.errorStream.first;
    native.events.addError(PlatformException(
      code: '0',
      message: 'Source error',
      details: {'index': 0, 'backendRetryable': true},
    ));
    native.events.add(native.event(errorCode: 0, errorMessage: 'Source error'));
    expect((await retryable).backendRetryable, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(errors, hasLength(1));

    await player.setAudioSource(AudioSource.uri(
      Uri.parse('https://example.com/recovered.webm'),
    ));
    final recovered = platform.player!;
    final unknown = player.errorStream.first;
    recovered.events
        .add(recovered.event(errorCode: 0, errorMessage: 'Source error'));
    expect((await unknown).backendRetryable, isFalse);
    expect(errors, hasLength(2));
    await subscription.cancel();
  });
}
