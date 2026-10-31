import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:river_player/river_player.dart';

class _DelayedSeekPlatform extends VideoPlayerPlatform {
  final streams = <int, StreamController<VideoEvent>>{};
  final commands = <String>[];
  Completer<void> seekStarted = Completer<void>();
  Completer<void> seekReleased = Completer<void>();
  bool playing = false;
  int nextId = 0;

  void reset() {
    commands.clear();
    seekStarted = Completer<void>();
    seekReleased = Completer<void>();
    playing = false;
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
  Future<void> setTrackParameters(
      int? textureId, int? width, int? height, int? bitrate) async {}
  @override
  Future<void> play(int? textureId) async {
    commands.add('play');
    playing = true;
  }

  @override
  Future<void> pause(int? textureId) async {
    commands.add('pause');
    playing = false;
  }

  @override
  Future<void> seekTo(int? textureId, Duration? position) async {
    commands.add('seek:${position!.inSeconds}');
    seekStarted.complete();
    await seekReleased.future;
    commands.add('seek-completed');
  }

  @override
  Future<Duration> getPosition(int? textureId) async =>
      const Duration(seconds: 40);
  @override
  Future<DateTime?> getAbsolutePosition(int? textureId) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = _DelayedSeekPlatform();
  VideoPlayerPlatform.instance = platform;
  setUp(platform.reset);

  for (final autoPlay in [false, true]) {
    test('source setup awaits initial seek with autoPlay=$autoPlay', () async {
      final controller = BetterPlayerController(BetterPlayerConfiguration(
        autoPlay: autoPlay,
        startAt: const Duration(seconds: 40),
        handleLifecycle: false,
        allowedScreenSleep: true,
      ));
      var setupCompleted = false;
      final setup = controller
          .setupDataSource(BetterPlayerDataSource(
            BetterPlayerDataSourceType.network,
            'https://example.com/video.mp4',
            videoFormat: BetterPlayerVideoFormat.other,
          ))
          .then((_) => setupCompleted = true);
      try {
        await platform.seekStarted.future;
        await Future<void>.delayed(Duration.zero);
        expect(setupCompleted, isFalse,
            reason: 'The caller must not race a pending resume seek.');
        platform.seekReleased.complete();
        await setup;
        expect(controller.videoPlayerController!.value.isPlaying, autoPlay);
        expect(platform.playing, autoPlay);

        // Videre starts the paused configuration explicitly after setup.
        // A late completion of the initial seek must not pause that playback.
        if (!autoPlay) await controller.play();
        await Future<void>.delayed(Duration.zero);
        expect(platform.playing, isTrue);
        expect(controller.videoPlayerController!.value.isPlaying, isTrue);
        expect(platform.commands.last, 'play');
        expect(controller.videoPlayerController!.value.position,
            const Duration(seconds: 40));
      } finally {
        if (!platform.seekReleased.isCompleted)
          platform.seekReleased.complete();
        await setup;
        controller.dispose();
        await Future<void>.delayed(Duration.zero);
      }
    });
  }

  for (final initiallyPlaying in [false, true]) {
    test(
        'pending seek preserves a newer playback command from $initiallyPlaying',
        () async {
      final controller = BetterPlayerController(BetterPlayerConfiguration(
        autoPlay: initiallyPlaying,
        handleLifecycle: false,
        allowedScreenSleep: true,
      ));
      await controller.setupDataSource(BetterPlayerDataSource(
        BetterPlayerDataSourceType.network,
        'https://example.com/video.mp4',
        videoFormat: BetterPlayerVideoFormat.other,
      ));
      final seek = controller.seekTo(const Duration(seconds: 40));
      try {
        await platform.seekStarted.future;
        if (initiallyPlaying) {
          await controller.pause();
        } else {
          await controller.play();
        }
        platform.seekReleased.complete();
        await seek;
        expect(platform.playing, !initiallyPlaying);
        expect(controller.videoPlayerController!.value.isPlaying,
            !initiallyPlaying);
      } finally {
        if (!platform.seekReleased.isCompleted)
          platform.seekReleased.complete();
        await seek;
        controller.dispose();
        await Future<void>.delayed(Duration.zero);
      }
    });
  }

  test('pending seek can finish after the player is disposed', () async {
    final controller = BetterPlayerController(const BetterPlayerConfiguration(
      autoPlay: false,
      handleLifecycle: false,
      allowedScreenSleep: true,
    ));
    await controller.setupDataSource(BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      'https://example.com/video.mp4',
      videoFormat: BetterPlayerVideoFormat.other,
    ));
    final seek = controller.seekTo(const Duration(seconds: 40));
    await platform.seekStarted.future;
    controller.dispose();
    await Future<void>.delayed(Duration.zero);
    platform.seekReleased.complete();
    await seek;
    expect(platform.commands.last, 'seek-completed');
  });

  for (final pauseDuringSeek in [false, true]) {
    test('replay from the end respects pause during seek: $pauseDuringSeek',
        () async {
      final controller = BetterPlayerController(const BetterPlayerConfiguration(
        autoPlay: false,
        handleLifecycle: false,
        allowedScreenSleep: true,
      ));
      await controller.setupDataSource(BetterPlayerDataSource(
        BetterPlayerDataSourceType.network,
        'https://example.com/video.mp4',
        videoFormat: BetterPlayerVideoFormat.other,
      ));
      final native = controller.videoPlayerController!;
      native.value = native.value.copyWith(position: native.value.duration);
      final seek = controller.seekTo(Duration.zero);
      try {
        await platform.seekStarted.future;
        if (pauseDuringSeek) await controller.pause();
        platform.seekReleased.complete();
        await seek;
        expect(platform.playing, !pauseDuringSeek);
        expect(native.value.isPlaying, !pauseDuringSeek);
      } finally {
        if (!platform.seekReleased.isCompleted)
          platform.seekReleased.complete();
        await seek;
        controller.dispose();
        await Future<void>.delayed(Duration.zero);
      }
    });
  }
}
