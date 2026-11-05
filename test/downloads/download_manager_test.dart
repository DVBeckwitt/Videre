import 'dart:async';
import 'dart:io';

import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/downloads/services/download_storage.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/gateway_session_bridge.dart';
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
import 'package:dio/dio.dart';

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
  const storageChannel = MethodChannel('videre/download_storage');
  const folder = 'content://documents/tree/primary%3AVidere';
  const document = '$folder/document/primary%3AVidere%2Fvideo.webm';
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

  test('malformed download IDs cannot delete files outside the download folder',
      () async {
    await manager.addDownloads([]);
    final sentinel = File('${documentsDirectory.path}/outside.webm');
    await sentinel.writeAsString('preserve');
    final malicious = video.copyWith(videoId: '../outside', audioOnly: true);
    await expectLater(
        manager.deleteVideo(malicious), throwsA(isA<FormatException>()));
    expect(await sentinel.readAsString(), 'preserve');
  });

  test('untrusted download IDs are rejected before queueing or building paths',
      () async {
    for (final id in [
      '../escape',
      r'..\escape',
      '/absolute',
      'a/b',
      'a:b',
      '',
      'a' * 129,
      'line\nbreak',
      'trailing\n'
    ]) {
      expect(await manager.addDownload(id), isFalse);
      expect(db.getDownloadByVideoId(id), isNull);
      final invalid = video.copyWith(videoId: id);
      expect(() => invalid.fileName, throwsA(isA<FormatException>()));
      await expectLater(invalid.downloadPath, throwsA(isA<FormatException>()));
      await expectLater(invalid.thumbnailPath, throwsA(isA<FormatException>()));
    }
  });

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
    messenger.setMockMethodCallHandler(storageChannel, null);
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

  test('folder selection persists, cancellation and reset preserve old jobs',
      () async {
    messenger.setMockMethodCallHandler(
        storageChannel, (_) async => {'uri': folder, 'name': 'Videre'});
    await manager.chooseFolder();
    await manager.addDownload('12345678901');
    expect(db.getDownloadByVideoId(video.videoId)!.folderUri, isNull);
    expect(db.getDownloadByVideoId('12345678901')!.folderUri, folder);
    await manager.close();
    await openManager();
    expect(manager.state.folderName, 'Videre');
    expect(manager.state.folderUri, folder);
    messenger.setMockMethodCallHandler(storageChannel, (_) async => null);
    await manager.chooseFolder();
    expect(manager.state.folderUri, folder);
    await manager.usePrivateFolder();
    expect(manager.state.folderUri, isNull);
    expect(db.getSettings(downloadFolderSetting), isNull);
    expect(db.getDownloadByVideoId('12345678901')!.folderUri, folder);
  });

  test('completed external media keeps its URI and frees private staging files',
      () async {
    final audio = video.copyWith(audioOnly: true, folderUri: folder);
    await db.upsertDownload(audio);
    service = _DownloadService((_) => audioVideo(audio.videoId));
    List<int>? savedBytes;
    String? deleted;
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      if (call.method == 'prepareDocument') {
        expect(call.arguments['folder'], folder);
        expect(call.arguments['mime'], 'audio/webm');
        expect(call.arguments['existing'], isNull);
        return document;
      }
      if (call.method == 'writeDocument') {
        expect(db.getDownloadByVideoId(video.videoId)!.storageUri, document);
        expect(
            db.getDownloadByVideoId(video.videoId)!.downloadComplete, isFalse);
        savedBytes =
            await File(call.arguments['source'] as String).readAsBytes();
      }
      if (call.method == 'deleteDocument') {
        deleted = call.arguments['uri'] as String;
      }
      return null;
    });
    await manager.setWifiOnly(false);
    await waitFor((state) =>
        state.videos.single.downloadComplete &&
        state.downloadProgresses.isEmpty);
    final completed = db.getDownloadByVideoId(video.videoId)!;
    expect(savedBytes, [0, 1, 2, 3, 4, 5, 6, 7]);
    expect(await completed.effectivePath, document);
    expect(await File(await audio.downloadPath).exists(), isFalse);
    expect(
        await File('${await audio.downloadPath}.mux.webm').exists(), isFalse);
    await manager.close();
    await openManager();
    expect(await manager.state.videos.single.effectivePath, document);
    await manager.deleteVideo(manager.state.videos.single);
    expect(deleted, document);
    expect(manager.state.videos, isEmpty);
  });

  test('HD MP4 uses AAC and saves a matching external document across reloads',
      () async {
    const muxChannel = MethodChannel('flutter.arthenica.com/ffmpeg_kit');
    const muxEvents = MethodChannel('flutter.arthenica.com/ffmpeg_kit_event');
    const mp4 = '$folder/document/primary%3AVidere%2Fvideo.mp4';
    const mediaBytes = [1, 2, 3, 4];
    final requests = <String>[];
    mediaServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    mediaServer!.listen((request) async {
      requests.add(request.uri.path);
      request.response.add(mediaBytes);
      await request.response.close();
    });
    final origin = 'http://127.0.0.1:${mediaServer!.port}';
    AdaptiveFormat track(String id, String type, String encoding,
            [String? quality]) =>
        AdaptiveFormat(null, '128000', null, '$origin/$id', id, type,
            '${mediaBytes.length}', '1', '', null, encoding, quality, quality);
    service = _DownloadService((id) async =>
        Video(videoId: id, title: 'Resolved title', adaptiveFormats: [
          track('251', 'audio/webm', 'opus'),
          track('140', 'audio/mp4', 'aac'),
          track('243', 'video/webm', 'vp9', '360p'),
          track('137', 'video/mp4', 'h264', '1080p'),
        ]));

    late List<String> muxArguments;
    messenger.setMockMethodCallHandler(muxEvents, (_) async => null);
    messenger.setMockMethodCallHandler(muxChannel, (call) async {
      switch (call.method) {
        case 'ffmpegSession':
          muxArguments = List<String>.from(call.arguments['arguments'] as List);
          return {'sessionId': 1};
        case 'ffmpegSessionExecute':
          await File(muxArguments.last).writeAsBytes(mediaBytes);
          return null;
        case 'abstractSessionGetReturnCode':
          return 0;
        default:
          return null;
      }
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(muxEvents, null);
      messenger.setMockMethodCallHandler(muxChannel, null);
    });
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      switch (call.method) {
        case 'pickFolder':
          return {'uri': folder, 'name': 'Videre'};
        case 'prepareDocument':
          expect(call.arguments['name'], endsWith('.mp4'));
          expect(call.arguments['mime'], 'video/mp4');
          return mp4;
        case 'writeDocument':
          expect(call.arguments['uri'], mp4);
          final saved = db.getDownloadByVideoId(video.videoId)!;
          expect(saved.container, DownloadContainer.mp4);
          expect(saved.downloadComplete, isFalse);
          expect(await File(call.arguments['source'] as String).readAsBytes(),
              mediaBytes);
          return null;
        default:
          return null;
      }
    });

    await manager.deleteVideo(video);
    await manager.chooseFolder();
    expect(await manager.addDownload(video.videoId, quality: '1080p'), isTrue);
    await manager.setWifiOnly(false);
    await waitFor((state) =>
        state.videos.single.downloadComplete &&
        state.downloadProgresses.isEmpty);

    expect(requests, ['/140', '/137']);
    expect(muxArguments.last, endsWith('.mux.mp4'));
    expect(await File(muxArguments.last).exists(), isFalse);
    await manager.close();
    await openManager();
    final completed = manager.state.videos.single;
    expect(completed.container, DownloadContainer.mp4);
    expect(await completed.effectivePath, mp4);
  });

  test('failed folder writes retry the same document instead of duplicating it',
      () async {
    final audio = video.copyWith(audioOnly: true, folderUri: folder);
    await db.upsertDownload(audio);
    final remote = await audioVideo(audio.videoId);
    service = _DownloadService((_) async => remote);
    var writes = 0;
    final previousUris = <String?>[];
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      if (call.method == 'prepareDocument') {
        previousUris.add(call.arguments['existing'] as String?);
        return document;
      }
      if (call.method == 'writeDocument' && ++writes == 1) {
        throw PlatformException(code: 'DOWNLOAD_STORAGE');
      }
      return null;
    });
    await manager.setWifiOnly(false);
    await waitFor((state) =>
        state.videos.single.downloadFailed && state.downloadProgresses.isEmpty);
    expect(manager.state.videos.single.storageFailed, isTrue);
    expect(manager.state.videos.single.storageUri, document);
    await manager.retryDownload(manager.state.videos.single);
    await waitFor((state) => state.videos.single.downloadComplete);
    expect(previousUris, [null, document]);
    expect(manager.state.videos.single.storageFailed, isFalse);
  });

  test(
      'failed external deletion preserves the record and local files for retry',
      () async {
    final completed = video.copyWith(
        folderUri: folder, storageUri: document, downloadComplete: true);
    await db.upsertDownload(completed);
    manager.setVideos();
    final artwork = File(await completed.thumbnailPath);
    final staging = File('${await completed.downloadPath}.mux.webm');
    await artwork.writeAsBytes([1, 2]);
    await staging.writeAsBytes([3, 4]);
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      expect(call.method, 'deleteDocument');
      expect(call.arguments['uri'], document);
      throw PlatformException(code: 'DOWNLOAD_STORAGE');
    });

    await expectLater(
        manager.deleteVideo(completed), throwsA(isA<PlatformException>()));
    expect(db.getDownloadByVideoId(video.videoId), completed);
    expect(manager.state.videos.single, completed);
    expect(await artwork.readAsBytes(), [1, 2]);
    expect(await staging.readAsBytes(), [3, 4]);

    messenger.setMockMethodCallHandler(storageChannel, (_) async => null);
    await manager.deleteVideo(completed);
    expect(db.getDownloadByVideoId(video.videoId), isNull);
    expect(manager.state.videos, isEmpty);
    expect(await artwork.exists(), isFalse);
    expect(await staging.exists(), isFalse);
  });

  test('lost folder access fails before fetching media and preserves the job',
      () async {
    await db.upsertDownload(video.copyWith(folderUri: folder));
    var fetched = false;
    service = _DownloadService((_) async {
      fetched = true;
      return Video(videoId: video.videoId);
    });
    messenger.setMockMethodCallHandler(storageChannel,
        (_) async => throw PlatformException(code: 'DOWNLOAD_STORAGE'));
    await manager.setWifiOnly(false);
    await waitFor((state) => state.videos.single.storageFailed);
    expect(fetched, isFalse);
    expect(manager.state.videos.single.downloadComplete, isFalse);
    expect(manager.state.videos.single.folderUri, folder);
  });

  test(
      'delete cancels an external write and removes its newly recorded document',
      () async {
    final audio = video.copyWith(audioOnly: true, folderUri: folder);
    await db.upsertDownload(audio);
    service = _DownloadService((_) => audioVideo(audio.videoId));
    final started = Completer<void>(), cancelled = Completer<void>();
    String? deleted;
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      if (call.method == 'prepareDocument') return document;
      if (call.method == 'writeDocument') {
        started.complete();
        await cancelled.future;
        throw PlatformException(code: 'DOWNLOAD_STORAGE');
      }
      if (call.method == 'cancelWrite') cancelled.complete();
      if (call.method == 'deleteDocument') {
        deleted = call.arguments['uri'] as String;
      }
      return null;
    });
    await manager.setWifiOnly(false);
    await started.future.timeout(const Duration(seconds: 5));
    await manager.deleteVideo(audio).timeout(const Duration(seconds: 5));
    expect(deleted, document);
    expect(manager.state.videos, isEmpty);
    expect(
        await File('${await audio.downloadPath}.mux.webm').exists(), isFalse);
  });

  test('legacy downloads keep their private path and filenames stay portable',
      () async {
    final legacy = DownloadedVideo.fromJson({
      'videoId': video.videoId,
      'title': video.title,
      'lengthSeconds': 12,
      'quality': '720p',
      'downloadComplete': true,
    });
    expect(legacy.storageUri, isNull);
    expect(legacy.folderUri, isNull);
    expect(await legacy.effectivePath, endsWith('${video.videoId}.mp4'));
    await File(await legacy.downloadPath).writeAsBytes([1]);
    expect(await legacy.effectivePath, await legacy.downloadPath);
    expect(video.copyWith(title: '../Title: a/b').fileName,
        '.._Title_ a_b_${video.videoId}.webm');
    expect(video.copyWith(title: List.filled(200, '🙂').join()).fileName.length,
        lessThan(150));
  });

  test('different people keep separate files for the same video', () async {
    final other = video.copyWith(profileId: 'another-person');
    final originalMedia = File(await video.downloadPath);
    final otherMedia = File(await other.downloadPath);
    expect(otherMedia.path, isNot(originalMedia.path));
    expect(await other.thumbnailPath, isNot(await video.thumbnailPath));
    await originalMedia.writeAsString('original');
    await otherMedia.writeAsString('other');
    await otherMedia.delete();
    expect(await originalMedia.readAsString(), 'original');

    for (final id in ['../outside', r'..\outside', '', 'a' * 129]) {
      await expectLater(video.copyWith(profileId: id).downloadPath,
          throwsA(isA<FormatException>()));
    }
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

  test('a queued download retains its account after a same-server switch',
      () async {
    await manager.deleteVideo(video);
    final remote = await audioVideo(video.videoId);
    const original = Server(
        id: 'first-account',
        url: 'https://instance.invalid',
        authToken: 'first');
    const other = Server(
        id: 'second-account',
        url: 'https://instance.invalid',
        authToken: 'second');
    await db.useServer(original);
    await manager.addDownload(video.videoId, audioOnly: true);
    await db.useServer(other);
    await manager.close();
    await openManager();
    Server? requestedAccount;
    service = _DownloadService((_) async => remote,
        onServer: (server) => requestedAccount = server);

    await manager.setWifiOnly(false);
    await waitFor((state) => state.videos.single.downloadComplete);

    expect(requestedAccount?.accountId, original.accountId);
    expect(requestedAccount?.authToken, original.authToken);
    expect(
        db.getDownloadByVideoId(video.videoId)!.accountId, original.accountId);
    expect((await db.getCurrentlySelectedServer()).accountId, other.accountId);
  });

  test('download retries cannot move to a different account on the same server',
      () async {
    final remote = await audioVideo(video.videoId);
    const original = Server(
        id: 'retry-original',
        url: 'https://instance.invalid',
        authToken: 'first');
    const other = Server(
        id: 'retry-other',
        url: 'https://instance.invalid',
        authToken: 'second');
    await db.useServer(original);
    await db.upsertDownload(video.copyWith(audioOnly: true));
    final requests = <String>[];
    var attempts = 0;
    service = _DownloadService((_) async {
      if (++attempts == 1) {
        await db.useServer(other);
        throw const SocketException('Temporary failure');
      }
      return remote;
    }, onServer: (server) => requests.add(server!.accountId));

    await manager.setWifiOnly(false);
    await waitFor((state) => state.videos.single.downloadComplete);

    expect(requests, [original.accountId, original.accountId]);
    expect(
        db.getDownloadByVideoId(video.videoId)!.accountId, original.accountId);
  });

  for (final removeOriginal in [false, true]) {
    test(
        'a legacy download ${removeOriginal ? 'rejects a replacement account' : 'retains its existing account'} at the same URL',
        () async {
      await manager.deleteVideo(video);
      final remote = await audioVideo(video.videoId);
      const original =
          Server(url: 'https://instance.invalid', authToken: 'legacy-account');
      const replacement = Server(
          id: 'replacement-account',
          url: 'https://instance.invalid',
          authToken: 'replacement-account');
      await db.upsertServer(original);
      await db.useServer(original);
      await manager.addDownload(video.videoId, audioOnly: true);
      final queued = db.getDownloadByVideoId(video.videoId)!;
      final partial = File('${await queued.downloadPath}.audio.part');
      await partial.writeAsBytes([0, 1, 2]);
      await db.upsertServer(replacement);
      await db.useServer(replacement);
      if (removeOriginal) await db.deleteServer(original);
      final requests = <Server>[];
      service = _DownloadService((_) async => remote,
          onServer: (server) => requests.add(server!));

      await manager.setWifiOnly(false);
      await waitFor((state) =>
          state.videos.single.downloadComplete ||
          state.videos.single.downloadFailed);

      final saved = db.getDownloadByVideoId(video.videoId)!;
      expect(saved.accountId, original.accountId);
      if (removeOriginal) {
        expect(requests, isEmpty);
        expect(saved.downloadFailed, isTrue);
        expect(saved.downloadComplete, isFalse);
        expect(await partial.readAsBytes(), [0, 1, 2]);
      } else {
        expect(requests.single.accountId, original.accountId);
        expect(requests.single.authToken, original.authToken);
        expect(saved.downloadComplete, isTrue);
      }
      expect((await db.getCurrentlySelectedServer()).accountId,
          replacement.accountId);
    });
  }

  for (final wrapped in [false, true]) {
    test('expired gateway pauses a download across restart (Dio: $wrapped)',
        () async {
      await db.upsertDownload(video.copyWith(audioOnly: true));
      final partial = File('${await video.downloadPath}.audio.part');
      await partial.writeAsBytes([0, 1, 2]);
      var requests = 0;
      service = _DownloadService((_) async {
        requests++;
        if (wrapped) {
          throw DioException(
              requestOptions: RequestOptions(path: '/audio'),
              error: const GatewayAuthenticationRequired());
        }
        throw const GatewayAuthenticationRequired();
      });

      await manager.setWifiOnly(false);
      await waitFor((state) =>
          state.videos.single.authenticationRequired &&
          state.downloadProgresses.isEmpty);
      expect(requests, 1);
      expect(manager.state.videos.single.downloadFailed, isFalse);
      expect(manager.state.pausedVideoIds, contains(video.videoId));
      expect(await partial.readAsBytes(), [0, 1, 2]);
      await manager.close();
      await openManager();
      expect(manager.state.videos.single.authenticationRequired, isTrue);
      expect(requests, 1);

      final remote = await audioVideo(video.videoId);
      service = _DownloadService((_) async => remote);
      await manager.retryDownload(manager.state.videos.single);
      await waitFor((state) => state.videos.single.downloadComplete);
      expect(manager.state.videos.single.authenticationRequired, isFalse);
      expect(manager.state.pausedVideoIds, isEmpty);
    });
  }

  test('switching people cancels metadata and ignores its late completion',
      () async {
    final originalLibrary = db.forProfile(db.profileId);
    final metadata = Completer<Video>();
    final started = Completer<void>();
    service = _DownloadService((_) {
      started.complete();
      return metadata.future;
    });
    await manager.setWifiOnly(false);
    await started.future;
    await manager.pauseForProfileSwitch().timeout(const Duration(seconds: 2));
    final person = await db.createProfile('Another person');
    await db.useProfile(person.id);
    await db.useServer(Server(
        profileId: person.id,
        id: 'another-account',
        url: 'https://instance.invalid'));
    await manager.reloadForProfile();
    metadata.complete(Video(videoId: video.videoId, title: 'Late result'));
    await Future<void>.delayed(Duration.zero);

    expect(manager.state.videos, isEmpty);
    expect(db.getAllDownloads(), isEmpty);
    expect(originalLibrary.getAllDownloads(), hasLength(1));
    expect(originalLibrary.getAllDownloads().single.downloadFailed, isFalse);
    expect(originalLibrary.getSettings('downloads-paused')!.value,
        contains(video.videoId));
    expect(await File(await video.downloadPath).exists(), isFalse);
  });

  test('stale actions cannot delete or resume another person\'s matching video',
      () async {
    final original = video.copyWith(downloadComplete: true);
    await db.upsertDownload(original);
    await File(await original.downloadPath).writeAsString('original');
    await manager.pauseForProfileSwitch();
    final person = await db.createProfile('Another person');
    await db.useProfile(person.id);
    await db.saveSetting(SettingsValue('downloads-wifi-only', 'true'));
    final other = video.copyWith(
        profileId: person.id, title: 'Other', downloadComplete: true);
    await db.upsertDownload(other);
    await File(await other.downloadPath).writeAsString('other');
    await manager.reloadForProfile();

    await manager.deleteVideo(original);
    await manager.retryDownload(original);
    await manager.pauseDownload(original);

    expect(db.getAllDownloads(), [other]);
    expect(manager.state.videos, [other]);
    expect(manager.state.pausedVideoIds, isEmpty);
    expect(await File(await other.downloadPath).readAsString(), 'other');
    expect(await File(await original.downloadPath).readAsString(), 'original');
  });

  test('a profile switch preserves an active partial and resumes its owner',
      () async {
    const originalBytes = [0, 1, 2, 3, 4, 5, 6, 7];
    const otherBytes = [8, 9, 10, 11, 12, 13, 14, 15];
    final releaseFirstResponse = Completer<void>();
    addTearDown(() {
      if (!releaseFirstResponse.isCompleted) releaseFirstResponse.complete();
    });
    final ranges = <String?>[];
    var originalRequests = 0;
    mediaServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    mediaServer!.listen((request) async {
      try {
        if (request.uri.queryParameters['person'] != 'default') {
          request.response.add(otherBytes);
        } else {
          ranges.add(request.headers.value(HttpHeaders.rangeHeader));
          if (++originalRequests == 1) {
            request.response.bufferOutput = false;
            request.response.add(originalBytes.take(3).toList());
            await request.response.flush();
            await releaseFirstResponse.future;
            request.response.add(originalBytes.skip(3).toList());
          } else {
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers
                .set(HttpHeaders.contentRangeHeader, 'bytes 3-7/8');
            request.response.add(originalBytes.skip(3).toList());
          }
        }
        await request.response.close();
      } on SocketException {
        // The profile switch intentionally closes the first response early.
      } on HttpException {
        // A cancelled connection can reject the remaining response bytes.
      }
    });
    Server? requestedAccount;
    service = _DownloadService((_) async {
      return Video(videoId: video.videoId, adaptiveFormats: [
        AdaptiveFormat(
            null,
            '128000',
            null,
            'http://127.0.0.1:${mediaServer!.port}/audio?person=${requestedAccount!.profileId}',
            '251',
            'audio/webm',
            '8',
            '1',
            '',
            'webm',
            'opus',
            null,
            null)
      ]);
    }, onServer: (server) => requestedAccount = server);
    await db.upsertDownload(video.copyWith(audioOnly: true));
    await manager.setWifiOnly(false);
    await waitFor((state) => state.totalProgress > 0).onError<TimeoutException>(
        (_, __) =>
            throw StateError('First transfer did not start: ${manager.state}'));
    await manager.pauseForProfileSwitch().timeout(const Duration(seconds: 2));
    releaseFirstResponse.complete();
    final originalLibrary = db.forProfile('default');
    final partial = File('${await video.downloadPath}.audio.part');
    expect(await partial.readAsBytes(), originalBytes.take(3).toList());

    final person = await db.createProfile('Other downloader');
    await db.useProfile(person.id);
    await db.useServer(Server(
        profileId: person.id,
        id: 'other-download-account',
        url: 'https://instance.invalid'));
    await manager.reloadForProfile();
    await manager.addDownload(video.videoId, audioOnly: true);
    await waitFor((state) => state.videos.single.downloadComplete)
        .onError<TimeoutException>((_, __) => throw StateError(
            'Other transfer did not complete: ${manager.state}'));
    final other = manager.state.videos.single;
    expect(await File(await other.downloadPath).readAsBytes(), otherBytes);
    expect(originalLibrary.getAllDownloads().single.downloadComplete, isFalse);
    expect(await partial.readAsBytes(), originalBytes.take(3).toList());

    await manager.pauseForProfileSwitch();
    await db.useProfile('default');
    await manager.reloadForProfile();
    await manager.close();
    await openManager();
    expect(manager.state.pausedVideoIds, contains(video.videoId));
    await manager.retryDownload(manager.state.videos.single);
    await waitFor((state) => state.videos.single.downloadComplete)
        .onError<TimeoutException>((_, __) => throw StateError(
            'Original resume did not complete: ${manager.state}'));
    expect(ranges, [null, 'bytes=3-']);
    expect(await File(await video.downloadPath).readAsBytes(), originalBytes);
    expect(await File(await other.downloadPath).readAsBytes(), otherBytes);
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
