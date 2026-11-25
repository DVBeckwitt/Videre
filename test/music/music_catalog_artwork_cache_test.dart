import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clipious/music/models/music_artwork_cache.dart';
import 'package:clipious/music/services/music_artwork_cache.dart';
import 'package:clipious/music/services/music_catalog_artwork_cache.dart';
import 'package:clipious/music/services/music_community_cover_cache.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:file/file.dart' as fs;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

class _Files implements FileSystem {
  _Files(this.directory);
  final Directory directory;
  @override
  Future<fs.File> createFile(String name) async =>
      const LocalFileSystem().file(p.join(directory.path, name));
}

class _BodyService extends FileService {
  _BodyService(this.response, {this.contentLength});
  final FutureOr<Stream<List<int>>> Function(String url) response;
  final int? Function(String url)? contentLength;
  @override
  Future<FileServiceResponse> get(String url,
          {Map<String, String>? headers}) async =>
      HttpGetResponse(http.StreamedResponse(await response(url), 200,
          contentLength: contentLength?.call(url),
          headers: {'content-type': 'application/vnd.cover+json'}));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final caches = <MusicCatalogArtworkCache>[];
  final folders = <String, Directory>{};
  const url = 'https://instance.example/ggpht/cover';
  const key = 'private-account-image';
  const mib = 1024 * 1024;
  const timeout = Duration(seconds: 5);

  setUp(
      () async => root = await Directory.systemTemp.createTemp('videre-art-'));

  tearDown(() async {
    for (final cache in caches) {
      await cache.dispose();
    }
    caches.clear();
    folders.clear();
    await root.delete(recursive: true);
  });

  MusicCatalogArtworkCache create(
      String profile, Future<http.Response> Function(http.Request) reply,
      {void Function()? onStored,
      FileService? service,
      bool Function()? available}) {
    final cache = MusicCatalogArtworkCache(profile, onStored: onStored,
        configFactory: (namespace) {
      if (available?.call() == false) {
        throw const FileSystemException('Unavailable storage');
      }
      final directory = Directory(p.join(root.path, namespace))..createSync();
      folders[profile] = directory;
      return Config(namespace,
          fileSystem: _Files(directory),
          repo: JsonCacheInfoRepository.withFile(
              File(p.join(directory.path, 'index.json'))),
          fileService:
              service ?? HttpFileService(httpClient: MockClient(reply)));
    });
    caches.add(cache);
    return cache;
  }

  Future<int> artworkBytes(String profile) async {
    final folder = folders[profile];
    if (folder == null) return 0;
    var bytes = 0;
    await for (final entry in folder.list(recursive: true)) {
      if (entry is File && p.basename(entry.path) != 'index.json') {
        bytes += (await entry.stat()).size;
      }
    }
    return bytes;
  }

