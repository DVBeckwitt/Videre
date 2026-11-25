import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/download_playback_provenance.dart';
import 'package:clipious/downloads/services/download_playback_source.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/media_handler.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/nerdvpn_access.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/backend_recovery.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/states/video_player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/format_stream.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

const _staticDashManifest = '''<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static"
 mediaPresentationDuration="PT60S" minBufferTime="PT1.5S">
 <Period>
  <AdaptationSet mimeType="video/mp4">
   <Representation id="137" width="1920" height="1080" bandwidth="1000000"
    frameRate="30" codecs="avc1.640028">
    <BaseURL>../../../videoplayback?itag=137&amp;signature=fixture%2Bvideo</BaseURL>
    <SegmentBase indexRange="100-200"><Initialization range="0-99"/></SegmentBase>
   </Representation>
  </AdaptationSet>
  <AdaptationSet mimeType="audio/mp4" lang="en" label="English">
   <Representation id="140" bandwidth="128000" codecs="mp4a.40.2">
    <BaseURL>../../../videoplayback?itag=140&amp;signature=fixture%2Baudio</BaseURL>
    <SegmentBase indexRange="100-200"><Initialization range="0-99"/></SegmentBase>
   </Representation>
  </AdaptationSet>
 </Period>
</MPD>''';

class _VideoWithoutAutostart extends VideoPlayerCubit {
  _VideoWithoutAutostart(super.initialState, super.player, super.settings);

  @override
  void onInit() {}
}

class _RecoveryPlayer extends TestPlayerCubit {
  _RecoveryPlayer(super.initialState, super.settings);

  final refreshRequests = <Video>[];
  final refreshResults = <Video>[];
  final refreshStarted = Completer<void>();
  Completer<void>? heldRefresh;
  Object? refreshError;
  bool interrupted = false;

  @override
  bool get playbackInterrupted => interrupted;

  @override
  bool get shouldStartPlayback => super.shouldStartPlayback && !interrupted;

  @override
  Future<Video?> refreshCurrentPlayback(Video video,
      {required bool Function() isCurrent}) async {
    refreshRequests.add(video);
    if (!refreshStarted.isCompleted) refreshStarted.complete();
    if (heldRefresh != null) await heldRefresh!.future;
    if (!isCurrent()) throw StateError('Playback changed');
    if (refreshError != null) throw refreshError!;
    if (refreshResults.isEmpty) return null;
    final replacement = refreshResults.removeAt(0);
    emit(state.copyWith(currentlyPlaying: replacement));
    return replacement;
  }
}

class _RetryService extends Service {
  _RetryService({super.httpClient});
  final retriedVideos = <Video>[];
  final visited = <String>[];
  Completer<void>? heldRetry;
  Completer<void>? heldManual;
  final manualStarted = Completer<void>();
  final metadataStarted = Completer<void>();
  Completer<void>? heldMetadata;
  Video? metadataResult;
  Object? metadataError;
  int metadataCalls = 0;
  int qualityMetadataCalls = 0;
  Completer<void>? heldQualityMetadata;
  Video? qualityMetadata;
  Object? qualityMetadataError;

  @override
  Future<Video> refreshPlaybackVideo(Video video,
      {required bool Function() isCurrent}) async {
    qualityMetadataCalls++;
    if (heldQualityMetadata != null) await heldQualityMetadata!.future;
    if (!isCurrent()) throw StateError('Playback changed');
    if (qualityMetadataError != null) throw qualityMetadataError!;
    return qualityMetadata ?? (throw StateError('No quality metadata set'));
  }

  @override
  Future<Video> getVideo(String videoId,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest,
      VideoLoadObserver? loadObserver}) async {
    metadataCalls++;
    if (!metadataStarted.isCompleted) metadataStarted.complete();
    if (heldMetadata != null) await heldMetadata!.future;
    if (metadataError != null) throw metadataError!;
    return metadataResult ?? (throw StateError('No metadata response set'));
  }

  @override
  Future<Video> getVideoForBackend(String videoId, BackendPlayback request,
      {void Function(BackendPlayback request)? onBackendRequest,
      bool Function()? isCurrent}) async {
    onBackendRequest?.call(request);
    if (!manualStarted.isCompleted) manualStarted.complete();
    if (heldManual != null) await heldManual!.future;
    return _video(videoId, request);
  }

  @override
  Future<List<SponsorSegment>> getSponsorSegments(
          String videoId, List<SponsorSegmentType> categories) async =>
      [];
  int? sourceCount;

  @override
  Future<Video?> retryVideoBackend(Video video,
      {required bool Function() isCurrent,
      void Function(BackendPlayback request)? onRetry}) async {
    retriedVideos.add(video);
    if (!isCurrent()) return null;
    final next = video.backendPlayback?.next();
    if (next == null) return null;
    visited.add(next.label);
    onRetry?.call(next);
    if (heldRetry != null) await heldRetry!.future;
    if (!isCurrent()) return null;
    return _video(video.videoId, next, sources: sourceCount ?? 1);
  }
}

Video _video(String id, BackendPlayback? playback, {int sources = 1}) {
  final backend = playback == null
      ? 'default'
      : playback.server.backendSelector?.selectedValue(playback.server) ??
          'default';
  return Video(
      videoId: id,
      lengthSeconds: 60,
      backendPlayback: playback,
      formatStreams: [
        for (var i = sources; i > 0; i--)
          FormatStream('https://instance.example/$id-$backend-$i.mp4', '$i',
              'video/mp4', 'medium', 'mp4', 'h264', '${i}p', '${i}p', '640x360')
      ]);
}

