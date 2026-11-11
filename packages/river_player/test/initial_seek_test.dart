import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river_player/river_player.dart';

class _DelayedSeekPlatform extends VideoPlayerPlatform {
  final streams = <int, StreamController<VideoEvent>>{};
  final commands = <String>[];
  final sources = <({int textureId, DataSource source})>[];
  Completer<void> seekStarted = Completer<void>();
  Completer<void> seekReleased = Completer<void>();
  bool playing = false;
  bool holdInitialization = false;
  Duration? reportedInitialPosition;
  int nextId = 0;
  Duration duration = const Duration(minutes: 3);

  void reset() {
    commands.clear();
    sources.clear();
    seekStarted = Completer<void>();
    seekReleased = Completer<void>();
    playing = false;
    holdInitialization = false;
    reportedInitialPosition = null;
    duration = const Duration(minutes: 3);
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
    sources.add((textureId: textureId!, source: source));
    if (!holdInitialization) initialize(sources.last);
  }

  void initialize(({int textureId, DataSource source}) load) {
    streams[load.textureId]!.add(VideoEvent(
      key: load.source.key,
      eventType: VideoEventType.initialized,
      duration: duration,
      position: reportedInitialPosition ?? load.source.initialPosition,
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

  group('explicit initial position', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      // A regression to the post-prepare seek should fail an assertion
      // rather than block the test waiting on the seek fake.
      platform.seekReleased.complete();
    });

    BetterPlayerController controllerWithResume() => BetterPlayerController(
          const BetterPlayerConfiguration(
            startAt: Duration(seconds: 40),
            autoPlay: false,
            handleLifecycle: false,
            allowedScreenSleep: true,
          ),
        );

    BetterPlayerDataSource video() => BetterPlayerDataSource(
          BetterPlayerDataSourceType.network,
          'https://example.com/video.mp4',
          videoFormat: BetterPlayerVideoFormat.other,
        );

    test('prepares at the requested position and keeps native position',
        () async {
      final controller = controllerWithResume();
      final source = video();
      const requested = Duration(seconds: 21);
      const reported = Duration(milliseconds: 20500);
      try {
        platform.reportedInitialPosition = reported;
        await controller.setupDataSource(source, initialPosition: requested);
        expect(platform.sources.single.source.initialPosition, requested);
        expect(controller.videoPlayerController!.value.position, reported);
        expect(platform.commands, isNot(contains(startsWith('seek:'))));

        platform.reportedInitialPosition = null;
        await controller.setupDataSource(source,
            initialPosition: Duration.zero);
        expect(platform.sources.last.source.initialPosition, Duration.zero);
        expect(controller.videoPlayerController!.value.position, Duration.zero);
        expect(platform.commands, isNot(contains(startsWith('seek:'))));
      } finally {
        controller.dispose();
        await Future<void>.delayed(Duration.zero);
      }
    });

    test('same URL ignores initialization from a replaced load', () async {
      final controller = controllerWithResume();
      final source = video();
      platform.holdInitialization = true;
      try {
        final first = controller.setupDataSource(source,
            initialPosition: const Duration(seconds: 20));
        await Future<void>.delayed(Duration.zero);
        expect(platform.sources, hasLength(1));
        final second = controller.setupDataSource(source,
            initialPosition: const Duration(seconds: 5));
        await Future<void>.delayed(Duration.zero);
        expect(platform.sources, hasLength(2));
        await first.timeout(const Duration(seconds: 1));

        platform.initialize(platform.sources.first);
        await Future<void>.delayed(Duration.zero);
        expect(controller.videoPlayerController!.value.initialized, isFalse);

        platform.initialize(platform.sources.last);
        await second;
        expect(controller.videoPlayerController!.value.position,
            const Duration(seconds: 5));
        expect(platform.commands, isNot(contains(startsWith('seek:'))));
      } finally {
        controller.dispose();
        await Future<void>.delayed(Duration.zero);
      }
    });

    test('uses the existing seek path on a platform without native support',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final controller = controllerWithResume();
      try {
        await controller.setupDataSource(video(),
            initialPosition: const Duration(seconds: 21));
        expect(platform.sources.single.source.initialPosition, isNull);
        expect(platform.commands, contains('seek:21'));
        expect(controller.videoPlayerController!.value.position,
            const Duration(seconds: 21));
      } finally {
        controller.dispose();
        await Future<void>.delayed(Duration.zero);
      }
    });
  });

  test('changing videos discards a pending subtitle selection', () async {
    final controller = BetterPlayerController(const BetterPlayerConfiguration(
      handleLifecycle: false,
      allowedScreenSleep: true,
    ));
    try {
      final pending =
          controller.setupSubtitleSource(BetterPlayerSubtitlesSource(
        type: BetterPlayerSubtitlesSourceType.memory,
        content: 'WEBVTT\n\n00:00:00.000 --> 00:00:05.000\nOld video\n\n',
      ));
      await controller.setupDataSource(BetterPlayerDataSource(
        BetterPlayerDataSourceType.network,
        'https://example.com/new-video.mp4',
        videoFormat: BetterPlayerVideoFormat.other,
      ));
      await pending;

      expect(controller.betterPlayerSubtitlesSource?.type,
          BetterPlayerSubtitlesSourceType.none);
      expect(controller.subtitlesLines, isEmpty);
    } finally {
      controller.dispose();
    }
  });

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

  test('a replaced source ignores completion of its old pending seek',
      () async {
    final controller = BetterPlayerController(const BetterPlayerConfiguration(
      autoPlay: false,
      handleLifecycle: false,
      allowedScreenSleep: true,
    ));
    final events = <BetterPlayerEventType>[];
    controller
        .addEventsListener((event) => events.add(event.betterPlayerEventType));
    await controller.setupDataSource(BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      'https://example.com/long.mp4',
      videoFormat: BetterPlayerVideoFormat.other,
    ));
    final seek = controller.seekTo(const Duration(seconds: 40));
    try {
      await platform.seekStarted.future;
      platform.duration = const Duration(seconds: 30);
      await controller.setupDataSource(BetterPlayerDataSource(
        BetterPlayerDataSourceType.network,
        'https://example.com/short.mp4',
        videoFormat: BetterPlayerVideoFormat.other,
      ));
      events.clear();
      platform.commands.clear();
      platform.seekReleased.complete();
      await seek;

      expect(events, isNot(contains(BetterPlayerEventType.finished)),
          reason: 'An old seek must not advance the new video queue entry.');
      expect(controller.videoPlayerController!.value.position, Duration.zero);
      expect(events, isNot(contains(BetterPlayerEventType.seekTo)));
      expect(platform.commands, ['seek-completed']);
    } finally {
      if (!platform.seekReleased.isCompleted) platform.seekReleased.complete();
      await seek;
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
    }
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