  Future<void> waitForArtworkBytes(String profile, int bytes) async {
    final watch = Stopwatch()..start();
    while (await artworkBytes(profile) != bytes && watch.elapsed < timeout) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await artworkBytes(profile), bytes);
  }

  MusicArtworkCache coordinator(SembastSqfDb database,
          FileService Function(String profile) services) =>
      MusicArtworkCache(
        community: MusicCommunityCoverCache(supportDirectory: () async => root),
        catalog: (profile, onStored) => create(
            profile, (_) async => http.Response('', 503),
            onStored: onStored, service: services(profile)),
        database: database.forProfile,
      );

  test('reports and clears artwork while its HTTP body is still open',
      () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    final owner = database.forProfile(database.profileId);
    final other =
        database.forProfile((await database.createProfile('Other')).id);
    for (final profile in [owner, other]) {
      await profile
          .saveSetting(SettingsValue(musicArtworkCacheLimitSettingName, '16'));
    }
    final bodyCanceled = Completer<void>();
    final body = StreamController<List<int>>(onCancel: bodyCanceled.complete);
    final otherBody = StreamController<List<int>>();
    var requests = 0;
    final cache = coordinator(
        database,
        (profile) => _BodyService((_) {
              if (profile == other.profileId) return otherBody.stream;
              if (++requests == 1) return body.stream;
              return Stream.value([9, 8]);
            }));
    final original = cache
        .catalogManager(owner.profileId)
        .getFileStream(url, key: key, withProgress: true);
    final otherDownload =
        cache.catalogManager(other.profileId).getSingleFile(url, key: key);
    final originalResult = original.toList();
    // Attach an error listener immediately so a failing assertion can still
    // release the held bodies without leaking an unhandled download error.
    unawaited(originalResult.then<void>((_) {}, onError: (Object _) {}));
    unawaited(otherDownload.then<void>((_) {}, onError: (Object _) {}));
    try {
      // The two independent profiles can each write more than half the limit.
      const activeBytes = 9 * mib;
      body.add(Uint8List(activeBytes));
      otherBody.add(Uint8List(activeBytes));
      await waitForArtworkBytes(owner.profileId, activeBytes);
      await waitForArtworkBytes(other.profileId, activeBytes);
      expect(await cache.read(owner),
          (usedBytes: activeBytes, limitMiB: 16, hasTransfers: true));
      expect((await cache.read(other)).usedBytes, activeBytes);
      final clearedDownload = expectLater(
          originalResult.timeout(timeout), throwsA(isA<HttpException>()));

      final cleared = await cache.clear(owner).timeout(timeout);
      expect(cleared, (usedBytes: 0, limitMiB: 16, hasTransfers: false));
      expect(await artworkBytes(owner.profileId), 0);
      await clearedDownload;
      await bodyCanceled.future.timeout(timeout);
      expect(await artworkBytes(other.profileId), activeBytes);
      expect((await cache.read(other)).usedBytes, activeBytes);

      final manager = cache.catalogManager(owner.profileId);
      expect(await manager.getFileFromCache(key), isNull);
      final fresh = await manager.getSingleFile(url, key: key);
      body.add([6, 5, 4]);
      await body.close().timeout(timeout);
      expect(await fresh.readAsBytes(), [9, 8]);
      expect((await cache.read(owner)).usedBytes, 2);
      expect(await artworkBytes(owner.profileId), 2);
      expect(requests, 2);

      await otherBody.close().timeout(timeout);
      final otherCover = await otherDownload.timeout(timeout);
      expect(await otherCover.length(), activeBytes);
      expect((await cache.read(other)).usedBytes, activeBytes);
    } finally {
      if (!body.isClosed) unawaited(body.close());
      if (!otherBody.isClosed) unawaited(otherBody.close());
    }
  });

  test('concurrent chunked responses share the limit before HTTP completes',
      () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    final owner = database.forProfile(database.profileId);
    await owner
        .saveSetting(SettingsValue(musicArtworkCacheLimitSettingName, '16'));
    final firstBody = StreamController<List<int>>();
    final secondCanceled = Completer<void>();
    final secondBody =
        StreamController<List<int>>(onCancel: secondCanceled.complete);
    var secondRequests = 0;
    final cache = coordinator(
        database,
        (_) => _BodyService((address) {
              if (address == url) return firstBody.stream;
              if (++secondRequests == 1) return secondBody.stream;
              return Stream.value([7, 6]);
            }));
    final manager = cache.catalogManager(owner.profileId);
    final first = manager.getSingleFile(url, key: key);
    final secondUrl = '$url-concurrent';
    final second = manager.getSingleFile(secondUrl);
    unawaited(first.then<void>((_) {}, onError: (Object _) {}));
    unawaited(second.then<void>((_) {}, onError: (Object _) {}));

    try {
      firstBody.add(Uint8List(9 * mib));
      await waitForArtworkBytes(owner.profileId, 9 * mib);
      secondBody.add(Uint8List(7 * mib));
      await waitForArtworkBytes(owner.profileId, 16 * mib);
      expect(await cache.read(owner),
          (usedBytes: 16 * mib, limitMiB: 16, hasTransfers: true));

      final rejected =
          expectLater(second.timeout(timeout), throwsA(isA<HttpException>()));
      secondBody.add([1]);
      await rejected;
      await secondCanceled.future.timeout(timeout);
      expect(firstBody.isClosed, isFalse);
      expect(secondBody.isClosed, isFalse);
      expect(await artworkBytes(owner.profileId), 9 * mib);
      expect(await manager.getFileFromCache(secondUrl), isNull);
      expect((await cache.read(owner)).usedBytes, 9 * mib);

      final replacement = await manager.getSingleFile(secondUrl);
      expect(await replacement.readAsBytes(), [7, 6]);
      expect(secondRequests, 2);
      await firstBody.close().timeout(timeout);
      expect(await (await first.timeout(timeout)).length(), 9 * mib);
      expect(await cache.read(owner),
          (usedBytes: 9 * mib + 2, limitMiB: 16, hasTransfers: false));
    } finally {
      if (!firstBody.isClosed) unawaited(firstBody.close());
      if (!secondBody.isClosed) unawaited(secondBody.close());
    }
  });

  test('a held refresh is indexed even if its own stale cover is evicted',
      () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    final owner = database.forProfile(database.profileId);
    await owner
        .saveSetting(SettingsValue(musicArtworkCacheLimitSettingName, '16'));
    final body = StreamController<List<int>>();
    var requests = 0;
    final cache = coordinator(
        database,
        (_) => _BodyService(
            (_) => ++requests == 1 ? body.stream : Stream.value([1])));
    final manager = cache.catalogManager(owner.profileId);
    final oldCover = await manager.putFile(url, Uint8List(8 * mib),
        key: key,
        eTag: '"old"',
        maxAge: const Duration(days: -1),
        fileExtension: 'vnd.cover+json');
    expect((await manager.getFileFromCache(key))?.file.path, oldCover.path);
    expect(await artworkBytes(owner.profileId), 8 * mib);

    final active = manager.getFileStream(url, key: key).toList();
    unawaited(active.then<void>((_) {}, onError: (Object _) {}));
    try {
      body.add(Uint8List(9 * mib));
      await waitForArtworkBytes(owner.profileId, 9 * mib);
      expect(body.isClosed, isFalse);
      expect(await oldCover.exists(), isFalse);
      expect(await manager.getFileFromCache(key), isNull);
      expect(await cache.read(owner),
          (usedBytes: 9 * mib, limitMiB: 16, hasTransfers: true));

      await body.close().timeout(timeout);
      final covers = (await active.timeout(timeout)).whereType<FileInfo>();
      expect(covers.map((cover) => cover.source),
          [FileSource.Cache, FileSource.Online]);
      final replacement = covers.last.file;
      expect(await replacement.length(), 9 * mib);
      expect(await cache.read(owner),
          (usedBytes: 9 * mib, limitMiB: 16, hasTransfers: false));
      expect(
          (await manager.getSingleFile(url, key: key)).path, replacement.path);
      expect(requests, 1);
    } finally {
      if (!body.isClosed) unawaited(body.close());
    }
  });

  test('lowering the limit cancels only the newest write needed to fit',
      () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    final owner = database.forProfile(database.profileId);
    final firstBody = StreamController<List<int>>();
    final secondCanceled = Completer<void>();
    final secondBody =
        StreamController<List<int>>(onCancel: secondCanceled.complete);
    final secondUrl = '$url-newer';
    final cache = coordinator(
        database,
        (_) => _BodyService((address) {
              return address == url ? firstBody.stream : secondBody.stream;
            }));
    await cache.configure(owner, 32);
    final manager = cache.catalogManager(owner.profileId);
    final first = manager.getSingleFile(url, key: key);
    unawaited(first.then<void>((_) {}, onError: (Object _) {}));
    try {
      firstBody.add(Uint8List(4 * mib));
      await waitForArtworkBytes(owner.profileId, 4 * mib);
      final second = manager.getSingleFile(secondUrl);
      final rejected =
          expectLater(second.timeout(timeout), throwsA(isA<HttpException>()));
      secondBody.add(Uint8List(15 * mib));
      await waitForArtworkBytes(owner.profileId, 19 * mib);

      expect(await cache.configure(owner, 16).timeout(timeout),
          (usedBytes: 4 * mib, limitMiB: 16, hasTransfers: true));
      await rejected;
      await secondCanceled.future.timeout(timeout);
      expect(await artworkBytes(owner.profileId), 4 * mib);
      expect(await manager.getFileFromCache(secondUrl), isNull);

      firstBody.add([1, 2]);
      await firstBody.close().timeout(timeout);
      expect(await (await first.timeout(timeout)).length(), 4 * mib + 2);
      expect(await cache.read(owner),
          (usedBytes: 4 * mib + 2, limitMiB: 16, hasTransfers: false));
    } finally {
      if (!firstBody.isClosed) unawaited(firstBody.close());
      if (!secondBody.isClosed) unawaited(secondBody.close());
    }
  });

  test('an oversized Content-Length is rejected before the body arrives',
      () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    final owner = database.forProfile(database.profileId);
    await owner
        .saveSetting(SettingsValue(musicArtworkCacheLimitSettingName, '16'));
    final oversizedBody = StreamController<List<int>>.broadcast();
    final oversizedUrl = '$url-oversized';
    final cache = coordinator(
        database,
        (_) => _BodyService(
            (address) => address == oversizedUrl
                ? oversizedBody.stream
                : Stream.value([1, 2, 3]),
            contentLength: (address) =>
                address == oversizedUrl ? 16 * mib + 1 : 3));
    final manager = cache.catalogManager(owner.profileId);
    try {
      final existing = await manager.getSingleFile(url, key: key);
      await expectLater(manager.getSingleFile(oversizedUrl).timeout(timeout),
          throwsA(isA<HttpException>()));
      expect(oversizedBody.isClosed, isFalse);
      expect(await existing.readAsBytes(), [1, 2, 3]);
      expect(await artworkBytes(owner.profileId), 3);
      expect(await cache.read(owner),
          (usedBytes: 3, limitMiB: 16, hasTransfers: false));
      expect(await manager.getFileFromCache(oversizedUrl), isNull);
      expect(await (await manager.getSingleFile('$url-small')).readAsBytes(),
          [1, 2, 3]);
    } finally {
      await oversizedBody.close();
    }
  });

  test('counts real bytes, touches hits and clears only the owning profile',
      () async {
    var stored = 0;
    var requests = 0;
    final first = create('one', (request) async {
      expect(request.headers['X-Account'], 'first');
      requests++;
      return http.Response.bytes([1, 2, 3], 200);
    }, onStored: () => stored++);
    final second = create('two', (_) async => http.Response.bytes([4], 200));
    expect(root.listSync(), isEmpty);
    final file = await first.manager
        .getSingleFile(url, key: key, headers: {'X-Account': 'first'});
    final other = await second.manager.getSingleFile(url, key: key);
    await file.writeAsBytes([5, 6], mode: FileMode.append);
    final original = (await first.entries()).single;
    expect(original.bytes, 5);
    expect(stored, 1);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await first.manager.getSingleFile(url, key: key);
    final recent = (await first.entries()).single;
    expect(recent.touched.isAfter(original.touched), isTrue);
    expect(requests, 1);
    expect(stored, 1);
    await original.remove();
    expect(await file.exists(), isTrue);
    await recent.remove();
    expect(await file.exists(), isFalse);
    expect(await first.entries(), isEmpty);
    await first.clear();
    expect(await other.readAsBytes(), [4]);
    expect((await second.entries()).single.bytes, 1);
  });

  test(
      'reopening keeps completed offline artwork and discards an abandoned write',
      () async {
    final initial =
        create('persistent', (_) async => http.Response.bytes([7, 8], 200));
    final cover = await initial.manager.getSingleFile(url, key: key);
    await initial.dispose();
    expect(await cover.readAsBytes(), [7, 8]);
    final index = File(p.join(cover.parent.path, 'index.json'));
    final rows = jsonDecode(await index.readAsString()) as List;
    expect(rows.single['relativePath'], p.basename(cover.path));
    final abandoned = File(
        p.join(cover.parent.path, '00000000-0000-0000-0000-000000000000.jpg'));
    await abandoned.writeAsBytes([1]);
    var requests = 0;
    final reopened = create('persistent', (_) async {
      requests++;
      return http.Response('', 503);
    });
    expect((await reopened.entries()).single.bytes, 2);
    expect(await abandoned.exists(), isFalse);
    final hit = await reopened.manager.getSingleFile(url, key: key);
    expect(await hit.readAsBytes(), [7, 8]);
    expect(requests, 0);
  });

  test('a storage lookup retries after the cache directory becomes available',
      () async {
    var online = false;
    final cache = create('retry', (_) async => http.Response('', 503),
        available: () => online);
    await expectLater(cache.entries(), throwsA(isA<FileSystemException>()));
    online = true;
    expect(await cache.entries(), isEmpty);
  });

  test(
      'idle cleanup removes a failed body while a canceled widget download may finish',
      () async {
    final release = Completer<void>();
    final live = StreamController<List<int>>();
    Stream<List<int>> failing() async* {
      yield [1, 2];
      await release.future;
      throw const HttpException('Lost connection');
    }

    final cache = create('partial', (_) async => http.Response('', 503),
        service: _BodyService(
            (address) => address == url ? live.stream : failing()));
    final consumer = cache.manager
        .getFileStream(url, withProgress: true)
        .firstWhere((event) => event is DownloadProgress);
    live.add([9]);
    await consumer; // firstWhere canceled the widget subscription.
    final failed =
        cache.manager.getFileStream('$url-broken', withProgress: true);
    final attempted = Completer<void>();
    final failedResult = expectLater(
        failed.map((event) {
          if (event is DownloadProgress && !attempted.isCompleted) {
            attempted.complete();
          }
        }).drain<void>(),
        throwsA(isA<HttpException>()));
    await attempted.future;
    release.complete();
    await failedResult;
    final continued = Completer<void>();
    final finalEvents =
        cache.manager.getFileStream(url, withProgress: true).map((event) {
      if (event is DownloadProgress && !continued.isCompleted) {
        continued.complete();
      }
      return event;
    }).toList();
    await continued.future;
    live.add([8]);
    await live.close();
    final complete = (await finalEvents).whereType<FileInfo>().last.file;
    expect(await complete.readAsBytes(), [9, 8]);
    final files = await complete.parent
        .list()
        .where((f) => f.path.endsWith('.vnd.cover+json'))
        .toList();
    expect(files, hasLength(1));
    expect((await cache.entries()).single.bytes, 2);
    await cache.clear();
    expect(await complete.exists(), isFalse);
  });

  test(
      'a failed late body after profile removal cannot leave files or disturb its replacement',
      () async {
    final started = Completer<void>();
    final sendHeaders = Completer<void>();
    Stream<List<int>> broken() async* {
      yield [7, 6];
      throw const HttpException('Broken response');
    }

    final retired = create('reused', (_) async => http.Response('', 503),
        service: _BodyService((_) async {
      started.complete();
      await sendHeaders.future;
      return broken();
    }));
    final failed = expectLater(retired.manager.getSingleFile(url, key: key),
        throwsA(isA<HttpException>()));
    await started.future;
    await retired.clear();
    await failed.timeout(timeout);
    await retired.dispose();
    final next = create(
        'reused',
        (_) async => http.Response.bytes([9], 200,
            headers: {'content-type': 'application/vnd.cover+json'}));
    final newCover = await next.manager.getSingleFile(url, key: key);
    sendHeaders.complete();
    expect(await newCover.readAsBytes(), [9]);
    final files = await newCover.parent
        .list()
        .where((entry) => entry.path.endsWith('.vnd.cover+json'))
        .toList();
    expect(files.map((entry) => entry.path), [newCover.path]);
  });

  test('a late response after clear cannot restore or replace a new download',
      () async {
    final started = Completer<void>();
    final oldResponse = Completer<http.Response>();
    var requests = 0;
    var stored = 0;
    final cache = create('profile', (_) async {
      if (++requests == 1) {
        started.complete();
        return oldResponse.future;
      }
      return http.Response.bytes([9, 8], 200);
    }, onStored: () => stored++);
    final old = expectLater(cache.manager.getSingleFile(url, key: key),
        throwsA(isA<HttpException>()));
    await started.future;
    await cache.clear();
    await old.timeout(timeout);
    expect(await cache.entries(), isEmpty);
    final fresh = await cache.manager.getSingleFile(url, key: key);
    oldResponse.complete(http.Response.bytes([1, 2, 3, 4], 200));
    expect((await cache.entries()).single.bytes, 2);
    expect(await fresh.readAsBytes(), [9, 8]);
    expect(stored, 1);
    expect(requests, 2);
  });
}