Future<void> _flush() async {
  for (var i = 0; i < 20; i++) {
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
  late _RecoveryPlayer player;
  late _RetryService retryService;
  late Service previousService;
  late Server preferred;
  late List<Map<dynamic, dynamic>> sources;
  late Map<String, bool> failedUrls;
  late Map<String, Completer<void>> heldSources;
  late Map<int, Completer<void>> heldSeeks;
  late List<int> seeks;
  late List<double> speeds;
  late List<double> pitches;
  late int playCalls;
  late bool rejectPlay;
  late bool nativePlaying;
  late int nativePosition;

  Future<void> error(
          {required bool retryable, bool mediaOriginBlocked = false}) =>
      messenger.handlePlatformMessage(
          events.name,
          const StandardMethodCodec().encodeErrorEnvelope(
              code: 'VideoError',
              message: 'Playback failed',
              details: {
                'backendRetryable': retryable,
                'mediaOriginBlocked': mediaOriginBlocked,
              }),
          (_) {});

  setUp(() async {
    previousService = service;
    service = retryService = _RetryService();
    db = await SembastSqfDb.createInMemory();
    final selector = BackendSelector(
        'backend',
        const [
          BackendOption('a', 'Backend A'),
          BackendOption('b', 'Backend B'),
          BackendOption('c', 'Backend C'),
        ],
        automaticFallback: true);
    preferred = selector.withSelection(
        Server(url: 'https://instance.example', backendSelector: selector),
        'a');
    await db.upsertServer(preferred);
    await db.useServer(preferred);
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    await settings.setUseDash(false);
    player = _RecoveryPlayer(PlayerState.init(null), settings);
    sources = [];
    failedUrls = {};
    heldSources = {};
    heldSeeks = {};
    seeks = [];
    speeds = [];
    pitches = [];
    playCalls = 0;
    rejectPlay = false;
    nativePlaying = false;
    nativePosition = 0;
    messenger.setMockMessageHandler(
        wakelock,
        (_) async =>
            const StandardMessageCodec().encodeMessage(<Object?>[null]));
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'create':
          return {'textureId': 1};
        case 'position':
          return nativePosition;
        case 'seekTo':
          nativePosition = call.arguments['location'] as int;
          seeks.add(nativePosition);
          final held = heldSeeks.remove(nativePosition);
          if (held != null) await held.future;
        case 'setPitch':
          pitches.add((call.arguments['pitch'] as num).toDouble());
        case 'setSpeed':
          speeds.add((call.arguments['speed'] as num).toDouble());
        case 'play':
          if (rejectPlay) throw PlatformException(code: 'PlayUnavailable');
          playCalls++;
          nativePlaying = true;
        case 'pause':
          nativePlaying = false;
        case 'setDataSource':
          final source = Map<dynamic, dynamic>.of(call.arguments['dataSource']);
          sources.add(source);
          final held = heldSources[source['uri']];
          if (held != null) await held.future;
          final retryable = failedUrls[source['uri']];
          if (retryable != null) {
            await error(retryable: retryable);
          } else {
            final initialPosition = source['initialPositionMs'] as int?;
            if (initialPosition != null) nativePosition = initialPosition;
            await messenger.handlePlatformMessage(
                events.name,
                const StandardMethodCodec().encodeSuccessEnvelope({
                  'event': 'initialized',
                  'key': source['key'],
                  'duration': 60000,
                  'width': 640,
                  'height': 360,
                  'isLiveStream': false,
                  if (initialPosition != null) 'position': initialPosition,
                }),
                (_) {});
          }
      }
      return null;
    });
  });

  tearDown(() async {
    EasyThrottle.cancel('video-player-progress');
    EasyThrottle.cancel('video-buffering');
    await _flush();
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    retryService.httpClient.close();
    service = previousService;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(events, null);
    messenger.setMockMessageHandler(wakelock, null);
  });

  _VideoWithoutAutostart cubit({int count = 1, bool session = true}) {
    final current = _video('video', session ? BackendPlayback(preferred) : null,
        sources: count);
    player.emit(player.state.copyWith(currentlyPlaying: current));
    return _VideoWithoutAutostart(
        VideoPlayerState(
            video: current,
            colors: ColorScheme.fromSeed(seedColor: Colors.blue),
            overFlowTextColor: Colors.white,
            key: GlobalKey()),
        player,
        settings);
  }

  Future<({Video current, Video remote, String uri})> savedVideo(
      {bool metadataFree = false, bool document = false}) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final documents =
        await Directory.systemTemp.createTemp('videre-video-saved-source-');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documents.path);
    addTearDown(() async {
      messenger.setMockMethodCallHandler(pathProvider, null);
      await documents.delete(recursive: true);
    });
    final audio = AdaptiveFormat(
        null,
        '128000',
        null,
        'https://instance.example/videoplayback?itag=251&sig=audio',
        '251',
        'audio/webm; codecs="opus"',
        '12345',
        '1700000000000',
        'RECTANGULAR',
        'webm',
        'opus',
        null,
        null,
        audioTrack: const AudioTrack(
            id: 'en.1', displayName: 'English', audioIsDefault: true));
    final rendition = AdaptiveFormat(
        null,
        '1000000',
        null,
        'https://instance.example/videoplayback?itag=248&sig=video',
        '248',
        'video/webm; codecs="vp9"',
        '54321',
        '1700000000000',
        'RECTANGULAR',
        'webm',
        'vp9',
        '1080p',
        '1080');
    final remote = _video('video', BackendPlayback(preferred))
        .copyWith(adaptiveFormats: [audio, rendition]);
    final proof = DownloadPlaybackProvenance.create(
        video: remote,
        server: preferred,
        audioOnly: false,
        container: DownloadContainer.webm,
        audio: audio,
        videoFormat: rendition,
        byteLength: 32100,
        sha256: 'a' * 64)!;
    const tree = 'content://documents/tree/primary%3AVidere';
    final download = DownloadedVideo(
        videoId: 'video',
        title: 'Saved video',
        profileId: preferred.profileId,
        accountId: preferred.accountId,
        lengthSeconds: 60,
        quality: '1080p',
        downloadComplete: true,
        container: DownloadContainer.webm,
        playbackProvenance: proof,
        storageUri:
            document ? '$tree/document/primary%3AVidere%2Fvideo.webm' : null,
        folderUri: document ? tree : null);
    await db.upsertDownload(download);
    final path = await download.effectivePath;
    final uri = document ? path : Uri.file(path).toString();
    final current = metadataFree
        ? (await prepareDownloadedPlaybackVideo(
            database: db,
            video: const Video(videoId: 'video', queueEntryId: 'saved-entry'),
            server: preferred,
            audioOnly: false,
            isCurrent: () => true))!
        : remote;
    return (current: current, remote: remote, uri: uri);
  }

  _VideoWithoutAutostart savedCubit(Video current) {
    player.emit(player.state.copyWith(currentlyPlaying: current));
    return _VideoWithoutAutostart(
        VideoPlayerState(
            video: current,
            colors: ColorScheme.fromSeed(seedColor: Colors.blue),
            overFlowTextColor: Colors.white,
            key: GlobalKey()),
        player,
        settings);
  }

  Video onlineQualities(Video remote) => remote.copyWith(
        dashUrl: 'https://instance.example/manifest.mpd',
        formatStreams: [
          for (final height in [360, 720])
            FormatStream(
                'https://instance.example/video-$height.mp4',
                '$height',
                'video/mp4',
                'medium',
                'mp4',
                'h264',
                '${height}p',
                '${height}p',
                '1280x$height'),
        ],
        adaptiveFormats: [
          ...remote.adaptiveFormats!,
          AdaptiveFormat.fromJson({
            ...remote.adaptiveFormats!.last.toJson(),
            'qualityLabel': '1440p',
            'resolution': '1440',
            'itag': '271',
            'url':
                'https://instance.example/videoplayback?itag=271&sig=fixture',
          }),
        ],
      );

  test(
      'saved quality metadata is optional and never replaces the local decoder',
      () async {
    final saved = await savedVideo(metadataFree: true);
    final video = savedCubit(saved.current);
    final held = retryService.heldQualityMetadata = Completer<void>();
    retryService.qualityMetadata = onlineQualities(saved.remote);
    try {
      await video.playVideo(false, startAt: const Duration(seconds: 12));
      await _flush();
      expect(video.getVideoTracks(), ['1080p']);
      expect(retryService.qualityMetadataCalls, 0);
      final preparing = video.prepareVideoTracks();
      final duplicate = video.prepareVideoTracks();
      await _flush();
      expect(retryService.qualityMetadataCalls, 1);
      expect(sources.single['uri'], saved.uri);
      expect(nativePlaying, isTrue);
      held.complete();
      expect(await preparing, isTrue);
      expect(await duplicate, isTrue);
      expect(video.getVideoTracks(), ['1440p', '1080p', '720p', '360p']);
      expect(sources, hasLength(1));
      expect(player.refreshRequests, isEmpty);
      expect(video.state.video, same(saved.current));
      expect(player.state.currentlyPlaying, same(saved.current));
      await video.selectVideoTrack(video.getVideoTracks().indexOf('1080p'));
      expect(sources, hasLength(1),
          reason: 'Choosing the current saved rendition is a no-op');
    } finally {
      if (!held.isCompleted) held.complete();
      await video.close();
    }
  });

  test(
      'saved quality selection uses admitted network sources with latest paused seek',
      () async {
    final saved = await savedVideo(metadataFree: true);
    final video = savedCubit(saved.current);
    retryService.qualityMetadata = onlineQualities(saved.remote);
    try {
      await video.playVideo(false, startAt: const Duration(seconds: 12));
      await _flush();
      expect(await video.prepareVideoTracks(), isTrue);
      video.pause();
      await video.seek(const Duration(seconds: 23));
      final previousPlays = playCalls;
      await video.selectVideoTrack(video.getVideoTracks().indexOf('720p'));
      await _flush();
      expect(sources.map((source) => source['uri']),
          [saved.uri, 'https://instance.example/video-720.mp4']);
      expect(sources.last['initialPositionMs'], 23000);
      expect((sources.last['playbackCache'] as Map?)?['download'], isNull);
      expect(nativePlaying, isFalse);
      expect(playCalls, previousPlays);
      expect(player.refreshRequests, isEmpty);
      expect(player.state.currentlyPlaying, same(saved.current));
    } finally {
      await video.close();
    }
  });

  test(
      'failed online quality restores the healthy saved rendition without a refresh loop',
      () async {
    final saved = await savedVideo(metadataFree: true);
    final video = savedCubit(saved.current);
    retryService.qualityMetadata = onlineQualities(saved.remote);
    failedUrls['https://instance.example/video-720.mp4'] = false;
    var failures = 0;
    try {
      await video.playVideo(false, startAt: const Duration(seconds: 12));
      await _flush();
      expect(await video.prepareVideoTracks(), isTrue);
      video.pause();
      await video.seek(const Duration(seconds: 23));
      await video.selectVideoTrack(video.getVideoTracks().indexOf('720p'),
          onQualityFailure: () => failures++);
      await _flush();
      expect(sources.map((source) => source['uri']),
          [saved.uri, 'https://instance.example/video-720.mp4', saved.uri]);
      expect(sources.last['initialPositionMs'], 23000);
      expect((sources.last['playbackCache'] as Map)['download'], isNotNull);
      expect(nativePlaying, isFalse);
      expect(failures, 1);
      expect(player.state.mediaEvent.state, isNot(MediaState.error));
      expect(player.refreshRequests, isEmpty);
      expect(retryService.qualityMetadataCalls, 1);
    } finally {
      await video.close();
    }
  });

  for (final admitted in [true, false]) {
    test(
        'online quality playback failure ${admitted ? 'restores saved playback' : 'cannot restore across changed credentials'}',
        () async {
      final saved = await savedVideo(metadataFree: true);
      final video = savedCubit(saved.current);
      retryService.qualityMetadata = onlineQualities(saved.remote);
      var failures = 0;
      try {
        await video.playVideo(false, startAt: const Duration(seconds: 12));
        await _flush();
        expect(await video.prepareVideoTracks(), isTrue);
        await video.selectVideoTrack(video.getVideoTracks().indexOf('720p'),
            onQualityFailure: () => failures++);
        await _flush();
        expect(sources, hasLength(2));
        video.pause();
        await video.seek(const Duration(seconds: 31));
        if (!admitted) {
          await db.upsertServer(preferred
              .copyWith(customHeaders: {'X-Account': 'changed'}, inUse: true));
        }
        await error(retryable: false);
        await _flush();
        expect(sources, hasLength(admitted ? 3 : 2));
        if (admitted) {
          expect(sources.last['uri'], saved.uri);
          expect(sources.last['initialPositionMs'], 31000);
          expect(nativePlaying, isFalse);
          expect(failures, 1);
          expect(player.state.mediaEvent.state, isNot(MediaState.error));
        } else {
          expect(failures, 0);
          expect(player.state.mediaEvent.state, MediaState.error);
        }
        expect(player.refreshRequests, isEmpty);
        expect(retryService.qualityMetadataCalls, 1);
      } finally {
        await video.close();
      }
    });
  }

  test(
      'saved quality metadata failure keeps the local source playable and can retry',
      () async {
    final saved = await savedVideo(metadataFree: true);
    final video = savedCubit(saved.current);
    retryService.qualityMetadataError = const SocketException('Offline');
    try {
      await video.playVideo(false, startAt: const Duration(seconds: 12));
      await _flush();
      expect(await video.prepareVideoTracks(), isFalse);
      expect(sources.single['uri'], saved.uri);
      expect(video.getVideoTracks(), ['1080p']);
      expect(nativePlaying, isTrue);
      expect(player.state.mediaEvent.state, isNot(MediaState.error));
      retryService.qualityMetadataError = null;
      retryService.qualityMetadata = onlineQualities(saved.remote);
      expect(await video.prepareVideoTracks(), isTrue);
      expect(retryService.qualityMetadataCalls, 2);
    } finally {
      await video.close();
    }
  });

  for (final change in ['credentials', 'proxy', 'playback']) {
    test('late saved quality metadata cannot outlive $change changes',
        () async {
      final saved = await savedVideo(metadataFree: true);
      final video = savedCubit(saved.current);
      final held = retryService.heldQualityMetadata = Completer<void>();
      retryService.qualityMetadata = onlineQualities(saved.remote);
      try {
        await video.playVideo(false);
        await _flush();
        final preparing = video.prepareVideoTracks();
        await _flush();
        if (change == 'credentials') {
          await db.upsertServer(preferred
              .copyWith(customHeaders: {'X-Account': 'changed'}, inUse: true));
        } else if (change == 'proxy') {
          await NetworkProxy.instance
              .initialize(saved: '{}', configureNative: false);
        } else {
          await video.stopForProxyChange();
        }
        held.complete();
        expect(await preparing, isFalse);
        expect(video.getVideoTracks(), isNot(contains('1440p')));
        expect(sources, hasLength(1));
      } finally {
        if (!held.isCompleted) held.complete();
        await video.close();
      }
    });
  }

  test(
      'prepared saved quality cannot select a source after account admission changes',
      () async {
    final saved = await savedVideo(metadataFree: true);
    final video = savedCubit(saved.current);
    retryService.qualityMetadata = onlineQualities(saved.remote);
    try {
      await video.playVideo(false);
      await _flush();
      expect(await video.prepareVideoTracks(), isTrue);
      await db.upsertServer(preferred
          .copyWith(customHeaders: {'X-Account': 'changed'}, inUse: true));
      await video.selectVideoTrack(video.getVideoTracks().indexOf('720p'));
      await _flush();
      expect(sources.single['uri'], saved.uri);
    } finally {
      await video.close();
    }
  });

  for (final toggle in [false, true]) {
    test(
        'saved video can ${toggle ? 'enable DASH' : 'select an adaptive quality'} without losing paused position',
        () async {
      final saved = await savedVideo(metadataFree: true);
      final video = savedCubit(saved.current);
      retryService.httpClient.close();
      service = retryService = _RetryService(
          httpClient:
              MockClient((_) async => http.Response(_staticDashManifest, 200)))
        ..qualityMetadata = onlineQualities(saved.remote);
      try {
        await video.playVideo(false, startAt: const Duration(seconds: 12));
        await _flush();
        expect(await video.prepareVideoTracks(), isTrue);
        video.pause();
        await video.seek(const Duration(seconds: 26));
        if (toggle) {
          await video.toggleDash();
        } else {
          await video.selectVideoTrack(video.getVideoTracks().indexOf('1440p'));
        }
        await _flush();
        expect(sources, hasLength(2));
        expect(sources.last['formatHint'], 'dash');
        expect(sources.last['initialPositionMs'], 26000);
        if (!toggle) expect(sources.last['initialDashHeight'], 1440);
        expect(nativePlaying, isFalse);
        expect(player.refreshRequests, isEmpty);
      } finally {
        await video.close();
      }
    });
  }

  for (final status in [401, 403, 429]) {
    test('DASH $status refusal restores only the admitted saved rendition',
        () async {
      final saved = await savedVideo(metadataFree: true);
      final video = savedCubit(saved.current);
      var requests = 0;
      retryService.httpClient.close();
      service = retryService = _RetryService(httpClient: MockClient((_) async {
        requests++;
        return http.Response('Refused', status);
      }))
        ..qualityMetadata = onlineQualities(saved.remote);
      var failures = 0;
      try {
        await video.playVideo(false, startAt: const Duration(seconds: 12));
        await _flush();
        expect(await video.prepareVideoTracks(), isTrue);
        video.pause();
        await video.seek(const Duration(seconds: 27));
        await video.selectVideoTrack(video.getVideoTracks().indexOf('1440p'),
            onQualityFailure: () => failures++);
        await _flush();
        expect(sources.map((source) => source['uri']), [saved.uri, saved.uri]);
        expect(sources.last['initialPositionMs'], 27000);
        expect(nativePlaying, isFalse);
        expect(failures, 1);
        expect(requests, 1);
        expect(player.refreshRequests, isEmpty);
        expect(retryService.retriedVideos, isEmpty);
        expect(player.state.mediaEvent.state, isNot(MediaState.error));
      } finally {
        await video.close();
      }
    });
  }

  test(
      'failed saved rollback after a DASH refusal cannot make another network request',
      () async {
    final saved = await savedVideo(metadataFree: true);
    final video = savedCubit(saved.current);
    var requests = 0;
    retryService.httpClient.close();
    service = retryService = _RetryService(httpClient: MockClient((_) async {
      requests++;
      return http.Response('Refused', 403);
    }))
      ..qualityMetadata = onlineQualities(saved.remote);
    try {
      await video.playVideo(false);
      await _flush();
      expect(await video.prepareVideoTracks(), isTrue);
      failedUrls[saved.uri] = true;
      await video.selectVideoTrack(video.getVideoTracks().indexOf('1440p'));
      await _flush();
      expect(sources.map((source) => source['uri']), [saved.uri, saved.uri]);
      expect(requests, 1);
      expect(player.refreshRequests, isEmpty);
      expect(retryService.retriedVideos, isEmpty);
      expect(player.state.mediaEvent.state, MediaState.error);
    } finally {
      await video.close();
    }
  });

  for (final change in ['generation', 'credentials']) {
    test(
        'late DASH refusal cannot restore saved playback after $change changes',
        () async {
      final saved = await savedVideo(metadataFree: true);
      final video = savedCubit(saved.current);
      final response = Completer<http.Response>();
      var requests = 0;
      retryService.httpClient.close();
      service = retryService = _RetryService(httpClient: MockClient((_) {
        requests++;
        return response.future;
      }))
        ..qualityMetadata = onlineQualities(saved.remote);
      var failures = 0;
      try {
        await video.playVideo(false);
        await _flush();
        expect(await video.prepareVideoTracks(), isTrue);
        await video.selectVideoTrack(video.getVideoTracks().indexOf('1440p'),
            onQualityFailure: () => failures++);
        await _flush();
        expect(requests, 1);
        if (change == 'generation') {
          await video.stopForProxyChange();
        } else {
          await db.upsertServer(preferred
              .copyWith(customHeaders: {'X-Account': 'changed'}, inUse: true));
        }
        response.complete(http.Response('Refused', 403));
        await _flush();
        expect(sources.single['uri'], saved.uri);
        expect(requests, 1);
        expect(failures, 0);
        expect(player.refreshRequests, isEmpty);
        expect(retryService.retriedVideos, isEmpty);
        expect(
            player.state.mediaEvent.state,
            change == 'generation'
                ? isNot(MediaState.error)
                : MediaState.error);
      } finally {
        if (!response.isCompleted) {
          response.complete(http.Response('Refused', 403));
        }
        await video.close();
      }
    });
  }

  for (final document in [false, true]) {
    test(
        'saved ${document ? 'SAF' : 'private'} video plays the whole local mux first',
        () async {
      final saved = await savedVideo(document: document);
      final video = savedCubit(saved.current);
      try {
        await video.playVideo(false, startAt: const Duration(seconds: 12));
        await _flush();
        expect(sources, hasLength(1));
        expect(sources.single['uri'], saved.uri);
        expect(sources.single['formatHint'], 'other');
        expect(sources.single['initialPositionMs'], 12000);
        final cache = sources.single['playbackCache'] as Map;
        final descriptor = cache['download'] as Map;
        expect(descriptor['uri'], saved.uri);
        expect(descriptor['remoteUri'], saved.remote.adaptiveFormats!.last.url);
        expect(descriptor['byteLength'], 32100);
        expect(descriptor['sha256'], 'a' * 64);
        expect(saved.uri, startsWith(document ? 'content:' : 'file:'));
        expect(nativePosition, 12000);
        expect(nativePlaying, isTrue);
        expect(retryService.metadataCalls, 0);
        expect(player.refreshRequests, isEmpty);
        expect(retryService.retriedVideos, isEmpty);
      } finally {
        await video.close();
      }
    });
  }

  test('saved-only video needs no remote metadata when its local mux opens',
      () async {
    final saved = await savedVideo(metadataFree: true);
    final video = savedCubit(saved.current);
    try {
      await video.playVideo(false, startAt: const Duration(seconds: 16));
      await _flush();
      expect(sources, hasLength(1));
      expect(sources.single['uri'], saved.uri);
      expect(sources.single['formatHint'], 'other');
      expect(sources.single['initialPositionMs'], 16000);
      final cache = sources.single['playbackCache'] as Map;
      expect(cache['resources'], isEmpty);
      expect((cache['download'] as Map).containsKey('remoteUri'), isFalse);
      expect(saved.current.adaptiveFormats, isNull);
      expect(saved.current.formatStreams, isNull);
      expect(retryService.metadataCalls, 0);
      expect(player.refreshRequests, isEmpty);
      expect(nativePlaying, isTrue);
    } finally {
      await video.close();
    }
  });

  test('unavailable saved mux falls back to the existing remote source',
      () async {
    final saved = await savedVideo();
    failedUrls[saved.uri] = true;
    final video = savedCubit(saved.current);
    try {
      await video.playVideo(false, startAt: const Duration(seconds: 12));
      await _flush();
      expect(sources.map((source) => source['uri']),
          [saved.uri, saved.remote.formatStreams!.first.url]);
      expect(sources.every((source) => source['initialPositionMs'] == 12000),
          isTrue);
      expect((sources.first['playbackCache'] as Map)['download'], isNotNull);
      expect((sources.last['playbackCache'] as Map?)?['download'], isNull);
      expect(retryService.metadataCalls, 0);
      expect(player.refreshRequests, isEmpty);
      expect(retryService.retriedVideos, isEmpty);
      expect(nativePosition, 12000);
      expect(nativePlaying, isTrue);
    } finally {
      await video.close();
    }
  });

  test(
      'unavailable saved-only video lazily refreshes an admitted online source',
      () async {
    final saved = await savedVideo(metadataFree: true);
    failedUrls[saved.uri] = true;
    final refreshed = saved.remote;
    player.refreshResults.add(refreshed);
    final video = savedCubit(saved.current);
    try {
      await video.playVideo(false, startAt: const Duration(seconds: 18));
      await _flush();
      expect(player.refreshRequests, [saved.current]);
      expect(sources.map((source) => source['uri']),
          [saved.uri, refreshed.formatStreams!.first.url]);
      expect(sources.every((source) => source['initialPositionMs'] == 18000),
          isTrue);
      expect(video.state.video, same(refreshed));
      expect(player.state.currentlyPlaying, same(refreshed));
      expect(retryService.retriedVideos, isEmpty);
      expect(nativePosition, 18000);
      expect(nativePlaying, isTrue);
    } finally {
      await video.close();
    }
  });

  test('pause during saved-only fallback preserves the latest seek and intent',
      () async {
    final saved = await savedVideo(metadataFree: true);
    failedUrls[saved.uri] = true;
    final refreshed = saved.remote;
    player.refreshResults.add(refreshed);
    final held = player.heldRefresh = Completer<void>();
    final video = savedCubit(saved.current);
    final loading =
        video.playVideo(false, startAt: const Duration(seconds: 12));
    try {
      await player.refreshStarted.future.timeout(const Duration(seconds: 5));
      expect(player.refreshRequests, [saved.current]);
      video.pause();
      await video.seek(const Duration(seconds: 21));
      held.complete();
      await loading;
      await _flush();
      expect(sources.map((source) => source['uri']),
          [saved.uri, refreshed.formatStreams!.first.url]);
      expect(sources.last['initialPositionMs'], 21000);
      expect(nativePosition, 21000);
      expect(nativePlaying, isFalse);
      expect(playCalls, 0);
      expect(retryService.retriedVideos, isEmpty);
    } finally {
      if (!held.isCompleted) held.complete();
      await loading;
      await video.close();
    }
  });

  for (final change in ['headers', 'instance', 'proxy']) {
    test('direct video admission rejects a stale $change snapshot', () async {
      final video = cubit();
      try {
        if (change == 'proxy') {
          await NetworkProxy.instance
              .initialize(saved: '{}', configureNative: false);
        } else {
          final updated = change == 'instance'
              ? preferred.copyWith(url: 'https://other.example')
              : preferred
                  .copyWith(customHeaders: {'Cookie': 'backend=a; login=new'});
          await db.upsertServer(updated);
          await db.useServer(updated);
        }
        await video.playVideo(false);
        await _flush();
        expect(sources, isEmpty);
        expect(retryService.retriedVideos, isEmpty);
        expect(player.state.mediaEvent.state, MediaState.error);
      } finally {
        await video.close();
      }
    });
  }

  test('ordinary startup still plays without requesting another backend',
      () async {
    final video = cubit();
    try {
      await video.playVideo(false);
      await _flush();
      expect(nativePlaying, isTrue);
      expect(playCalls, 1);
      expect(retryService.retriedVideos, isEmpty);
      expect(player.state.requestedBackend?.label, 'Backend A');
    } finally {
      await video.close();
    }
  });

  test('Android VOD starts at resume and a reused source can start at zero',
      () async {
    final video = cubit();
    try {
      await video.playVideo(false, startAt: const Duration(seconds: 12));
      expect(sources.single['initialPositionMs'], 12000);
      expect(video.position(), const Duration(seconds: 12));
      expect(player.state.position, const Duration(seconds: 12));
      expect(seeks, isEmpty);

      video.switchVideo(_video('replacement', BackendPlayback(preferred)));
      await _flush();
      expect(sources.last['initialPositionMs'], 0);
      expect(video.position(), Duration.zero);
      expect(seeks, isEmpty);
    } finally {
      await video.close();
    }
  });

  test('early seeks wait for initialization and override the native start',
      () async {
    final held = heldSources['https://instance.example/video-a-1.mp4'] =
        Completer<void>();
    final video = cubit();
    final loading =
        video.playVideo(false, startAt: const Duration(seconds: 12));
    try {
      await _flush();
      await video.seek(const Duration(seconds: 10));
      await video.seek(const Duration(seconds: 25));
      video.pause();
      expect(sources.single['initialPositionMs'], 12000);
      expect(seeks, isEmpty);
      held.complete();
      await loading;
      await _flush();
      expect(seeks, [25000]);
      expect(nativePlaying, isFalse);
    } finally {
      if (!held.isCompleted) held.complete();
      await loading;
      await video.close();
    }
  });

  test('new video discards a seek queued during backend recovery', () async {
    final video = cubit();
    final held = retryService.heldRetry = Completer<void>();
    try {
      await video.playVideo(false);
      await error(retryable: true);
      await _flush();
      await video.seek(const Duration(seconds: 25));
      video.switchVideo(_video('replacement', BackendPlayback(preferred)));
      await _flush();
      held.complete();
      await _flush();
      expect(
          sources.last['uri'], 'https://instance.example/replacement-a-1.mp4');
      expect(seeks, isNot(contains(25000)));
    } finally {
      if (!held.isCompleted) held.complete();
      await video.close();
    }
  });

  test('native play failure stays terminal without an unhandled setup future',
      () async {
    rejectPlay = true;
    final video = cubit();
    try {
      await video.playVideo(false);
      await _flush();
      expect(retryService.retriedVideos, isEmpty);
      expect(player.state.mediaEvent.state, MediaState.error);
    } finally {
      await video.close();
    }
  });

  test('exhausts formats before retrying with the effective server headers',
      () async {
    failedUrls['https://instance.example/video-a-1.mp4'] = true;
    failedUrls['https://instance.example/video-a-2.mp4'] = true;
    final video = cubit(count: 2);
    try {
      await video.playVideo(false);
      await _flush();
      expect(sources.map((source) => source['uri']), [
        'https://instance.example/video-a-1.mp4',
        'https://instance.example/video-a-2.mp4',
        'https://instance.example/video-b-1.mp4',
      ]);
      expect(retryService.visited, ['Backend B']);
      expect((sources.last['headers'] as Map)['Cookie'], 'backend=b');
      expect((await db.getCurrentlySelectedServer()).customHeaders,
          preferred.customHeaders);
      expect(nativePlaying, isTrue);
    } finally {
      await video.close();
    }
  });

  test('recovered metadata survives a decoder remount', () async {
    failedUrls['https://instance.example/video-a-1.mp4'] = true;
    final video = cubit();
    _VideoWithoutAutostart? replacement;
    try {
      await video.playVideo(false);
      await _flush();
      expect(retryService.visited, ['Backend B']);
      final recovered = video.state.video!;
      expect(player.state.currentlyPlaying, same(recovered));
      await video.close();
      player.switchAudio(true);
      player.switchAudio(false);
      replacement = _VideoWithoutAutostart(
          VideoPlayerState(
              video: player.state.currentlyPlaying,
              colors: ColorScheme.fromSeed(seedColor: Colors.blue),
              overFlowTextColor: Colors.white,
              key: GlobalKey()),
          player,
          settings);
      await replacement.playVideo(false);
      await _flush();
      expect(sources.last['uri'], 'https://instance.example/video-b-1.mp4');
      expect(retryService.visited, ['Backend B']);
    } finally {
      if (!video.isClosed) await video.close();
      await replacement?.close();
    }
  });

  test('empty native buffering ranges reset progress without throwing',
      () async {
    final video = cubit();
    try {
      await video.playVideo(false);
      await _flush();
      for (final ranges in <List<List<int>>>[
        [
          [0, 20000],
          [0, 10000]
        ],
        [],
      ]) {
        EasyThrottle.cancel('video-buffering');
        await messenger.handlePlatformMessage(
            events.name,
            const StandardMethodCodec().encodeSuccessEnvelope({
              'event': 'bufferingUpdate',
              'values': ranges,
            }),
            (_) {});
        await _flush();
        expect(video.state.bufferPosition,
            ranges.isEmpty ? Duration.zero : const Duration(seconds: 20));
      }
    } finally {
      await video.close();
    }
  });

  test('recovered DASH response reaches native playback with its signed base',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const original =
        'https://instance.example/companion/api/manifest/dash/id/dash-video?local=true';
    const signed = '$original&check=fixture%2Bsignature';
    final requests = <http.Request>[];
    retryService.httpClient.close();
    service =
        retryService = _RetryService(httpClient: MockClient((request) async {
      requests.add(request);
      expect(request.headers['Cookie'], 'backend=a');
      if (request.url.path == '/watch') {
        return http.Response(
            '<video id="player"><source type="application/dash+xml" '
            'src="${signed.replaceAll('&', '&amp;')}"></video>',
            200,
            request: request);
      }
      return request.url.queryParameters.containsKey('check')
          ? http.Response(_staticDashManifest, 200, request: request)
          : http.Response('No check ID.', 400, request: request);
    }));
    final video = cubit();
    try {
      video.switchVideo(_video('dash-video', BackendPlayback(preferred))
          .copyWith(formatStreams: [], dashUrl: original));
      await _flush();

      expect(requests.map((request) => request.url.path), [
        '/companion/api/manifest/dash/id/dash-video',
        '/watch',
        '/companion/api/manifest/dash/id/dash-video',
      ]);
      expect(sources, hasLength(1));
      expect(sources.single['uri'], signed);
      expect(sources.single['inlineDashManifest'], _staticDashManifest);
      expect(sources.single['fastDashStartupFallback'], isNull);
      expect((sources.single['headers'] as Map)['Cookie'], 'backend=a');
      final controller = video.videoController!;
      expect(controller.betterPlayerDataSource!.useAsmsAudioTracks, isTrue);
      expect(controller.betterPlayerAsmsAudioTracks!.single.language, 'en');
      expect(controller.betterPlayerAsmsTracks.single.height, 1080);
      expect(nativePlaying, isTrue);
    } finally {
      await video.close();
    }
  });

  for (final (live, height, expected) in [
    (false, 360, true),
    (false, 720, false),
    (true, 360, false),
  ]) {
    test('DASH fast fallback respects live=$live and quality=$height',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await settings.setUseDash(true);
      await settings.setLastVideoQuality(height);
      retryService.httpClient.close();
      service =
          retryService = _RetryService(httpClient: MockClient((request) async {
        return http.Response(_staticDashManifest, 200, request: request);
      }));
      final video = cubit();
      try {
        video.switchVideo(
            _video('dash-video', BackendPlayback(preferred)).copyWith(
          liveNow: live,
          dashUrl: 'https://instance.example/manifest.mpd',
          formatStreams: [
            FormatStream(
                'https://instance.example/video.mp4',
                '18',
                'video/mp4',
                'medium',
                'mp4',
                'h264',
                '360p',
                '360p',
                '640x360'),
          ],
        ));
        await _flush();
        expect(sources.single['formatHint'], 'dash');
        expect(
            sources.single['fastDashStartupFallback'], expected ? true : null);
      } finally {
        await video.close();
      }
    });
  }

  test('advertised live video keeps network DASH even for a static response',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    retryService.httpClient.close();
    service =
        retryService = _RetryService(httpClient: MockClient((request) async {
      return http.Response(_staticDashManifest, 200, request: request);
    }));
    final video = cubit();
    try {
      video.switchVideo(_video('live-video', BackendPlayback(preferred))
          .copyWith(
              formatStreams: [],
              liveNow: true,
              dashUrl: 'https://instance.example/manifest.mpd'));
      await _flush();
      expect(sources, hasLength(1));
      expect(sources.single['uri'],
          'https://instance.example/manifest.mpd?local=true');
      expect(sources.single['inlineDashManifest'], isNull);
      expect(video.videoController!.betterPlayerDataSource!.inlineDashManifest,
          isNull);
      expect(nativePlaying, isTrue);
    } finally {
      await video.close();
    }
  });

  for (final cancel in ['stop', 'new video']) {
    test('a late downloaded DASH manifest cannot reopen after $cancel',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final response = Completer<http.Response>();
      final started = Completer<http.Request>();
      retryService.httpClient.close();
      service =
          retryService = _RetryService(httpClient: MockClient((request) async {
        started.complete(request);
        return response.future;
      }));
      final video = cubit();
      try {
        video.switchVideo(_video('old-video', BackendPlayback(preferred))
            .copyWith(
                formatStreams: [],
                dashUrl: 'https://instance.example/old.mpd'));
        final request = await started.future;
        if (cancel == 'stop') {
          await video.stopForProxyChange();
        } else {
          video.switchVideo(_video('new-video', BackendPlayback(preferred)));
          await _flush();
        }
        response.complete(
            http.Response(_staticDashManifest, 200, request: request));
        await _flush();
        if (cancel == 'stop') {
          expect(sources, isEmpty);
          expect(video.videoController, isNull);
        } else {
          expect(sources.map((source) => source['uri']),
              ['https://instance.example/new-video-a-1.mp4']);
          expect(sources.single['inlineDashManifest'], isNull);
          expect(video.state.video!.videoId, 'new-video');
        }
        expect(retryService.retriedVideos, isEmpty);
      } finally {
        if (!response.isCompleted) {
          response.complete(http.Response('Unavailable', 503));
        }
        await video.close();
      }
    });
  }

  test('typed manifest failure can recover before a native source is installed',
      () async {
    retryService.httpClient.close();
    service =
        retryService = _RetryService(httpClient: MockClient((request) async {
      expect(request.headers['Cookie'], 'backend=a');
      return http.Response('Unavailable', 503);
    }));
    final video = cubit();
    try {
      video.switchVideo(_video('dash-video', BackendPlayback(preferred))
          .copyWith(
              formatStreams: [],
              dashUrl: 'https://instance.example/manifest.mpd'));
      await _flush();
      expect(retryService.visited, ['Backend B']);
      expect(
          sources.single['uri'], 'https://instance.example/dash-video-b-1.mp4');
      expect(nativePlaying, isTrue);
    } finally {
      await video.close();
    }
  });

  test('gateway manifest rejection ends playback without retrying sources',
      () async {
    retryService.httpClient.close();
    service = retryService = _RetryService(httpClient: MockClient((_) async {
      throw const NerdVpnAccessRequired('unavailable');
    }));
    final video = cubit();
    try {
      video.switchVideo(_video('dash-video', BackendPlayback(preferred))
          .copyWith(
              formatStreams: [],
              dashUrl: 'https://instance.example/manifest.mpd'));
      await _flush();
      expect(retryService.visited, isEmpty);
      expect(retryService.retriedVideos, isEmpty);
      expect(sources, isEmpty);
      expect(player.state.mediaEvent.state, MediaState.error);
    } finally {
      await video.close();
    }
  });

  for (final (status, retryAfter) in [
    (401, null),
    (403, null),
    (429, null),
    (503, '10'),
    (503, 'invalid'),
  ]) {
    test('manifest refusal $status/$retryAfter cannot fall back to playback',
        () async {
      var requests = 0;
      retryService.httpClient.close();
      service = retryService = _RetryService(httpClient: MockClient((_) async {
        requests++;
        return http.Response('Refused', status,
            headers: {if (retryAfter != null) 'retry-after': retryAfter});
      }));
      await settings.setUseDash(true);
      final video = cubit();
      try {
        video.switchVideo(_video('dash-video', BackendPlayback(preferred))
            .copyWith(dashUrl: 'https://instance.example/manifest.mpd'));
        await _flush();
        expect(requests, 1);
        expect(sources, isEmpty);
        expect(retryService.retriedVideos, isEmpty);
        expect(player.state.mediaEvent.state, MediaState.error);
      } finally {
        await video.close();
      }
    });
  }

  test('generic decoder errors and videos without a session do not retry',
      () async {
    for (final withSession in [true, false]) {
      sources.clear();
      failedUrls[withSession
          ? 'https://instance.example/video-a-1.mp4'
          : 'https://instance.example/video-default-1.mp4'] = !withSession;
      final video = cubit(session: withSession);
      try {
        await video.playVideo(false);
        await _flush();
        expect(retryService.retriedVideos, isEmpty);
        expect(player.state.mediaEvent.state, MediaState.error);
      } finally {
        await video.close();
      }
    }
  });

  test('a later codec failure does not inherit earlier transport eligibility',
      () async {
    failedUrls['https://instance.example/video-a-1.mp4'] = true;
    final video = cubit();
    try {
      await video.playVideo(false);
      await _flush();
      expect(retryService.visited, ['Backend B']);
      await error(retryable: false);
      await _flush();
      expect(retryService.visited, ['Backend B']);
      expect(retryService.retriedVideos, hasLength(1));
      expect(player.state.mediaEvent.state, MediaState.error);
    } finally {
      await video.close();
    }
  });

  test('video admission honors a pause requested before metadata arrives',
      () async {
    final video = cubit();
    player.pause();
    try {
      await video.playVideo(false, startAt: const Duration(seconds: 12));
      await _flush();

      expect(sources, hasLength(1));
      expect(playCalls, 0);
      expect(nativePlaying, isFalse);
      expect(player.state.isPlaying, isFalse);
    } finally {
      await video.close();
    }
  });

  test('terminal video failure publishes pause without hiding the error',
      () async {
    final video = cubit();
    try {
      await video.playVideo(false);
      await _flush();
      expect(player.state.isPlaying, isTrue);
      await error(retryable: false);
      await _flush();

      expect(nativePlaying, isFalse);
      expect(player.state.isPlaying, isFalse);
      expect(player.state.mediaEvent.state, MediaState.error);
      expect(retryService.retriedVideos, isEmpty);
    } finally {
      await video.close();
    }
  });

  test('offline video retry keeps the parent resume position without metadata',
      () async {
    const offline = DownloadedVideo(
        videoId: 'offline',
        title: 'Offline',
        storageUri: 'content://test/download.mp4',
        lengthSeconds: 60,
        quality: '360p');
    final video = cubit();
    player.emit(player.state.copyWith(
        currentlyPlaying: null,
        offlineCurrentlyPlaying: offline,
        offlineVideos: [offline],
        startAt: const Duration(seconds: 33)));
    try {
      video.switchToOfflineVideo(offline);
      await _flush();

      expect(sources.single['uri'], 'content://test/download.mp4');
      expect(nativePosition, 33000);
      expect(retryService.metadataCalls, 0);
      expect(nativePlaying, isTrue);
    } finally {
      await video.close();
    }
  });

  for (final pauseDuringRetry in [false, true]) {
    test('manual video Play reloads once and honors pause=$pauseDuringRetry',
        () async {
      player.audioSession = await AudioSession.instance;
      app_main.mediaHandler = MediaHandler(player);
      final video = cubit();
      final queued = video.state.video!.copyWith(queueEntryId: 'entry');
      video.emit(video.state.copyWith(video: queued));
      player.emit(player.state.copyWith(
          currentlyPlaying: queued, videos: [queued], isHidden: false));
      try {
        await video.playVideo(false, startAt: const Duration(seconds: 12));
        await _flush();
        await error(retryable: false);
        await _flush();
        expect(player.state.isPlaying, isFalse);
        final initialPlayCalls = playCalls;
        final position = player.state.position;
        retryService.heldMetadata = Completer<void>();
        retryService.metadataResult =
            _video('video', BackendPlayback(preferred));

        player.play();
        video.handleCommand(player.state.mediaCommand!);
        await _flush();
        expect(retryService.metadataCalls, 1);
        video.handleCommand(const MediaCommand(MediaCommandType.play));
        await _flush();
        expect(retryService.metadataCalls, 1);
        expect(playCalls, initialPlayCalls);
        expect(player.state.isPlaying, isFalse);
        if (pauseDuringRetry) {
          player.pause();
          video.handleCommand(player.state.mediaCommand!);
        }
        retryService.heldMetadata!.complete();
        await _flush();
        // The old decoder remains stale until it receives the actual switch.
        video.handleCommand(const MediaCommand(MediaCommandType.play));
        expect(retryService.metadataCalls, 1);
        expect(playCalls, initialPlayCalls);
        expect(player.state.mediaCommand!.type, MediaCommandType.switchVideo);
        video.handleCommand(player.state.mediaCommand!);
        await _flush();

        expect(sources, hasLength(2));
        expect(nativePosition, position.inMilliseconds);
        expect(nativePlaying, !pauseDuringRetry);
        expect(player.state.isPlaying, !pauseDuringRetry);
        expect(player.state.currentlyPlaying!.queueEntryId, 'entry');
      } finally {
        if (retryService.heldMetadata?.isCompleted == false) {
          retryService.heldMetadata!.complete();
        }
        await _flush();
        await video.close();
      }
    });
  }

  test('failed manual video retry retains its item and permits another Play',
      () async {
    player.audioSession = await AudioSession.instance;
    app_main.mediaHandler = MediaHandler(player);
    final video = cubit();
    final queued = video.state.video!.copyWith(queueEntryId: 'entry');
    video.emit(video.state.copyWith(video: queued));
    player.emit(player.state
        .copyWith(currentlyPlaying: queued, videos: [queued], isHidden: false));
    try {
      await video.playVideo(false, startAt: const Duration(seconds: 12));
      await _flush();
      await error(retryable: false);
      await _flush();
      retryService.metadataError = StateError('Unavailable');
      player.play();
      video.handleCommand(player.state.mediaCommand!);
      await _flush();

      expect(retryService.metadataCalls, 1);
      expect(player.state.videos, [queued]);
      expect(player.state.currentlyPlaying!.queueEntryId, 'entry');
      expect(player.state.position, const Duration(seconds: 12));
      expect(player.state.isHidden, isFalse);
      expect(player.state.isPlaying, isFalse);
      expect(player.state.mediaEvent.state, MediaState.error);
      expect(sources, hasLength(1));
      // BlocListener delivers the parent's failure-triggered Pause after the
      // parent has published its terminal error.
      expect(player.state.mediaCommand!.type, MediaCommandType.pause);
      video.handleCommand(player.state.mediaCommand!);
      expect(player.state.mediaEvent.state, MediaState.error);

      retryService.metadataError = null;
      retryService.metadataResult = _video('video', BackendPlayback(preferred));
      player.play();
      video.handleCommand(player.state.mediaCommand!);
      await _flush();
      expect(retryService.metadataCalls, 2);
      expect(player.state.mediaCommand!.type, MediaCommandType.switchVideo);
      video.handleCommand(player.state.mediaCommand!);
      await _flush();
      expect(sources, hasLength(2));
      expect(nativePosition, 12000);
      expect(nativePlaying, isTrue);
    } finally {
      await video.close();
    }
  });

  test('paused midstream recovery preserves position and current speed',
      () async {
    final video = cubit();
    try {
      await video.playVideo(false);
      await video.videoController!.setSpeed(1.75);
      video.setPitchSemitones(-12);
      video.seek(const Duration(seconds: 23));
      video.pause();
      await _flush();
      final previousPlayCalls = playCalls;
      await error(retryable: true);
      await _flush();
      expect(retryService.visited, ['Backend B']);
      expect(seeks.last, 23000);
      expect(speeds.last, 1.75);
      expect(pitches.last, 0.5);
      expect(nativePlaying, isFalse);
      expect(playCalls, previousPlayCalls);
      expect(video.state.video!.backendPlayback!.label, 'Backend B');
    } finally {
      await video.close();
    }
  });

  test('standard Invidious refreshes its current route after a transient error',
      () async {
    final video = cubit(session: false);
    try {
      final original = video.state.video!;
      final refreshed = original.copyWith(
          formatStreams: _video('refreshed', null).formatStreams);
      player.refreshResults.add(refreshed);
      await video.playVideo(false);
      await video.seek(const Duration(seconds: 18));
      await error(retryable: true);
      await _flush();
      expect(player.refreshRequests, [original]);
      expect(retryService.retriedVideos, isEmpty);
      expect(sources.last['uri'],
          'https://instance.example/refreshed-default-1.mp4');
      expect(seeks.last, 18000);
      expect(nativePlaying, isTrue);
      expect(player.state.currentlyPlaying, same(refreshed));
      expect(video.state.video, same(refreshed));
    } finally {
      await video.close();
    }
  });

  test('refresh preserves quality, speed, pitch and the latest paused seek',
      () async {
    final video = cubit(count: 2);
    final held = player.heldRefresh = Completer<void>();
    try {
      final original = video.state.video!;
      player.refreshResults.add(original.copyWith(
          formatStreams:
              _video('refreshed', original.backendPlayback, sources: 2)
                  .formatStreams));
      await video.playVideo(false);
      await video.selectVideoTrack(0);
      video.setSpeed(1.75);
      video.setPitchSemitones(-12);
      await video.seek(const Duration(seconds: 23));
      await _flush();
      await error(retryable: true);
      await _flush();
      video.pause();
      await video.seek(const Duration(seconds: 27));
      final previousPlayCalls = playCalls;
      held.complete();
      await _flush();
      expect(sources.last['uri'], 'https://instance.example/refreshed-a-2.mp4');
      expect(sources.last['initialPositionMs'], 27000);
      expect(nativePosition, 27000);
      expect(seeks.last, 23000);
      expect(speeds.last, 1.75);
      expect(pitches.last, 0.5);
      expect(nativePlaying, isFalse);
      expect(playCalls, previousPlayCalls);
      expect(
          video.state.video!.backendPlayback, same(original.backendPlayback));
      expect(retryService.retriedVideos, isEmpty);
    } finally {
      if (!held.isCompleted) held.complete();
      await video.close();
    }
  });

  test('failed refreshed source uses the remaining refresh before alternates',
      () async {
    final video = cubit();
    try {
      final original = video.state.video!;
      player.refreshResults.addAll([
        original.copyWith(
            formatStreams: _video('refreshed-one', original.backendPlayback)
                .formatStreams),
        original.copyWith(
            formatStreams: _video('refreshed-two', original.backendPlayback)
                .formatStreams),
      ]);
      failedUrls['https://instance.example/refreshed-one-a-1.mp4'] = true;
      await video.playVideo(false);
      await video.seek(const Duration(seconds: 19));
      await error(retryable: true);
      await _flush();
      expect(player.refreshRequests, hasLength(2));
      expect(retryService.retriedVideos, isEmpty);
      expect(sources.map((source) => source['uri']), [
        'https://instance.example/video-a-1.mp4',
        'https://instance.example/refreshed-one-a-1.mp4',
        'https://instance.example/refreshed-two-a-1.mp4',
      ]);
      expect(seeks.last, 19000);
      expect(nativePlaying, isTrue);
    } finally {
      await video.close();
    }
  });

  test('focus loss during refresh gates play and seek before a pause arrives',
      () async {
    final video = cubit();
    final held = player.heldRefresh = Completer<void>();
    try {
      final original = video.state.video!;
      player.refreshResults.add(original.copyWith(
          formatStreams:
              _video('refreshed', original.backendPlayback).formatStreams));
      await video.playVideo(false);
      await video.seek(const Duration(seconds: 14));
      await error(retryable: true);
      await _flush();
      player.interrupted = true;
      final previousPlayCalls = playCalls;
      video.play();
      held.complete();
      await _flush();
      expect(nativePlaying, isFalse);
      expect(playCalls, previousPlayCalls);
      await video.seek(const Duration(seconds: 17));
      video.play();
      await _flush();
      expect(nativePlaying, isFalse);
      expect(playCalls, previousPlayCalls);
      player.interrupted = false;
      video.play();
      await _flush();
      expect(nativePlaying, isTrue);
      expect(seeks.last, 17000);
    } finally {
      if (!held.isCompleted) held.complete();
      await video.close();
    }
  });

  test('parent pause during refresh wins before its decoder command arrives',
      () async {
    final video = cubit();
    final held = player.heldRefresh = Completer<void>();
    try {
      final original = video.state.video!;
      player.refreshResults.add(original.copyWith(
          formatStreams:
              _video('refreshed', original.backendPlayback).formatStreams));
      await video.playVideo(false);
      await video.seek(const Duration(seconds: 14));
      await error(retryable: true);
      await _flush();
      player.pause();
      final previousPlayCalls = playCalls;
      held.complete();
      await _flush();
      expect(nativePlaying, isFalse);
      expect(playCalls, previousPlayCalls);
      expect(seeks.last, 14000);
      expect(player.state.mediaCommand!.type, MediaCommandType.pause);
    } finally {
      if (!held.isCompleted) held.complete();
      await video.close();
    }
  });

  for (final (status, retryAfter) in [
    (401, null),
    (403, null),
    (429, null),
    (503, const Duration(seconds: 10)),
  ]) {
    test('refresh refusal $status/$retryAfter never switches backend',
        () async {
      final video = cubit();
      player.refreshError = InvidiousServiceError('Unavailable',
          statusCode: status, retryAfter: retryAfter);
      try {
        await video.playVideo(false);
        await error(retryable: true);
        await _flush();
        expect(player.refreshRequests, hasLength(1));
        expect(retryService.retriedVideos, isEmpty);
        expect(sources, hasLength(1));
        expect(player.state.mediaEvent.state, MediaState.error);
        expect(nativePlaying, isFalse);
      } finally {
        await video.close();
      }
    });
  }

  test('new video cancels refresh and duplicate errors cannot start another',
      () async {
    final video = cubit();
    final held = player.heldRefresh = Completer<void>();
    try {
      final original = video.state.video!;
      player.refreshResults.add(original.copyWith(
          formatStreams:
              _video('stale', original.backendPlayback).formatStreams));
      await video.playVideo(false);
      await error(retryable: true);
      await error(retryable: true);
      await _flush();
      expect(player.refreshRequests, hasLength(1));
      video.switchVideo(_video('replacement', BackendPlayback(preferred)));
      await _flush();
      held.complete();
      await _flush();
      expect(sources.map((source) => source['uri']), [
        'https://instance.example/video-a-1.mp4',
        'https://instance.example/replacement-a-1.mp4',
      ]);
      expect(video.state.video!.videoId, 'replacement');
      expect(retryService.retriedVideos, isEmpty);
    } finally {
      if (!held.isCompleted) held.complete();
      await video.close();
    }
  });

  test('paused quality change retains position, speed and paused intent',
      () async {
    final video = cubit(count: 2);
    try {
      await video.playVideo(false);
      await video.videoController!.setSpeed(1.75);
      video.seek(const Duration(seconds: 12));
      video.pause();
      await _flush();
      final previousPlayCalls = playCalls;
      video.selectVideoTrack(0);
      await _flush();
      expect(sources.last['uri'], 'https://instance.example/video-a-2.mp4');
      expect(seeks.last, 12000);
      expect(speeds.last, 1.75);
      expect(nativePlaying, isFalse);
      expect(playCalls, previousPlayCalls);
    } finally {
      await video.close();
    }
  });

  test('quality change retains a user seek awaiting native completion',
      () async {
    final video = cubit(count: 2);
    final held = heldSeeks[18000] = Completer<void>();
    Future<void>? seeking;
    try {
      await video.playVideo(false);
      await video.seek(const Duration(seconds: 12));
      video.pause();
      await _flush();
      seeking = video.seek(const Duration(seconds: 18));
      await _flush();
      final previousPlayCalls = playCalls;
      await video.selectVideoTrack(0);
      await _flush();
      expect(sources.last['uri'], 'https://instance.example/video-a-2.mp4');
      expect(sources.last['initialPositionMs'], 18000);
      expect(seeks.last, 18000,
          reason: 'Quality changes must restore the latest requested seek.');
      held.complete();
      await seeking;
      await _flush();
      expect(video.position(), const Duration(seconds: 18));
      expect(nativePlaying, isFalse);
      expect(playCalls, previousPlayCalls);
    } finally {
      if (!held.isCompleted) held.complete();
      await seeking;
      await video.close();
    }
  });

  for (final interruption in ['pause', 'parent pause', 'focus']) {
    test('$interruption during quality setup prevents stale autoplay',
        () async {
      final video = cubit(count: 2);
      final held = heldSources['https://instance.example/video-a-2.mp4'] =
          Completer<void>();
      try {
        await video.playVideo(false);
        video.setSpeed(1.75);
        video.setPitchSemitones(-12);
        await video.seek(const Duration(seconds: 12));
        await video.selectVideoTrack(0);
        await _flush();
        if (interruption == 'pause') {
          video.pause();
        } else if (interruption == 'parent pause') {
          // Do not deliver the queued command to the decoder. Admission must
          // already honor the parent's latest intent at this point.
          player.pause();
        } else {
          player.interrupted = true;
        }
        await video.seek(const Duration(seconds: 18));
        final previousPlayCalls = playCalls;
        held.complete();
        await _flush();
        expect(sources.last['uri'], 'https://instance.example/video-a-2.mp4');
        expect(seeks.last, 18000);
        expect(speeds.last, 1.75);
        expect(pitches.last, 0.5);
        expect(nativePlaying, isFalse);
        expect(playCalls, previousPlayCalls);
      } finally {
        if (!held.isCompleted) held.complete();
        await video.close();
      }
    });
  }

  test('pause during a failed source survives ordinary format fallback',
      () async {
    const first = 'https://instance.example/video-a-1.mp4';
    failedUrls[first] = false;
    final held = heldSources[first] = Completer<void>();
    final video = cubit(count: 2);
    try {
      final loading = video.playVideo(false);
      await _flush();
      video.pause();
      held.complete();
      await loading;
      await _flush();
      expect(sources, hasLength(2));
      expect(retryService.retriedVideos, isEmpty);
      expect(nativePlaying, isFalse);
      expect(playCalls, 0);
    } finally {
      await video.close();
    }
  });

  for (final pauseDuringSwitch in [false, true]) {
    test(
        'DASH child origin block advances once and resumes, pause=$pauseDuringSwitch',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await settings.setUseDash(true);
      retryService.httpClient.close();
      service = retryService = _RetryService(
          httpClient: MockClient((request) async =>
              http.Response(_staticDashManifest, 200, request: request)));
      final video = cubit();
      final original = video.state.video!
          .copyWith(dashUrl: 'https://instance.example/manifest.mpd');
      final held = heldSources['https://instance.example/video-a-1.mp4'] =
          Completer<void>();
      final heldSeek = heldSeeks[18000] = Completer<void>();
      Future<void>? seeking;
      try {
        video.switchVideo(original);
        await _flush();
        expect(sources.single['formatHint'], 'dash');
        await video.seek(const Duration(seconds: 12));
        if (pauseDuringSwitch) {
          seeking = video.seek(const Duration(seconds: 18));
          await _flush();
        }
        final previousPlayCalls = playCalls;
        await error(retryable: false, mediaOriginBlocked: true);
        await _flush();
        expect(sources.last['initialPositionMs'],
            pauseDuringSwitch ? 18000 : 12000);
        if (pauseDuringSwitch) {
          video.pause();
          await video.seek(const Duration(seconds: 25));
        }
        held.complete();
        heldSeek.complete();
        await seeking;
        await _flush();
        expect(
            video.position(), Duration(seconds: pauseDuringSwitch ? 25 : 12));
        expect(nativePlaying, !pauseDuringSwitch);
        if (pauseDuringSwitch) expect(playCalls, previousPlayCalls);
        await error(retryable: false, mediaOriginBlocked: true);
        await _flush();
        expect(sources.map((source) => source['uri']), [
          'https://instance.example/manifest.mpd?local=true',
          'https://instance.example/video-a-1.mp4',
        ]);
        expect(player.state.mediaEvent.value,
            PlaybackFailureReason.separateMediaHost);
        expect(player.refreshRequests, isEmpty);
        expect(retryService.retriedVideos, isEmpty);
      } finally {
        if (!held.isCompleted) held.complete();
        if (!heldSeek.isCompleted) heldSeek.complete();
        await seeking;
        await video.close();
      }
    });
  }

  for (final change in ['mode', 'credentials', 'queue']) {
    test('late media-source fallback cannot autoplay after $change changes',
        () async {
      final video = cubit(count: 2);
      final held = heldSources['https://instance.example/video-a-2.mp4'] =
          Completer<void>();
      try {
        await video.playVideo(false);
        await error(retryable: false, mediaOriginBlocked: true);
        await _flush();
        expect(sources, hasLength(2));
        final previousPlayCalls = playCalls;
        switch (change) {
          case 'mode':
            player.switchAudio(true);
          case 'credentials':
            await db.upsertServer((await db.getCurrentlySelectedServer())
                .copyWith(authToken: 'replacement'));
          case 'queue':
            player.emit(player.state.copyWith(
                currentlyPlaying: _video('next', BackendPlayback(preferred))));
        }
        held.complete();
        await _flush();
        expect(playCalls, previousPlayCalls);
        expect(player.refreshRequests, isEmpty);
        expect(retryService.retriedVideos, isEmpty);
      } finally {
        if (!held.isCompleted) held.complete();
        await video.close();
      }
    });
  }

  test('a refused replacement manifest keeps its own terminal reason',
      () async {
    retryService.httpClient.close();
    service = retryService = _RetryService(
        httpClient: MockClient((request) async =>
            http.Response('Refused', 429, headers: {'retry-after': '60'})));
    final video = cubit();
    try {
      video.switchVideo(video.state.video!
          .copyWith(dashUrl: 'https://instance.example/manifest.mpd'));
      await _flush();
      expect(sources.single['uri'], 'https://instance.example/video-a-1.mp4');
      await error(retryable: false, mediaOriginBlocked: true);
      await _flush();
      expect(sources, hasLength(1));
      expect(player.state.mediaEvent.state, MediaState.error);
      expect(player.state.mediaEvent.value, isNull);
      expect(player.refreshRequests, isEmpty);
      expect(retryService.retriedVideos, isEmpty);
    } finally {
      await video.close();
    }
  });

  test('a pause while retry metadata is pending prevents autoplay', () async {
    final video = cubit();
    try {
      await video.playVideo(false);
      retryService.heldRetry = Completer<void>();
      await error(retryable: true);
      await _flush();
      expect(retryService.visited, ['Backend B']);
      expect(player.state.requestedBackend?.label, 'Backend B');
      expect(player.state.mediaEvent.value, 'Backend B');
      video.pause();
      final previousPlayCalls = playCalls;
      retryService.heldRetry!.complete();
      await _flush();
      expect(sources, hasLength(2));
      expect(nativePlaying, isFalse);
      expect(playCalls, previousPlayCalls);
      expect(player.state.requestedBackend?.label, 'Backend B');
    } finally {
      await video.close();
    }
  });

  test('stopping invalidates pending metadata and duplicate native failures',
      () async {
    final video = cubit();
    await video.playVideo(false);
    retryService.heldRetry = Completer<void>();
    await error(retryable: true);
    await error(retryable: true);
    await _flush();
    expect(retryService.visited, ['Backend B']);
    await video.stopForProxyChange();
    retryService.heldRetry!.complete();
    await _flush();
    expect(sources, hasLength(1));
    expect(video.videoController, isNull);
    await video.close();
  });

  test('new video supersedes an older backend response', () async {
    final video = cubit();
    try {
      await video.playVideo(false);
      retryService.heldRetry = Completer<void>();
      await error(retryable: true);
      await _flush();
      video.switchVideo(_video('new-video', BackendPlayback(preferred)));
      await _flush();
      retryService.heldRetry!.complete();
      await _flush();
      expect(video.state.video!.videoId, 'new-video');
      expect(sources.map((source) => source['uri']), [
        'https://instance.example/video-a-1.mp4',
        'https://instance.example/new-video-a-1.mp4',
      ]);
    } finally {
      await video.close();
    }
  });

  test('manual metadata supersedes an in-flight automatic native recovery',
      () async {
    player.audioSession = await AudioSession.instance;
    app_main.mediaHandler = MediaHandler(player);
    final video = cubit();
    try {
      await video.playVideo(false);
      retryService.heldRetry = Completer<void>();
      await error(retryable: true);
      await _flush();
      expect(retryService.visited, ['Backend B']);
      final automaticRequest = player.state.requestedBackend!;
      final originalGeneration = player.backendPlaybackGeneration;
      retryService.heldManual = Completer<void>();
      final selecting = player.selectBackend('c',
          expectedVideoId: 'video', expectedRequest: automaticRequest);
      await retryService.manualStarted.future;
      final manualRequest = player.state.requestedBackend!;
      expect(player.backendPlaybackGeneration, greaterThan(originalGeneration));
      expect(manualRequest.label, 'Backend C');
      expect(player.state.backendRecovery!.phase, BackendRecoveryPhase.trying);

      // The old recovery result and its decoder errors must not install B,
      // fail C, or replace C's progress message while its metadata is pending.
      retryService.heldRetry!.complete();
      await error(retryable: false);
      await _flush();
      expect(sources, hasLength(1));
      expect(player.state.requestedBackend, same(manualRequest));
      expect(player.state.backendRecovery!.phase, BackendRecoveryPhase.trying);

      retryService.heldManual!.complete();
      await selecting;
      video.handleCommand(player.state.mediaCommand!);
      await _flush();
      expect(sources.map((source) => source['uri']), [
        'https://instance.example/video-a-1.mp4',
        'https://instance.example/video-c-1.mp4',
      ]);
      expect(video.state.video!.backendPlayback, same(manualRequest));
      expect(player.state.requestedBackend, same(manualRequest));
      expect(retryService.visited, ['Backend B']);
    } finally {
      if (retryService.heldRetry?.isCompleted == false) {
        retryService.heldRetry!.complete();
      }
      if (retryService.heldManual?.isCompleted == false) {
        retryService.heldManual!.complete();
      }
      await _flush();
      await video.close();
    }
  });

  test('repeated backend failures share the two-alternative budget', () async {
    for (final backend in ['a', 'b', 'c']) {
      failedUrls['https://instance.example/video-$backend-1.mp4'] = true;
    }
    final video = cubit();
    try {
      await video.playVideo(false);
      await _flush();
      expect(retryService.visited, ['Backend B', 'Backend C']);
      expect(sources, hasLength(3));
      expect(player.state.mediaEvent.state, MediaState.error);
      expect(nativePlaying, isFalse);
    } finally {
      await video.close();
    }
  });
}
