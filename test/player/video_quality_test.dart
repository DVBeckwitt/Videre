import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/media_handler.dart';
import 'package:clipious/network/nerdvpn_origin.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/video_quality.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/states/tv_player_settings.dart';
import 'package:clipious/player/states/video_player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/server_settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/caption.dart';
import 'package:clipious/videos/models/format_stream.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river_player/river_player.dart';

import '../support/media_companion_transport.dart';
import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _VideoPlayer extends VideoPlayerCubit {
  _VideoPlayer(super.initialState, super.player, super.settings);

  @override
  void onInit() {}
}

Video _video(String id,
        {List<int> heights = const [1080, 480, 360],
        String serverUrl = 'https://instance.example'}) =>
    Video(videoId: id, lengthSeconds: 60, formatStreams: [
      for (final height in heights)
        FormatStream(
            '$serverUrl/$id-$height.mp4',
            '$height',
            'video/mp4',
            'medium',
            'mp4',
            'h264',
            '${height}p',
            '${height}p',
            '1920x$height'),
    ]);

Future<void> _flush() async {
  for (var i = 0; i < 15; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('better_player_channel');
  const events = MethodChannel('better_player_channel/videoEvents1');
  const wakelock =
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;
  late List<String> sources;
  late List<Map<dynamic, dynamic>> nativeSources;
  late List<int?> initialDashHeights;
  late List<int> trackHeights;
  late Set<String> failedSources;
  late Map<String, Completer<void>> heldSources;
  late Service previousService;

  setUp(() async {
    previousService = service;
    service = Service(
        httpClient: MockClient((_) async => http.Response('<MPD/>', 200)));
    db = await SembastSqfDb.createInMemory();
    const server = Server(url: 'https://instance.example');
    await db.upsertServer(server);
    await db.useServer(server);
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    await settings.setUseDash(false);
    player = TestPlayerCubit(PlayerState.init(null), settings);
    sources = [];
    nativeSources = [];
    initialDashHeights = [];
    trackHeights = [];
    failedSources = {};
    heldSources = {};
    messenger.setMockMessageHandler(
        wakelock,
        (_) async =>
            const StandardMessageCodec().encodeMessage(<Object?>[null]));
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'create') return {'textureId': 1};
      if (call.method == 'position') return 12000;
      if (call.method == 'setTrackParameters') {
        trackHeights.add(call.arguments['height'] as int);
      }
      if (call.method == 'setDataSource') {
        final source = call.arguments['dataSource'] as Map;
        nativeSources.add(source);
        final uri = source['uri'] as String;
        sources.add(uri);
        initialDashHeights.add(source['initialDashHeight'] as int?);
        if (failedSources.contains(uri)) {
          throw PlatformException(code: 'VideoError');
        }
        if (heldSources[uri] case final held?) await held.future;
        await messenger.handlePlatformMessage(
            events.name,
            const StandardMethodCodec().encodeSuccessEnvelope({
              'event': 'initialized',
              'duration': 60000,
              'width': 640,
              'height': 360,
              'isLiveStream': false,
            }),
            (_) {});
      }
      return null;
    });
  });

  tearDown(() async {
    await _flush();
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    service.httpClient.close();
    service = previousService;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(events, null);
    messenger.setMockMessageHandler(wakelock, null);
  });

  _VideoPlayer create(Video video) => _VideoPlayer(
      VideoPlayerState(
          video: video,
          colors: ColorScheme.fromSeed(seedColor: Colors.blue),
          overFlowTextColor: Colors.white,
          key: GlobalKey()),
      player,
      settings);

  test('Retry on the same video uses the newly approved companion', () async {
    mockMediaCompanionTransport();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const companion = 'https://media.example';
    const signed = '$companion/watch.mpd?sig=a%2Fb&part=1&part=2';
    const metadata = Video(videoId: 'song', dashUrl: signed, lengthSeconds: 60);
    final requests = <Uri>[];
    service.httpClient.close();
    service = Service(httpClient: MockClient((request) async {
      requests.add(request.url);
      return request.url.path == '/api/v1/videos/song'
          ? http.Response(jsonEncode(metadata.toJson()), 200,
              headers: {'content-type': 'application/json'})
          : http.Response('[]', 200,
              headers: {'content-type': 'application/json'});
    }));
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    final directory =
        await Directory.systemTemp.createTemp('videre-companion-retry-');
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => directory.path);
    final selected = await db.getCurrentlySelectedServer();
    await fileDb.useServer(selected);
    final accountSettings =
        ServerSettingsCubit(ServerSettingsState(server: selected), app);
    final original = (await service.getVideo(metadata.videoId))
        .copyWith(queueEntryId: 'entry-1');
    await player.close();
    player = TestPlayerCubit(
        PlayerState.init([original]).copyWith(
            currentlyPlaying: original,
            position: const Duration(seconds: 12),
            isHidden: false,
            isMini: false),
        settings);
    player.audioSession = await AudioSession.instance;
    app_main.mediaHandler = MediaHandler(player);
    final video = create(original);
    try {
      await video.playVideo(false);
      expect(player.playbackFailureReason,
          PlaybackFailureReason.separateMediaHost);
      expect(nativeSources, isEmpty);
      await accountSettings.setMediaCompanionOrigin(selected, companion,
          enabled: true);
      await player.retryCurrentVideo();
      expect(player.state.currentQueueId, 'entry-1');
      expect(player.playbackFailureReason, isNull);
      video.handleCommand(player.state.mediaCommand!);
      await _flush();
      expect(nativeSources.single['uri'], signed);
      expect(nativeSources.single['mediaCompanions']['origins'], [companion]);
      expect(nativeSources.single['initialPositionMs'], 12000);
      expect(requests.where((uri) => uri.path == '/api/v1/videos/song'),
          hasLength(2));
    } finally {
      await video.close();
      await accountSettings.close();
      messenger.setMockMethodCallHandler(pathProvider, null);
      await directory.delete(recursive: true);
    }
  });

  test('resolution matching ignores Auto, stream IDs, and bitrate labels', () {
    expect(videoQualityHeight('1080p60'), 1080);
    expect(videoQualityHeight('720p - 2 MB/s'), 720);
    expect(videoQualityHeight('18'), isNull);
    expect(videoQualityHeight('unknown'), isNull);
    expect(preferredVideoQualityIndex([0, null, 1080, 360, 480], 720), 4);
    expect(preferredVideoQualityIndex([1080, 480], 360), 1);
    expect(preferredVideoQualityIndex([1080, 480], 1080), 0);
    expect(preferredVideoQualityIndex([0, null], 720), isNull);
    expect(preferredVideoQualityIndex([360, 1080], 0), isNull);
  });

  test(
      'returning to Video keeps the requested track in progressive DASH fallback',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const base = 'https://instance.example';
    const dash = '$base/watch.dash';
    const nativeDash = '$dash?local=true';
    const original = AudioTrack(id: 'en.1', displayName: 'English');
    const alternate = AudioTrack(id: 'fr.1', displayName: 'French');
    FormatStream rendition(int height, AudioTrack track) => FormatStream(
        '$base/${track.id}-$height.mp4',
        '$height',
        'video/mp4',
        'medium',
        'mp4',
        'h264',
        '${height}p',
        '${height}p',
        '1920x$height',
        audioTrack: track);
    final entry = Video(
        videoId: 'watch',
        lengthSeconds: 60,
        queueEntryId: 'first',
        dashUrl: dash,
        formatStreams: [
          rendition(480, alternate),
          rendition(360, alternate),
          rendition(480, original),
          rendition(360, original),
        ]);
    await player.close();
    player = TestPlayerCubit(
        PlayerState.init([entry]).copyWith(
            currentlyPlaying: entry,
            position: const Duration(seconds: 12),
            isHidden: false,
            isMini: false),
        settings);
    await settings.setUseDash(true);
    failedSources.add(nativeDash);
    final before = create(entry);
    try {
      await before.playVideo(false, startAt: const Duration(seconds: 12));
      expect(sources, [nativeDash, '$base/en.1-360.mp4']);
      expect(player.watchAudioPreferenceFor(entry),
          (trackId: 'en.1', progressiveUrl: '$base/en.1-360.mp4'));
    } finally {
      await before.close();
    }

    final queue = player.state.currentQueueId;
    await player.onProgress(const Duration(seconds: 12));
    player.switchAudio(true);
    player.rememberWatchAudioTrack(entry, 'fr.1');
    player.switchAudio(false);
    final after = create(entry);
    addTearDown(after.close);
    await after.playVideo(false, startAt: player.state.startAt);
    expect(sources.skip(2), [nativeDash, '$base/fr.1-360.mp4']);
    expect(nativeSources.last['initialPositionMs'], 12000);
    expect(player.state.currentQueueId, queue);
    expect(settings.state.useDash, isTrue);
    final quality = after.getVideoTracks();
    await after.selectVideoTrack(quality.indexOf('480p'));
    await _flush();
    expect(sources.last, '$base/fr.1-480.mp4');
    expect(player.watchAudioPreferenceFor(entry),
        (trackId: 'fr.1', progressiveUrl: '$base/fr.1-480.mp4'));

    // A pending old Video setup does not replace the last mounted fallback
    // after a mode round trip, even if its native initialized event arrives.
    final pendingSource = Completer<void>();
    addTearDown(() {
      if (!pendingSource.isCompleted) pendingSource.complete();
    });
    heldSources['$base/fr.1-360.mp4'] = pendingSource;
    await after.selectVideoTrack(after.getVideoTracks().indexOf('360p'));
    await _flush();
    expect(sources.last, '$base/fr.1-360.mp4');
    player.switchAudio(true);
    player.switchAudio(false);
    pendingSource.complete();
    await _flush();
    expect(player.watchAudioPreferenceFor(entry),
        (trackId: 'fr.1', progressiveUrl: '$base/fr.1-480.mp4'));
  });

  test('only a classified native failure reports a separate media host',
      () async {
    final video = create(_video('first', heights: [360]));
    addTearDown(video.close);
    await video.playVideo(false);
    await _flush();
    video.onVideoListener(BetterPlayerEvent(BetterPlayerEventType.exception,
        parameters: {'mediaOriginBlocked': true}));
    expect(
        player.state.mediaEvent.value, PlaybackFailureReason.separateMediaHost);

    video.switchVideo(_video('second', heights: [360]));
    await _flush();
    video.onVideoListener(BetterPlayerEvent(BetterPlayerEventType.exception));
    expect(sources, [
      'https://instance.example/first-360.mp4',
      'https://instance.example/second-360.mp4',
    ]);
    expect(player.state.mediaEvent.state, MediaState.error);
    expect(player.state.mediaEvent.value, isNull);
  });

  test('selecting captions lazily uses the playing backend snapshot', () async {
    final requests = <http.Request>[];
    service.httpClient.close();
    service = Service(httpClient: MockClient((request) async {
      requests.add(request);
      return http.Response(
        '{"transcript":{"body":[{"type":"regular","startMs":0,'
        '"endMs":20000,"line":"Selected backend captions"}]}}',
        200,
        headers: {'content-type': 'application/json'},
      );
    }));
    final selector = BackendSelector('COMPANION_ID', [
      const BackendOption('2', 'Preferred'),
      const BackendOption('7', 'Playing'),
    ]);
    final preferred = selector.withSelection(
        const Server(url: 'https://instance.example'), '2');
    await db.upsertServer(preferred);
    await db.useServer(preferred);
    final playback = BackendPlayback.manual(preferred, '7');
    final video = create(_video('captioned').copyWith(
      captions: [
        Caption('English', 'en',
            'https://music.youtube.com/untrusted-caption-location'),
      ],
      backendPlayback: playback,
    ));
    try {
      await video.playVideo(false);
      await _flush();
      expect(requests, isEmpty);
      expect(video.getSubtitles(), contains('English'));
      video.selectSubtitle(video.getSubtitles().indexOf('English'));
      await _flush();
      expect(requests, hasLength(1));
      expect(requests.single.url.origin, preferred.url);
      expect(requests.single.url.path, '/api/v1/transcripts/captioned');
      expect(requests.single.headers['Cookie'], 'COMPANION_ID=7');
      expect(video.videoController!.subtitlesLines.single.texts,
          ['Selected backend captions']);
      expect(video.state.subtitleFailed, isFalse);
      expect(
          selector.selectedValue(await db.getCurrentlySelectedServer()), '2');
    } finally {
      await video.close();
    }
  });

  for (final trusted in [false, true]) {
    test('direct companion DASH preserves consent and signed URL: $trusted',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const origin = 'https://instance.example';
      const companion = 'https://media.example';
      const signed = '$companion/stream.mpd?sig=a%2Fb&part=1&part=2';
      final selected = (await db.getCurrentlySelectedServer())
          .copyWith(customHeaders: {'X-Private-Header': 'instance-only'});
      await db.upsertServer(selected);
      if (trusted) {
        mockMediaCompanionTransport();
        await db.setMediaCompanionOrigin(selected, companion, enabled: true);
      }
      await settings.setUseDash(true);
      final requests = <Uri>[];
      service.httpClient.close();
      service = Service(httpClient: MockClient((request) async {
        requests.add(request.url);
        return http.Response('', 500);
      }));
      final video = create(
          const Video(videoId: 'video', dashUrl: signed, lengthSeconds: 60));
      addTearDown(video.close);
      await video.playVideo(false);
      await _flush();
      expect(requests, isEmpty);
      if (trusted) {
        final source = nativeSources.single;
        expect(source['uri'], signed);
        expect(source['headers'], isEmpty);
        expect(source['mediaCompanions']['origin'], origin);
        expect(source['mediaCompanions']['origins'], [companion]);
        expect(source['mediaCompanions']['gatewayContext'], isA<String>());
        expect(source['playbackCache']['origin'], origin);
        expect(source['playbackCache']['resources'].first['url'], signed);
      } else {
        expect(sources, isEmpty);
        expect(player.state.mediaEvent.value,
            PlaybackFailureReason.separateMediaHost);
      }
    });
  }

  test(
      'protected companion accounts use the guarded loader for HLS track discovery',
      () async {
    mockMediaCompanionTransport();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final selected = (await db.getCurrentlySelectedServer()).copyWith(
        gatewayEnabled: true, customHeaders: {'X-Test-Instance': 'frontend'});
    await db.upsertServer(selected);
    await db.setMediaCompanionOrigin(selected, 'https://media.example',
        enabled: true);
    final requests = <http.Request>[];
    service.httpClient.close();
    service = Service(httpClient: MockClient((request) async {
      requests.add(request);
      return http.Response(
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100000,RESOLUTION=640x360\nvariant.m3u8\n',
          200);
    }));
    final video = create(const Video(
        videoId: 'video', hlsUrl: 'https://instance.example/manifest.m3u8'));
    addTearDown(video.close);
    await video.playVideo(false);
    await _flush();
    expect(requests.single.url.toString(),
        'https://instance.example/manifest.m3u8?local=true');
    expect(requests.single.followRedirects, isFalse);
    expect(requests.single.headers['X-Test-Instance'], 'frontend');
    expect(video.videoController?.betterPlayerAsmsTracks.last.height, 360);
  });

  test('signed companion handoff clears frontend headers before native setup',
      () async {
    mockMediaCompanionTransport();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const companion = 'https://media.example';
    const signed =
        '$companion/api/manifest/dash/id/video?local=true&check=a%2Fb&x=1&x=2';
    final selected = (await db.getCurrentlySelectedServer()).copyWith(
        gatewayEnabled: true, customHeaders: {'X-Test-Instance': 'frontend'});
    await db.upsertServer(selected);
    await db.setMediaCompanionOrigin(selected, companion, enabled: true);
    final requests = <http.Request>[];
    service.httpClient.close();
    service = Service(httpClient: MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/watch') {
        return http.Response(
            '<video id="player"><source type="application/dash+xml" src="${signed.replaceAll('&', '&amp;')}"></video>',
            200);
      }
      return http.Response('No check ID.', 400);
    }));
    final video = create(const Video(
        videoId: 'video',
        lengthSeconds: 60,
        dashUrl: 'https://instance.example/api/manifest/dash/id/video'));
    addTearDown(video.close);
    await video.playVideo(false);
    await _flush();
    final source = nativeSources.single;
    expect(source['uri'], signed);
    expect(source['headers'], isEmpty);
    expect(source['mediaCompanions']['origin'], selected.url);
    expect(source['mediaCompanions']['origins'], [companion]);
    expect(source['playbackCache']['origin'], selected.url);
    expect(source['playbackCache']['resources'].first['url'], signed);
    expect(requests.map((request) => request.url.path),
        ['/api/manifest/dash/id/video', '/watch']);
    expect(
        requests.every((request) =>
            request.url.origin == selected.url &&
            request.headers['X-Test-Instance'] == 'frontend'),
        isTrue);
  });

  test('offline document URIs reach the native player without file conversion',
      () async {
    const uri = 'content://documents/tree/folder/document/video.webm';
    final video = _VideoPlayer(
        VideoPlayerState(
            offlineVideo: const DownloadedVideo(
                videoId: 'offline',
                title: 'Offline',
                lengthSeconds: 60,
                quality: '480p',
                downloadComplete: true,
                storageUri: uri),
            colors: ColorScheme.fromSeed(seedColor: Colors.blue),
            overFlowTextColor: Colors.white,
            key: GlobalKey()),
        player,
        settings);
    try {
      await video.playVideo(true);
      expect(sources, [uri]);
    } finally {
      await video.close();
    }
  });

  test('offline captions load from the saved file without network access',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('videre-offline-captions-');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => directory.path);
    final requests = <http.Request>[];
    service.httpClient.close();
    service = Service(httpClient: MockClient((request) async {
      requests.add(request);
      throw StateError('Offline playback must not request subtitles');
    }));
    const downloaded = DownloadedVideo(
        videoId: 'offline-captions',
        title: 'Offline captions',
        lengthSeconds: 60,
        quality: '480p',
        downloadComplete: true,
        captionLabel: 'French',
        storageUri: 'content://documents/video.mp4');
    final video = _VideoPlayer(
        VideoPlayerState(
            offlineVideo: downloaded,
            colors: ColorScheme.fromSeed(seedColor: Colors.blue),
            overFlowTextColor: Colors.white,
            key: GlobalKey()),
        player,
        settings);
    try {
      final subtitles = File(await downloaded.subtitlePath);
      await subtitles.writeAsString(
          'WEBVTT\n\n00:00:00.000 --> 00:00:05.000\nBonjour\n\n');
      await video.playVideo(true);
      expect(video.getSubtitles(), contains('French'));
      final source = video.videoController!.betterPlayerSubtitlesSourceList
          .firstWhere((source) => source.name == 'French');
      await video.videoController!.setupSubtitleSource(source);
      expect(video.videoController!.subtitlesLines.single.texts, ['Bonjour']);
      expect(video.state.subtitleFailed, isFalse);
      expect(requests, isEmpty);

      await subtitles.delete();
      await video.videoController!.setupSubtitleSource(source);
      expect(video.state.subtitleFailed, isTrue);
      expect(sources, ['content://documents/video.mp4']);
      expect(requests, isEmpty);
    } finally {
      await video.close();
      messenger.setMockMethodCallHandler(pathProvider, null);
      await directory.delete(recursive: true);
    }
  });

  for (final preference in [null, 0, 144, 480, 720, 1080, 2160]) {
    test('progressive source starts at preferred quality $preference',
        () async {
      if (preference != null) await settings.setLastVideoQuality(preference);
      final video = create(_video('first'));
      try {
        await video.playVideo(false);
        final expected = switch (preference) {
          480 || 720 => 480,
          1080 || 2160 => 1080,
          _ => 360,
        };
        expect(sources.first, endsWith('first-$expected.mp4'));
        expect(video.getVideoTracks(), ['1080p', '480p', '360p']);
        expect(
            video.getVideoTracks()[video.selectedVideoTrack()], '${expected}p');
        expect(settings.state.lastVideoQuality, preference);
      } finally {
        await video.close();
      }
    });
  }

  for (final fromTv in [false, true]) {
    test('explicit choice persists to next video and restart (TV=$fromTv)',
        () async {
      var video = create(_video('first'));
      try {
        await video.playVideo(false);
        if (fromTv) {
          final tv = TvPlayerSettingsCubit(
              const TvPlayerSettingsState(), video, settings);
          await tv.changeVideoTrack('480p');
          await tv.close();
        } else {
          await video.selectVideoTrack(video.getVideoTracks().indexOf('480p'));
        }
        await _flush();
        expect(SettingsState.init().lastVideoQuality, 480);
        video.switchVideo(_video('second'));
        await _flush();
        expect(sources.last, endsWith('second-480.mp4'));
        await video.close();
        video = create(_video('reopened'));
        await video.playVideo(false);
        expect(sources.last, endsWith('reopened-480.mp4'));
      } finally {
        await video.close();
      }
    });
  }

  test('opt-out ignores saved quality and does not replace it', () async {
    await settings.setLastVideoQuality(1080);
    await settings.setRememberVideoQuality(false);
    final video = create(_video('first'));
    try {
      await video.playVideo(false);
      expect(sources.last, endsWith('first-360.mp4'));
      await video.selectVideoTrack(video.getVideoTracks().indexOf('480p'));
      await _flush();
      expect(sources.last, endsWith('first-480.mp4'));
      expect(settings.state.lastVideoQuality, 1080);
      video.switchVideo(_video('second'));
      await _flush();
      expect(sources.last, endsWith('second-360.mp4'));
    } finally {
      await video.close();
    }
  });

  test(
      'a failed preferred source still tries alternatives without changing preference',
      () async {
    await settings.setLastVideoQuality(480);
    failedSources.add('https://instance.example/first-480.mp4');
    final video = create(_video('first'));
    try {
      await video.playVideo(false);
      await _flush();
      expect(sources.take(2), [
        'https://instance.example/first-480.mp4',
        'https://instance.example/first-360.mp4',
      ]);
      expect(settings.state.lastVideoQuality, 480);
    } finally {
      await video.close();
    }
  });

  test('adaptive choices from TV use actual tracks even with DASH disabled',
      () async {
    final video = create(_video('first'));
    try {
      await video.playVideo(false);
      video.videoController!.betterPlayerAsmsTracks.addAll([
        BetterPlayerAsmsTrack.defaultTrack(),
        BetterPlayerAsmsTrack('480', 854, 480, 1000000, 30, '', ''),
        BetterPlayerAsmsTrack('1080', 1920, 1080, 4000000, 30, '', ''),
      ]);
      final tv =
          TvPlayerSettingsCubit(const TvPlayerSettingsState(), video, settings);
      await tv.changeVideoTrack('480p');
      expect(trackHeights.last, 480);
      expect(SettingsState.init().lastVideoQuality, 480);
      await tv.changeVideoTrack('0p');
      expect(trackHeights.last, 0);
      expect(SettingsState.init().lastVideoQuality, 0);
      await tv.close();
    } finally {
      await video.close();
    }
  });

  for (final legacyPreference in [null, 'false']) {
    test(
        'official manifests are skipped with legacy use-proxy=$legacyPreference',
        () async {
      if (legacyPreference != null) {
        await db.saveSetting(SettingsValue('use-proxy', legacyPreference));
      }
      await settings.setUseDash(true);
      final requests = <Uri>[];
      service.httpClient.close();
      service = Service(httpClient: MockClient((request) async {
        requests.add(request.url);
        return http.Response('<MPD/>', 200);
      }));
      final video = create(_video('private', heights: [360]).copyWith(
        hlsUrl:
            'https://manifest.youtube.com/api/manifest/hls_playlist/id/private',
        dashUrl:
            'https://manifest.googlevideo.com/api/manifest/dash/id/private',
      ));
      try {
        await video.playVideo(false);
        await _flush();
        expect(sources, ['https://instance.example/private-360.mp4']);
        expect(requests, isEmpty,
            reason: 'Official manifests must be rejected before probing them');
        expect(video.selectedVideoTrack(), 0);
      } finally {
        await video.close();
      }
    });
  }

  test('adaptive startup applies saved cap before manifest tracks arrive',
      () async {
    await settings.setLastVideoQuality(720);
    final video = create(_video('first').copyWith(
        hlsUrl: 'https://instance.example/first.m3u8', liveNow: true));
    try {
      await video.playVideo(false);
      await _flush();
      expect(sources.first, 'https://instance.example/first.m3u8?local=true');
      expect(trackHeights.last, 720);
      // Track discovery can finish after native initialization. The selected
      // row should reflect the closest available resolution to the saved cap.
      video.videoController!.betterPlayerAsmsTracks.addAll([
        BetterPlayerAsmsTrack('1080', 1920, 1080, 4000000, 30, '', ''),
        BetterPlayerAsmsTrack('360', 640, 360, 500000, 30, '', ''),
        BetterPlayerAsmsTrack('480', 854, 480, 1000000, 30, '', ''),
      ]);
      expect(video.selectedVideoTrack(), 2);
      expect(settings.state.lastVideoQuality, 720);

      await settings.setRememberVideoQuality(false);
      video.switchVideo(_video('second').copyWith(
          hlsUrl: 'https://instance.example/second.m3u8', liveNow: true));
      await _flush();
      expect(sources.last, 'https://instance.example/second.m3u8?local=true');
      expect(trackHeights.last, 0);
      expect(settings.state.lastVideoQuality, 720);
    } finally {
      await video.close();
    }
  });

  test('DASH startup and progressive fallback both honor remembered quality',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await settings.setUseDash(true);
    await settings.setLastVideoQuality(480);
    final video = create(_video('first')
        .copyWith(dashUrl: 'https://instance.example/first.dash'));
    try {
      await video.playVideo(false);
      await _flush();
      expect(sources.first, 'https://instance.example/first.dash?local=true');
      expect(initialDashHeights, [480]);
      expect(trackHeights, isEmpty,
          reason: 'The cap must accompany native preparation');
      failedSources.add('https://instance.example/second.dash?local=true');
      video.switchVideo(_video('second')
          .copyWith(dashUrl: 'https://instance.example/second.dash'));
      await _flush();
      expect(sources.last, endsWith('second-480.mp4'));
      expect(initialDashHeights, [480, 480, null]);
      expect(settings.state.lastVideoQuality, 480);
    } finally {
      await video.close();
    }
  });

  test('DASH prepares with Auto on a reused player when quality is disabled',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await settings.setUseDash(true);
    await settings.setLastVideoQuality(480);
    final video = create(_video('first')
        .copyWith(dashUrl: 'https://instance.example/first.dash'));
    addTearDown(video.close);

    await video.playVideo(false);
    final controller = video.videoController;
    expect(controller?.betterPlayerAsmsTrack?.height, 480);
    await settings.setRememberVideoQuality(false);
    video.switchVideo(_video('second')
        .copyWith(dashUrl: 'https://instance.example/second.dash'));
    await _flush();

    expect(video.videoController, same(controller));
    expect(initialDashHeights, [480, 0]);
    expect(controller?.betterPlayerAsmsTrack?.height, 0);
    expect(trackHeights, isEmpty);
    expect(settings.state.lastVideoQuality, 480);
  });

  group('Android playback startup', () {
    const nerdVpn = 'https://invidious.nerdvpn.de';
    const dashPath = '/api/manifest/dash/id/startup';
    const dashQuery = '$dashPath?local=true';
    late List<Uri> manifestRequests;

    setUp(() async {
      final platform = debugDefaultTargetPlatformOverride;
      final tv = app_main.isTv;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      app_main.isTv = false;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = platform;
        app_main.isTv = tv;
      });
      await db.deleteSetting(useDashSettingName);
      settings.emit(SettingsState.init());

      manifestRequests = [];
      service.httpClient.close();
      service = Service(httpClient: MockClient((request) async {
        manifestRequests.add(request.url);
        return http.Response('<MPD type="static"/>', 200, request: request);
      }));
    });

    Future<_VideoPlayer> createStartupVideo({
      String serverUrl = nerdVpn,
      bool liveNow = false,
      List<int> heights = const [480, 360],
      List<AdaptiveFormat>? adaptiveFormats,
    }) async {
      final server = Server(url: serverUrl);
      await db.upsertServer(server);
      await db.useServer(server);
      return create(_video('startup', heights: heights, serverUrl: serverUrl)
          .copyWith(
              dashUrl: '$serverUrl$dashPath',
              liveNow: liveNow,
              adaptiveFormats: adaptiveFormats));
    }

    AdaptiveFormat adaptive(String url, String itag, {int? height}) =>
        AdaptiveFormat(
            '500-999',
            '100000',
            '0-499',
            url,
            itag,
            height == null
                ? 'audio/mp4; codecs="mp4a.40.2"'
                : 'video/mp4; codecs="avc1.640028"',
            '1000000',
            '',
            'RECTANGULAR',
            'mp4',
            null,
            null,
            null,
            size: height == null ? null : '1280x$height');

    List<AdaptiveFormat> adaptiveFormats({bool foreignAudio = false}) => [
          adaptive('$nerdVpn/videoplayback?itag=134', '134', height: 360),
          adaptive('https://rr1.googlevideo.com/videoplayback?itag=136', '136',
              height: 720),
          adaptive(
              foreignAudio
                  ? 'https://unrelated.example/audio'
                  : '$nerdVpn/videoplayback?itag=140',
              '140'),
          adaptive('https://unrelated.example/video', '137', height: 1080),
        ];

    for (final (hasAudio, hasProgressive) in [
      (true, false),
      (false, true),
      (false, false),
    ]) {
      test(
          'blocked public DASH redirect with audio=$hasAudio and combined=$hasProgressive',
          () async {
        const origin = 'https://instance.example';
        service.httpClient.close();
        service = Service(httpClient: MockClient((request) async {
          manifestRequests.add(request.url);
          return http.Response('', 302,
              headers: {'location': 'https://media.example/manifest'});
        }));
        final video = await createStartupVideo(
            serverUrl: origin,
            heights: hasProgressive ? [360] : [],
            adaptiveFormats: [
              adaptive('$origin/videoplayback?itag=134', '134', height: 360),
              if (hasAudio) adaptive('$origin/videoplayback?itag=140', '140'),
              adaptive('https://media.example/audio', '251'),
            ]);
        addTearDown(video.close);

        await video.playVideo(false);
        await _flush();

        expect(manifestRequests, [Uri.parse('$origin$dashQuery')]);
        if (hasAudio) {
          expect(sources, ['$origin$dashQuery']);
          final manifest =
              video.videoController!.betterPlayerDataSource!.inlineDashManifest;
          expect(manifest, contains('$origin/videoplayback?itag=134'));
          expect(manifest, contains('$origin/videoplayback?itag=140'));
          expect(manifest, isNot(contains('media.example')));
        } else if (hasProgressive) {
          expect(sources, ['$origin/startup-360.mp4']);
          expect(player.state.mediaEvent.state, isNot(MediaState.error));
        } else {
          expect(sources, isEmpty);
          expect(player.state.mediaEvent.state, MediaState.error);
          expect(player.state.mediaEvent.value,
              PlaybackFailureReason.separateMediaHost);
        }
      });
    }

    test('onion API tracks provide HD without the protected browser manifest',
        () async {
      const onion = 'http://$nerdVpnOnionHost';
      service.httpClient.close();
      service = Service(httpClient: MockClient((request) async {
        manifestRequests.add(request.url);
        return http.Response('', 302,
            headers: {'location': '$nerdVpn/companion$dashQuery'},
            request: request);
      }));
      await settings.setLastVideoQuality(720);
      final video = await createStartupVideo(
          serverUrl: onion, adaptiveFormats: adaptiveFormats());
      addTearDown(video.close);

      await video.playVideo(false);
      await _flush();
      expect(manifestRequests, isEmpty);
      expect(sources, ['$onion$dashQuery']);
      final source = video.videoController!.betterPlayerDataSource!;
      expect(source.inlineDashManifest, contains('height="720"'));
      expect(
          source.inlineDashManifest,
          contains(
              '$onion/videoplayback?itag=136&amp;host=rr1.googlevideo.com'));
      expect(
          source.inlineDashManifest, contains('$onion/videoplayback?itag=140'));
      expect(source.inlineDashManifest, isNot(contains(nerdVpn)));
      expect(source.inlineDashManifest, isNot(contains('unrelated.example')));
      expect(source.useAsmsAudioTracks, isFalse);
      expect(video.videoController!.betterPlayerAsmsTracks.map((t) => t.height),
          [360, 720]);
      expect(initialDashHeights, [720]);
      expect(video.isUsingDash(), isTrue);
      expect(video.isOnionPlayback, isTrue);
    });

    for (final (live, enabled, foreignAudio) in [
      (true, true, false),
      (false, false, false),
      (false, true, true),
    ]) {
      test(
          'onion generated DASH respects live=$live enabled=$enabled foreignAudio=$foreignAudio',
          () async {
        const onion = 'http://$nerdVpnOnionHost';
        await settings.setUseDash(enabled);
        final video = await createStartupVideo(
            serverUrl: onion,
            liveNow: live,
            adaptiveFormats: adaptiveFormats(foreignAudio: foreignAudio));
        addTearDown(video.close);

        await video.playVideo(false);
        await _flush();
        expect(
            video.videoController!.betterPlayerDataSource!.inlineDashManifest,
            enabled && !live ? '<MPD type="static"/>' : isNull);
        expect(manifestRequests,
            enabled ? [Uri.parse('$onion$dashQuery')] : isEmpty);
        expect(
            sources, [enabled ? '$onion$dashQuery' : '$onion/startup-360.mp4']);
      });
    }

    test('starts progressive without probing DASH and can enable DASH',
        () async {
      final video = await createStartupVideo();
      addTearDown(video.close);

      await video.playVideo(false);
      await _flush();
      expect(sources, ['$nerdVpn/startup-360.mp4']);
      expect(manifestRequests, isEmpty);
      expect(video.isUsingDash(), isFalse);
      expect(video.getVideoTracks()[video.selectedVideoTrack()], '360p');
      expect(db.getSettings(useDashSettingName), isNull);

      video.toggleDash();
      await _flush();
      expect(sources.last, '$nerdVpn$dashQuery');
      expect(manifestRequests, [Uri.parse('$nerdVpn$dashQuery')]);
      expect(video.isUsingDash(), isTrue);
      expect(db.getSettings(useDashSettingName)?.value, 'true');
    });

    test('a failed progressive startup tries DASH before another quality',
        () async {
      failedSources.add('$nerdVpn/startup-360.mp4');
      final video = await createStartupVideo();
      addTearDown(video.close);

      await video.playVideo(false);
      await _flush();
      expect(sources, ['$nerdVpn/startup-360.mp4', '$nerdVpn$dashQuery']);
      expect(manifestRequests, [Uri.parse('$nerdVpn$dashQuery')]);
      expect(video.isUsingDash(), isTrue);
      expect(db.getSettings(useDashSettingName), isNull);
    });

    test('a remembered matching height starts at that progressive quality',
        () async {
      await settings.setLastVideoQuality(480);
      final video = await createStartupVideo();
      addTearDown(video.close);

      await video.playVideo(false);
      await _flush();
      expect(sources, ['$nerdVpn/startup-480.mp4']);
      expect(manifestRequests, isEmpty);
      expect(video.getVideoTracks()[video.selectedVideoTrack()], '480p');
      expect(settings.state.lastVideoQuality, 480);
    });

    for (final height in [0, 720]) {
      test('retains DASH for remembered quality $height without a match',
          () async {
        await settings.setLastVideoQuality(height);
        final video = await createStartupVideo();
        addTearDown(video.close);

        await video.playVideo(false);
        await _flush();
        expect(sources, ['$nerdVpn$dashQuery']);
        expect(video.isUsingDash(), isTrue);
        expect(settings.state.lastVideoQuality, height);
      });
    }

    test('retains explicitly enabled DASH', () async {
      await settings.setUseDash(true);
      final video = await createStartupVideo();
      addTearDown(video.close);

      await video.playVideo(false);
      await _flush();
      expect(sources, ['$nerdVpn$dashQuery']);
      expect(video.isUsingDash(), isTrue);
    });

    for (final serverUrl in [
      'https://invidious.dvbeckwitt.duckdns.org',
      'http://$nerdVpnOnionHost',
    ]) {
      test('keeps DASH priority on $serverUrl', () async {
        final video = await createStartupVideo(serverUrl: serverUrl);
        addTearDown(video.close);

        await video.playVideo(false);
        await _flush();
        expect(sources, ['$serverUrl$dashQuery']);
        expect(video.isUsingDash(), isTrue);
      });
    }

    test('keeps DASH priority for live NerdVPN streams', () async {
      final video = await createStartupVideo(liveNow: true);
      addTearDown(video.close);

      await video.playVideo(false);
      await _flush();
      expect(sources, ['$nerdVpn$dashQuery']);
      expect(video.isUsingDash(), isTrue);
    });

    test('onion progressive fallback shows DASH off and can retry DASH',
        () async {
      const onion = 'http://$nerdVpnOnionHost';
      failedSources.add('$onion$dashQuery');
      final video = await createStartupVideo(serverUrl: onion);
      addTearDown(video.close);

      await video.playVideo(false);
      await _flush();
      expect(sources, ['$onion$dashQuery', '$onion/startup-360.mp4']);
      expect(video.isUsingDash(), isFalse);
      expect(settings.state.useDash, isTrue,
          reason: 'A failed source must not change the saved preference');

      failedSources.clear();
      video.toggleDash();
      await _flush();
      expect(sources.last, '$onion$dashQuery');
      expect(video.isUsingDash(), isTrue);
      expect(settings.state.useDash, isTrue);
    });

    test('keeps DASH priority on TV without an in-player toggle', () async {
      app_main.isTv = true;
      final video = await createStartupVideo();
      addTearDown(video.close);

      await video.playVideo(false);
      await _flush();
      expect(sources, ['$nerdVpn$dashQuery']);
      expect(video.isUsingDash(), isTrue);
    });
  });
}
