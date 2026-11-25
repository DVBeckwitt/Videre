import 'dart:convert';

import 'package:clipious/music/services/music_passage_bookmarks.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';

const _recording = 'video:abcdefghijk';
const _occurrence = 'abcdefghijk#1';
const _position = Duration(milliseconds: 23145);

bool _current() => true;

Future<bool> _save(
  MusicPassageBookmarks bookmarks, {
  String recording = _recording,
  String occurrence = _occurrence,
  Duration position = _position,
  String name = 'First chorus',
  bool Function() isCurrent = _current,
}) =>
    bookmarks.add(
      recordingId: recording,
      occurrenceId: occurrence,
      position: position,
      name: name,
      isCurrent: isCurrent,
    );

void main() {
  late SembastSqfDb database;
  late MusicPassageBookmarks bookmarks;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    bookmarks = MusicPassageBookmarks(database, database.profileId);
  });

  tearDown(() => database.close());

  test('persists exact positions and occurrence IDs after reopening', () async {
    final factory = newDatabaseFactoryMemory();
    const path = 'music-passage-bookmarks';
    final first = SembastSqfDb(await factory.openDatabase(path));
    await first.getProfiles();
    final store = MusicPassageBookmarks(first, first.profileId);
    expect(await _save(store, name: '  Solo  '), isTrue);
    expect(
      await _save(
        store,
        name: 'Solo',
        occurrence: 'abcdefghijk',
        position: Duration.zero,
      ),
      isTrue,
    );
    final ids = store.list(_recording).map((bookmark) => bookmark.id).toList();
    expect(ids.toSet(), hasLength(2));
    await first.close();

    final reopened = SembastSqfDb(await factory.openDatabase(path));
    addTearDown(reopened.close);
    await reopened.getProfiles();
    final reopenedStore = MusicPassageBookmarks(reopened, reopened.profileId);
    final saved = reopenedStore.list(_recording);
    expect(saved.map((bookmark) => bookmark.id), ids);
    expect(saved.map((bookmark) => bookmark.name), ['Solo', 'Solo']);
    expect(saved.map((bookmark) => bookmark.occurrenceId), [
      _occurrence,
      'abcdefghijk',
    ]);
    expect(saved.map((bookmark) => bookmark.position), [
      _position,
      Duration.zero,
    ]);
    expect(reopenedStore.list('video:nearbytrack'), isEmpty);
  });

  test(
    'isolates recordings and profiles across an active profile change',
    () async {
      final second = await database.createProfile('Second');
      expect(await _save(bookmarks), isTrue);
      final first = bookmarks.list(_recording).single;
      await database.useProfile(second.id);
      final secondStore = MusicPassageBookmarks(database, second.id);
      expect(secondStore.list(_recording), isEmpty);
      expect(await _save(secondStore, name: 'Second profile'), isTrue);
      expect(await secondStore.remove(first, isCurrent: _current), isFalse);
      expect(secondStore.list(_recording).single.name, 'Second profile');
      expect(bookmarks.list(_recording).single.name, 'First chorus');
      expect(await _save(secondStore, recording: 'device:digest'), isTrue);
      expect(secondStore.list(_recording), hasLength(1));
      expect(secondStore.list('device:digest'), hasLength(1));
      expect(bookmarks.list('device:digest'), isEmpty);
    },
  );

  test(
    'serializes add, rename and delete across views of the same profile',
    () async {
      final another = MusicPassageBookmarks(database, database.profileId);
      expect(await _save(bookmarks, name: 'Rename me'), isTrue);
      expect(await _save(bookmarks, name: 'Delete me'), isTrue);
      final [keep, remove] = bookmarks.list(_recording);
      final operations = await Future.wait([
        for (var index = 0; index < 12; index++)
          _save(index.isEven ? bookmarks : another, name: 'Bookmark $index'),
        another.rename(keep, 'Renamed', isCurrent: _current),
        bookmarks.remove(remove, isCurrent: _current),
        another.rename(remove, 'Deleted bookmark', isCurrent: _current),
      ]);
      expect(operations.take(14), everyElement(isTrue));
      expect(operations.last, isFalse);
      final saved = another.list(_recording);
      expect(saved, hasLength(13));
      final updated = saved.singleWhere((bookmark) => bookmark.id == keep.id);
      expect(updated.name, 'Renamed');
      expect(updated.position, keep.position);
      expect(updated.occurrenceId, keep.occurrenceId);
      expect(saved.any((bookmark) => bookmark.id == remove.id), isFalse);
    },
  );

  test(
    'queued edits check that the opening selection is still current',
    () async {
      expect(await _save(bookmarks), isTrue);
      final saved = bookmarks.list(_recording).single;
      var current = true;
      bool valid() => current;
      final add = _save(bookmarks, name: 'Stale add', isCurrent: valid);
      final rename = bookmarks.rename(saved, 'Stale name', isCurrent: valid);
      final remove = bookmarks.remove(saved, isCurrent: valid);
      current = false;
      expect(await Future.wait([add, rename, remove]), everyElement(isFalse));
      expect(bookmarks.list(_recording).single.name, saved.name);
    },
  );

  test(
    'discards invalid stored rows and accepts valid edits beside them',
    () async {
      const setting = 'music-passage-bookmarks-v1';
      await database.saveSetting(SettingsValue(setting, '{invalid'));
      expect(bookmarks.list(_recording), isEmpty);
      final valid = <String, Object>{
        'id': 'good-id',
        'name': 'Valid',
        'recordingId': _recording,
        'occurrenceId': _occurrence,
        'positionMs': 1,
      };
      await database.saveSetting(
        SettingsValue(
          setting,
          jsonEncode([
            null,
            valid,
            {...valid, 'name': 'Duplicate'},
            {...valid, 'id': 'negative', 'positionMs': -1},
            {...valid, 'id': 'bad-position', 'positionMs': '18'},
            {...valid, 'id': 'bad-name', 'name': ' '},
            {
              ...valid,
              'id': 'raw-identity',
              'occurrenceId': 'content://audio/1',
            },
          ]),
        ),
      );
      expect(bookmarks.list(_recording).single.name, 'Valid');
      expect(await _save(bookmarks, occurrence: 'content://audio/1'), isFalse);
      expect(
        await _save(bookmarks, position: const Duration(microseconds: -1)),
        isFalse,
      );
      expect(await _save(bookmarks, name: '   '), isFalse);
      expect(await _save(bookmarks), isTrue);
      expect(bookmarks.list(_recording).map((bookmark) => bookmark.name), [
        'Valid',
        'First chorus',
      ]);
    },
  );
}
