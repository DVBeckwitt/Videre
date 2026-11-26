import 'dart:convert';

import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_rule_playlist.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_rule_playlist_store.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';

const _short = MusicLibraryEntry(
  kind: MusicLibraryKind.song,
  id: 'short000001',
  title: 'Été live',
  artistCredits: [MusicArtistCredit(name: 'Björk')],
  album: 'Début',
  durationSeconds: 120,
);
const _long = MusicLibraryEntry(
  kind: MusicLibraryKind.song,
  id: 'long0000001',
  title: 'Été session',
  subtitle: 'Björk',
  album: 'Début',
  durationSeconds: 180,
);
const _missing = MusicLibraryEntry(
  kind: MusicLibraryKind.song,
  id: 'missing0001',
  title: 'missing0001',
  durationSeconds: 0,
);
const _rule = MusicRulePlaylist(
  id: 'rule-id',
  name: 'Summer songs',
  titleContains: 'ete',
  sort: MusicRulePlaylistSort.duration,
  limit: 1,
);

void main() {
  test('intersects reliable, normalized song metadata and inclusive bounds',
      () {
    const filtered = MusicRulePlaylist(
      id: 'both',
      name: 'Both',
      titleContains: '  ETE ',
      artistContains: 'BJORK',
      albumContains: ' debut ',
      minimumDurationSeconds: 120,
      maximumDurationSeconds: 180,
    );
    const playlist = MusicLibraryEntry(
      kind: MusicLibraryKind.playlist,
      id: 'playlist',
      title: 'Été set',
      subtitle: 'Björk',
      album: 'Début',
      durationSeconds: 150,
    );
    const outsideRange = MusicLibraryEntry(
      kind: MusicLibraryKind.song,
      id: 'jumbo000001',
      title: 'Été extended',
      subtitle: 'Björk',
      album: 'Début',
      durationSeconds: 181,
    );
    const unknownDuration = MusicLibraryEntry(
      kind: MusicLibraryKind.song,
      id: 'unknown0001',
      title: 'Été home recording',
      subtitle: 'Björk',
      album: 'Début',
    );
    expect(
      filtered
          .resolve([playlist, _long, unknownDuration, outsideRange, _short]),
      [_long, _short],
    );
    expect(
      const MusicRulePlaylist(
              id: 'id', name: 'Missing', titleContains: 'missing')
          .resolve([_missing]),
      isEmpty,
    );
    expect(
      const MusicRulePlaylist(
              id: 'id', name: 'Unknown', maximumDurationSeconds: 0)
          .resolve([_missing, unknownDuration]),
      isEmpty,
    );
  });

  test('sorts known values first with stable ties before applying the limit',
      () {
    for (final sort in MusicRulePlaylistSort.values
        .where((sort) => sort != MusicRulePlaylistSort.saved)) {
      for (final descending in [true, false]) {
        final rule = MusicRulePlaylist(
          id: 'sorted',
          name: 'Sorted',
          sort: sort,
          descending: descending,
          limit: 2,
        );
        final tied = sort == MusicRulePlaylistSort.artist ||
            sort == MusicRulePlaylistSort.album;
        final expected = descending || tied ? [_long, _short] : [_short, _long];
        expect(rule.resolve([_missing, _long, _short]), expected);
      }
    }

    expect(
      const MusicRulePlaylist(
              id: 'saved', name: 'Oldest saved first', descending: true)
          .resolve([_short, _long, _missing]),
      [_missing, _long, _short],
    );
  });

  test('round-trips only validated definitions', () {
    final input = _rule.toJson();
    expect(
        MusicRulePlaylist.tryParse({
          ...input,
          'members': [_short.id]
        })?.toJson(),
        input);
    expect(
        MusicRulePlaylist.tryParse({...input, 'name': '   Summer songs  '})
            ?.name,
        _rule.name);
    for (final invalid in [
      {'id': 'unsafe/id'},
      {'name': ' '},
      {'name': 'Invalid\nline'},
      {'name': 'a' * (musicRulePlaylistTextLimit + 1)},
      {'titleContains': 1},
      {'sort': 'unrecognized'},
      {'descending': 'no'},
      {'limit': 0},
      {'limit': musicLibraryMaximumEntries + 1},
      {'limit': 1.5},
      {'minimumDurationSeconds': -1},
      {'maximumDurationSeconds': '10'},
      {'minimumRating': 0},
      {'minimumRating': 6},
      {'minimumRating': '1'},
      {'maximumDurationSeconds': musicRulePlaylistMaximumDuration + 1},
      {'minimumDurationSeconds': 20, 'maximumDurationSeconds': 19},
    ]) {
      expect(MusicRulePlaylist.tryParse({...input, ...invalid}), isNull,
          reason: 'Accepted $invalid');
    }
  });

  test('a minimum rating includes its boundary and excludes unrated songs', () {
    final rule = MusicRulePlaylist.tryParse({
      ..._rule.toJson(),
      'minimumRating': 1,
      'limit': 3,
    })!;
    final songs = [_short, _long];
    final ratings = {_long.id: 1, 'unsaved0001': 5};
    expect(rule.toJson()['minimumRating'], 1);
    expect(rule.resolve(songs, ratings: ratings), [_long]);
    expect(rule.resolve(songs), isEmpty);
    final anyRating = MusicRulePlaylist.tryParse({
      ...rule.toJson(),
      'minimumRating': null,
    })!;
    expect(anyRating.toJson(), isNot(contains('minimumRating')));
    expect(anyRating.resolve(songs, ratings: ratings), songs);
  });

  test('persists a rule and resolves changing membership after reopening',
      () async {
    final factory = newDatabaseFactoryMemory();
    var connection = await factory.openDatabase('rule-library');
    var database = SembastSqfDb(connection);
    await database.getProfiles();
    var store = MusicRulePlaylistStore.forProfile(database, database.profileId);
    var library = MusicLibraryService.forProfile(database, database.profileId);
    await store.save(_rule, isCurrent: () => true);
    expect(store.playlists.single.resolve(library.entries), isEmpty);
    await library.save(_short);
    await library.save(_long);
    expect(
        store.playlists.single.resolve(library.entries).single.id, _short.id);
    await database.close();

    connection = await factory.openDatabase('rule-library');
    database = SembastSqfDb(connection);
    addTearDown(database.close);
    await database.getProfiles();
    store = MusicRulePlaylistStore.forProfile(database, database.profileId);
    library = MusicLibraryService.forProfile(database, database.profileId);
    expect(store.playlists.single.toJson(), _rule.toJson());
    final before = database.getSettings(musicRulePlaylistSettingName)?.value;
    await library.remove(MusicLibraryKind.song, _short.id);
    expect(store.playlists.single.resolve(library.entries).single.id, _long.id);
    await library.remove(MusicLibraryKind.song, _long.id);
    expect(store.playlists.single.resolve(library.entries), isEmpty);
    expect(database.getSettings(musicRulePlaylistSettingName)?.value, before);
  });

  test('shares ordered writes and rejects stale changes for the same profile',
      () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    final profileId = database.profileId;
    final otherId = (await database.createProfile('Other listener')).id;
    final store = MusicRulePlaylistStore.forProfile(database, profileId);
    final same = MusicRulePlaylistStore.forProfile(database, profileId);
    final other = MusicRulePlaylistStore.forProfile(database, otherId);
    var notifications = 0;
    same.changes.addListener(() => notifications++);
    const second = MusicRulePlaylist(id: 'second', name: 'Second rule');
    await Future.wait([
      store.save(_rule, isCurrent: () => true),
      same.save(second, isCurrent: () => true),
    ]);
    expect(same.playlists.map((rule) => rule.id), [second.id, _rule.id]);
    expect(other.playlists, isEmpty);
    expect(notifications, 2);
    await other.save(_rule, isCurrent: () => true);
    expect(notifications, 2);

    final previous = same.playlists.last;
    const edited = MusicRulePlaylist(id: 'rule-id', name: 'Edited rule');
    final update = same.save(edited, previous: previous, isCurrent: () => true);
    final staleRemoval = store.remove(previous, isCurrent: () => true);
    await expectLater(staleRemoval, throwsStateError);
    await update;
    await expectLater(
      store.save(_rule, previous: previous, isCurrent: () => true),
      throwsStateError,
    );
    expect(store.playlists.last.name, edited.name);
    var isCurrent = true;
    final inactiveRemoval =
        store.remove(store.playlists.last, isCurrent: () => isCurrent);
    isCurrent = false;
    await inactiveRemoval;
    expect(store.playlists.last.name, edited.name);
    await store.remove(store.playlists.last, isCurrent: () => true);
    expect(store.playlists.single.name, second.name);
    expect(other.playlists.single.name, _rule.name);
    expect(notifications, 4);
  });

  test('damaged rows and duplicate identities do not hide valid rules',
      () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    final store =
        MusicRulePlaylistStore.forProfile(database, database.profileId);
    await database.saveSetting(SettingsValue(
      musicRulePlaylistSettingName,
      jsonEncode({
        'version': 1,
        'playlists': [
          null,
          {..._rule.toJson(), 'limit': -1},
          _rule.toJson(),
          {..._rule.toJson(), 'name': 'Duplicated'},
        ],
      }),
    ));
    expect(store.playlists.single.name, _rule.name);
  });
}
