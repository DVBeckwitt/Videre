import 'dart:convert';

import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_recording_rating_store.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';

const _catalogId = 'abcdefghijk';
const _otherCatalogId = 'lmnopqrstuv';
const _deviceId = 'device:'
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

bool _current() => true;

void main() {
  late SembastSqfDb database;
  late MusicRecordingRatingStore store;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    store = MusicRecordingRatingStore.forProfile(database, database.profileId);
  });

  tearDown(() => database.close());

  test('the lowest rating and an unset rating are distinct', () async {
    expect(store.ratings[_catalogId], isNull);
    await store.setRating(_catalogId, 1, isCurrent: _current);
    final snapshot = store.ratings;
    expect(snapshot, {_catalogId: 1});
    expect(() => snapshot[_catalogId] = 5, throwsUnsupportedError);

    await store.setRating(_catalogId, null, isCurrent: _current);
    expect(store.ratings[_catalogId], isNull);
    expect(snapshot[_catalogId], 1);
  });

  test('catalog and opaque device ratings persist after reopening', () async {
    final factory = newDatabaseFactoryMemory();
    const path = 'music-recording-ratings';
    final first = SembastSqfDb(await factory.openDatabase(path));
    await first.getProfiles();
    final firstStore =
        MusicRecordingRatingStore.forProfile(first, first.profileId);
    await firstStore.setRating(_catalogId, 1, isCurrent: _current);
    await firstStore.setRating(_deviceId, 5, isCurrent: _current);
    await first.close();

    final reopened = SembastSqfDb(await factory.openDatabase(path));
    addTearDown(reopened.close);
    await reopened.getProfiles();
    final reopenedStore =
        MusicRecordingRatingStore.forProfile(reopened, reopened.profileId);
    expect(reopenedStore.ratings, {_catalogId: 1, _deviceId: 5});
  });

  test('same-profile views serialize writes and ignore a stale session',
      () async {
    final same =
        MusicRecordingRatingStore.forProfile(database, database.profileId);
    final snapshots = <Map<String, int>>[];
    same.changes.addListener(() => snapshots.add(same.ratings));
    var current = true;
    final writes = [
      store.setRating(_catalogId, 3, isCurrent: _current),
      same.setRating(_deviceId, 2, isCurrent: _current),
      store.setRating(_catalogId, null, isCurrent: () => current),
      same.setRating(_deviceId, 2, isCurrent: _current),
    ];
    current = false;
    await Future.wait(writes);
    expect(snapshots, [
      {_catalogId: 3},
      {_catalogId: 3, _deviceId: 2},
    ]);
    expect(store.ratings, same.ratings);
  });

  test('the selected profile has its own ratings and notifications', () async {
    final otherProfile = await database.createProfile('Other listener');
    final other =
        MusicRecordingRatingStore.forProfile(database, otherProfile.id);
    var otherNotifications = 0;
    other.changes.addListener(() => otherNotifications++);

    await store.setRating(_catalogId, 1, isCurrent: _current);
    expect(other.ratings, isEmpty);
    expect(otherNotifications, 0);

    await database.useProfile(otherProfile.id);
    await other.setRating(_catalogId, 5, isCurrent: _current);
    expect(store.ratings, {_catalogId: 1});
    expect(other.ratings, {_catalogId: 5});
    expect(otherNotifications, 1);
  });

  test('malformed metadata and invalid rows leave valid ratings usable',
      () async {
    await database.saveSetting(
        SettingsValue(musicRecordingRatingsSettingName, '{invalid'));
    expect(store.ratings, isEmpty);
    await database.saveSetting(SettingsValue(
      musicRecordingRatingsSettingName,
      jsonEncode({
        'version': 1,
        'ratings': {
          _catalogId: 1,
          _deviceId: 5,
          _otherCatalogId: 0,
          'video_id_01': '5',
          'video_id_02': 4.5,
          'video_id_03': 6,
          'video_id_04': null,
          'device:NaN': 5,
          'content://audio/1': 5,
          '$_catalogId\n': 5,
        },
      }),
    ));
    expect(store.ratings, {_catalogId: 1, _deviceId: 5});

    await expectLater(
      store.setRating('$_catalogId#1', 3, isCurrent: _current),
      throwsArgumentError,
    );
    await expectLater(
      store.setRating(_catalogId, 0, isCurrent: _current),
      throwsArgumentError,
    );
    await expectLater(
      store.setRating(_catalogId, 6, isCurrent: _current),
      throwsArgumentError,
    );
    await store.setRating(_otherCatalogId, 2, isCurrent: _current);
    expect(store.ratings, {_catalogId: 1, _deviceId: 5, _otherCatalogId: 2});
  });

  test('rating an item leaves the bookmark and Like settings intact', () async {
    final library =
        MusicLibraryService.forProfile(database, database.profileId);
    const saved = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: _catalogId, title: 'Saved song');
    const liked = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: _otherCatalogId, title: 'Liked song');
    await library.save(saved);
    final existing = database.getSettings(musicLibrarySettingName)!.value;
    final withLike = jsonEncode({
      ...jsonDecode(existing) as Map<String, dynamic>,
      'likes': [liked.toJson()],
    });
    await database
        .saveSetting(SettingsValue(musicLibrarySettingName, withLike));

    await store.setRating(_catalogId, 1, isCurrent: _current);
    await store.setRating(_otherCatalogId, 5, isCurrent: _current);
    await store.setRating(_catalogId, null, isCurrent: _current);

    expect(store.ratings, {_otherCatalogId: 5});
    expect(library.entries.map((entry) => entry.id), [_catalogId]);
    expect(database.getSettings(musicLibrarySettingName)?.value, withLike);
  });
}
