import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river_player/river_player.dart';
import 'package:river_player/src/video_player/method_channel_video_player.dart';

class _PitchPlatform extends VideoPlayerPlatform {
  final streams = <int, StreamController<VideoEvent>>{};
  final pitchCalls = <double>[];
  bool rejectPitch = false;
  int nextId = 0;

  @override
  Future<void> init() async {}
  @override
  Future<int?> create({
    BetterPlayerBufferingConfiguration? bufferingConfiguration,
  }) async {
    final id = ++nextId;
    streams[id] = StreamController<VideoEvent>.broadcast();
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int? textureId) =>
      streams[textureId]!.stream;
  @override
  Future<void> setDataSource(int? textureId, DataSource source) async {
    streams[textureId]!.add(VideoEvent(
      key: source.key,
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 30),
    ));
  }

  @override
  Future<void> dispose(int? textureId) async =>
      streams.remove(textureId)?.close();
  @override
  Future<void> setLooping(int? textureId, bool looping) async {}
  @override
  Future<void> setVolume(int? textureId, double volume) async {}
  @override
  Future<void> setSpeed(int? textureId, double speed) async {}
  @override
  Future<void> setPitch(int? textureId, double pitch) async {
    pitchCalls.add(pitch);
    if (rejectPitch) {
      throw PlatformException(code: 'UnsupportedPitch');
    }
  }

  @override
  Future<void> play(int? textureId) async {}
  @override
  Future<void> pause(int? textureId) async {}
  @override
  Future<void> setTrackParameters(
      int? textureId, int? width, int? height, int? bitrate) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = _PitchPlatform();
  VideoPlayerPlatform.instance = platform;

  Future<BetterPlayerController> player() async {
    final result = BetterPlayerController(const BetterPlayerConfiguration(
      autoPlay: false,
      handleLifecycle: false,
      allowedScreenSleep: true,
    ));
    await result.setupDataSource(BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      'https://example.com/video.mp4',
      videoFormat: BetterPlayerVideoFormat.other,
    ));
    addTearDown(() async {
      result.dispose();
      await Future<void>.delayed(Duration.zero);
    });
    return result;
  }

  setUp(() {
    platform.pitchCalls.clear();
    platform.rejectPitch = false;
  });

  test('pitch and speed remain independent in the controller', () async {
    final controller = await player();
    final native = controller.videoPlayerController!;
    expect(native.value.pitch, 1);
    await controller.setSpeed(1.5);
    await controller.setPitch(2);
    expect(native.value.speed, 1.5);
    expect(native.value.pitch, 2);
    await controller.setSpeed(0.75);
    expect(native.value.pitch, 2);
    await controller.setPitch(0.5);
    expect(native.value.speed, 0.75);
    expect(native.value.pitch, 0.5);
    expect(native.value.isPlaying, isFalse);
  });

  test('source replacement preserves the requested pitch', () async {
    final controller = await player();
    await controller.setPitch(1.5);
    await controller.setupDataSource(BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      'https://example.com/next.mp4',
      videoFormat: BetterPlayerVideoFormat.other,
    ));
    expect(controller.videoPlayerController!.value.pitch, 1.5);
  });

  test('pitch events follow accepted native changes, with rollback on failure',
      () async {
    final controller = await player();
    final events = <BetterPlayerEvent>[];
    controller.addEventsListener(events.add);
    await controller.setPitch(1.25);
    final event = events.singleWhere((event) =>
        event.betterPlayerEventType == BetterPlayerEventType.setPitch);
    expect(event.parameters?['pitch'], 1.25);
    events.clear();
    platform.rejectPitch = true;
    await expectLater(
        controller.setPitch(2), throwsA(isA<PlatformException>()));
    expect(controller.videoPlayerController!.value.pitch, 1.25);
    expect(
        events.where((event) =>
            event.betterPlayerEventType == BetterPlayerEventType.setPitch),
        isEmpty);
  });

  test('invalid pitch is rejected before reaching the platform', () async {
    final controller = await player();
    for (final value in [0.0, -1.0, double.nan, double.infinity]) {
      await expectLater(controller.setPitch(value), throwsArgumentError);
      await expectLater(controller.videoPlayerController!.setPitch(value),
          throwsArgumentError);
    }
    expect(platform.pitchCalls, isEmpty);
    expect(controller.videoPlayerController!.value.pitch, 1);
  });

  test('method channel sends pitch independently with the correct texture',
      () async {
    const channel = MethodChannel('better_player_channel');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await MethodChannelVideoPlayer().setPitch(42, 0.5);
    expect(calls.single.method, 'setPitch');
    expect(calls.single.arguments, {'textureId': 42, 'pitch': 0.5});
  });
}
