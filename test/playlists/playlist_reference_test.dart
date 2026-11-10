import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SembastSqfDb database;
  const public = Playlist(
      title: 'Public', playlistId: 'PLpublic', author: '', videoCount: 0);
  const private = Playlist(
      title: 'Private', playlistId: 'IVPLprivate', author: '', videoCount: 0);

  setUp(() async => database = await SembastSqfDb.createInMemory());
  tearDown(() async => database.close());

  test('public playlist identity survives backend and account switching', () {
    const first = Server(url: 'https://one.example', id: 'one');
    const second = Server(url: 'https://two.example', id: 'two');
    final a = PlaylistReference.forPlaylist(public, database, server: first);
    final b = PlaylistReference.forPlaylist(
        public.copyWith(type: invidiousPlaylist), database,
        server: second);
    expect(a, b);
    expect(a.kind, PlaylistSourceKind.public);
    expect(a.resolveServer(database), isNull);
    expect(PlaylistReference.fromJson(a.toJson()), a);
  });

  test('instance playlists retain exact account and origin', () async {
    const first = Server(url: 'https://one.example', id: 'first');
    const other = Server(url: 'https://one.example', id: 'other');
    await database.upsertServer(first);
    await database.upsertServer(other);
    final reference =
        PlaylistReference.forPlaylist(private, database, server: first);
    expect(reference.resolveServer(database)?.accountId, 'first');
    expect(reference,
        isNot(PlaylistReference.forPlaylist(private, database, server: other)));
    await database.deleteServerById(first);
    expect(() => reference.resolveServer(database), throwsStateError);
    expect(() => PlaylistReference.forPlaylist(private, database),
        throwsStateError);
  });

  test('local playlists and malformed saved sources cannot cross profiles',
      () async {
    const local = Playlist(
        title: 'Local', playlistId: 'local:queue', author: '', videoCount: 0);
    final reference = PlaylistReference.forPlaylist(local, database);
    final other = await database.createProfile('Other');
    expect(reference.matchesOwner(database.forProfile(other.id)), isFalse);
    expect(() => reference.resolveServer(database.forProfile(other.id)),
        throwsStateError);
    for (final malformed in [
      {'kind': 'account', 'playlistId': 'IVPLx', 'profileId': 'default'},
      {
        'kind': 'account',
        'playlistId': 'IVPLx',
        'profileId': 'default',
        'accountId': 'account',
        'origin': 'https://secret@example.com',
      },
      {'kind': 'public', 'playlistId': 'local:x', 'profileId': 'default'},
      {'kind': 'public', 'playlistId': 'IVPLx', 'profileId': 'default'},
      {
        'kind': 'public',
        'playlistId': '../other?private',
        'profileId': 'default'
      },
      {'kind': 'unknown', 'playlistId': 'PLx', 'profileId': 'default'},
    ]) {
      expect(PlaylistReference.tryParse(malformed), isNull);
    }
  });

  test('repeated uploads retain distinct stable source occurrences', () {
    const first = Video(videoId: 'repeat', indexId: 'first', index: 0);
    const second = Video(videoId: 'repeat', indexId: 'second', index: 1);
    final original = assignPlaylistEntryIds([first, second]);
    final reordered = assignPlaylistEntryIds([
      second.copyWith(index: 0),
      first.copyWith(index: 1),
    ]);
    expect(original.map((entry) => entry.queueEntryId).toSet(), hasLength(2));
    expect(reordered[0].queueEntryId, original[1].queueEntryId);
    expect(reordered[1].queueEntryId, original[0].queueEntryId);
    expect(playlistSourceEntryId(first),
        playlistSourceEntryId(first.copyWith(index: 99)));
  });

  test('metadata-free duplicates survive and keep IDs as later pages append',
      () {
    const repeat = Video(videoId: 'repeat');
    final first = assignPlaylistEntryIds([repeat, repeat]);
    final appended = assignPlaylistEntryIds([...first, repeat]);
    expect(appended.map((entry) => entry.queueEntryId).toSet(), hasLength(3));
    expect(appended.take(2), first);
    expect(playlistSourceEntryId(repeat), isNull);
    final indexed = assignPlaylistEntryIds([
      repeat.copyWith(index: 0),
      repeat.copyWith(index: 1),
    ]);
    expect(indexed[0].queueEntryId, isNot(indexed[1].queueEntryId));
  });
}
