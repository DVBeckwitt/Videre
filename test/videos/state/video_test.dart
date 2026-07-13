import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/states/video_player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/dislike.dart';
import 'package:clipious/videos/models/caption.dart';
import 'package:clipious/videos/models/format_stream.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/states/video.dart';
import 'package:river_player/river_player.dart';

import '../../test_app_cubit.dart';
import '../../test_player_cubit.dart';
import '../../test_settings_cubit.dart';

class FakeService extends Service {
  @override
  Future<Video> getVideo(String videoId, {Server? serverOverride}) async =>
      Video(videoId: videoId, adaptiveFormats: [], formatStreams: []);

  @override
  Future<Dislike> getDislikes(String videoId) async {
    throw Error();
  }

  @override
  Future<bool> isLoggedIn() async => false;
}

class RecordingPlayerCubit extends TestPlayerCubit {
  RecordingPlayerCubit(super.initialState, super.settings);

  final events = <MediaEvent>[];
  Iterable<MediaEvent> get errorEvents =>
      events.where((event) => event.state == MediaState.error);

  Future<void> waitForError() => errorEvents.isNotEmpty
      ? Future<void>.value()
      : stream
          .firstWhere((state) => state.mediaEvent.state == MediaState.error)
          .then((_) {});

  @override
  void setEvent(MediaEvent event) {
    events.add(event);
    emit(state.copyWith(mediaEvent: event));
  }
}

class TestVideoPlayerCubit extends VideoPlayerCubit {
  TestVideoPlayerCubit(super.initialState, super.player, super.settings);

  RecordingPlayerController? replacementController;
  final seekPositions = <Duration>[];
  final seekWaiters = <({int count, Completer<void> completer})>[];

  Future<void> waitForSeekCount(int count) {
    if (seekPositions.length >= count) return Future<void>.value();
    final waiter = Completer<void>();
    seekWaiters.add((count: count, completer: waiter));
    return waiter.future;
  }

  @override
  void onInit() {}

  @override
  void disposeControllers() {
    super.disposeControllers();
    videoController = replacementController;
    replacementController = null;
  }

  @override
  void seek(Duration position) {
    seekPositions.add(position);
    for (final waiter in List.of(seekWaiters)) {
      if (seekPositions.length >= waiter.count) {
        waiter.completer.complete();
        seekWaiters.remove(waiter);
      }
    }
  }
}

class RecordingPlayerController extends BetterPlayerController {
  RecordingPlayerController() : super(const BetterPlayerConfiguration());

  final sources = <BetterPlayerDataSource>[];
  Iterable<String> get sourceUrls => sources.map((source) => source.url);
  @override
  BetterPlayerDataSource? get betterPlayerDataSource =>
      sources.isEmpty ? null : sources.last;
  final listeners = <Function(BetterPlayerEvent)>[];
  final failingUrls = <String>{};
  final heldUrls = <String, Completer<void>>{};
  final resolutionUrls = <String>[];
  final sourceWaiters = <String, List<Completer<void>>>{};
  final idleWaiters = <Completer<void>>[];
  var activeSetups = 0;
  var maxActiveSetups = 0;
  var pauseCalls = 0;
  var playing = false;
  var disposed = false;

  Completer<void> hold(String url) =>
      heldUrls.putIfAbsent(url, Completer<void>.new);

  Future<void> waitForSource(String url) {
    if (sources.any((source) => source.url == url)) return Future<void>.value();
    final waiter = Completer<void>();
    sourceWaiters.putIfAbsent(url, () => []).add(waiter);
    return waiter.future;
  }

  Future<void> waitForIdle() {
    if (activeSetups == 0) return Future<void>.value();
    final waiter = Completer<void>();
    idleWaiters.add(waiter);
    return waiter.future;
  }

  void dispatch(BetterPlayerEvent event) {
    for (final listener in List.of(listeners)) {
      listener(event);
    }
  }

  @override
  void addEventsListener(Function(BetterPlayerEvent) listener) {
    listeners.add(listener);
  }

