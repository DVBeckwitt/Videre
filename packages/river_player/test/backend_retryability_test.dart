import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river_player/river_player.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

class _VideoPlatform extends VideoPlayerPlatform {
  final streams = <int, StreamController<VideoEvent>>{};
  DataSource? lastSource;
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
    lastSource = dataSource;
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
  @override
  Future<void> setAudioTrack(int? textureId, String? name, int? index) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = _VideoPlatform();
  VideoPlayerPlatform.instance = platform;

  test('inline DASH supplies track options and the native manifest body',
      () async {
    const url = 'https://example.com/manifest';
    const manifest = '''<MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
      <Period><AdaptationSet mimeType="video/mp4">
        <Representation id="137" width="1920" height="1080"
          bandwidth="3000000" codecs="avc1.640028"/>
      </AdaptationSet><AdaptationSet mimeType="audio/mp4" lang="en"/>
      </Period>
    </MPD>''';
    final controller = BetterPlayerController(const BetterPlayerConfiguration(
      autoPlay: false,
      handleLifecycle: false,
      allowedScreenSleep: true,
    ));
    try {
      final source = BetterPlayerDataSource(
        BetterPlayerDataSourceType.network,
        url,
        videoFormat: BetterPlayerVideoFormat.dash,
      ).copyWith(inlineDashManifest: manifest);
      await controller.setupDataSource(source);
      final nativeSource = platform.lastSource!;
      expect(nativeSource.uri, url);
      expect(nativeSource.formatHint, VideoFormat.dash);
      expect(nativeSource.inlineDashManifest, manifest);
      expect(nativeSource.toString(), isNot(contains('avc1.640028')));
      expect(controller.betterPlayerAsmsTracks.single.height, 1080);
      expect(controller.betterPlayerAsmsAudioTracks!.single.language, 'en');
      expect(controller.betterPlayerAsmsAudioTrack!.language, 'en');

      await controller
          .setupDataSource(source.copyWith(useAsmsAudioTracks: false));
      expect(controller.betterPlayerAsmsTracks.single.height, 1080);
      expect(controller.betterPlayerAsmsAudioTracks, isNull);
      expect(controller.betterPlayerAsmsAudioTrack, isNull);

      await controller.setupDataSource(BetterPlayerDataSource.network(
        'https://example.com/video.mp4',
        videoFormat: BetterPlayerVideoFormat.other,
      ));
      expect(platform.lastSource!.inlineDashManifest, isNull);
      expect(controller.betterPlayerAsmsTracks, isEmpty);
    } finally {
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
    }
  });

  for (final embeddedSubtitles in [false, true]) {
    test(
        'delayed HLS metadata preserves selected captions ($embeddedSubtitles)',
        () => HttpOverrides.runWithHttpOverrides(() async {
              final server =
                  await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
              final pendingManifest = Completer<HttpRequest>();
              server.listen(pendingManifest.complete);
              final controller =
                  BetterPlayerController(const BetterPlayerConfiguration(
                autoPlay: false,
                handleLifecycle: false,
                allowedScreenSleep: true,
              ));
              addTearDown(() async {
                controller.dispose();
                await server.close(force: true);
              });
              final external = BetterPlayerSubtitlesSource(
                type: BetterPlayerSubtitlesSourceType.memory,
                content:
                    'WEBVTT\n\n00:00:00.000 --> 00:00:05.000\nExternal cue\n\n',
              );
              await controller.setupDataSource(BetterPlayerDataSource(
                BetterPlayerDataSourceType.network,
                'http://127.0.0.1:${server.port}/manifest.m3u8',
                videoFormat: BetterPlayerVideoFormat.hls,
                subtitles: [external],
                useAsmsSubtitles: embeddedSubtitles,
              ));
              final request = await pendingManifest.future
                  .timeout(const Duration(seconds: 3));
              await controller.setupSubtitleSource(external);
              expect(controller.betterPlayerSubtitlesSource, same(external));

              request.response.write('#EXTM3U\n'
                  '#EXT-X-STREAM-INF:BANDWIDTH=100000,RESOLUTION=640x360\n'
                  'video.m3u8\n');
              await request.response.close();
              final deadline = Stopwatch()..start();
              while (controller.betterPlayerAsmsTracks.isEmpty &&
                  deadline.elapsed < const Duration(seconds: 3)) {
                await Future<void>.delayed(const Duration(milliseconds: 10));
              }

              expect(controller.betterPlayerAsmsTracks.last.height, 360);
              expect(
                  controller.betterPlayerSubtitlesSourceList.where((track) =>
                      track.type == BetterPlayerSubtitlesSourceType.none),
                  hasLength(1));
              expect(controller.betterPlayerSubtitlesSource, same(external));
              expect(controller.subtitlesLines.single.texts, ['External cue']);
            }, _LoopbackHttpOverrides()));
  }

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
