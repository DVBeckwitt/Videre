import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:river_player/river_player.dart';
import 'package:river_player/src/video_player/video_player.dart';

class _DelayedPlayPlatform extends VideoPlayerPlatform {
  final streams = <int, StreamController<VideoEvent>>{};
  final pendingPlays = <Completer<void>>[];
  int nextId = 0;
  Completer<Duration>? heldPosition;
  Completer<DateTime?>? heldAbsolutePosition;
  Completer<void> positionStarted = Completer<void>();
  Completer<void> absolutePositionStarted = Completer<void>();
  Duration position = const Duration(seconds: 1);

  void reset() {
    pendingPlays.clear();
    heldPosition = null;
    heldAbsolutePosition = null;
    positionStarted = Completer<void>();
    absolutePositionStarted = Completer<void>();
    position = const Duration(seconds: 1);
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
  Future<void> seekTo(int? textureId, Duration? position) async {}
  @override
  Future<Duration> getPosition(int? textureId) async {
    if (!positionStarted.isCompleted) positionStarted.complete();
    final held = heldPosition;
    if (held != null) return held.future;
    return position;
  }

  @override
  Future<DateTime?> getAbsolutePosition(int? textureId) async {
    if (!absolutePositionStarted.isCompleted)
      absolutePositionStarted.complete();
    return heldAbsolutePosition?.future;
  }
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

  for (final heldStage in ['position', 'absolute position']) {
    test(
        'a pending $heldStage poll cannot update a replacement source',
        () => trackTimers((timers) async {
              final controller = await player();
              final heldPosition = heldStage == 'position'
                  ? platform.heldPosition = Completer<Duration>()
                  : null;
              final heldAbsolute = heldStage == 'absolute position'
                  ? platform.heldAbsolutePosition = Completer<DateTime?>()
                  : null;
              platform.position = const Duration(seconds: 40);
              try {
                final play = controller.play();
                platform.pendingPlays.last.complete();
                await play;
                await (heldPosition != null
                    ? platform.positionStarted.future
                    : platform.absolutePositionStarted.future);
                await controller.setNetworkDataSource(
                    'https://example.com/replacement.mp4');
                heldPosition?.complete(const Duration(seconds: 40));
                heldAbsolute?.complete(DateTime.utc(2026, 1, 1));
                await Future<void>.delayed(Duration.zero);
                await Future<void>.delayed(Duration.zero);

                expect(controller.value.position, Duration.zero);
                expect(controller.value.absolutePosition, isNull);
                expect(controller.value.isPlaying, isFalse);
                expect(timers.where((timer) => timer.isActive), isEmpty);
              } finally {
                if (heldPosition != null && !heldPosition.isCompleted) {
                  heldPosition.complete(const Duration(seconds: 40));
                }
                if (heldAbsolute != null && !heldAbsolute.isCompleted) {
                  heldAbsolute.complete(null);
                }
                await controller.dispose();
              }
            }));
  }

  test(
      'a pending position poll cannot release a newer seek target',
      () => trackTimers((timers) async {
            final controller = await player();
            final held = platform.heldPosition = Completer<Duration>();
            try {
              final play = controller.play();
              platform.pendingPlays.last.complete();
              await play;
              await platform.positionStarted.future;
              await controller.pause();
              await controller.seekTo(const Duration(seconds: 18));
              held.complete(const Duration(seconds: 40));
              await Future<void>.delayed(Duration.zero);
              await Future<void>.delayed(Duration.zero);

              platform.heldPosition = null;
              platform.position = const Duration(seconds: 12);
              platform.positionStarted = Completer<void>();
              final resume = controller.play();
              platform.pendingPlays.last.complete();
              await resume;
              await platform.positionStarted.future;
              await Future<void>.delayed(Duration.zero);
              await controller.pause();
              expect(controller.value.position, const Duration(seconds: 18),
                  reason: 'A pre-seek poll must not release the seek target; '
                      'the native decoder has not yet reached it.');
            } finally {
              if (!held.isCompleted) held.complete(const Duration(seconds: 40));
              await controller.dispose();
            }
          }));
}