  @override
  void removeEventsListener(Function(BetterPlayerEvent) listener) {
    listeners.remove(listener);
  }

  @override
  Future<void> setupDataSource(BetterPlayerDataSource source) async {
    if (disposed) throw StateError('Cannot set up a disposed controller');
    sources.add(source);
    for (final waiter in sourceWaiters.remove(source.url) ?? const []) {
      waiter.complete();
    }
    activeSetups++;
    if (activeSetups > maxActiveSetups) maxActiveSetups = activeSetups;
    try {
      final held = heldUrls[source.url];
      if (held != null) await held.future;
      if (!disposed) playing = true;
      if (failingUrls.contains(source.url)) {
        throw StateError('Rejected ${source.url}');
      }
    } finally {
      activeSetups--;
      if (activeSetups == 0) {
        for (final waiter in idleWaiters) {
          waiter.complete();
        }
        idleWaiters.clear();
      }
    }
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    playing = false;
  }

  @override
  bool isPlaying() => playing;

  @override
  void setResolution(String url) {
    resolutionUrls.add(url);
  }

  @override
  void dispose({bool forceDispose = false}) {
    disposed = true;
    playing = false;
  }
}

FormatStream _stream(
  String url,
  String resolution, {
  String? itag,
  String quality = 'medium',
  String? qualityLabel,
  String size = '640x360',
}) =>
    FormatStream(url, itag ?? resolution, 'video/mp4', quality, 'mp4', 'h264',
        qualityLabel ?? resolution, resolution, size);

Video _videoWithFallback(
  String name, {
  String resolution = '360p',
  String? qualityLabel,
}) =>
    Video(
      videoId: '$name-video',
      dashUrl: 'https://r1.googlevideo.com/$name.mpd',
      formatStreams: [
        _stream('https://r1.googlevideo.com/$name.mp4', resolution,
            itag: '18', qualityLabel: qualityLabel),
      ],
    );

