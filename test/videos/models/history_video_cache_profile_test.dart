import 'dart:async';
import 'dart:convert';

import 'package:clipious/globals.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late SembastSqfDb database;

  setUp(() async {
    db = database = await SembastSqfDb.createInMemory();
  });

  tearDown(() async {
    service = Service();
    await database.close();
  });

  test('pending history metadata stays in the originating profile', () async {
    const origin = Server(
      url: 'https://instance.example',
      id: 'first-account',
      customHeaders: {'X-Person': 'first'},
    );
    await database.upsertServer(origin);
    final owner = database.forProfile(database.profileId);
    final other = await database.createProfile('Second person');
    final otherOwner = database.forProfile(other.id);
    await otherOwner.upsertServer(Server(
      url: origin.url,
      id: 'second-account',
      profileId: other.id,
      customHeaders: const {'X-Person': 'second'},
    ));

    final requested = Completer<void>();
    final response = Completer<http.Response>();
    final client = MockClient((request) async {
      expect(request.url.path, '/api/v1/videos/first-video');
      expect(request.headers['X-Person'], 'first');
      requested.complete();
      return response.future;
    });
    addTearDown(client.close);
    service = Service(httpClient: client);

    final pending = HistoryVideoCache.fromVideoIdToVideo('first-video');
    await requested.future;
    await database.useProfile(other.id);
    response.complete(http.Response(
        jsonEncode({
          'videoId': 'first-video',
          'title': 'First person history',
          'author': 'A channel',
          'lengthSeconds': 240,
          'videoThumbnails': [
            {
              'quality': 'high',
              'url': 'https://instance.example/thumbnail.jpg',
              'width': 1280,
              'height': 720,
            }
          ],
        }),
        200));

    final loaded = await pending;
    expect(loaded.title, 'First person history');
    expect(owner.getLocalHistory().single.videoId, 'first-video');
    expect(otherOwner.getLocalHistory(), isEmpty);
    expect(database.profileId, other.id);
  });

  test('cached history needs neither an account nor a network request',
      () async {
    final cached = HistoryVideoCache('cached', 'Local video', 'Channel', '');
    await database.upsertHistoryVideo(cached);
    final client = MockClient((_) async {
      fail('Cached history must not make a network request');
    });
    addTearDown(client.close);
    service = Service(httpClient: client);

    final loaded = await HistoryVideoCache.fromVideoIdToVideo('cached');

    expect(loaded.toJson(), cached.toJson());
    expect(database.getLocalHistory().length, 1);
  });

  test('cached Music history retains catalog artwork and song metadata',
      () async {
    const cover = 'https://lh3.googleusercontent.com/album=w512-h512';
    final stored = HistoryVideoCache.fromJson({
      'videoId': 'song',
      'title': 'Song',
      'author': 'Artist',
      'thumbnail': cover,
      'lengthSeconds': 185,
      'created': '2026-11-01T00:00:00.000',
      'musicMetadata': {
        'title': 'Song',
        'artist': 'Artist',
        'album': 'Album',
        'thumbnails': [
          {'url': cover, 'width': 512, 'height': 512}
        ],
      },
    });
    await database.upsertHistoryVideo(stored);
    final restored = HistoryVideoCache.fromJson(jsonDecode(
        jsonEncode(database.getHistoryVideoByVideoId('song')!.toJson())));
    final video = restored.toVideo();

    expect(video.musicMetadata?.title, 'Song');
    expect(video.musicMetadata?.artist, 'Artist');
    expect(video.musicMetadata?.album, 'Album');
    expect(video.musicMetadata?.thumbnails.single.url, cover);
    expect(video.musicMetadata?.thumbnails.single.width, 512);
    expect(video.videoThumbnails.single.url, cover);
    expect(video.lengthSeconds, 185);
  });

  test('legacy history remains an ordinary video without Music metadata', () {
    final stored = HistoryVideoCache.fromJson({
      'videoId': 'video',
      'title': 'Video',
      'author': 'Channel',
      'thumbnail': '/vi/video/hqdefault.jpg',
      'created': '2026-11-01T00:00:00.000',
    });
    final video = stored.toVideo();

    expect(video.musicMetadata, isNull);
    expect(video.videoThumbnails.single.url, '/vi/video/hqdefault.jpg');
    expect(video.lengthSeconds, isNull);
  });
}
