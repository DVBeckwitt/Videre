import 'dart:async';

import 'package:flutter/foundation.dart';
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
  TargetPlatform? originalTargetPlatform;

  setUp(() {
    originalTargetPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
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
    debugDefaultTargetPlatformOverride = originalTargetPlatform;
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

  group('native playback progress', () {
    Map<String, Object?> observation() => {
          'positionMillis': 1250,
          'bufferedPositionMillis': 7500,
          'durationMillis': 30000,
          'sampledAtMillis': 123456,
          'sourceRevision': 7,
          'playWhenReady': true,
          'isPlaying': false,
          'processingState': ProcessingState.buffering.index,
          'suppressionReason': 1,
          'seekPending': true,
          'hasError': true,
        };

    Future<MethodChannel> activate() async {
      await player.setAudioSource(AudioSource.uri(
        Uri.parse('https://example.com/audio.webm'),
      ));
      final channel = MethodChannel(
          'com.ryanheise.just_audio.methods.${platform.player!.id}');
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      return channel;
    }

    void respond(MethodChannel channel, Future<Object?> Function() response) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) {
        expect(call.method, 'getPlaybackProgress');
        expect(call.arguments, isNull);
        return response();
      });
    }

    test('inactive observation never initializes a native decoder', () async {
      expect(await player.getNativePlaybackProgress(), isNull);
      expect(platform.player, isNull);
    });

    test('returns actual native values independently of Dart position',
        () async {
      final channel = await activate();
      respond(channel, () async => observation());
      expect(player.position, Duration.zero);
      final result = (await player.getNativePlaybackProgress())!;
      expect(result.position, const Duration(milliseconds: 1250));
      expect(result.bufferedPosition, const Duration(milliseconds: 7500));
      expect(result.duration, const Duration(seconds: 30));
      expect(result.sampledAtMillis, 123456);
      expect(result.sourceRevision, 7);
      expect(result.playWhenReady, isTrue);
      expect(result.isPlaying, isFalse);
      expect(result.processingState, ProcessingState.buffering);
      expect(result.suppressionReason, 1);
      expect(result.seekPending, isTrue);
      expect(result.hasError, isTrue);
      expect(player.position, Duration.zero);
    });

    test('unknown duration is preserved', () async {
      final channel = await activate();
      respond(channel, () async => observation()..['durationMillis'] = null);
      expect((await player.getNativePlaybackProgress())!.duration, isNull);
    });

    test('unsupported platform never invokes the native channel', () async {
      final channel = await activate();
      var calls = 0;
      respond(channel, () async {
        calls++;
        return observation();
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(await player.getNativePlaybackProgress(), isNull);
      expect(calls, 0);
    });

    test('missing native capability returns no observation', () async {
      final channel = await activate();
      respond(channel, () async => throw MissingPluginException());
      expect(await player.getNativePlaybackProgress(), isNull);
    });

    test('null native player returns no observation', () async {
      final channel = await activate();
      respond(channel, () async => null);
      expect(await player.getNativePlaybackProgress(), isNull);
    });

    for (final invalid in <String, Object?>{
      'positionMillis': -1,
      'bufferedPositionMillis': '7500',
      'durationMillis': -1,
      'sampledAtMillis': null,
      'sourceRevision': -1,
      'playWhenReady': 'true',
      'isPlaying': null,
      'processingState': ProcessingState.values.length,
      'suppressionReason': -1,
      'seekPending': 0,
      'hasError': null,
    }.entries) {
      test('rejects malformed ${invalid.key}', () async {
        final channel = await activate();
        respond(
            channel, () async => observation()..[invalid.key] = invalid.value);
        expect(await player.getNativePlaybackProgress(), isNull);
      });
    }

    for (final action in ['stop', 'dispose', 'replace source']) {
      test('rejects observation completed after $action', () async {
        final channel = await activate();
        final dispatched = Completer<void>();
        final response = Completer<Object?>();
        respond(channel, () {
          dispatched.complete();
          return response.future;
        });
        final pending = player.getNativePlaybackProgress();
        await dispatched.future;
        switch (action) {
          case 'stop':
            await player.stop();
          case 'dispose':
            await player.dispose();
          case 'replace source':
            await player.setAudioSource(AudioSource.uri(
              Uri.parse('https://example.com/replacement.webm'),
            ));
        }
        response.complete(observation());
        expect(await pending, isNull);
      });
    }
  });
}
