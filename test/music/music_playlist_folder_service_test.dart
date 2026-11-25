import 'dart:convert';

import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_playlist_folder_service.dart';
import 'package:clipious/player/models/playback_session.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_progress.dart';
import 'package:clipious/settings/models/db/person_profile.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const profileId = PersonProfile.defaultId;
  const path = 'music-playlist-folders';
  const title = 'Shared title';
  const local = PlaylistReference(
    kind: PlaylistSourceKind.local,
    playlistId: 'local:mix',
    profileId: profileId,
    displayTitle: title,
  );
  const public = PlaylistReference(
    kind: PlaylistSourceKind.public,
    playlistId: 'PLmix',
    profileId: profileId,
    displayTitle: title,
  );
  const entries = [
    Video(
        videoId: 'abcdefghijk',
        indexId: 'first',
        queueEntryId: 'occurrence-one',
        musicMetadata: MusicMetadata(title: 'Track', artist: 'Artist')),
    Video(
        videoId: 'abcdefghijk',
        indexId: 'second',
        queueEntryId: 'occurrence-two',
        musicMetadata: MusicMetadata(title: 'Track', artist: 'Artist')),
  ];
  late DatabaseFactory factory;
  late SembastSqfDb database;
  late MusicPlaylistFolderService folders;

  Future<void> openDatabase() async {
    database = SembastSqfDb(await factory.openDatabase(path));
    await database.getProfiles();
    folders = MusicPlaylistFolderService.forProfile(database, profileId);
  }

  setUp(() async {
    factory = newDatabaseFactoryMemory();
    await openDatabase();
    await database.saveSetting(SettingsValue(
      localPlaylistsSetting,
      jsonEncode([
        Playlist(
          playlistId: local.playlistId,
          title: title,
          author: '',
          videoCount: entries.length,
          videos: entries,
        ),
      ]),
    ));
    await MusicLibraryService.forProfile(database, profileId).save(
      MusicLibraryEntry(
        kind: MusicLibraryKind.playlist,
        id: public.playlistId,
        title: title,
      ),
    );
  });

  tearDown(() => database.close());

  test('existing playlists start at the root and folder IDs survive reopen',
      () async {
    expect(folders.snapshot.folders, isEmpty);
    expect(folders.snapshot.folderFor(local), isNull);
    expect(folders.snapshot.folderFor(public), isNull);

    final first = await folders.createFolder('First');
    final nested = await folders.createFolder('Nested', parentId: first.id);
    await folders.movePlaylist(local, nested.id);
    await folders.movePlaylist(public, first.id);
    await folders.renameFolder(first.id, 'Renamed');
    await database.close();
    await openDatabase();

    final snapshot = folders.snapshot;
    final breadcrumb = snapshot.pathTo(nested.id);
    expect(breadcrumb.map((folder) => folder.id), [first.id, nested.id]);
    expect(breadcrumb.map((folder) => folder.name), ['Renamed', 'Nested']);
    expect(snapshot.folderFor(local), nested.id);
    expect(snapshot.folderFor(public), first.id);
    const renamedPlaylist = PlaylistReference(
      kind: PlaylistSourceKind.local,
      playlistId: 'local:mix',
      profileId: profileId,
      displayTitle: 'Renamed playlist',
    );
    expect(snapshot.folderFor(renamedPlaylist), nested.id);

    await folders.movePlaylist(local, null);
    expect(folders.snapshot.folderFor(local), isNull);
    expect(folders.snapshot.folderFor(public), first.id);
  });

  test('invalid moves and stale operations leave the tree intact', () async {
    final parent = await folders.createFolder('Parent');
    final child = await folders.createFolder('Child', parentId: parent.id);
    final destination = await folders.createFolder('Destination');
    final other = MusicPlaylistFolderService.forProfile(
        database.forProfile(profileId), profileId);
    await other.movePlaylist(local, child.id);
    expect(folders.snapshot.canMoveFolder(parent.id, parent.id), isFalse);
    expect(folders.snapshot.canMoveFolder(parent.id, child.id), isFalse);
    expect(folders.snapshot.canMoveFolder(parent.id, 'missing'), isFalse);
    expect(folders.snapshot.canMoveFolder(parent.id, destination.id), isTrue);

    final rejected =
        expectLater(other.moveFolder(parent.id, child.id), throwsStateError);
    final allowed = folders.moveFolder(parent.id, destination.id);
    await rejected;
    await allowed;
    await expectLater(folders.movePlaylist(local, 'missing'), throwsStateError);
    await expectLater(folders.movePlaylist(local, null, isCurrent: () => false),
        throwsStateError);
    await expectLater(
        folders.renameFolder(parent.id, '  '), throwsArgumentError);

    expect(other.snapshot.pathTo(child.id).map((folder) => folder.id),
        [destination.id, parent.id, child.id]);
    expect(other.snapshot.folderFor(local), child.id);
  });

  test('other profiles and account sources cannot assign a playlist', () async {
    final person = await database.createProfile('Another listener');
    final other = MusicPlaylistFolderService.forProfile(database, person.id);
    final ownFolder = await folders.createFolder('Own folder');
    final otherFolder = await other.createFolder('Other folder');
    await folders.movePlaylist(local, ownFolder.id);
    const account = PlaylistReference(
      kind: PlaylistSourceKind.account,
      playlistId: 'IVPmix',
      profileId: profileId,
      accountId: 'account',
      origin: 'https://example.test',
    );

    await expectLater(
        other.movePlaylist(local, otherFolder.id), throwsStateError);
    await expectLater(
        folders.movePlaylist(local, otherFolder.id), throwsStateError);
    await expectLater(
        folders.movePlaylist(account, ownFolder.id), throwsStateError);

    expect(other.snapshot.folderFor(local), isNull);
    expect(folders.snapshot.folders.map((folder) => folder.id), [ownFolder.id]);
    expect(folders.snapshot.folderFor(local), ownFolder.id);
  });

  test('damaged folder metadata leaves existing playlists reachable', () async {
    await database
        .saveSetting(SettingsValue(musicPlaylistFolderSettingName, '{'));
    expect(folders.snapshot.folders, isEmpty);
    expect(folders.snapshot.folderFor(local), isNull);
    await database.saveSetting(SettingsValue(
      musicPlaylistFolderSettingName,
      jsonEncode({
        'version': 1,
        'folders': [
          {'id': 'one', 'name': 'One', 'parentId': 'two'},
          {'id': 'two', 'name': 'Two', 'parentId': 'one'},
          {'id': 'orphan', 'name': 'Orphan', 'parentId': 'missing'},
        ],
        'memberships': [
          {'playlist': local.toJson(), 'folderId': 'missing'},
          {'playlist': public.toJson(), 'folderId': 'orphan'},
        ],
      }),
    ));
    final repaired = folders.snapshot;
    expect(repaired.pathTo('one').map((folder) => folder.id),
        hasLength(lessThanOrEqualTo(2)));
    expect(repaired.pathTo('orphan').map((folder) => folder.id), ['orphan']);
    expect(repaired.folderFor(local), isNull);
    expect(repaired.folderFor(public), 'orphan');
  });

  test('removing a folder promotes its contents in one committed update',
      () async {
    final parent = await folders.createFolder('Parent');
    final removed = await folders.createFolder('Removed', parentId: parent.id);
    final child = await folders.createFolder('Child', parentId: removed.id);
    await folders.movePlaylist(local, removed.id);
    await folders.movePlaylist(public, child.id);
    final notifications = <({String? parent, String? localFolder})>[];
    void record() {
      final snapshot = folders.snapshot;
      notifications.add((
        parent: snapshot.folder(child.id)?.parentId,
        localFolder: snapshot.folderFor(local),
      ));
    }

    folders.changes.addListener(record);
    addTearDown(() => folders.changes.removeListener(record));
    await folders.removeFolder(removed.id);

    expect(notifications, [(parent: parent.id, localFolder: parent.id)]);
    expect(folders.snapshot.folders.map((folder) => folder.id),
        unorderedEquals([parent.id, child.id]));
    expect(folders.snapshot.folderFor(public), child.id);
  });

  test('organizing a playlist preserves its queue and exact resume occurrence',
      () async {
    final progress = PlaylistProgressService.forProfile(database, profileId);
    expect(await progress.save(local, entries.last, entries: entries), isTrue);
    final session = PlaybackSession(
      videos: entries,
      currentId: entries.last.queueEntryId!,
      seconds: 43,
      audio: true,
      playlistReference: local,
      playlistEntries: entries,
      playlistComplete: true,
    );
    await database
        .saveSetting(SettingsValue(playbackSessionSetting, session.encode()));
    final source = database.getSettings(localPlaylistsSetting)!.value;
    final checkpoint = database.getSettings(playlistProgressSettingName)!.value;

    final folder = await folders.createFolder('Queue source');
    await folders.movePlaylist(local, folder.id);
    await folders.renameFolder(folder.id, 'Renamed folder');
    await folders.removeFolder(folder.id);

    expect(database.getSettings(localPlaylistsSetting)!.value, source);
    expect(
        database.getSettings(playlistProgressSettingName)!.value, checkpoint);
    final target = progress.get(local)!.resolve(entries)!;
    expect(target.index, 1);
    expect(target.video.queueEntryId, entries.last.queueEntryId);
    final stored = database.getSettings(playbackSessionSetting)!.value;
    expect(stored, session.encode());
    final restored = PlaybackSession.decode(stored)!;
    expect(restored.playlistReference, local);
    expect(restored.currentId, entries.last.queueEntryId);
    expect(restored.seconds, 43);
  });
}
