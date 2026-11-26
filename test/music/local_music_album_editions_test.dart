import 'package:clipious/music/models/local_music_album.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/services/local_music_album_editions.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final originalKey = 'a' * 64;
  final preferredKey = 'b' * 64;
  final alternateKey = 'c' * 64;
  final similarKey = 'd' * 64;

  LocalMusicAlbum album(String key, String title, String recording) =>
      groupLocalMusicAlbums([
        LocalMusicTrack(
          uri: 'content://provider/tree/music/document/$recording',
          title: recording,
          album: title,
          albumKey: key,
        )
      ]).single;

  test('browse chooses an exact visible release and keeps similar titles', () {
    final original = album(originalKey, 'Shoreline', 'First recording');
    final preferred = album(preferredKey, 'Shoreline', 'Second recording');
    final alternate = album(alternateKey, 'Shoreline (Live)', 'Live recording');
    final similar = album(similarKey, 'Shorelines', 'Unrelated recording');
    final group = LocalMusicAlbumEditionGroup.tryCreate(
        [originalKey, alternateKey, preferredKey], preferredKey)!;

    expect(
        browseLocalMusicAlbumEditions(
            [original, preferred, similar, alternate], [group]),
        [same(preferred), same(similar)]);
    expect(
        browseLocalMusicAlbumEditions([alternate, original, similar], [group]),
        [same(original), same(similar)]);
    expect(browseLocalMusicAlbumEditions([similar], [group]), [same(similar)]);
    expect(group.preferredKey, preferredKey);
    expect(browseLocalMusicAlbumEditions([original, preferred], [group]),
        [same(preferred)]);
    expect(original.tracks.single.playbackId,
        isNot(preferred.tracks.single.playbackId));
  });

  group('profile edition preferences', () {
    late SembastSqfDb database;
    late String profileId;
    late LocalMusicAlbumEditions editions;

    setUp(() async {
      database = await SembastSqfDb.createInMemory();
      profileId = database.profileId;
      editions = LocalMusicAlbumEditions(database, profileId);
    });

    tearDown(() async => database.close());

    test('group, change preference, and dissolve within one profile', () async {
      final keys = [originalKey, preferredKey];
      expect(
          await editions.save(
            previous: null,
            albumKeys: keys,
            preferredKey: originalKey,
            isCurrent: () => true,
          ),
          isTrue);
      final other = await database.createProfile('Other listener');
      await database.useProfile(other.id);
      expect(LocalMusicAlbumEditions(database, other.id).groups, isEmpty);
      await database.useProfile(profileId);

      final reopened = LocalMusicAlbumEditions(database, profileId);
      final original = reopened.groups.single;
      expect(original.albumKeys, keys);
      expect(original.preferredKey, originalKey);
      expect(
          await reopened.save(
            previous: original,
            albumKeys: keys,
            preferredKey: preferredKey,
            isCurrent: () => true,
          ),
          isTrue);
      final updated = editions.groups.single;
      expect(updated.preferredKey, preferredKey);
      expect(
          await reopened.save(
            previous: updated,
            albumKeys: [],
            preferredKey: preferredKey,
            isCurrent: () => true,
          ),
          isTrue);
      expect(editions.groups, isEmpty);
    });

    test('serializes competing edits from separate handles to the same profile',
        () async {
      final otherHandle =
          LocalMusicAlbumEditions(database.forProfile(profileId), profileId);
      final first = editions.save(
          previous: null,
          albumKeys: [originalKey, preferredKey],
          preferredKey: originalKey,
          isCurrent: () => true);
      final second = otherHandle.save(
          previous: null,
          albumKeys: [preferredKey, alternateKey],
          preferredKey: alternateKey,
          isCurrent: () => true);
      expect(await Future.wait([first, second]), [true, false]);
      expect(editions.groups.single.albumKeys, [originalKey, preferredKey]);
    });

    test('rejects a queued change when its session has moved on', () async {
      var active = true;
      final save = editions.save(
          previous: null,
          albumKeys: [originalKey, preferredKey],
          preferredKey: originalKey,
          isCurrent: () => active);
      active = false;
      expect(await save, isFalse);
      expect(editions.groups, isEmpty);
    });
  });
}
