import 'dart:async';

import 'package:clipious/globals.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_load_session.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

class _Pages extends Service {
  final requests = <({int page, Server? server, bool private})>[];
  final responses = <Completer<Playlist>>[];

  Future<Playlist> _request(int? page, Server? server, bool private) {
    requests.add((page: page ?? 1, server: server, private: private));
    final response = Completer<Playlist>();
    responses.add(response);
    return response.future;
  }

  @override
  Future<Playlist> getPublicPlaylists(String playlistId,
          {int? page, bool saveLastSeen = true, Server? serverOverride}) =>
      _request(page, serverOverride, false);

  @override
  Future<Playlist> getUserPlaylist(String playlistId,
          {int? page, Server? serverOverride}) =>
      _request(page, serverOverride, true);
}

class _DelayedSourceDb implements IDbClient {
  final IDbClient delegate;
  final captures = <Completer<Server>>[];

  _DelayedSourceDb(this.delegate);

  @override
  String get profileId => delegate.profileId;

  @override
  IDbClient forProfile(String id) => this;

  @override
  Server? getAccount(String accountId) => delegate.getAccount(accountId);

  @override
  Future<Server> getCurrentlySelectedServer() {
    final response = Completer<Server>();
    captures.add(response);
    return response.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 50 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const original = Server(url: 'https://first.example', id: 'original');
  const initial = Playlist(
      title: 'Collection',
      playlistId: 'PLtest',
      author: 'Creator',
      videoCount: 4,
      videos: [Video(videoId: 'a', index: 0)]);
  late _Pages pages;
  late List<PlaylistLoadSession> sessions;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    await db.upsertServer(original);
    pages = _Pages();
    sessions = [];
  });

  tearDown(() async {
    for (final session in sessions) {
      session.release();
      session.release();
    }
    await db.close();
  });

  PlaylistLoadSession open(
      {Playlist playlist = initial, PlaylistReference? reference}) {
    final session = PlaylistLoadSession(
        playlist: playlist,
        database: db,
        reference: reference,
        playlistService: pages);
    sessions.add(session);
    session.retain();
    return session;
  }

  test('paging retains repeated uploads and exact account across a switch',
      () async {
    final session = open();
    await _until(() => pages.requests.length == 1);
    await db.upsertServer(
        const Server(url: 'https://second.example', id: 'second'));
    await db.useServer(db.getAccount('second')!);
    await db
        .upsertServer(original.copyWith(customHeaders: {'X-Test': 'updated'}));
    pages.responses[0].complete(initial.copyWith(videos: [
      const Video(videoId: 'a', index: 0),
      const Video(videoId: 'b', index: 1),
    ]));
    await _until(() => pages.requests.length == 2);
    pages.responses[1].complete(initial.copyWith(videos: [
      const Video(videoId: 'a', index: 2),
      const Video(videoId: 'b', index: 3),
    ]));
    await _until(() => session.complete && !session.loading);
    expect(session.videos.map((v) => v.videoId), ['a', 'b', 'a', 'b']);
    expect(session.videos.map((v) => v.queueEntryId).toSet(), hasLength(4));
    expect(pages.requests.map((r) => r.server?.accountId),
        ['original', 'original']);
    expect(pages.requests.map((r) => r.page), [1, 2]);
    expect(pages.requests.last.server?.customHeaders['X-Test'], 'updated');
  });

  test('page failure preserves loaded entries and retries the failed page',
      () async {
    final session = open();
    await _until(() => pages.requests.length == 1);
    pages.responses[0].complete(initial.copyWith(videos: [
      const Video(videoId: 'a', index: 0),
      const Video(videoId: 'b', index: 1),
    ]));
    await _until(() => pages.requests.length == 2);
    pages.responses[1].completeError(StateError('offline'));
    await _until(() => session.error != null && !session.loading);
    expect(session.complete, isFalse);
    expect(session.videos, hasLength(2));
    final retry = session.retry();
    await _until(() => pages.requests.length == 3);
    expect(pages.requests.last.page, 2);
    pages.responses[2].complete(initial.copyWith(videos: [
      const Video(videoId: 'c', index: 2),
      const Video(videoId: 'd', index: 3),
    ]));
    await retry;
    expect(session.error, isNull);
    expect(session.complete, isTrue);
    expect(session.videos, hasLength(4));
  });

  test('repeated pages stop with retryable error instead of an infinite queue',
      () async {
    final session = open();
    await _until(() => pages.requests.length == 1);
    final repeated = initial.copyWith(videos: [
      const Video(videoId: 'a'),
      const Video(videoId: 'a'),
    ]);
    pages.responses[0].complete(repeated);
    await _until(() => pages.requests.length == 2);
    pages.responses[1].complete(repeated);
    await _until(() => session.error != null && !session.loading);
    expect(session.videos, hasLength(2));
    expect(session.videos.map((v) => v.queueEntryId).toSet(), hasLength(2));
    expect(pages.requests, hasLength(2));
    expect(session.complete, isFalse);
  });

  test('player retention keeps paging alive after the screen releases',
      () async {
    final session = open();
    session.retain();
    await _until(() => pages.requests.length == 1);
    session.release();
    pages.responses[0].complete(initial.copyWith(videos: [
      const Video(videoId: 'a', index: 0),
      const Video(videoId: 'b', index: 1),
    ]));
    await _until(() => pages.requests.length == 2);
    session.release();
    pages.responses[1].complete(initial.copyWith(videos: [
      const Video(videoId: 'c', index: 2),
      const Video(videoId: 'd', index: 3),
    ]));
    await Future<void>.delayed(Duration.zero);
    expect(session.videos, hasLength(2));
    expect(pages.requests, hasLength(2));
  });

  test('profile switch rejects a pending page even with the mutable root db',
      () async {
    final session = open();
    await _until(() => pages.requests.length == 1);
    final other = await db.createProfile('Other');
    await db.useProfile(other.id);
    pages.responses[0].complete(initial.copyWith(videos: [
      const Video(videoId: 'a', index: 0),
      const Video(videoId: 'b', index: 1),
    ]));
    await Future<void>.delayed(Duration.zero);
    expect(session.videos, hasLength(1));
    expect(pages.requests, hasLength(1));
  });

  test('saved previews force a fresh read even when count appears complete',
      () async {
    final cached = initial.copyWith(videoCount: 1);
    final session = open(
        playlist: cached, reference: PlaylistReference.forPlaylist(cached, db));
    await _until(() => pages.requests.length == 1);
    expect(session.hasPlayableSnapshot, isFalse);
    pages.responses[0].complete(cached.copyWith(
        title: 'Updated title',
        videos: [const Video(videoId: 'new', index: 0)]));
    await _until(() => session.complete && !session.loading);
    expect(session.playlist.title, 'Updated title');
    expect(session.videos.single.videoId, 'new');
    expect(session.hasPlayableSnapshot, isTrue);
  });

  test('refresh ignores the old pending page and replaces the visible snapshot',
      () async {
    final session = open();
    await _until(() => pages.requests.length == 1);
    final refreshed = session.refresh();
    await _until(() => pages.requests.length == 2);
    pages.responses[0].complete(initial.copyWith(videoCount: 1));
    pages.responses[1].complete(initial.copyWith(
        videoCount: 1, videos: [const Video(videoId: 'fresh', index: 0)]));
    await refreshed;
    expect(session.videos.single.videoId, 'fresh');
    expect(session.complete, isTrue);
  });

  test('a stale source lookup cannot change the refreshed paging account',
      () async {
    const other = Server(url: 'https://second.example', id: 'second');
    await db.upsertServer(other);
    final delayed = _DelayedSourceDb(db.forProfile(db.profileId));
    final private =
        initial.copyWith(playlistId: 'IVPprivate', type: invidiousPlaylist);
    final session = PlaylistLoadSession(
        playlist: private, database: delayed, playlistService: pages);
    sessions.add(session);
    session.retain();
    await _until(() => delayed.captures.length == 1);
    final refreshing = session.refresh();
    await _until(() => delayed.captures.length == 2);
    delayed.captures[1].complete(other);
    await _until(() => pages.requests.length == 1);
    delayed.captures[0].complete(original);
    await Future<void>.delayed(Duration.zero);
    pages.responses[0].complete(private.copyWith(videos: [
      const Video(videoId: 'a', index: 0),
      const Video(videoId: 'b', index: 1),
    ]));
    await _until(() => pages.requests.length == 2);
    pages.responses[1].complete(private.copyWith(videos: [
      const Video(videoId: 'c', index: 2),
      const Video(videoId: 'd', index: 3),
    ]));
    await refreshing;
    expect(session.reference?.accountId, other.accountId);
    expect(pages.requests.map((request) => request.server?.accountId),
        [other.accountId, other.accountId]);
    expect(session.complete, isTrue);
  });

  test('a response for another playlist cannot redirect subsequent pages',
      () async {
    final session = open();
    await _until(() => pages.requests.length == 1);
    pages.responses[0].complete(initial.copyWith(
        playlistId: 'PLwrong', videos: [const Video(videoId: 'wrong')]));
    await _until(() => session.error != null && !session.loading);
    expect(session.playlist.playlistId, initial.playlistId);
    expect(session.videos.single.videoId, 'a');
    expect(pages.requests, hasLength(1));
    expect(session.complete, isFalse);

    final retrying = session.retry();
    await _until(() => pages.requests.length == 2);
    pages.responses[1].complete(initial.copyWith(videoCount: 1));
    await retrying;
    expect(session.complete, isTrue);
    expect(session.error, isNull);
  });
}
