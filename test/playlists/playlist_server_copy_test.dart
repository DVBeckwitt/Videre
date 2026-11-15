import 'dart:async';

import 'package:clipious/globals.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_server_copy.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

class _Server extends Service {
  int creations = 0;
  final videos = <String>[];
  bool loseAcknowledgment = false;
  bool failCreation = false;
  Completer<void>? pending;
  final accounts = <Server>[];

  @override
  Future<String> createServerPlaylist(
      String name, String privacy, Server server) async {
    expect(privacy, 'private');
    accounts.add(server);
    creations++;
    if (failCreation) throw StateError('Connection closed');
    return 'IVPcopy';
  }

  @override
  Future<Playlist> getServerPlaylist(String playlistId,
      {int? page, Server? serverOverride}) async {
    accounts.add(serverOverride!);
    return Playlist(
        title: 'Saved',
        playlistId: playlistId,
        author: '',
        videoCount: videos.length,
        videos: videos
            .skip(((page ?? 1) - 1) * 2)
            .take(2)
            .map((id) => Video(videoId: id))
            .toList());
  }

  @override
  Future<void> addVideoToServerPlaylist(
      String playListId, String videoId, Server server) async {
    accounts.add(server);
    videos.add(videoId);
    await pending?.future;
    if (loseAcknowledgment) {
      loseAcknowledgment = false;
      throw StateError('Response lost after saving');
    }
  }
}

void main() {
  const server =
      Server(url: 'https://playlist.example', authToken: 'test-token');
  const playlist = Playlist(
      title: 'Saved',
      playlistId: 'local:saved',
      author: '',
      videoCount: 3,
      videos: [
        Video(videoId: 'first'),
        Video(videoId: 'first'),
        Video(videoId: 'second')
      ]);
  late _Server client;
  PlaylistServerCopy copy({Playlist source = playlist}) => PlaylistServerCopy(
      database: db.forProfile(db.profileId),
      client: client,
      playlist: source,
      reference: PlaylistReference.forPlaylist(source, db),
      server: server);

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    await db.upsertServer(server);
    client = _Server();
  });
  tearDown(() async => db.close());

  test('creates a private copy and preserves repeated occurrences', () async {
    final progress = <int>[];
    expect(await copy().save(onProgress: (saved, _) => progress.add(saved)),
        'IVPcopy');
    expect(client.videos, ['first', 'first', 'second']);
    expect(progress, [0, 1, 2, 3]);
    expect(client.accounts.every((account) => account == server), isTrue);
    await copy().save();
    expect(client.creations, 1);
    expect(client.videos, ['first', 'first', 'second']);
  });

  test('reopening and retrying reconciles a lost append acknowledgment',
      () async {
    client.loseAcknowledgment = true;
    await expectLater(copy().save(), throwsStateError);
    expect(client.videos, ['first']);
    await copy().save();
    expect(client.creations, 1);
    expect(client.videos, ['first', 'first', 'second']);
  });

  test('does not append after another client edits the saved prefix', () async {
    client.loseAcknowledgment = true;
    await expectLater(copy().save(), throwsStateError);
    client.videos[0] = 'changed';
    await expectLater(copy().save(), throwsStateError);
    expect(client.videos, ['changed']);
    expect(client.creations, 1);
  });

  test('account changes stop further appends', () async {
    client.pending = Completer<void>();
    final operation = copy().save();
    final failed = expectLater(operation, throwsStateError);
    for (var i = 0; i < 30 && client.videos.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(client.videos, ['first']);
    const other = Server(
        url: 'https://playlist.example', id: 'other', authToken: 'other');
    await db.upsertServer(other);
    await db.useServer(other);
    client.pending!.complete();
    await failed;
    expect(client.videos, ['first']);
  });

  test('concurrent screens serialize a copy without duplicate appends',
      () async {
    client.pending = Completer<void>();
    final first = copy().save();
    for (var i = 0; i < 30 && client.videos.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final second = copy().save();
    await Future<void>.delayed(Duration.zero);
    expect(client.creations, 1);
    expect(client.videos, ['first']);
    client.pending!.complete();
    await Future.wait([first, second]);
    expect(client.creations, 1);
    expect(client.videos, ['first', 'first', 'second']);
  });

  test('incomplete metadata cannot create a partial server copy', () async {
    await expectLater(copy(source: playlist.copyWith(videoCount: 4)).save(),
        throwsStateError);
    expect(client.creations, 0);
  });

  test('ambiguous creation reports uncertainty without automatic retries',
      () async {
    client.failCreation = true;
    await expectLater(
        copy().save(), throwsA(isA<PlaylistCreationUnconfirmed>()));
    expect(client.creations, 1);
    expect(client.videos, isEmpty);
  });
}