Future<void> _waitForDeferredFallback() {
  final done = Completer<void>();
  Timer.run(done.complete);
  return done.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler(
    'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
    (message) async =>
        const StandardMessageCodec().encodeMessage(<Object?>[null]),
  );

  group('VideoCubit', () {
    setUp(() async {
      db = await SembastSqfDb.createInMemory();
      const server = Server(url: 'https://inv.example');
      await db.upsertServer(server);
      await db.useServer(server);
    });
    tearDown(() async {
      service = Service();
      await db.close();
    });

    test('If youtube dislike is down, it should not break the video loading',
        () async {
      // using service that will fail on dislikes
      service = FakeService();

      final loggedIn = await service.isLoggedIn();
      final settingsCubit = TestSettingsCubit(
          SettingsState.init(), TestAppCubit(AppState(0, null, HomeLayout())));

      // using youtube dislikes
      await settingsCubit.setUseReturnYoutubeDislike(true);

      final player =
          TestPlayerCubit(PlayerState(playQueue: ListQueue()), settingsCubit);
      final downloadManager =
          DownloadManagerCubit(const DownloadManagerState(), player);
      final video = VideoCubit(
          VideoState(videoId: 'dQw4w9WgXcQ', isLoggedIn: loggedIn),
          downloadManager,
          player,
          settingsCubit);
      await video.onReady();

      expect(video.state.error, '');

      await video.close();
      await downloadManager.close();
      await player.close();
      await settingsCubit.close();
    });
  });

  group('VideoPlayerCubit fallback', () {
    late TestSettingsCubit settings;
    late RecordingPlayerCubit player;
    late TestVideoPlayerCubit cubit;
    late RecordingPlayerController controller;
    setUp(() async {
      db = await SembastSqfDb.createInMemory();
      const server = Server(url: 'https://inv.example');
      await db.upsertServer(server);
      await db.useServer(server);
      settings = TestSettingsCubit(
          SettingsState.init(), TestAppCubit(AppState(0, null, HomeLayout())));
      player =
          RecordingPlayerCubit(PlayerState(playQueue: ListQueue()), settings);
      cubit = TestVideoPlayerCubit(
        VideoPlayerState(
          colors: ColorScheme.fromSeed(seedColor: Colors.blue),
          overFlowTextColor: Colors.white,
          key: GlobalKey(),
          video: Video(
            videoId: 'video-id',
            dashUrl: 'https://r1.googlevideo.com/manifest.mpd',
            formatStreams: [
              _stream('https://r1.googlevideo.com/video.mp4', '360p',
                  itag: '18'),
            ],
          ),
        ),
        player,
        settings,
      );
      controller = RecordingPlayerController();
      cubit.videoController = controller;
      final initialSource =
          controller.waitForSource('https://r1.googlevideo.com/manifest.mpd');
      final initialSetup = cubit.waitForSeekCount(1);
      cubit.playVideo(false);
      await initialSource;
      await initialSetup;
    });

    tearDown(() async {
      if (!cubit.isClosed) await cubit.close();
      await player.close();
      await settings.close();
      await db.close();
    });

    test('rejects unsafe external media destinations', () async {
      player.events.clear();
      final failed = player.waitForError();

      cubit.switchVideo(Video(
        videoId: 'unsafe-video',
        hlsUrl: 'http://r1.googlevideo.com/live.m3u8',
        dashUrl: 'https://localhost/manifest.mpd',
        formatStreams: [
          _stream('https://127.0.0.1/video.mp4', '360p'),
          _stream('https://evil.example/video.mp4', '480p'),
          _stream('https://r1.googlevideo.com:444/video.mp4', '720p'),
          _stream('https://googlevideo.com.evil/video.mp4', '1080p'),
          _stream('https://inv.example:444/video.mp4', '1440p'),
          _stream('https://inv.example@evil.example/video.mp4', '2160p'),
        ],
      ));
      await failed;

      expect(controller.sources, hasLength(1));
    });

    test('preserves HLS live and remembered subtitle configuration', () async {
      await settings.setRememberSubtitles(true);
      await settings.setLastSubtitle('English');
      const expected = 'https://manifest.youtube.com/live.m3u8';
      final started = controller.waitForSource(expected);

      cubit.switchVideo(Video(
        videoId: 'live-video',
        hlsUrl: expected,
        liveNow: true,
        captions: [Caption('English', 'en', '/captions/en.vtt')],
      ));
      await started;

      final source = controller.sources.last;
      expect(source.headers, isNull);
      expect(source.videoFormat, BetterPlayerVideoFormat.hls);
      expect(source.liveStream, isTrue);
      expect(source.subtitles!.single.urls,
          ['https://inv.example/captions/en.vtt']);
      expect(source.subtitles!.single.selectedByDefault, isTrue);
    });

    test('bounds fallback attempts from oversized metadata', () async {
      final urls = [
        for (var index = 0; index < 20; index++)
          'https://r$index.googlevideo.com/video.mp4',
      ];
      controller.failingUrls.addAll(urls);
      player.events.clear();
      final failed = player.waitForError();

      cubit.switchVideo(Video(
        videoId: 'oversized-video',
        formatStreams: [
          for (var index = 0; index < urls.length; index++)
            _stream(urls[index], '${index}p'),
        ],
      ));
      await failed;

      expect(controller.sourceUrls.skip(1), urls.reversed.take(10));
    });

    test('keeps duplicate resolution fallbacks selectable', () async {
      await settings.toggleDash(false);
      const preferred = 'https://r1.googlevideo.com/preferred.mp4';
      const fallback = 'https://r1.googlevideo.com/fallback.mp4';
      controller.failingUrls.add(preferred);
      final started = controller.waitForSource(fallback);

      cubit.switchVideo(Video(
        videoId: 'duplicate-resolution-video',
        formatStreams: [
          _stream(fallback, '360p'),
          _stream(preferred, '360p'),
        ],
      ));
      await started;
      await controller.waitForIdle();

      expect(controller.sources[controller.sources.length - 2].resolutions,
          {'360p': preferred});
      expect(controller.sources.last.resolutions, {'360p': fallback});
      cubit.selectVideoTrack(0);
      expect(controller.resolutionUrls, [fallback]);
    });

    test('exposes only retained progressive quality tracks', () async {
      const hls = 'https://r1.googlevideo.com/live.m3u8';
      const dash = 'https://r1.googlevideo.com/manifest-2.mpd';
      final urls = [
        for (var index = 0; index < 20; index++)
          'https://r$index.googlevideo.com/video.mp4',
      ];
      final started = controller.waitForSource(hls);

      cubit.switchVideo(Video(
        videoId: 'bounded-quality-video',
        hlsUrl: hls,
        dashUrl: dash,
        formatStreams: [
          for (var index = 0; index < urls.length; index++)
            _stream(urls[index], '${index}p'),
        ],
      ));
      await started;

      expect(cubit.getVideoTracks(), [
        for (var index = 12; index < 20; index++) '${index}p',
      ]);
      final selected = controller.waitForSource(urls[12]);
      cubit.selectVideoTrack(0);
      await selected;
      expect(controller.sources.last.url, urls[12]);
      expect(cubit.selectedVideoTrack(), 0);
    });

    test('deduplicates fragment variants before falling back', () async {
      const hls = 'https://r1.googlevideo.com/media#hls';
      controller.failingUrls.add(hls);
      player.events.clear();
      final failed = player.waitForError();

      cubit.switchVideo(Video(
        videoId: 'fragment-video',
        hlsUrl: hls,
        dashUrl: 'https://r1.googlevideo.com/media#dash',
      ));
      await failed;

      expect(controller.sourceUrls.skip(1), [hls]);
    });

    test('revalidates proxied URLs and preserves repeated query values',
        () async {
      await settings.setUseProxy(true);
      const expected = 'https://inv.example/video.mp4?sig=one&sig=two';
      final started = controller.waitForSource(expected);

      cubit.switchVideo(Video(
        videoId: 'proxied-video',
        formatStreams: [
          _stream('http://googlevideo.com/video.mp4?sig=one&sig=two', '360p'),
        ],
      ));
      await started;

      expect(Uri.parse(controller.sources.last.url).queryParametersAll['sig'],
          ['one', 'two']);
      expect(controller.sources.last.headers, isNull);
    });

    test('defers fallback until exception dispatch finishes', () async {
      final fallback =
          controller.waitForSource('https://r1.googlevideo.com/video.mp4');
      controller.dispatch(BetterPlayerEvent(BetterPlayerEventType.exception));

      expect(
          controller.sourceUrls, ['https://r1.googlevideo.com/manifest.mpd']);

      await fallback;
      expect(controller.sourceUrls, [
        'https://r1.googlevideo.com/manifest.mpd',
        'https://r1.googlevideo.com/video.mp4',
      ]);
    });

    test('close cancels pending fallback and disposes the controller',
        () async {
      expect(controller.listeners, hasLength(1));
      controller.dispatch(BetterPlayerEvent(BetterPlayerEventType.exception));
      await cubit.close();
      await _waitForDeferredFallback();

      expect(
          controller.sourceUrls, ['https://r1.googlevideo.com/manifest.mpd']);
      expect(controller.disposed, isTrue);
      expect(controller.listeners, isEmpty);
      expect(cubit.videoController, isNull);
    });

    test('waits for a failed setup before starting its fallback', () async {
      final slow = controller.hold('https://r1.googlevideo.com/slow.mpd');
      final slowStarted =
          controller.waitForSource('https://r1.googlevideo.com/slow.mpd');
      cubit.switchVideo(_videoWithFallback('slow'));
      await slowStarted;

      controller.dispatch(BetterPlayerEvent(BetterPlayerEventType.exception));
      final attemptsBeforeFailureCompleted = controller.sources
          .where((source) => source.url.contains('/slow.'))
          .map((source) => source.url)
          .toList();
      final fallback =
          controller.waitForSource('https://r1.googlevideo.com/slow.mp4');
      slow.completeError(StateError('Rejected slow source'));
      await fallback;

      expect(attemptsBeforeFailureCompleted,
          ['https://r1.googlevideo.com/slow.mpd']);
      expect(controller.maxActiveSetups, 1);
      expect(
          controller.sources.last.url, 'https://r1.googlevideo.com/slow.mp4');
    });

    test('keeps an initialized source after an earlier exception', () async {
      final slow = controller.hold('https://r1.googlevideo.com/slow.mpd');
      final slowStarted =
          controller.waitForSource('https://r1.googlevideo.com/slow.mpd');
      cubit.switchVideo(_videoWithFallback('slow'));
      await slowStarted;

      controller.dispatch(BetterPlayerEvent(BetterPlayerEventType.exception));
      controller.dispatch(BetterPlayerEvent(BetterPlayerEventType.initialized));
      final settled = cubit.waitForSeekCount(cubit.seekPositions.length + 1);
      slow.complete();
      await settled;

      expect(
          controller.sources.where(
              (source) => source.url == 'https://r1.googlevideo.com/slow.mp4'),
          isEmpty);
    });

    test('cancels a queued fallback when the source initializes', () async {
      controller.dispatch(BetterPlayerEvent(BetterPlayerEventType.exception));
      controller.dispatch(BetterPlayerEvent(BetterPlayerEventType.initialized));
      await _waitForDeferredFallback();

      expect(
          controller.sourceUrls, ['https://r1.googlevideo.com/manifest.mpd']);
    });

    test('keeps an initialized fallback after a duplicate old exception',
        () async {
      final fallback = controller.hold('https://r1.googlevideo.com/video.mp4');
      final fallbackStarted =
          controller.waitForSource('https://r1.googlevideo.com/video.mp4');
      controller.dispatch(BetterPlayerEvent(BetterPlayerEventType.exception));
      await fallbackStarted;
      expect(
          controller.sources.last.url, 'https://r1.googlevideo.com/video.mp4');

      controller.dispatch(BetterPlayerEvent(BetterPlayerEventType.exception));
      controller.dispatch(BetterPlayerEvent(BetterPlayerEventType.initialized));
      final settled = cubit.waitForSeekCount(cubit.seekPositions.length + 1);
      fallback.complete();
      await settled;

      expect(controller.sources, hasLength(2));
      expect(player.errorEvents, isEmpty);
    });

    test('ignores a held setup failure after close', () async {
      final fallback = controller.hold('https://r1.googlevideo.com/video.mp4');
      final fallbackStarted =
          controller.waitForSource('https://r1.googlevideo.com/video.mp4');
      controller.dispatch(BetterPlayerEvent(BetterPlayerEventType.exception));
      await fallbackStarted;
      expect(
          controller.sources.last.url, 'https://r1.googlevideo.com/video.mp4');

      await cubit.close();
      final idle = controller.waitForIdle();
      fallback.completeError(StateError('Late failure'));
      await idle;

      expect(player.errorEvents, isEmpty);
    });

    test('does not change sources after playback initializes', () {
      cubit.onVideoListener(
          BetterPlayerEvent(BetterPlayerEventType.initialized));
      cubit.onVideoListener(BetterPlayerEvent(BetterPlayerEventType.exception));

      expect(
          controller.sourceUrls, ['https://r1.googlevideo.com/manifest.mpd']);
      expect(player.errorEvents, hasLength(1));
      expect(controller.pauseCalls, 1);
    });

    test('emits one terminal error after every candidate fails', () async {
      final exception = BetterPlayerEvent(BetterPlayerEventType.exception);
      final fallback =
          controller.waitForSource('https://r1.googlevideo.com/video.mp4');

      cubit.onVideoListener(exception);
      await fallback;
      final failed = player.waitForError();
      cubit.onVideoListener(exception);
      cubit.onVideoListener(exception);
      await failed;

      expect(controller.sources, hasLength(2));
      expect(player.errorEvents, hasLength(1));
      expect(controller.pauseCalls, 1);
    });

    test('starts a new video without waiting for obsolete setup', () async {
      final oldSetup = controller.hold('https://r1.googlevideo.com/slow.mpd');
      addTearDown(() {
        if (!oldSetup.isCompleted) oldSetup.complete();
      });
      cubit.switchVideo(_videoWithFallback('slow'));
      await controller.waitForSource('https://r1.googlevideo.com/slow.mpd');

      final replacement = RecordingPlayerController();
      cubit.replacementController = replacement;
      final nextStarted =
          replacement.waitForSource('https://r1.googlevideo.com/next.mpd');

      cubit.switchVideo(_videoWithFallback('next'));
      await nextStarted;

      expect(oldSetup.isCompleted, isFalse);
      expect(controller.disposed, isTrue);
      expect(controller.listeners, isEmpty);
      expect(replacement.sourceUrls, ['https://r1.googlevideo.com/next.mpd']);
      expect(controller.maxActiveSetups, 1);
      expect(replacement.maxActiveSetups, 1);

      final oldIdle = controller.waitForIdle();
      oldSetup.complete();
      await oldIdle;
      expect(replacement.sourceUrls, ['https://r1.googlevideo.com/next.mpd']);
      expect(player.errorEvents, isEmpty);
    });

    test('ignores a listener captured before switching videos', () async {
      final staleListener = controller.listeners.single;
      final nextStarted =
          controller.waitForSource('https://r1.googlevideo.com/next.mpd');
      cubit.switchVideo(_videoWithFallback('next'));
      await nextStarted;
      final attemptsAfterSwitch = controller.sources.length;

      staleListener(BetterPlayerEvent(BetterPlayerEventType.exception));

      expect(controller.sources, hasLength(attemptsAfterSwitch));
      expect(
          controller.sources.last.url, 'https://r1.googlevideo.com/next.mpd');
    });

    test('resets fallback attempts when switching videos', () async {
      final exception = BetterPlayerEvent(BetterPlayerEventType.exception);
      final initialFallback =
          controller.waitForSource('https://r1.googlevideo.com/video.mp4');
      final initialFallbackSettled =
          cubit.waitForSeekCount(cubit.seekPositions.length + 1);
      cubit.onVideoListener(exception);
      await initialFallback;
      await initialFallbackSettled;

      final next =
          controller.waitForSource('https://r1.googlevideo.com/next.mpd');
      final nextSettled =
          cubit.waitForSeekCount(cubit.seekPositions.length + 1);
      cubit.switchVideo(_videoWithFallback('next'));
      await next;
      await nextSettled;
      final nextFallback =
          controller.waitForSource('https://r1.googlevideo.com/next.mp4');
      cubit.onVideoListener(exception);
      await nextFallback;

      expect(controller.sourceUrls, [
        'https://r1.googlevideo.com/manifest.mpd',
        'https://r1.googlevideo.com/video.mp4',
        'https://r1.googlevideo.com/next.mpd',
        'https://r1.googlevideo.com/next.mp4',
      ]);
    });

    test('rebuilds source order after toggling DASH preference', () async {
      final rebuilt =
          controller.waitForSource('https://r1.googlevideo.com/video.mp4');
      cubit.toggleDash();
      await rebuilt;

      expect(settings.state.useDash, isFalse);
      expect(controller.sourceUrls, [
        'https://r1.googlevideo.com/manifest.mpd',
        'https://r1.googlevideo.com/video.mp4',
      ]);
    });

    test('keeps the requested start position when falling back', () async {
      cubit.seekPositions.clear();
      final nextSettled = cubit.waitForSeekCount(1);
      cubit.switchVideo(_videoWithFallback('next'),
          startAt: const Duration(seconds: 42));
      await nextSettled;
      final fallbackSettled = cubit.waitForSeekCount(2);
      cubit.onVideoListener(BetterPlayerEvent(BetterPlayerEventType.exception));
      await fallbackSettled;

      expect(cubit.seekPositions, [
        const Duration(seconds: 42),
        const Duration(seconds: 42),
      ]);
    });

    test('keeps fallback track state after synchronous setup failure',
        () async {
      controller.failingUrls.add('https://r1.googlevideo.com/next.mpd');
      final fallback =
          controller.waitForSource('https://r1.googlevideo.com/next.mp4');

      cubit.switchVideo(_videoWithFallback('next',
          resolution: '640x360', qualityLabel: 'Medium'));
      await fallback;

      expect(controller.sourceUrls, [
        'https://r1.googlevideo.com/manifest.mpd',
        'https://r1.googlevideo.com/next.mpd',
        'https://r1.googlevideo.com/next.mp4',
      ]);
      expect(cubit.state.selectedNonDashTrack, '640x360');
    });

    test('stops the previous source when new metadata has no valid media',
        () async {
      player.events.clear();
      final failed = player.waitForError();
      cubit.switchVideo(Video(
        videoId: 'invalid-video',
        dashUrl: 'not a URL',
        formatStreams: [],
      ));
      await failed;

      expect(controller.pauseCalls, 1);
      expect(player.errorEvents, hasLength(1));
    });

    test('stops an old setup again after invalid replacement metadata',
        () async {
      final fallback = controller.hold('https://r1.googlevideo.com/video.mp4');
      final fallbackStarted =
          controller.waitForSource('https://r1.googlevideo.com/video.mp4');
      controller.dispatch(BetterPlayerEvent(BetterPlayerEventType.exception));
      await fallbackStarted;

      player.events.clear();
      final failed = player.waitForError();
      cubit.switchVideo(Video(
        videoId: 'invalid-video',
        dashUrl: 'not a URL',
        formatStreams: [],
      ));
      await failed;
      final disposedBeforeCompletion = controller.disposed;

      final idle = controller.waitForIdle();
      fallback.complete();
      await idle;

      expect(disposedBeforeCompletion, isTrue);
      expect(controller.pauseCalls, 0);
      expect(controller.playing, isFalse);
    });

    test('keeps terminal error last when every setup throws', () async {
      controller.failingUrls.addAll({
        'https://r1.googlevideo.com/bad.mpd',
        'https://r1.googlevideo.com/bad.mp4',
      });
      player.events.clear();
      final failed = player.waitForError();

      cubit.switchVideo(_videoWithFallback('bad'));
      await failed;

      expect(player.errorEvents, hasLength(1));
      expect(player.events.last.state, MediaState.error);
    });

    test('switches cross-origin quality without rebuilding the source',
        () async {
      const authenticatedServer = Server(
        url: 'https://inv.example',
        customHeaders: {'Authorization': 'Basic secret'},
      );
      await db.upsertServer(authenticatedServer);
      await db.useServer(authenticatedServer);
      await settings.toggleDash(false);
      final started = controller.waitForSource('https://inv.example/720.mp4');

      cubit.switchVideo(Video(
        videoId: 'mixed-origin-video',
        formatStreams: [
          _stream('https://r1.googlevideo.com/360.mp4', '360p', itag: '18'),
          _stream('https://inv.example/720.mp4', '720p',
              itag: '22', quality: 'hd720', size: '1280x720'),
        ],
      ));
      await started;
      expect(controller.sources.last.headers, isNull);
      expect(controller.sources.last.resolutions, {
        '720p': 'https://inv.example/720.mp4',
        '360p': 'https://r1.googlevideo.com/360.mp4',
      });

      controller.playing = false;
      final sourceCount = controller.sources.length;
      cubit.selectVideoTrack(0);

      expect(controller.sources, hasLength(sourceCount));
      expect(controller.resolutionUrls, ['https://r1.googlevideo.com/360.mp4']);
      expect(controller.playing, isFalse);
    });
  });
}
