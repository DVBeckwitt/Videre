import 'dart:convert';

import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SembastSqfDb database;
  late MusicLibraryService library;

  MusicLibraryEntry song(int index, {String? title}) => MusicLibraryEntry(
      kind: MusicLibraryKind.song,
      id: 'song${index.toString().padLeft(7, '0')}',
      title: title ?? 'Song $index',
      subtitle: 'Artist $index',
      album: 'Album $index');

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    library = MusicLibraryService.forProfile(database, database.profileId);
  });

  tearDown(() async => database.close());

  test('bulk import keeps existing data and appends unique songs in file order',
      () async {
    await database.saveSetting(SettingsValue('theme-mode', 'dark'));
    await library.markLocalPlaylist('local:saved-music');
    const artist = MusicLibraryEntry(
        kind: MusicLibraryKind.artist, id: 'artist', title: 'Saved artist');
    await library.save(artist);
    await library.save(song(1, title: 'Existing title'));
    var changes = 0;
    library.changes.addListener(() => changes++);

    final imported = await library.importSongs([
      song(3),
      song(1, title: 'Replacement title'),
      song(2),
      song(3, title: 'Duplicate title'),
    ]);

    expect(imported, 2);
    expect(library.entries.map((entry) => entry.id),
        ['song0000001', 'artist', 'song0000003', 'song0000002']);
    expect(library.entries.first.title, 'Existing title');
    expect(library.entries[2].title, 'Song 3');
    expect(changes, 1);
    expect(database.getSettings('theme-mode')?.value, 'dark');
    expect(
        library.isMusicPlaylist(const Playlist(
            title: 'Saved music',
            playlistId: 'local:saved-music',
            author: '',
            videoCount: 0)),
        isTrue);

    final stored = database.getSettings(musicLibrarySettingName)?.value;
    expect(await library.importSongs([song(3), song(1), song(2)]), 0);
    expect(database.getSettings(musicLibrarySettingName)?.value, stored);
  });

  test('imported songs retain text metadata but never imported artwork',
      () async {
    final entry = MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'abcdefghijk',
        title: '  Song\nname  ',
        subtitle: 'Artist',
        album: 'Album',
        durationSeconds: 123,
        usesVideoThumbnails: true,
        thumbnails: [
          ImageObject(
              null, 'https://i.ytimg.com/vi/abcdefghijk/default.jpg', 120, 90),
        ]);
    expect(await library.importSongs([entry]), 1);
    final stored = library.entries.single;
    expect(stored.title, 'Song name');
    expect(stored.subtitle, 'Artist');
    expect(stored.album, 'Album');
    expect(stored.durationSeconds, 123);
    expect(stored.thumbnails, isEmpty);
    expect(stored.usesVideoThumbnails, isFalse);
    expect(stored.toVideo().videoThumbnails, isEmpty);
    expect(stored.toVideo().musicMetadata!.thumbnails, isEmpty);
  });

  test('invalid rows reject the complete import without partial writes',
      () async {
    await library.save(song(0));
    final before = database.getSettings(musicLibrarySettingName)?.value;
    for (final invalid in [
      const MusicLibraryEntry(
          kind: MusicLibraryKind.artist,
          id: 'abcdefghijk',
          title: 'Not a song'),
      const MusicLibraryEntry(
          kind: MusicLibraryKind.song, id: 'too-short', title: 'Bad ID'),
      const MusicLibraryEntry(
          kind: MusicLibraryKind.song,
          id: 'https://youtube.com/watch?v=abcdefghijk',
          title: 'URL is not an ID'),
      const MusicLibraryEntry(
          kind: MusicLibraryKind.song, id: 'abcdefghijk', title: '  '),
    ]) {
      await expectLater(
          library.importSongs([song(1), invalid]), throwsArgumentError);
      expect(database.getSettings(musicLibrarySettingName)?.value, before);
    }
  });

  test('capacity failure keeps the full previous library and sends no notice',
      () async {
    final stored = jsonEncode({
      'version': 1,
      'entries': [
        for (var index = 0; index < musicLibraryMaximumEntries - 1; index++)
          song(index).toJson(),
      ],
      'playlists': [],
    });
    await database.saveSetting(SettingsValue(musicLibrarySettingName, stored));
    var changes = 0;
    library.changes.addListener(() => changes++);
    await expectLater(
        library.importSongs([song(10000), song(10001)]), throwsStateError);
    expect(database.getSettings(musicLibrarySettingName)?.value, stored);
    expect(changes, 0);
    expect(await library.importSongs([song(10000)]), 1);
    expect(library.entries, hasLength(musicLibraryMaximumEntries));
  });

  test('UTF-8 byte capacity rejects the whole import', () async {
    await library.save(song(0));
    final stored = database.getSettings(musicLibrarySettingName)?.value;
    await expectLater(
        library.importSongs([
          for (var index = 1; index < 1000; index++)
            MusicLibraryEntry(
                kind: MusicLibraryKind.song,
                id: song(index).id,
                title: 'é' * 1024,
                subtitle: 'é' * 1024,
                album: 'é' * 1024),
        ]),
        throwsStateError);
    expect(database.getSettings(musicLibrarySettingName)?.value, stored);
  });

  test('concurrent imports and ordinary saves preserve every new song',
      () async {
    final other = MusicLibraryService.forProfile(database, database.profileId);
    final first = library.importSongs([song(1), song(2)]);
    final saved = other.save(song(3));
    final second = other.importSongs([song(2), song(4)]);
    expect(await first, 2);
    await saved;
    expect(await second, 1);
    expect(library.entries.map((entry) => entry.id),
        ['song0000003', 'song0000001', 'song0000002', 'song0000004']);
  });

  test('captured imports stay in their profile after a switch', () async {
    final original = database.profileId;
    final second = await database.createProfile('Second listener');
    final imported = library.importSongs([song(1), song(2)]);
    await database.useProfile(second.id);
    expect(await imported, 2);
    expect(library.profileId, original);
    expect(library.entries, hasLength(2));
    final other = MusicLibraryService.forProfile(database, second.id);
    expect(other.entries, isEmpty);
  });

  test('deleted profile cannot receive or be recreated by an import', () async {
    final original = database.profileId;
    final second = await database.createProfile('Second listener');
    await database.useProfile(second.id);
    await database.deleteProfile(original);
    await expectLater(library.importSongs([song(1)]), throwsStateError);
    expect((await database.getProfiles()).map((profile) => profile.id),
        [second.id]);
  });
}
