import 'dart:async';
import 'dart:io';

import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/states/video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

class _Player extends Fake implements PlayerCubit {}

class _Settings extends Fake implements SettingsCubit {}

class _DownloadTestBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

class _DownloadService extends Service {
  final Future<Video> Function(String) fetch;
  final void Function(Server?)? onServer;

  _DownloadService(this.fetch, {this.onServer});

  @override
  Future<Video> getVideo(String videoId,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest}) {
    onServer?.call(serverOverride);
    return fetch(videoId);
  }
}

class _VideoCubit extends VideoCubit {
  _VideoCubit(DownloadManagerCubit manager)
      : super(
            VideoState(
                videoId: 'abcdefghijk',
                isLoggedIn: false,
                video: Video(videoId: 'abcdefghijk')),
            manager,
            _Player(),
            _Settings());

  @override
  Future<void> onReady() async => getDownloadStatus();
}

void main() {
  _DownloadTestBinding();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Service originalService;
  late DownloadManagerCubit manager;
  late Directory documentsDirectory;
  HttpServer? mediaServer;
  const video = DownloadedVideo(
      videoId: 'abcdefghijk',
      title: 'A video',
      lengthSeconds: 12,
      quality: '720p');

  Future<void> openManager() async {
    manager = DownloadManagerCubit(const DownloadManagerState(), _Player());
    await manager.addDownloads([]); // Wait for saved preferences to load.
  }

  Future<void> waitFor(bool Function(DownloadManagerState) predicate,
      {Duration timeout = const Duration(seconds: 5)}) async {
    if (!predicate(manager.state)) {
      await manager.stream.firstWhere(predicate).timeout(timeout);
    }
  }

  Future<Video> audioVideo(String videoId,
      {void Function(HttpRequest)? onRequest}) async {
    const bytes = [0, 1, 2, 3, 4, 5, 6, 7];
    mediaServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    mediaServer!.listen((request) async {
      onRequest?.call(request);
      request.response.add(bytes);
      await request.response.close();
    });
    await db.upsertServer(
        const Server(url: 'https://instance.invalid', inUse: true));
    return Video(videoId: videoId, title: 'Resolved title', adaptiveFormats: [
      AdaptiveFormat(
          null,
          '128000',
          null,
          'http://127.0.0.1:${mediaServer!.port}/audio',
          '251',
          'audio/webm',
          '${bytes.length}',
          '1',
          '',
          'webm',
          'opus',
          null,
          null)
    ]);
  }

  Future<Video> audioVideoWithArtwork({
    required Future<void> Function(HttpRequest) onArtwork,
    void Function(HttpRequest)? onAudio,
    Duration audioDelay = Duration.zero,
  }) async {
    const bytes = [0, 1, 2, 3, 4, 5, 6, 7];
    mediaServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    mediaServer!.listen((request) async {
      try {
        if (request.uri.path.startsWith('/vi/')) {
          await onArtwork(request);
        } else {
          onAudio?.call(request);
          await Future<void>.delayed(audioDelay);
          request.response.add(bytes);
          await request.response.close();
        }
      } on IOException {
        // Cancellation intentionally closes an in-flight response.
      }
    });
    final origin = 'http://127.0.0.1:${mediaServer!.port}';
    await db.useServer(Server(
        url: origin, customHeaders: {'X-Instance-Key': 'artwork-instance'}));
    return Video(
        videoId: video.videoId,
        title: 'Resolved title',
        videoThumbnails: [
          ImageObject('default',
              'https://i.ytimg.com/vi/${video.videoId}/default.jpg', 320, 180)
        ],
        adaptiveFormats: [
          AdaptiveFormat(
              null,
              '128000',
              null,
              '$origin/audio',
              '251',
              'audio/webm',
              '${bytes.length}',
              '1',
              '',
              'webm',
              'opus',
              null,
              null)
        ]);
  }

  setUp(() async {
    originalService = service;
    documentsDirectory =
        await Directory.systemTemp.createTemp('videre-download-manager-test-');
    mediaServer = null;
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documentsDirectory.path);
    db = await SembastSqfDb.createInMemory();
    await db.upsertServer(
        const Server(url: 'https://instance.invalid', inUse: true));
    await db.saveSetting(SettingsValue('downloads-wifi-only', 'true'));
    await db.upsertDownload(video);
    await openManager();
  });

  tearDown(() async {
    await manager.close();
    await mediaServer?.close(force: true);
    await db.close();
    messenger.setMockMethodCallHandler(pathProvider, null);
    await documentsDirectory.delete(recursive: true);
    service = originalService;
  });

  test('interrupted jobs remain queued and respect Wi-Fi-only after restart',
      () {
    expect(manager.state.videos.single.downloadFailed, false);
    expect(manager.state.videos.single.downloadComplete, false);
    expect(manager.state.wifiOnly, true);
    expect(manager.state.waitingForWifi, true);
    expect(manager.state.downloadProgresses, isEmpty);
    expect(manager.state.totalProgress, 0);
  });

  test('pause survives restart and resume keeps the queued job', () async {
    await manager.pauseDownload(video);
    await manager.close();
    await openManager();
    expect(manager.state.pausedVideoIds, contains(video.videoId));
    await manager.retryDownload(video);
    expect(manager.state.pausedVideoIds, isEmpty);
    expect(manager.state.videos.single, video);
    expect(manager.state.waitingForWifi, true);
  });

  test('stale retry actions preserve completed downloads', () async {
    final completed = video.copyWith(
        title: 'Resolved title', downloadComplete: true, audioOnly: true);
    await db.upsertDownload(completed);
    manager.setVideos();

    await manager.retryDownload(video);

    expect(db.getDownloadByVideoId(video.videoId), completed);
    expect(manager.state.videos.single, completed);
  });

  test('stale retry actions cannot recreate deleted downloads', () async {
    await manager.deleteVideo(video);

    await manager.retryDownload(video);

    expect(db.getDownloadByVideoId(video.videoId), isNull);
    expect(manager.state.videos, isEmpty);
  });

  test('a failed deletion does not leave the download permanently blocked',
      () async {
    final failed = video.copyWith(downloadFailed: true);
    await db.upsertDownload(failed);
    manager.setVideos();
    messenger.setMockMethodCallHandler(pathProvider,
        (_) async => throw PlatformException(code: 'storage-unavailable'));

    await expectLater(
        manager.deleteVideo(failed), throwsA(isA<PlatformException>()));
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documentsDirectory.path);
    await manager.retryDownload(failed);

    expect(manager.state.videos.single.downloadFailed, isFalse);
  });

  test('retry clears failure on the saved job without restoring stale metadata',
      () async {
    final failed = video.copyWith(
        title: 'Resolved title', downloadFailed: true, audioOnly: true);
    await db.upsertDownload(failed);
    manager.setVideos();

    await manager.retryDownload(video);

    expect(db.getDownloadByVideoId(video.videoId),
        failed.copyWith(downloadFailed: false));
    expect(manager.state.videos.single, failed.copyWith(downloadFailed: false));
  });

  test('batch queues unique jobs and skips existing videos', () async {
    final added = await manager.addDownloads(
        ['abcdefghijk', '12345678901', '12345678901', 'zyxwvutsrqp'],
        audioOnly: true);
    expect(added, 2);
    expect(manager.state.videos, hasLength(3));
    expect(manager.state.videos.where((v) => v.audioOnly), hasLength(2));
  });

  test('concurrent duplicate requests create just one job', () async {
    final results = await Future.wait([
      manager.addDownload('12345678901'),
      manager.addDownload('12345678901')
    ]);
    expect(results.where((accepted) => accepted), hasLength(1));
    expect(manager.state.videos, hasLength(2));
  });

  test('pausing a metadata request prevents transfer and resume completes it',
      () async {
    final audio = video.copyWith(audioOnly: true);
    await db.upsertDownload(audio);
    manager.setVideos();
    var requests = 0;
    final remote =
        await audioVideo(audio.videoId, onRequest: (_) => requests++);
    final metadata = Completer<Video>();
    final metadataStarted = Completer<void>();
    var fetches = 0;
    service = _DownloadService((_) {
      fetches++;
      if (fetches == 1) metadataStarted.complete();
      return fetches == 1 ? metadata.future : Future.value(remote);
    });
    await manager.setWifiOnly(false);
    await metadataStarted.future;
    await manager.pauseDownload(audio);
    metadata.complete(remote);
    await waitFor((state) => state.downloadProgresses.isEmpty);
    expect(requests, 0);
    expect(manager.state.videos.single.downloadFailed, false);

    await manager.retryDownload(manager.state.videos.single);
    await waitFor((state) => state.videos.single.downloadComplete);
    expect(fetches, 2);
    expect(requests, 1);
    expect(await File(await audio.downloadPath).readAsBytes(),
        [0, 1, 2, 3, 4, 5, 6, 7]);
  });

  test('switching servers during metadata keeps the original transfer headers',
      () async {
    final audio = video.copyWith(audioOnly: true);
    await db.upsertDownload(audio);
    manager.setVideos();
    final receivedKeys = <String?>[];
    final remote = await audioVideo(audio.videoId,
        onRequest: (request) =>
            receivedKeys.add(request.headers.value('X-Instance-Key')));
    final originalServer = Server(
        url: 'http://127.0.0.1:${mediaServer!.port}',
        customHeaders: {'X-Instance-Key': 'original-instance'});
    final nextServer = Server(
        url: 'http://localhost:${mediaServer!.port}',
        customHeaders: {'X-Instance-Key': 'next-instance'});
    await db.useServer(originalServer);
    final metadata = Completer<Video>();
    final metadataStarted = Completer<void>();
    Server? metadataServer;
    service = _DownloadService((_) {
      metadataStarted.complete();
      return metadata.future;
    }, onServer: (server) => metadataServer = server);

    await manager.setWifiOnly(false);
    await metadataStarted.future;
    await db.useServer(nextServer);
    metadata.complete(remote);
    await waitFor((state) =>
        state.videos.single.downloadComplete ||
        state.videos.single.downloadFailed);

    expect(manager.state.videos.single.downloadComplete, isTrue);
    expect(receivedKeys, ['original-instance']);
    expect(metadataServer?.url, originalServer.url);
    expect(metadataServer?.customHeaders, originalServer.customHeaders);
    expect((await db.getCurrentlySelectedServer()).url, nextServer.url);
    expect(await File(await audio.downloadPath).readAsBytes(),
        [0, 1, 2, 3, 4, 5, 6, 7]);
  });

  test('malformed image error bodies cannot fail the media download', () async {
    final audio = video.copyWith(audioOnly: true);
    await db.upsertDownload(audio);
    manager.setVideos();
    var mediaRequests = 0;
    final remote = await audioVideoWithArtwork(
        audioDelay: const Duration(milliseconds: 200),
        onAudio: (_) => mediaRequests++,
        onArtwork: (request) async {
          request.response.statusCode = 502;
          request.response.headers.contentType = ContentType.json;
          request.response.write('upstream gateway unavailable');
          await request.response.close();
        });
    service = _DownloadService((_) async => remote);

    await manager.setWifiOnly(false);
    await waitFor((state) => state.downloadProgresses.isEmpty);

    expect(manager.state.videos.single.downloadFailed, isFalse);
    expect(manager.state.videos.single.downloadComplete, isTrue);
    expect(mediaRequests, 1);
    expect(await File(await audio.downloadPath).readAsBytes(),
        [0, 1, 2, 3, 4, 5, 6, 7]);
    final cover = await audio.thumbnailPath;
    expect(await File(cover).exists(), isFalse);
    expect(await File('$cover.part').exists(), isFalse);
  });

  test('media starts while artwork is pending and artwork is committed whole',
      () async {
    final audio = video.copyWith(audioOnly: true);
    await db.upsertDownload(audio);
    manager.setVideos();
    final artworkStarted = Completer<void>();
    final mediaStarted = Completer<void>();
    final releaseArtwork = Completer<void>();
    addTearDown(() {
      if (!releaseArtwork.isCompleted) releaseArtwork.complete();
    });
    final headers = <String?>[];
    final remote = await audioVideoWithArtwork(onArtwork: (request) async {
      headers.add(request.headers.value('X-Instance-Key'));
      request.response.add([10, 11]);
      await request.response.flush();
      artworkStarted.complete();
      await releaseArtwork.future;
      request.response.add([12, 13]);
      await request.response.close();
    }, onAudio: (request) {
      headers.add(request.headers.value('X-Instance-Key'));
      mediaStarted.complete();
    });
    service = _DownloadService((_) async => remote);

    await manager.setWifiOnly(false);
    await artworkStarted.future.timeout(const Duration(seconds: 2));
    await mediaStarted.future.timeout(const Duration(seconds: 2));
    final artwork = File(await audio.thumbnailPath);
    expect(await artwork.exists(), isFalse);
    expect(manager.state.videos.single.downloadComplete, isFalse);
    releaseArtwork.complete();
    await waitFor((state) => state.videos.single.downloadComplete);

    expect(headers, ['artwork-instance', 'artwork-instance']);
    expect(await artwork.readAsBytes(), [10, 11, 12, 13]);
    expect(await File('${artwork.path}.part').exists(), isFalse);
    expect(await File(await audio.downloadPath).readAsBytes(),
        [0, 1, 2, 3, 4, 5, 6, 7]);
  });

  test('stalled artwork has a deadline and does not retry completed media',
      () async {
    final audio = video.copyWith(audioOnly: true);
    await db.upsertDownload(audio);
    manager.setVideos();
    final releaseArtwork = Completer<void>();
    addTearDown(() {
      if (!releaseArtwork.isCompleted) releaseArtwork.complete();
    });
    var mediaRequests = 0;
    var metadataRequests = 0;
    final remote = await audioVideoWithArtwork(
        onArtwork: (request) async {
          request.response.add([10, 11]);
          await request.response.flush();
          await releaseArtwork.future;
          await request.response.close();
        },
        onAudio: (_) => mediaRequests++);
    service = _DownloadService((_) async {
      metadataRequests++;
      return remote;
    });

    await manager.setWifiOnly(false);
    await waitFor((state) => state.videos.single.downloadComplete,
        timeout: const Duration(seconds: 8));

    expect(metadataRequests, 1);
    expect(mediaRequests, 1);
    expect(manager.state.videos.single.downloadFailed, isFalse);
    final path = await audio.thumbnailPath;
    expect(await File(path).exists(), isFalse);
    expect(await File('$path.part').exists(), isFalse);
  });

  test('deleting during artwork transfer joins cleanup before removing files',
      () async {
    final audio = video.copyWith(audioOnly: true);
    await db.upsertDownload(audio);
    manager.setVideos();
    final artworkStarted = Completer<void>();
    final releaseArtwork = Completer<void>();
    addTearDown(() {
      if (!releaseArtwork.isCompleted) releaseArtwork.complete();
    });
    final remote = await audioVideoWithArtwork(onArtwork: (request) async {
      request.response.add([10, 11]);
      await request.response.flush();
      artworkStarted.complete();
      await releaseArtwork.future;
      request.response.add([12, 13]);
      await request.response.close();
    });
    service = _DownloadService((_) async => remote);

    await manager.setWifiOnly(false);
    await artworkStarted.future;
    await manager.deleteVideo(audio).timeout(const Duration(seconds: 2));
    releaseArtwork.complete();

    expect(db.getDownloadByVideoId(audio.videoId), isNull);
    expect(manager.state.videos, isEmpty);
    expect(manager.state.downloadProgresses, isEmpty);
    expect(await File(await audio.downloadPath).exists(), isFalse);
    final path = await audio.thumbnailPath;
    expect(await File(path).exists(), isFalse);
    expect(await File('$path.part').exists(), isFalse);
  });

  test('pausing partial artwork retries it without keeping partial cover data',
      () async {
    final audio = video.copyWith(audioOnly: true);
    await db.upsertDownload(audio);
    manager.setVideos();
    final artworkStarted = Completer<void>();
    final releaseFirstArtwork = Completer<void>();
    addTearDown(() {
      if (!releaseFirstArtwork.isCompleted) releaseFirstArtwork.complete();
    });
    var artworkRequests = 0;
    final remote = await audioVideoWithArtwork(onArtwork: (request) async {
      artworkRequests++;
      if (artworkRequests == 1) {
        request.response.add([99]);
        await request.response.flush();
        artworkStarted.complete();
        await releaseFirstArtwork.future;
      } else {
        request.response.add([10, 11, 12]);
      }
      await request.response.close();
    });
    service = _DownloadService((_) async => remote);

    await manager.setWifiOnly(false);
    await artworkStarted.future;
    await manager.pauseDownload(audio);
    await waitFor((state) => state.downloadProgresses.isEmpty);
    final artwork = File(await audio.thumbnailPath);
    expect(await artwork.exists(), isFalse);
    expect(await File('${artwork.path}.part').exists(), isFalse);
    releaseFirstArtwork.complete();
    await manager.retryDownload(manager.state.videos.single);
    await waitFor((state) => state.videos.single.downloadComplete);

    expect(artworkRequests, 2);
    expect(await artwork.readAsBytes(), [10, 11, 12]);
  });

  test('deleting a download does not wait for its pending metadata request',
      () async {
    final metadata = Completer<Video>();
    final metadataStarted = Completer<void>();
    service = _DownloadService((_) {
      metadataStarted.complete();
      return metadata.future;
    });
    await manager.setWifiOnly(false);
    await metadataStarted.future;
    final deleting = manager.deleteVideo(video);
    try {
      await deleting.timeout(const Duration(seconds: 2));
    } finally {
      metadata.complete(Video(videoId: video.videoId, adaptiveFormats: []));
      await deleting;
    }
    expect(manager.state.videos, isEmpty);
    expect(db.getDownloadByVideoId(video.videoId), isNull);
    expect(manager.state.downloadProgresses, isEmpty);
  });

  test('proxy change cancels downloads before a slower consumer finishes',
      () async {
    final proxy = NetworkProxy.instance;
    await proxy.initialize(saved: '{}', configureNative: false);
    // Model playback being created before the downloads tab is first opened.
    await manager.close();
    final slowStarted = Completer<void>();
    final releaseSlow = Completer<void>();
    Future<void> stopSlowConsumer() {
      slowStarted.complete();
      return releaseSlow.future;
    }

    proxy.addBeforeApply(stopSlowConsumer);
    await openManager();
    final metadata = Completer<Video>();
    final metadataStarted = Completer<void>();
    var fetches = 0;
    service = _DownloadService((_) {
      fetches++;
      metadataStarted.complete();
      return metadata.future;
    });
    Future<void>? applying;
    try {
      await manager.setWifiOnly(false);
      await metadataStarted.future;
      final token =
          manager.state.downloadProgresses[video.videoId]!.cancelToken;
      var applied = false;
      applying = proxy
          .apply(SocksProxyConfig(enabled: true))
          .then((_) => applied = true);
      // Cancellation is synchronous; no other listener's native disposal can
      // delay it. A connection failure after this point must not retry/fail.
      expect(token.isCancelled, isTrue);
      await slowStarted.future;
      await waitFor((state) => state.pausedVideoIds.contains(video.videoId));
      metadata.completeError(const SocketException('Connection reset'));
      await waitFor((state) => state.downloadProgresses.isEmpty);
      expect(fetches, 1);
      expect(manager.state.videos.single.downloadFailed, isFalse);
      expect(manager.state.videos.single.downloadComplete, isFalse);
      expect(applied, isFalse);
      releaseSlow.complete();
      await applying;
      expect(applied, isTrue);
    } finally {
      if (!metadata.isCompleted) {
        metadata.completeError(const SocketException('Test cleanup'));
      }
      if (!releaseSlow.isCompleted) releaseSlow.complete();
      await applying;
      proxy.removeBeforeApply(stopSlowConsumer);
      await proxy.initialize(saved: '{}', configureNative: false);
    }
  });

  test('a failed job does not block the next queued audio download', () async {
    const nextId = 'zyxwvutsrqp';
    final remote = await audioVideo(nextId);
    service = _DownloadService((id) async {
      if (id == video.videoId) throw StateError('No downloadable streams');
      return remote;
    });
    await manager.addDownload(nextId, audioOnly: true);
    await manager.setWifiOnly(false);
    await waitFor((state) => state.videos
        .any((item) => item.videoId == nextId && item.downloadComplete));
    expect(db.getDownloadByVideoId(video.videoId)!.downloadFailed, true);
    expect(db.getDownloadByVideoId(nextId)!.downloadFailed, false);
  });

  test('video details observe queued jobs through failure and completion',
      () async {
    final viewer = _VideoCubit(manager);
    expect(viewer.state.downloadedVideo, video);
    expect(viewer.state.downloading, false);
    final failed = viewer.stream.firstWhere((state) => state.downloadFailed);
    await db.upsertDownload(video.copyWith(downloadFailed: true));
    manager.setVideos();
    await failed;
    final complete = viewer.stream
        .firstWhere((state) => state.downloadedVideo?.downloadComplete == true);
    await db.upsertDownload(video.copyWith(downloadComplete: true));
    manager.setVideos();
    await complete;
    expect(viewer.state.downloadFailed, false);
    expect(viewer.state.downloadProgress, 1);
    await viewer.close();
    manager.setVideos();
  });
}
