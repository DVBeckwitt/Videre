import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river_player/river_player.dart';

class _VideoPlatform extends VideoPlayerPlatform {
  final streams = <int, StreamController<VideoEvent>>{};
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
  Future<void> setDataSource(int? textureId, DataSource dataSource) async {
    streams[textureId]!.add(VideoEvent(
      key: dataSource.key,
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
  Future<void> play(int? textureId) async {}
  @override
  Future<void> pause(int? textureId) async {}
  @override
  Future<void> setTrackParameters(
      int? textureId, int? width, int? height, int? bitrate) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = _VideoPlatform();
  VideoPlayerPlatform.instance = platform;

  test('retryability defaults false and copyWith preserves explicit changes',
      () {
    final initial = VideoPlayerValue(duration: null);
    expect(initial.backendRetryable, isFalse);
    final retryable = initial.copyWith(
      errorDescription: 'Source error',
      backendRetryable: true,
    );
    expect(
        retryable.copyWith(position: Duration.zero).backendRetryable, isTrue);
    expect(
        retryable.copyWith(backendRetryable: false).backendRetryable, isFalse);
  });

  test('native error detail reaches BetterPlayer exception events', () async {
    final controller = BetterPlayerController(const BetterPlayerConfiguration(
      autoPlay: false,
      handleLifecycle: false,
      allowedScreenSleep: true,
    ));
    final events = <BetterPlayerEvent>[];
    controller.addEventsListener(events.add);
    await controller.setupDataSource(BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      'https://example.com/video.mp4',
      videoFormat: BetterPlayerVideoFormat.other,
    ));
    final native = controller.videoPlayerController!;

    for (final detail in [true, false, 'true', null]) {
      final changed = Completer<void>();
      void listener() {
        if (native.value.hasError && !changed.isCompleted) changed.complete();
      }

      native.addListener(listener);
      platform.streams[native.textureId]!.addError(PlatformException(
        code: 'VideoError',
        message: 'Source error',
        details: {'backendRetryable': detail},
      ));
      await changed.future;
      native.removeListener(listener);
      expect(native.value.backendRetryable, detail == true);
      final error = events.lastWhere((event) =>
          event.betterPlayerEventType == BetterPlayerEventType.exception);
      expect(error.parameters?['exception'], 'Source error');
      expect(error.parameters?['backendRetryable'], detail == true);
    }

    await controller.setupDataSource(BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      'https://example.com/next.mp4',
      videoFormat: BetterPlayerVideoFormat.other,
    ));
    expect(native.value.backendRetryable, isFalse);
    expect(native.value.hasError, isFalse);
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
  });
}
