import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:river_player/river_player.dart';
import 'package:river_player/src/video_player/video_player.dart';

class _DelayedPlayPlatform extends VideoPlayerPlatform {
  final streams = <int, StreamController<VideoEvent>>{};
  final pendingPlays = <Completer<void>>[];
  int nextId = 0;

  void reset() {
    pendingPlays.clear();
  }

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
      duration: const Duration(minutes: 3),
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
  Future<void> play(int? textureId) {
    final pending = Completer<void>();
    pendingPlays.add(pending);
    return pending.future;
  }

  @override
  Future<void> pause(int? textureId) async {}
  @override
  Future<Duration> getPosition(int? textureId) async =>
      const Duration(seconds: 1);

  @override
  Future<DateTime?> getAbsolutePosition(int? textureId) async => null;
}

Future<void> trackTimers(Future<void> Function(List<Timer>) body) async {
  final timers = <Timer>[];
  try {
    await runZoned(
      () => body(timers),
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createPeriodicTimer(zone, duration, callback);
          timers.add(timer);
          return timer;
        },
      ),
    );
  } finally {
    for (final timer in timers) {
      timer.cancel();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = _DelayedPlayPlatform();
  VideoPlayerPlatform.instance = platform;
  setUp(platform.reset);

  Future<VideoPlayerController> player() async {
    final controller = VideoPlayerController();
    await controller.setNetworkDataSource('https://example.com/video.mp4');
    return controller;
  }

  test(
      'a pending play cannot restart position polling after pause',
      () => trackTimers((timers) async {
            final controller = await player();
            try {
              final play = controller.play();
              await controller.pause();
              platform.pendingPlays.single.complete();
              await play;

              expect(controller.value.isPlaying, isFalse);
              expect(timers.where((timer) => timer.isActive), isEmpty);
            } finally {
              await controller.dispose();
            }
          }));

  test(
      'a pending play cannot leave a timer after disposal',
      () => trackTimers((timers) async {
            final controller = await player();
            final play = controller.play();
            await controller.dispose();
            platform.pendingPlays.single.complete();
            await play;

            expect(timers.where((timer) => timer.isActive), isEmpty);
          }));

  test(
      'overlapping play completions keep only one position poller',
      () => trackTimers((timers) async {
            final controller = await player();
            try {
              final first = controller.play();
              final second = controller.play();
              platform.pendingPlays[0].complete();
              await first;
              platform.pendingPlays[1].complete();
              await second;

              expect(controller.value.isPlaying, isTrue);
              expect(timers.where((timer) => timer.isActive), hasLength(1));

              await controller.pause();
              expect(timers.where((timer) => timer.isActive), isEmpty);
            } finally {
              await controller.dispose();
            }
          }));
}
