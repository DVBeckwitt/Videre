import 'dart:async';
import 'dart:convert';

import 'package:clipious/globals.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/db/progress.dart';
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

  test(
      'scoped history keeps each section, profile, and legacy rows independent',
      () async {
    const music = PlaybackHistoryOrigin.music;
    const video = PlaybackHistoryOrigin.video;
    final older = HistoryVideoCache('same', 'Video title', null, '')
      ..created = DateTime.utc(2026, 1);
    final latest = HistoryVideoCache('same', 'Music title', null, '')
      ..created = DateTime.utc(2026, 3);
    final legacy = HistoryVideoCache('legacy', 'Legacy', null, '')
      ..created = DateTime.utc(2026, 2);
    await database.recordPlaybackHistory(video, older);
    await database.recordPlaybackHistory(music, latest);
    await database.upsertHistoryVideo(legacy);
    await database.saveProgress(Progress(.4, 'same'));
    expect(database.getLocalHistory().map((v) => v.title),
        ['Music title', 'Legacy']);
    expect(database.getPlaybackHistory(video).single.title, 'Video title');
    expect(database.getPlaybackHistory(music).single.title, 'Music title');
    final other =
        database.forProfile((await database.createProfile('Second')).id);
    expect(other.getLocalHistory(), isEmpty);
    await other.recordPlaybackHistory(music, latest);
    await database.clearPlaybackHistory(music);
    expect(database.getPlaybackHistory(music), isEmpty);
    expect(database.getLocalHistory().map((v) => v.title),
        ['Legacy', 'Video title']);
    expect(database.getVideoProgress('same'), .4);
    expect(other.getPlaybackHistory(music).single.title, 'Music title');
    await database.deletePlaybackHistory(video, 'same');
    expect(database.getLocalHistory().single.videoId, 'legacy');
    expect(database.getVideoProgress('same'), .4);
    await database.recordPlaybackHistory(video, older);
    await database.deleteLocalHistory('same');
    expect(database.getPlaybackHistory(video), isEmpty);
    expect(database.getVideoProgress('same'), 0);
    await database.recordPlaybackHistory(music, latest);
    await database.clearLocalHistory();
    expect(database.getLocalHistory(), isEmpty);
    expect(other.getPlaybackHistory(music).single.title, 'Music title');
  });

  test('scoped and combined histories order timestamp instants consistently',
      () async {
    const music = PlaybackHistoryOrigin.music;
    final instant = DateTime.utc(2026, 11, 20);
    for (final entry in [
      HistoryVideoCache('earlier', 'Earlier', null, '')..created = instant,
      HistoryVideoCache('later', 'Later', null, '')
        ..created = instant.add(const Duration(microseconds: 1)),
    ]) {
      await database.recordPlaybackHistory(music, entry);
    }
    for (final history in [
      database.getPlaybackHistory(music),
      database.getLocalHistory(),
    ]) {
      expect(history.map((entry) => entry.videoId), ['later', 'earlier']);
    }
  });

  for (final combined in [false, true]) {
    for (final clear in [false, true]) {
      test(
          'pending playback obeys history edits (combined=$combined, clear=$clear)',
          () async {
        const music = PlaybackHistoryOrigin.music;
        const video = PlaybackHistoryOrigin.video;
        final same = HistoryVideoCache('same', 'First', null, '');
        final another = HistoryVideoCache('another', 'Second', null, '');
        final selected = database.forProfile(database.profileId);
        final other =
            database.forProfile((await database.createProfile('Second')).id);
        final pending = selected.beginPlaybackHistory(music, same.videoId);
        final otherId = selected.beginPlaybackHistory(music, another.videoId);
        final otherSection = selected.beginPlaybackHistory(video, same.videoId);
        final otherPerson = other.beginPlaybackHistory(music, same.videoId);
        if (combined) {
          await (clear
              ? database.clearLocalHistory()
              : database.deleteLocalHistory(same.videoId));
        } else {
          await (clear
              ? database.clearPlaybackHistory(music)
              : database.deletePlaybackHistory(music, same.videoId));
        }
        await pending.record(same);
        await otherId.record(another);
        await otherSection.record(same);
        await otherPerson.record(same);
        expect(selected.getPlaybackHistoryVideo(music, same.videoId), isNull);
        expect(selected.getPlaybackHistoryVideo(music, another.videoId),
            clear ? isNull : isNotNull);
        expect(selected.getPlaybackHistoryVideo(video, same.videoId),
            combined ? isNull : isNotNull);
        expect(other.getPlaybackHistory(music).single.videoId, same.videoId);
        await selected.beginPlaybackHistory(music, same.videoId).record(same);
        expect(
            selected.getPlaybackHistoryVideo(music, same.videoId), isNotNull);
      });
    }
  }

  test('cancelling a history write already waiting for the database drops it',
      () async {
    const music = PlaybackHistoryOrigin.music;
    final release = Completer<void>();
    final entered = Completer<void>();
    final locked = database.db.transaction((_) async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final pending = database.beginPlaybackHistory(music, 'waiting');
    final writing = pending.record(HistoryVideoCache('waiting', '', null, ''));
    pending.cancel();
    release.complete();
    await Future.wait([locked, writing]);
    expect(database.getPlaybackHistory(music), isEmpty);
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
