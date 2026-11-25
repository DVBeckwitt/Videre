import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  const first = 'local:first';
  const second = 'local:second';
  late SembastSqfDb database;
  late MusicLibraryService library;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    library = MusicLibraryService.forProfile(database, database.profileId);
  });

  tearDown(() async => database.close());

  test('pins persist after database reopen', () async {
    final factory = newDatabaseFactoryMemory();
    const path = 'music-playlist-pins';
    final initial = SembastSqfDb(await factory.openDatabase(path));
    await initial.getProfiles();
    final owner = MusicLibraryService.forProfile(initial, initial.profileId);
    await owner.markLocalPlaylist(first);
    await owner.setLocalPlaylistPinned(first, pinned: true);
    await initial.close();

    final reopened = SembastSqfDb(await factory.openDatabase(path));
    addTearDown(reopened.close);
    await reopened.getProfiles();
    final restored =
        MusicLibraryService.forProfile(reopened, reopened.profileId);
    expect(restored.pinnedLocalPlaylistIds, {first});
    await restored.setLocalPlaylistPinned(first, pinned: false);
    expect(restored.pinnedLocalPlaylistIds, isEmpty);
    expect(restored.localPlaylistIds, {first});
  });

  test('pins and changes stay with their owner when profiles share an ID',
      () async {
    final profile = await database.createProfile('Second');
    final other = MusicLibraryService.forProfile(database, profile.id);
    await library.markLocalPlaylist(first);
    await other.markLocalPlaylist(first);
    var originalChanges = 0;
    var otherChanges = 0;
    library.changes.addListener(() => originalChanges++);
    other.changes.addListener(() => otherChanges++);

    await database.useProfile(profile.id);
    await library.setLocalPlaylistPinned(first, pinned: true);
    expect(library.pinnedLocalPlaylistIds, {first});
    expect(other.pinnedLocalPlaylistIds, isEmpty);
    expect((originalChanges, otherChanges), (1, 0));

    await other.setLocalPlaylistPinned(first, pinned: true);
    await library.setLocalPlaylistPinned(first, pinned: false);
    expect(library.pinnedLocalPlaylistIds, isEmpty);
    expect(other.pinnedLocalPlaylistIds, {first});
    expect((originalChanges, otherChanges), (2, 1));
  });

  test('same-owner pin updates serialize and no-op writes do not notify',
      () async {
    final another =
        MusicLibraryService.forProfile(database, database.profileId);
    await library.markLocalPlaylist(first);
    await library.markLocalPlaylist(second);
    var changes = 0;
    another.changes.addListener(() => changes++);

    await Future.wait([
      library.setLocalPlaylistPinned(first, pinned: true),
      another.setLocalPlaylistPinned(second, pinned: true),
      another.setLocalPlaylistPinned(first, pinned: false),
      library.setLocalPlaylistPinned(second, pinned: true),
      another.setLocalPlaylistPinned(first, pinned: false),
    ]);

    expect(library.pinnedLocalPlaylistIds, {second});
    expect(another.pinnedLocalPlaylistIds, {second});
    expect(changes, 3);
  });

  test('older libraries and malformed pin storage start without pins',
      () async {
    await library.markLocalPlaylist(first);
    expect(library.pinnedLocalPlaylistIds, isEmpty);

    for (final invalid in ['[', '{"pins":["local:first"]}']) {
      await database
          .saveSetting(SettingsValue(musicPlaylistPinsSettingName, invalid));
      expect(library.pinnedLocalPlaylistIds, isEmpty);
    }

    expect(() => library.setLocalPlaylistPinned('PLremote', pinned: true),
        throwsArgumentError);
    await library.setLocalPlaylistPinned(first, pinned: true);
    expect(library.pinnedLocalPlaylistIds, {first});
    expect(library.localPlaylistIds, {first});
  });
}
