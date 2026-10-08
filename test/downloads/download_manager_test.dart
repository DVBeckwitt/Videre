import 'dart:async';
import 'dart:io';

import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
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

  _DownloadService(this.fetch);

  @override
  Future<Video> getVideo(String videoId, {Server? serverOverride}) =>
      fetch(videoId);
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

  Future<void> waitFor(bool Function(DownloadManagerState) predicate) async {
    if (!predicate(manager.state)) {
      await manager.stream
          .firstWhere(predicate)
          .timeout(const Duration(seconds: 5));
    }
  }

  Future<Video> audioVideo(String videoId, {void Function()? onRequest}) async {
    const bytes = [0, 1, 2, 3, 4, 5, 6, 7];
    mediaServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    mediaServer!.listen((request) async {
      onRequest?.call();
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

  setUp(() async {
    originalService = service;
    documentsDirectory =
        await Directory.systemTemp.createTemp('videre-download-manager-test-');
    mediaServer = null;
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documentsDirectory.path);
    db = await SembastSqfDb.createInMemory();
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
    final remote = await audioVideo(audio.videoId, onRequest: () => requests++);
    final metadata = Completer<Video>();
    var fetches = 0;
    service = _DownloadService((_) {
      fetches++;
      return fetches == 1 ? metadata.future : Future.value(remote);
    });
    await manager.setWifiOnly(false);
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

  test('deleting an active metadata request never restores the removed job',
      () async {
    final metadata = Completer<Video>();
    service = _DownloadService((_) => metadata.future);
    await manager.setWifiOnly(false);
    final deleting = manager.deleteVideo(video);
    metadata.complete(Video(videoId: video.videoId, adaptiveFormats: []));
    await deleting;
    expect(manager.state.videos, isEmpty);
    expect(db.getDownloadByVideoId(video.videoId), isNull);
    expect(manager.state.downloadProgresses, isEmpty);
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
