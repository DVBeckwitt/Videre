import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

class _AudioPlatform extends JustAudioPlatform {
  PlatformException? loadError;
  _Player? player;
  int initializations = 0;
  List<AudioEffectMessage> initialEffects = [];

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    initializations++;
    initialEffects = request.androidAudioEffects;
    return player = _Player(request.id, loadError);
  }

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
  Map<dynamic, dynamic>? loadPayload;
  final events = StreamController<PlaybackEventMessage>.broadcast();

  _Player(super.id, this.loadError);

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => events.stream;

  PlaybackEventMessage event(
          {int? errorCode,
          String? errorMessage,
          int? sessionId,
          Duration position = Duration.zero}) =>
      PlaybackEventMessage(
        processingState: errorCode == null
            ? ProcessingStateMessage.ready
            : ProcessingStateMessage.idle,
        updateTime: DateTime.now(),
        updatePosition: position,
        bufferedPosition: Duration.zero,
        duration: const Duration(seconds: 30),
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: sessionId,
        errorCode: errorCode,
        errorMessage: errorMessage,
      );

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    loadPayload = request.audioSourceMessage.toMap();
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

  for (final extension in ['webm', 'mpd', 'm3u8']) {
    test(
        'cache source metadata survives $extension serialization without headers',
        () async {
      const identity = <String, Object?>{
        'version': 1,
        'profileId': 'person',
        'sessionId': 'occurrence'
      };
      await player.setAudioSource(AudioSource.uri(
          Uri.parse('https://instance.example/media.$extension'),
          playbackCache: identity));
      final children = platform.player!.loadPayload!['children'] as List;
      expect(children.single['playbackCache'], identity);
      expect(children.single['headers'], isNull);
      expect(children.single.containsKey('podcast'), isFalse);
    });
  }

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

  group('lazy Android equalizer', () {
    Map<String, Object?> parameters({double gain = 0}) => {
          'parameters': {
            'minDecibels': -12.0,
            'maxDecibels': 12.0,
            'bands': [
              {
                'index': 0,
                'lowerFrequency': 30.0,
                'upperFrequency': 150.0,
                'centerFrequency': 60.0,
                'gain': gain,
              },
            ],
          },
        };

    Future<MethodChannel> activate() async {
      await player.setAudioSource(AudioSource.uri(
        Uri.parse('https://example.com/audio.webm'),
      ));
      final sessionReady =
          player.androidAudioSessionIdStream.firstWhere((id) => id == 42);
      platform.player!.events.add(platform.player!.event(sessionId: 42));
      await sessionReady;
      final channel = MethodChannel(
          'com.ryanheise.just_audio.methods.${platform.player!.id}');
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      return channel;
    }

    test('ordinary loading does not reserve equalizer hardware', () async {
      await activate();
      expect(platform.initialEffects, isEmpty);
      expect(player.processingState, ProcessingState.ready);
      expect(platform.initializations, 1);
    });

    test('inactive equalizer calls never initialize a native decoder',
        () async {
      await expectLater(
          player.getAndroidEqualizerParameters(), throwsStateError);
      await expectLater(
          player.setAndroidEqualizerEnabled(false), throwsStateError);
      await expectLater(
          player.setAndroidEqualizerBandGain(0, 3), throwsStateError);
      expect(platform.initializations, 0);
    });

    test('commands use the current session and return confirmed band values',
        () async {
      final channel = await activate();
      var gain = 0.0;
      var enabled = false;
      final commands = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.arguments['expectedSessionId'], 42);
        expect(call.arguments['lazyAndroidEqualizer'], isTrue);
        commands.add(call.method);
        switch (call.method) {
          case 'androidEqualizerGetParameters':
            return parameters(gain: gain);
          case 'audioEffectSetEnabled':
            expect(call.arguments['type'], 'AndroidEqualizer');
            enabled = call.arguments['enabled'] as bool;
          case 'androidEqualizerBandSetGain':
            expect(call.arguments['bandIndex'], 0);
            gain = (call.arguments['gain'] as num).toDouble();
        }
        return <String, Object?>{};
      });
      final initial =
          await player.getAndroidEqualizerParameters(expectedSessionId: 42);
      expect(initial.minDecibels, -12);
      expect(initial.bands.single.centerFrequency, 60);
      await player.setAndroidEqualizerEnabled(true, expectedSessionId: 42);
      await player.setAndroidEqualizerBandGain(0, 4, expectedSessionId: 42);
      expect(enabled, isTrue);
      expect(
          (await player.getAndroidEqualizerParameters(expectedSessionId: 42))
              .bands
              .single
              .gain,
          4);
      await player.setAndroidEqualizerBandGain(0, 0, expectedSessionId: 42);
      await player.setAndroidEqualizerEnabled(false, expectedSessionId: 42);
      expect(gain, 0);
      expect(enabled, isFalse);
      expect(commands.where((call) => call == 'androidEqualizerBandSetGain'),
          hasLength(2));
      expect(platform.initializations, 1);
      expect(player.processingState, ProcessingState.ready);
    });

    for (final command in ['read', 'enable', 'gain']) {
      test('$command survives ordinary playback updates in the same session',
          () async {
        final channel = await activate();
        final dispatched = Completer<void>();
        final response = Completer<Object?>();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) {
          expect(call.arguments['expectedSessionId'], 42);
          expect(
              call.method,
              {
                'read': 'androidEqualizerGetParameters',
                'enable': 'audioEffectSetEnabled',
                'gain': 'androidEqualizerBandSetGain',
              }[command]);
          dispatched.complete();
          return response.future;
        });
        final Future<void> pending = switch (command) {
          'read' => player
              .getAndroidEqualizerParameters(expectedSessionId: 42)
              .then((value) => expect(value.bands.single.gain, 4)),
          'enable' =>
            player.setAndroidEqualizerEnabled(true, expectedSessionId: 42),
          _ => player.setAndroidEqualizerBandGain(0, 4, expectedSessionId: 42),
        };
        final checked = expectLater(pending, completes);
        await dispatched.future;
        const position = Duration(seconds: 4);
        final updated = player.playbackEventStream
            .firstWhere((event) => event.updatePosition == position);
        platform.player!.events
            .add(platform.player!.event(sessionId: 42, position: position));
        await updated;
        response.complete(command == 'read' ? parameters(gain: 4) : {});
        await checked;
        expect(player.androidAudioSessionId, 42);
        expect(player.processingState, ProcessingState.ready);
        expect(platform.initializations, 1);
      });
    }

    test('unsupported effects do not emit playback errors or poison loading',
        () async {
      final channel = await activate();
      final playbackErrors = <PlayerException>[];
      final subscription = player.errorStream.listen(playbackErrors.add);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              channel,
              (_) async => throw PlatformException(
                  code: 'audio_effect_unavailable',
                  message: 'No equalizer on this device'));
      await expectLater(player.getAndroidEqualizerParameters(),
          throwsA(isA<PlatformException>()));
      await expectLater(player.setAndroidEqualizerEnabled(true),
          throwsA(isA<PlatformException>()));
      expect(player.processingState, ProcessingState.ready);
      expect(playbackErrors, isEmpty);
      await player.setAudioSource(AudioSource.uri(
        Uri.parse('https://example.com/next.webm'),
      ));
      expect(player.processingState, ProcessingState.ready);
      expect(playbackErrors, isEmpty);
      await subscription.cancel();
    });

    test('missing plugin and failed setters report their actual failure',
        () async {
      final channel = await activate();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              channel, (_) async => throw MissingPluginException());
      await expectLater(player.getAndroidEqualizerParameters(),
          throwsA(isA<MissingPluginException>()));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              channel,
              (_) async => throw PlatformException(
                  code: 'audio_effect_unavailable',
                  message: 'Device rejected gain'));
      await expectLater(player.setAndroidEqualizerBandGain(0, 3),
          throwsA(isA<PlatformException>()));
      expect(player.processingState, ProcessingState.ready);
    });

    test('invalid and stale commands never reach the native session', () async {
      final channel = await activate();
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
        calls++;
        return parameters();
      });
      await expectLater(
          player.getAndroidEqualizerParameters(expectedSessionId: 41),
          throwsStateError);
      await expectLater(
          player.setAndroidEqualizerEnabled(true, expectedSessionId: 41),
          throwsStateError);
      await expectLater(
          player.setAndroidEqualizerBandGain(0, 3, expectedSessionId: 41),
          throwsStateError);
      for (final gain in [
        double.nan,
        double.infinity,
        double.negativeInfinity
      ]) {
        await expectLater(
            player.setAndroidEqualizerBandGain(0, gain), throwsArgumentError);
      }
      await expectLater(
          player.setAndroidEqualizerBandGain(-1, 0), throwsArgumentError);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await expectLater(
          player.getAndroidEqualizerParameters(), throwsUnsupportedError);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await player.dispose();
      await expectLater(
          player.getAndroidEqualizerParameters(), throwsStateError);
      expect(calls, 0);
      expect(platform.initializations, 1);
    });

    for (final action in [
      'session change',
      'stop',
      'dispose',
      'replace source'
    ]) {
      test('rejects an equalizer response completed after $action', () async {
        final channel = await activate();
        final dispatched = Completer<void>();
        final response = Completer<Object?>();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (_) {
          dispatched.complete();
          return response.future;
        });
        final pending =
            player.getAndroidEqualizerParameters(expectedSessionId: 42);
        await dispatched.future;
        switch (action) {
          case 'session change':
            final changed =
                player.androidAudioSessionIdStream.firstWhere((id) => id == 43);
            platform.player!.events.add(platform.player!.event(sessionId: 43));
            await changed;
          case 'stop':
            await player.stop();
          case 'dispose':
            await player.dispose();
          case 'replace source':
            await player.setAudioSource(AudioSource.uri(
              Uri.parse('https://example.com/replacement.webm'),
            ));
        }
        response.complete(parameters());
        await expectLater(pending, throwsStateError);
      });
    }

    test('malformed device capabilities are rejected', () async {
      final channel = await activate();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              channel,
              (_) async => {
                    'parameters': {
                      'minDecibels': 0.0,
                      'maxDecibels': 0.0,
                      'bands': <Object?>[],
                    }
                  });
      await expectLater(
          player.getAndroidEqualizerParameters(), throwsStateError);
      expect(player.processingState, ProcessingState.ready);
    });
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
