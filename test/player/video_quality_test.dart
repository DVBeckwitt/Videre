import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/network/nerdvpn_origin.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/video_quality.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/states/tv_player_settings.dart';
import 'package:clipious/player/states/video_player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
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
  late List<int> trackHeights;
  late Set<String> failedSources;
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
    trackHeights = [];
    failedSources = {};
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
        final uri = call.arguments['dataSource']['uri'] as String;
        sources.add(uri);
        if (failedSources.contains(uri)) {
          throw PlatformException(code: 'VideoError');
        }
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
    await settings.setUseDash(true);
    await settings.setLastVideoQuality(480);
    final video = create(_video('first')
        .copyWith(dashUrl: 'https://instance.example/first.dash'));
    try {
      await video.playVideo(false);
      await _flush();
      expect(sources.first, 'https://instance.example/first.dash?local=true');
      expect(trackHeights.last, 480);
      failedSources.add('https://instance.example/second.dash?local=true');
      video.switchVideo(_video('second')
          .copyWith(dashUrl: 'https://instance.example/second.dash'));
      await _flush();
      expect(sources.last, endsWith('second-480.mp4'));
      expect(settings.state.lastVideoQuality, 480);
    } finally {
      await video.close();
    }
  });

  group('NerdVPN automatic startup', () {
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
    }) async {
      final server = Server(url: serverUrl);
      await db.upsertServer(server);
      await db.useServer(server);
      return create(_video('startup', heights: [480, 360], serverUrl: serverUrl)
          .copyWith(dashUrl: '$serverUrl$dashPath', liveNow: liveNow));
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
