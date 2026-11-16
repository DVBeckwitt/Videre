import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/podcasts/models/podcast.dart';
import 'package:clipious/globals.dart' as globals;
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/podcasts/services/podcast_downloads.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

String _id(String text) => sha256.convert(utf8.encode(text)).toString();

class _Player extends Fake implements PlayerCubit {}

void main() {
  late SembastSqfDb database;
  late Directory directory;
  late HttpServer server;
  late PodcastDownloads downloads;
  late Future<void> Function(HttpRequest) respond;
  late PodcastEpisode episode;
  late PodcastFeed feed;
  late StreamController<bool> connectivity;
  var wifiConnected = true;
  Future<bool> Function()? wifiQuery;
  final audio = List<int>.generate(64, (index) => index);
  final heldResponses = <Completer<void>>[];
  final services = <PodcastDownloads>[];
  var requests = 0;

  PodcastDownloads service([String? profile]) {
    final result = PodcastDownloads.forProfile(
        database, profile ?? database.profileId,
        documentsDirectory: () async => directory,
        wifiConnected: () async =>
            wifiQuery == null ? wifiConnected : await wifiQuery!(),
        networkChanges: connectivity.stream);
    services.add(result);
    return result;
  }

  setUp(() async {
    requests = 0;
    wifiConnected = true;
    wifiQuery = null;
    connectivity = StreamController<bool>.broadcast();
    database = await SembastSqfDb.createInMemory();
    globals.db = database;
    directory =
        await Directory.systemTemp.createTemp('videre-podcast-download');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final url = 'http://${server.address.address}:${server.port}';
    episode = PodcastEpisode(
        id: _id('episode'),
        title: 'First episode',
        mediaUrl: '$url/audio.mp3',
        mimeType: 'audio/mpeg',
        lengthBytes: audio.length,
        durationSeconds: 30);
    feed = PodcastFeed(
        id: _id('feed'),
        feedUrl: '$url/feed.xml',
        title: 'A podcast',
        episodes: [episode]);
    respond = (request) async {
      request.response.headers.contentType = ContentType('audio', 'mpeg');
      request.response.contentLength = audio.length;
      request.response.add(audio);
      await request.response.close();
    };
    server.listen((request) {
      requests++;
      unawaited(respond(request).catchError((_) {}));
    });
    downloads = service();
  });

  tearDown(() async {
    for (final response in heldResponses) {
      if (!response.isCompleted) response.complete();
    }
    heldResponses.clear();
    for (final item in services.toSet()) {
      await item.cancelAll();
      item.dispose();
    }
    services.clear();
    await connectivity.close();
    await server.close(force: true);
    database.close();
    await directory.delete(recursive: true);
  });

  test('downloads publisher audio and resolves completed file without network',
      () async {
    await downloads.download(feed, episode);
    expect(requests, 1);
    expect(downloads.entries.single.episode.title, 'First episode');
    expect(downloads.entries.single.feedTitle, 'A podcast');
    final path = await downloads.localPath(episode.id);
    expect(path, isNotNull);
    expect(await File(path!).readAsBytes(), audio);
    expect(path, startsWith(directory.path));
    expect(downloads.progress, isEmpty);
    expect(downloads.activeId, isNull);

    await server.close(force: true);
    expect(await downloads.localPath(episode.id), path);
    await downloads.download(feed, episode);
    expect(requests, 1);
    expect(downloads.entries, hasLength(1));
    expect(await File(path).exists(), isTrue);
    expect(
        await directory
            .list(recursive: true)
            .where((entry) =>
                entry.path.endsWith('.part') ||
                entry.path.endsWith('.identity'))
            .toList(),
        isEmpty);
  });

  test(
      'completed metadata and files remain available across service recreation',
      () async {
    await downloads.download(feed, episode);
    final owner = database.forProfile(database.profileId);
    final recreated = PodcastDownloads.forProfile(owner, owner.profileId,
        documentsDirectory: () async => directory);
    services.add(recreated);
    expect(recreated.entries.single.episode.id, episode.id);
    expect(await recreated.localPath(episode.id),
        await downloads.localPath(episode.id));
  });

  test('same profile shares the in-flight service across screens', () {
    expect(service(), same(downloads));
  });

  test('missing or truncated completed files are never offline playable',
      () async {
    await downloads.download(feed, episode);
    final path = (await downloads.localPath(episode.id))!;
    await File(path).writeAsBytes(audio.take(4).toList());
    expect(await downloads.localPath(episode.id), isNull);
    expect(downloads.entries, isEmpty);
    await downloads.download(feed, episode);
    expect(await File((await downloads.localPath(episode.id))!).readAsBytes(),
        audio);
    await File(path).delete();
    expect(await downloads.localPath(episode.id), isNull);
    expect(downloads.entries, isEmpty);
  });

  test(
      'Wi-Fi-only preference prevents a mobile download before its first request',
      () async {
    await database.saveSetting(SettingsValue('downloads-wifi-only', 'true'));
    wifiConnected = false;
    await downloads.download(feed, episode);
    expect(requests, 0);
    expect(downloads.entries, isEmpty);
    expect(downloads.errors[episode.id], contains('Wi-Fi'));
    wifiConnected = true;
    await downloads.download(feed, episode);
    expect(requests, 1);
    expect(downloads.entries, hasLength(1));
    expect(downloads.errors, isEmpty);
  });

  test('losing Wi-Fi cancels an active Wi-Fi-only download without completion',
      () async {
    await database.saveSetting(SettingsValue('downloads-wifi-only', 'true'));
    final started = Completer<void>();
    final release = Completer<void>();
    heldResponses.add(release);
    respond = (request) async {
      request.response.headers.contentType = ContentType('audio', 'mpeg');
      request.response.contentLength = audio.length;
      request.response.add(audio.take(8).toList());
      await request.response.flush();
      started.complete();
      await release.future;
    };
    final downloading = downloads.download(feed, episode);
    await started.future;
    wifiConnected = false;
    connectivity.add(false);
    await downloading;
    expect(downloads.activeId, isNull);
    expect(downloads.entries, isEmpty);
    expect(downloads.errors[episode.id], contains('Wi-Fi'));
  });

  for (final connected in [false, true]) {
    test(
        connected
            ? 'enabling Wi-Fi-only preserves an active Wi-Fi podcast download'
            : 'enabling Wi-Fi-only cancels an active cellular podcast download',
        () async {
      wifiConnected = connected;
      final manager =
          DownloadManagerCubit(const DownloadManagerState(), _Player());
      final started = Completer<void>();
      final release = Completer<void>();
      heldResponses.add(release);
      respond = (request) async {
        request.response.headers.contentType = ContentType('audio', 'mpeg');
        request.response.contentLength = audio.length;
        request.response.add(audio.take(8).toList());
        await request.response.flush();
        started.complete();
        await release.future;
        request.response.add(audio.skip(8).toList());
        await request.response.close();
      };
      final downloading = downloads.download(feed, episode);
      try {
        await started.future;
        await manager.setWifiOnly(true);
        release.complete();
        await downloading;
        if (connected) {
          expect(downloads.entries, hasLength(1));
          expect(downloads.errors, isEmpty);
        } else {
          expect(downloads.entries, isEmpty);
          expect(downloads.errors[episode.id], contains('Wi-Fi'));
        }
      } finally {
        await manager.close();
      }
    });
  }

  test('a delayed Wi-Fi policy query cannot cancel a replacement transfer',
      () async {
    final manager =
        DownloadManagerCubit(const DownloadManagerState(), _Player());
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final firstRelease = Completer<void>();
    final secondRelease = Completer<void>();
    heldResponses.addAll([firstRelease, secondRelease]);
    respond = (request) async {
      final first = requests == 1;
      request.response.headers.contentType = ContentType('audio', 'mpeg');
      request.response.contentLength = audio.length;
      request.response.add(audio.take(8).toList());
      await request.response.flush();
      (first ? firstStarted : secondStarted).complete();
      await (first ? firstRelease : secondRelease).future;
      request.response.add(audio.skip(8).toList());
      await request.response.close();
    };
    final firstDownload = downloads.download(feed, episode);
    final queryStarted = Completer<void>();
    final queryResult = Completer<bool>();
    try {
      await firstStarted.future;
      wifiQuery = () {
        queryStarted.complete();
        return queryResult.future;
      };
      final settingChanged = manager.setWifiOnly(true);
      await queryStarted.future;
      downloads.cancel(episode.id);
      await firstDownload;
      wifiQuery = null;
      final replacement = downloads.download(feed, episode);
      await secondStarted.future;
      queryResult.complete(false);
      await settingChanged;
      secondRelease.complete();
      await replacement;
      expect(downloads.entries, hasLength(1));
      expect(downloads.errors, isEmpty);
    } finally {
      if (!queryResult.isCompleted) queryResult.complete(false);
      await manager.close();
    }
  });

  test('cancel stops a transfer and leaves no complete or partial download',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    heldResponses.add(release);
    respond = (request) async {
      request.response.headers.contentType = ContentType('audio', 'mpeg');
      request.response.contentLength = audio.length;
      request.response.add(audio.take(8).toList());
      await request.response.flush();
      started.complete();
      await release.future;
      request.response.add(audio.skip(8).toList());
      await request.response.close();
    };
    final downloading = downloads.download(feed, episode);
    await started.future;
    expect(downloads.isDownloading(episode.id), isTrue);
    expect(await downloads.localPath(episode.id), isNull);
    downloads.cancel(episode.id);
    await downloading;
    expect(downloads.entries, isEmpty);
    expect(downloads.errors, isEmpty);
    expect(
        await directory
            .list(recursive: true)
            .where((entry) => entry is File)
            .toList(),
        isEmpty);
  });

  test('cancelAll joins the current file writer before returning', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    heldResponses.add(release);
    respond = (request) async {
      request.response.headers.contentType = ContentType('audio', 'mpeg');
      request.response.contentLength = audio.length;
      request.response.add(audio.take(8).toList());
      await request.response.flush();
      started.complete();
      await release.future;
    };
    final downloading = downloads.download(feed, episode);
    await started.future;
    await downloads.cancelAll();
    await downloading;
    expect(downloads.activeId, isNull);
    expect(downloads.entries, isEmpty);
  });

  test(
      'changing the network proxy cancels and joins an active podcast transfer',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    heldResponses.add(release);
    respond = (request) async {
      request.response.headers.contentType = ContentType('audio', 'mpeg');
      request.response.contentLength = audio.length;
      request.response.add(audio.take(8).toList());
      await request.response.flush();
      started.complete();
      await release.future;
    };
    final downloading = downloads.download(feed, episode);
    await started.future;
    await NetworkProxy.instance.apply(SocksProxyConfig(host: 'localhost'));
    await downloading;
    expect(downloads.activeId, isNull);
    expect(downloads.entries, isEmpty);
    expect(downloads.errors, isEmpty);
  });

  test('incomplete content cannot create completion metadata', () async {
    respond = (request) async {
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.add(ascii.encode('HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\n'
          'Content-Length: ${audio.length}\r\nConnection: close\r\n\r\n'));
      socket.add(audio.take(4).toList());
      await socket.flush();
      await socket.close();
    };
    await expectLater(downloads.download(feed, episode), throwsStateError);
    expect(downloads.entries, isEmpty);
    expect(await downloads.localPath(episode.id), isNull);
    expect(downloads.errors[episode.id], isNot(contains(episode.mediaUrl)));
  });

  test('stale RSS enclosure length does not reject a complete HTTP response',
      () async {
    final stale = PodcastEpisode(
        id: episode.id,
        title: episode.title,
        mediaUrl: episode.mediaUrl,
        mimeType: episode.mimeType,
        lengthBytes: 4);
    await downloads.download(feed, stale);
    expect(downloads.entries.single.bytes, audio.length);
    expect(await File((await downloads.localPath(episode.id))!).readAsBytes(),
        audio);
  });

  test('HTML error pages are rejected even with a successful status', () async {
    respond = (request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.add(audio);
      await request.response.close();
    };
    await expectLater(downloads.download(feed, episode), throwsStateError);
    expect(downloads.entries, isEmpty);
  });

  test('official Google and YouTube redirects cannot produce downloads',
      () async {
    for (final destination in [
      'https://www.youtube.com/audio.mp3',
      'https://media.googlevideo.com/audio.mp3',
      'https://feeds.feedburner.com/podcast',
    ]) {
      respond = (request) async {
        request.response.statusCode = 302;
        request.response.headers.set(HttpHeaders.locationHeader, destination);
        await request.response.close();
      };
      await expectLater(downloads.download(feed, episode), throwsStateError);
      expect(downloads.entries, isEmpty);
    }
    expect(requests, 3);
  });

  test('oversized enclosure is rejected before downloading bytes', () async {
    final tooLarge = PodcastEpisode(
        id: episode.id,
        title: episode.title,
        mediaUrl: episode.mediaUrl,
        mimeType: episode.mimeType,
        lengthBytes: PodcastDownloads.maximumDownloadBytes + 1);
    await expectLater(downloads.download(feed, tooLarge), throwsStateError);
    expect(requests, 0);
    expect(downloads.entries, isEmpty);
  });

  test(
      'profile changes keep completed metadata and paths in the original owner',
      () async {
    final original = database.profileId;
    final other = await database.createProfile('Other person');
    await database.useProfile(other.id);
    await downloads.download(feed, episode);
    final others = service(other.id);
    expect(others.entries, isEmpty);
    expect(await others.localPath(episode.id), isNull);
    await others.download(feed, episode);
    expect(await others.localPath(episode.id),
        isNot(await downloads.localPath(episode.id)));
    expect(database.forProfile(original).getSettings(podcastDownloadsSetting),
        isNotNull);
    await others.remove(episode.id);
    expect(await downloads.localPath(episode.id), isNotNull);
    expect(others.entries, isEmpty);
  });

  test('removing a download removes its own metadata and file only', () async {
    await downloads.download(feed, episode);
    final unrelated = File('${directory.path}/keep.txt');
    await unrelated.writeAsString('keep');
    final path = (await downloads.localPath(episode.id))!;
    await downloads.remove(episode.id);
    expect(downloads.entries, isEmpty);
    expect(await File(path).exists(), isFalse);
    expect(await unrelated.readAsString(), 'keep');
  });

  test('invalid stored metadata never exposes arbitrary paths', () async {
    await database.saveSetting(SettingsValue(
        podcastDownloadsSetting,
        jsonEncode({
          'version': 1,
          'entries': [
            {
              'feedId': '../../unsafe',
              'feedTitle': 'Broken',
              'episode': {'id': '../../file'},
              'bytes': 10
            }
          ],
        })));
    expect(downloads.entries, isEmpty);
    expect(await downloads.localPath('../../file'), isNull);
  });
}
