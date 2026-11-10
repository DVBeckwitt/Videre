import 'dart:async';
import 'dart:convert';

import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/models/saved_playlist.dart';
import 'package:clipious/playlists/services/playlist_library_service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  late SembastSqfDb database;
  late PlaylistLibraryService library;
  const source = Playlist(
      playlistId: 'PLsaved',
      title: 'A saved playlist',
      author: 'Creator',
      videoCount: 8);
  const reference = PlaylistReference(
      kind: PlaylistSourceKind.public,
      playlistId: 'PLsaved',
      profileId: 'default');
  final saved = SavedPlaylist.fromPlaylist(source, reference);

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    library = PlaylistLibraryService.forProfile(database, database.profileId);
  });

  tearDown(() async => database.close());

  test('guest save and remove survive a database reopen', () async {
    final factory = newDatabaseFactoryMemory();
    var store = SembastSqfDb(await factory.openDatabase('saved-playlists'));
    var bookmarks = PlaylistLibraryService.forProfile(store, store.profileId);
    await bookmarks.save(saved);
    await store.close();
    store = SembastSqfDb(await factory.openDatabase('saved-playlists'));
    bookmarks = PlaylistLibraryService.forProfile(store, store.profileId);
    expect(bookmarks.entries.single.toJson(), saved.toJson());
    expect(bookmarks.contains(reference), isTrue);
    await bookmarks.remove(reference);
    await store.close();
    store = SembastSqfDb(await factory.openDatabase('saved-playlists'));
    expect(PlaylistLibraryService.forProfile(store, store.profileId).entries,
        isEmpty);
    await store.close();
  });

  test('same-person wrappers serialize concurrent writes and notify together',
      () async {
    final wrapper = database.forProfile(database.profileId);
    final second =
        PlaylistLibraryService.forProfile(wrapper, wrapper.profileId);
    var changes = 0;
    second.changes.addListener(() => changes++);
    await Future.wait([
      for (var index = 0; index < 20; index++)
        (index.isEven ? library : second).save(SavedPlaylist.fromPlaylist(
            source.copyWith(playlistId: 'PL$index'),
            PlaylistReference(
                kind: PlaylistSourceKind.public,
                playlistId: 'PL$index',
                profileId: database.profileId))),
    ]);
    expect(library.entries, hasLength(20));
    expect(changes, 20);
    await library.save(saved);
    await second.save(saved);
    expect(library.entries, hasLength(21));
  });

  test('save queued during restore retains both imported and saved entries',
      () async {
    final importing = Completer<void>();
    final finishImport = Completer<void>();
    final imported = SavedPlaylist.fromPlaylist(
        source.copyWith(playlistId: 'PLimported'),
        const PlaylistReference(
            kind: PlaylistSourceKind.public,
            playlistId: 'PLimported',
            profileId: 'default'));
    final restore = database.db.transaction((txn) async {
      importing.complete();
      await finishImport.future;
      await database.settingsStore.record(playlistLibrarySettingName).put(
          txn,
          SettingsValue(
              playlistLibrarySettingName,
              jsonEncode({
                'version': 1,
                'entries': [imported.toJson()]
              })).toJson());
    });
    await importing.future;
    final saving = library.save(saved);
    // Let the save enqueue while the import still owns the transaction.
    await Future<void>.delayed(Duration.zero);
    finishImport.complete();
    await Future.wait([restore, saving]);
    expect(library.entries.map((entry) => entry.reference.playlistId),
        unorderedEquals(['PLsaved', 'PLimported']));
  });

  test('captured writes remain with their person after a switch', () async {
    final next = await database.createProfile('Another person');
    final pending = library.save(saved);
    await database.useProfile(next.id);
    await pending;
    final nextLibrary = PlaylistLibraryService.forProfile(database, next.id);
    expect(library.entries.single.reference.profileId, 'default');
    expect(nextLibrary.entries, isEmpty);
    expect(() => nextLibrary.save(saved), throwsArgumentError);
    expect(() => nextLibrary.remove(reference), throwsArgumentError);
  });

  test('public bookmarks deduplicate across backends, accounts stay distinct',
      () async {
    const first = Server(url: 'https://first.example', id: 'first');
    const second = Server(url: 'https://second.example', id: 'second');
    for (final server in [first, second]) {
      await library.save(SavedPlaylist.fromPlaylist(source,
          PlaylistReference.forPlaylist(source, database, server: server)));
    }
    expect(library.entries, hasLength(1));
    final private = source.copyWith(playlistId: 'IVPLprivate');
    for (final account in [first, first.copyWith(id: 'another-account')]) {
      await library.save(SavedPlaylist.fromPlaylist(private,
          PlaylistReference.forPlaylist(private, database, server: account)));
    }
    expect(library.entries, hasLength(3));
    final result = library.merge([source], server: second);
    expect(result, hasLength(3));
    expect(result.where((entry) => entry.saved), hasLength(2));
    expect(result.first.playlist, same(source));
  });

  test('malformed cache rows do not hide valid bookmarks or cross profiles',
      () async {
    await database.saveSetting(SettingsValue(
        playlistLibrarySettingName,
        jsonEncode({
          'version': 1,
          'entries': [
            saved.toJson(),
            {'reference': null},
            {
              ...saved.toJson(),
              'reference': {...reference.toJson(), 'profileId': 'other'}
            },
            saved.toJson(),
          ]
        })));
    expect(library.entries.single.toJson(), saved.toJson());
    await database.saveSetting(SettingsValue(playlistLibrarySettingName, '{'));
    expect(library.entries, isEmpty);
    await library.save(saved);
    expect(library.entries.single.title, source.title);
  });

  test('server bookmarks retain deletion ownership without owning the source',
      () async {
    const server = Server(url: 'https://instance.example', id: 'owner');
    await database.upsertServer(server);
    await library.save(saved);
    final remote = source.copyWith(type: invidiousPlaylist);
    final item = library.merge([remote], server: server).single;
    expect(item.reference, reference);
    expect(item.saved, isFalse);
    expect(item.bookmarkOwner?.kind, PlaylistSourceKind.account);
    expect(item.bookmarkOwner?.playlistId, source.playlistId);
    expect(item.bookmarkOwner?.resolveServer(database)?.accountId, 'owner');
    // Search/channel lists and local bookmarks must not gain server deletion.
    expect(
        library.merge([source], server: server).single.bookmarkOwner, isNull);
    expect(library.merge([]).single.bookmarkOwner, isNull);
    expect(library.merge([remote]).single.bookmarkOwner, isNull);
  });

  test('bookmarks retain bounded display metadata without media credentials',
      () {
    final playlist = source.copyWith(videos: [
      const Video(videoId: 'filtered', filtered: true),
      for (var index = 0; index < 8; index++)
        Video(
            videoId: 'video$index',
            title: 'Video $index',
            author: 'Creator',
            hlsUrl: 'https://media.example/secret-stream?token=private',
            videoThumbnails: [
              ImageObject(
                  null,
                  '/vi/video$index/mqdefault.jpg?token=private#fragment',
                  320,
                  180),
              ImageObject(
                  null, 'https://user:password@image.example/a.jpg', 320, 180),
            ]),
    ]);
    final clean = SavedPlaylist.fromPlaylist(playlist, reference);
    expect(clean.previews, hasLength(4));
    expect(clean.previews.map((video) => video.videoId),
        ['video0', 'video1', 'video2', 'video3']);
    expect(clean.previews.first.videoThumbnails.single.url,
        '/vi/video0/mqdefault.jpg');
    final encoded = jsonEncode(clean.toJson());
    expect(encoded, isNot(contains('private')));
    expect(encoded, isNot(contains('hlsUrl')));
    expect(encoded, isNot(contains('password')));
    expect(clean.toPlaylist().videoCount, 8);
  });

  test('local editable playlists cannot be bookmarked as remote references',
      () {
    final local = source.copyWith(playlistId: 'local:mine');
    expect(
        () => SavedPlaylist.fromPlaylist(
            local, PlaylistReference.forPlaylist(local, database)),
        throwsArgumentError);
  });

  test('cached metadata must match the referenced playlist', () {
    expect(
        () => SavedPlaylist.fromPlaylist(
            source.copyWith(playlistId: 'PLother'), reference),
        throwsArgumentError);
  });

  test('restored library notification is shared by existing owner views', () {
    var changes = 0;
    library.changes.addListener(() => changes++);
    PlaylistLibraryService.notifyProfileChanged(
        database.forProfile(database.profileId), database.profileId);
    expect(changes, 1);
  });
}
