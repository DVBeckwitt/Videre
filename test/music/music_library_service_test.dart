import 'dart:convert';

import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_identity.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_visibility.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  late SembastSqfDb database;
  late MusicLibraryService library;
  const song = MusicLibraryEntry(
      kind: MusicLibraryKind.song,
      id: 'abcdefghijk',
      title: 'Saved song',
      subtitle: 'Artist',
      album: 'Album',
      albumPlaylistId: 'OLAK5uy_release1',
      durationSeconds: 185);

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    library = MusicLibraryService.forProfile(database, database.profileId);
  });

  tearDown(() async => database.close());

  test('playlist hides and Discovery snoozes keep their scope after reopen',
      () async {
    final factory = newDatabaseFactoryMemory();
    final store = SembastSqfDb(await factory.openDatabase('visibility'));
    final profile = store.profileId;
    final other = await store.createProfile('Other listener');
    const recording = MusicTrack(videoId: 'abcdefghijk', title: 'Recording');
    PlaylistReference playlist(String id, {String? name, String? owner}) =>
        PlaylistReference(
          kind: PlaylistSourceKind.local,
          playlistId: 'local:$id',
          profileId: owner ?? profile,
          displayTitle: name,
        );
    var now = DateTime.utc(2026, 1, 1, 18);
    const day = Duration(days: 1);
    final expiry = now.add(day);
    final before =
        MusicVisibility.withClock(store.forProfile(profile), () => now);
    await Future.wait([
      before.setHiddenInPlaylist(playlist('first'), recording.videoId, true),
      before.snooze(recording, day),
    ]);
    await store.close();
    before.dispose();

    final reopened = SembastSqfDb(await factory.openDatabase('visibility'));
    final after =
        MusicVisibility.withClock(reopened.forProfile(profile), () => now);
    final otherVisibility =
        MusicVisibility.withClock(reopened.forProfile(other.id), () => now);
    addTearDown(after.dispose);
    addTearDown(otherVisibility.dispose);
    expect(
        after.isHiddenInPlaylist(
            playlist('first', name: 'Renamed'), recording.videoId),
        isTrue);
    expect(after.isHiddenInPlaylist(playlist('second'), recording.videoId),
        isFalse);
    expect(
        otherVisibility.isHiddenInPlaylist(
            playlist('first', owner: other.id), recording.videoId),
        isFalse);
    expect(otherVisibility.isSnoozed(recording.videoId), isFalse);
    expect(after.activeSnoozes.single.expiresAt, expiry);
    expect(after.isSnoozed(recording.videoId), isTrue);

    await after.setHiddenInPlaylist(
        playlist('first'), recording.videoId, false);
    expect(after.isHiddenInPlaylist(playlist('first'), recording.videoId),
        isFalse);
    now = expiry.subtract(const Duration(microseconds: 1));
    expect(after.isSnoozed(recording.videoId), isTrue);
    now = expiry;
    expect(after.isSnoozed(recording.videoId), isFalse);
    expect(after.activeSnoozes, isEmpty);
    await reopened.close();

    final restarted = SembastSqfDb(await factory.openDatabase('visibility'));
    addTearDown(restarted.close);
    final restored =
        MusicVisibility.withClock(restarted.forProfile(profile), () => now);
    addTearDown(restored.dispose);
    expect(restored.isHiddenInPlaylist(playlist('first'), recording.videoId),
        isFalse);
    expect(restored.activeSnoozes, isEmpty);
  });

  testWidgets('Discovery announces the next expiry while observed',
      (tester) async {
    final start = DateTime.utc(2026, 1, 1);
    var now = start;
    final visibility = MusicVisibility.withClock(
        database.forProfile(database.profileId), () => now);
    addTearDown(visibility.dispose);
    await tester.runAsync(() => visibility.snooze(
        const MusicTrack(videoId: 'abcdefghijk', title: 'Recording'),
        const Duration(seconds: 10)));
    var changes = 0;
    visibility.addListener(() => changes++);
    now = start.add(const Duration(seconds: 9));
    await tester.pump(const Duration(seconds: 9));
    expect(visibility.isSnoozed('abcdefghijk'), isTrue);
    expect(changes, 0);
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(visibility.isSnoozed('abcdefghijk'), isFalse);
    expect(changes, 1);
  });

  test('catalog aliases persist per profile and separate namesake artists',
      () async {
    const first = MusicArtistIdentity.catalog('UC1234567890123456789012');
    const second = MusicArtistIdentity.catalog('UC0123456789012345678901');
    const credits = [
      MusicArtistCredit(name: 'Same Name', id: 'UC1234567890123456789012'),
      MusicArtistCredit(name: 'Same Name', id: 'UC0123456789012345678901'),
      MusicArtistCredit(name: 'Session Artist'),
    ];
    const original = 'Same Name, Same Name, Session Artist';
    const bookmark = MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'artistAlias',
        title: 'Song with credits',
        subtitle: original,
        artistCredits: credits);
    final factory = newDatabaseFactoryMemory();
    var store = SembastSqfDb(await factory.openDatabase('artist-aliases'));
    await store.getProfiles();
    final ownerId = store.profileId;
    final otherId = (await store.createProfile('Another listener')).id;
    var saved = MusicLibraryService.forProfile(store, ownerId);
    await saved.save(bookmark);
    final sameOwner = MusicLibraryService.forProfile(store, ownerId);
    var notifications = 0;
    sameOwner.changes.addListener(() => notifications++);
    expect(
        await Future.wait([
          saved.setArtistAlias(first, '  Stage Name  ', isCurrent: () => true),
          sameOwner.setArtistAlias(second, 'Stage Name', isCurrent: () => true),
        ]),
        [true, true]);
    expect(notifications, 2);
    await store.close();

    store = SembastSqfDb(await factory.openDatabase('artist-aliases'));
    await store.getProfiles();
    saved = MusicLibraryService.forProfile(store, ownerId);
    final other = MusicLibraryService.forProfile(store, otherId);
    expect(saved.catalogArtistByline(original, credits),
        'Stage Name, Stage Name, Session Artist');
    expect(other.catalogArtistByline(original, credits), original);
    expect(
        await saved.setArtistAlias(first, null, isCurrent: () => true), true);
    expect(saved.artistDisplayName(first, credits.first.name), 'Same Name');
    expect(saved.artistAlias(second), 'Stage Name');
    expect(saved.catalogArtistByline(original, credits),
        'Same Name, Stage Name, Session Artist');
    expect(saved.entries.single.toJson(), bookmark.toJson());
    await store.close();
  });

  test('device aliases resolve from original credits and leave the tags intact',
      () async {
    const performer = MusicArtistIdentity.device('raw artist');
    const albumArtist = MusicArtistIdentity.device('raw album artist');
    const track = LocalMusicTrack(
        uri: 'content://media/external/audio/media/1',
        title: 'Track',
        artist: 'Raw Artist',
        albumArtist: 'Raw Album Artist');
    await library.setArtistAlias(albumArtist, 'New Label',
        isCurrent: () => true);
    expect(library.deviceArtistByline(track), 'Raw Artist');
    await library.setArtistAlias(performer, 'New Label', isCurrent: () => true);
    expect(library.deviceArtistByline(track), 'New Label');
    expect(library.artistDisplayName(albumArtist, track.albumArtist!),
        'New Label');

    await library.setArtistAlias(performer, null, isCurrent: () => true);
    expect(library.deviceArtistByline(track), 'Raw Artist');
    expect(library.artistAlias(albumArtist), 'New Label');
    expect(track.artist, 'Raw Artist');
    expect(track.albumArtist, 'Raw Album Artist');
  });

  test('artist alias writes reject stale sessions and ignore damaged settings',
      () async {
    const artist = MusicArtistIdentity.device('device:artist');
    await database.saveSetting(SettingsValue(
        musicArtistAliasesSettingName,
        jsonEncode({
          artist.storageKey: ' \t ',
          'catalog:not-a-channel': 'Invalid credit',
          'device:another artist': '  Existing Artist ',
        })));
    expect(library.artistAlias(artist), isNull);
    expect(
        await library.setArtistAlias(artist, 'Stale', isCurrent: () => false),
        isFalse);
    expect(library.artistAlias(artist), isNull);
    await expectLater(
        library.setArtistAlias(artist, ''.padRight(1025, 'a'),
            isCurrent: () => true),
        throwsArgumentError);
    await library.setArtistAlias(artist, ' Local\tAlias ',
        isCurrent: () => true);
    expect(
        jsonDecode(database.getSettings(musicArtistAliasesSettingName)!.value),
        {
          artist.storageKey: 'Local Alias',
          'device:another artist': 'Existing Artist'
        });
  });

  test('bookmarks and explicit empty playlists persist after database reopen',
      () async {
    final factory = newDatabaseFactoryMemory();
    var connection = await factory.openDatabase('music-library');
    var store = SembastSqfDb(connection);
    await store.getProfiles();
    var saved = MusicLibraryService.forProfile(store, store.profileId);
    await saved.save(song);
    await saved.markLocalPlaylist('local:music');
    await store.close();

    connection = await factory.openDatabase('music-library');
    store = SembastSqfDb(connection);
    await store.getProfiles();
    saved = MusicLibraryService.forProfile(store, store.profileId);
    expect(saved.entries.single.toJson(), song.toJson());
    expect(
        saved.isMusicPlaylist(const Playlist(
            title: 'Music',
            playlistId: 'local:music',
            author: '',
            videoCount: 0)),
        isTrue);
    expect(saved.entries.single.toVideo().musicMetadata?.album, 'Album');
    expect(saved.entries.single.toVideo().musicMetadata?.albumPlaylistId,
        'OLAK5uy_release1');
    await store.close();
  });

  test('release metadata survives hydration and ignores unsafe or legacy IDs',
      () {
    const labels = MusicMetadata(
        title: 'abcdefghijk',
        artist: '',
        album: 'Record',
        albumPlaylistId: 'OLAK5uy_release1');
    const song = Video(videoId: 'abcdefghijk', musicMetadata: labels);
    const detail =
        Video(videoId: 'abcdefghijk', title: 'Song', author: 'Artist');
    final hydrated = detail.preservingMusicMetadataFrom(song);
    final restored = Video.fromJson(
        jsonDecode(jsonEncode(hydrated)) as Map<String, dynamic>);
    expect(restored.musicMetadata!.title, 'Song');
    expect(restored.musicMetadata!.withThumbnails([]).albumPlaylistId,
        'OLAK5uy_release1');
    final bookmark = MusicLibraryEntry.song(restored);
    const fresh =
        MusicMetadata(title: 'Fresh song title', artist: 'Fresh artist');
    final withAlbum = fresh.withAlbumFrom(bookmark.toVideo().musicMetadata);
    expect(withAlbum.title, fresh.title);
    expect(withAlbum.artist, fresh.artist);
    expect(withAlbum.album, 'Record');
    expect(withAlbum.albumPlaylistId, 'OLAK5uy_release1');
    expect(identical(withAlbum.withAlbumFrom(fresh), withAlbum), isTrue);
    for (final invalid in [
      null,
      7,
      'MPREalbum',
      'RDmix',
      'PLplaylist',
      'OLAK5uy_',
      'OLAK5uy_a\n',
      'https://example.org/OLAK5uy_release',
      'OLAK5uy_a/b',
      'OLAK5uy_'.padRight(129, 'a')
    ]) {
      final decoded = MusicMetadata.fromJson(
          {...labels.toJson(), 'albumPlaylistId': invalid});
      expect(decoded.album, 'Record');
      expect(decoded.albumPlaylistId, isNull);
      expect(decoded.toJson().containsKey('albumPlaylistId'), isFalse);
      final entry = MusicLibraryEntry.tryParse(
          {...bookmark.toJson(), 'albumPlaylistId': invalid})!;
      expect(entry.toVideo().musicMetadata!.albumPlaylistId, isNull);
    }
    expect(
        MusicMetadata.fromJson({'title': 'Old', 'artist': ''}).albumPlaylistId,
        isNull);
    expect(
        const MusicTrack(
                videoId: 'abcdefghijk', title: 'Song', albumId: 'MPREalbum')
            .musicMetadata
            .albumPlaylistId,
        isNull);
  });

  test('same-owner concurrent saves keep every bookmark and deduplicate IDs',
      () async {
    final another =
        MusicLibraryService.forProfile(database, database.profileId);
    await Future.wait([
      for (var index = 0; index < 30; index++)
        (index.isEven ? library : another).save(MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: 'song${index.toString().padLeft(7, '0')}',
            title: 'Song $index')),
    ]);
    expect(library.entries, hasLength(30));
    await library.save(song);
    await another.save(song);
    expect(library.entries, hasLength(31));
    await another.remove(song.kind, song.id);
    expect(library.contains(song.kind, song.id), isFalse);
    expect(library.entries, hasLength(30));
  });

  test('save if absent deduplicates queued writes without refreshing a song',
      () async {
    final duplicate = MusicLibraryEntry(
        kind: song.kind, id: song.id, title: 'Different metadata');
    final another =
        MusicLibraryService.forProfile(database, database.profileId);
    final results = await Future.wait(
        [library.saveIfAbsent(song), another.saveIfAbsent(duplicate)]);
    expect(results, [true, false]);
    expect(library.entries.single.title, song.title);

    const latest = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: 'secondsong2', title: 'Latest song');
    await library.save(latest);
    expect(await another.saveIfAbsent(duplicate), isFalse);
    expect(library.entries.map((entry) => entry.title),
        [latest.title, song.title]);
  });

  test('saved song title is private to its profile and survives reopening',
      () async {
    final factory = newDatabaseFactoryMemory();
    var store = SembastSqfDb(await factory.openDatabase('saved-song-title'));
    await store.getProfiles();
    final ownerId = store.profileId;
    final otherId = (await store.createProfile('Another listener')).id;
    var saved = MusicLibraryService.forProfile(store, ownerId);
    await saved.save(song);
    await MusicLibraryService.forProfile(store, otherId).save(song);
    await saved.markLocalPlaylist('local:playlist');
    expect(
        await saved.setSavedSongTitle(song.id, '  My\tSong  ',
            isCurrent: () => true),
        isTrue);
    await store.close();

    store = SembastSqfDb(await factory.openDatabase('saved-song-title'));
    await store.getProfiles();
    saved = MusicLibraryService.forProfile(store, ownerId);
    final edited = saved.savedSong(song.id)!;
    expect(edited.toJson(), {...song.toJson(), 'savedTitle': 'My Song'});
    expect(edited.displayTitle, 'My Song');
    expect(edited.toVideo().videoId, song.id);
    expect(edited.toVideo().musicMetadata!.title, song.title);
    expect(saved.localPlaylistIds, {'local:playlist'});
    final other = MusicLibraryService.forProfile(store, otherId);
    expect(other.savedSong(song.id)!.displayTitle, song.title);
    expect(await saved.setSavedSongTitle(song.id, null, isCurrent: () => true),
        isTrue);
    expect(saved.savedSong(song.id)!.toJson(), song.toJson());
    await store.close();
  });

  test('title edits preserve order, survive details and respect stale writes',
      () async {
    const imported = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: 'takeout0001', title: 'takeout0001');
    const details = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: 'takeout0001', title: 'Catalog title');
    await library.save(song);
    await library.importSongs([imported]);

    var current = true;
    final stale = library.setSavedSongTitle(imported.id, 'Stale',
        isCurrent: () => current);
    current = false;
    expect(await stale, isFalse);
    expect(library.savedSong(imported.id)!.savedTitle, isNull);

    await library.setSavedSongTitle(imported.id, 'Mine', isCurrent: () => true);
    expect(library.entries.map((entry) => entry.id), [song.id, imported.id]);
    expect(await library.fillSongDetails([details], isCurrent: () => true), 1);
    expect(library.savedSong(imported.id)!.displayTitle, 'Mine');
    expect(library.savedSong(imported.id)!.title, details.title);
    await library.save(details);
    expect(library.savedSong(imported.id)!.displayTitle, 'Mine');
    await library.setSavedSongTitle(imported.id, null, isCurrent: () => true);
    expect(library.savedSong(imported.id)!.displayTitle, details.title);

    final removed = library.remove(imported.kind, imported.id);
    final pending = library.setSavedSongTitle(imported.id, 'Removed',
        isCurrent: () => true);
    await removed;
    expect(await pending, isFalse);
    expect(library.savedSong(imported.id), isNull);
  });

  test('invalid saved title leaves the song readable and preserves its title',
      () async {
    await library.save(song);
    for (final invalid in [' \n\t ', 'x' * (savedSongTitleMaximumLength + 1)]) {
      await expectLater(
          library.setSavedSongTitle(song.id, invalid, isCurrent: () => true),
          throwsArgumentError);
      final parsed =
          MusicLibraryEntry.tryParse({...song.toJson(), 'savedTitle': invalid});
      expect(parsed?.displayTitle, song.title);
    }
    expect(library.savedSong(song.id)?.toJson(), song.toJson());
  });

  test('explicit Likes import deduplicates without adding saved songs',
      () async {
    expect(await library.importSongs([song, song], asLikes: true), 1);
    expect(await library.importSongs([song], asLikes: true), 0);
    expect(library.likedSongs.single.id, song.id);
    expect(library.entries, isEmpty);
    expect(await library.importSongs([song]), 1);
    expect(library.entries.single.id, song.id);
    expect(library.likedSongs, hasLength(1));
  });

  test('checks the playback owner when the queued Like write starts', () async {
    var isCurrent = true;
    final pending =
        library.setSongLiked(song, liked: true, isCurrent: () => isCurrent);
    isCurrent = false;
    await pending;
    expect(library.isLiked(song.id), isFalse);
    await library.setSongLiked(song, liked: true, isCurrent: () => true);
    expect(library.isLiked(song.id), isTrue);
  });

  test('legacy saves and Likes remain independent through removal', () async {
    await database.saveSetting(SettingsValue(
        musicLibrarySettingName,
        jsonEncode({
          'version': 1,
          'entries': [song.toJson()],
          'playlists': ['local:music'],
        })));
    expect(library.contains(song.kind, song.id), isTrue);
    expect(library.likedSongs, isEmpty);
    expect(library.isLiked(song.id), isFalse);

    await library.setSongLiked(song, liked: true);
    expect(library.likedSongs.single.toJson(), song.toJson());
    expect(library.contains(song.kind, song.id), isTrue);

    await library.remove(song.kind, song.id);
    expect(library.entries, isEmpty);
    expect(library.isLiked(song.id), isTrue);

    await library.save(song);
    await library.setSongLiked(song, liked: false);
    expect(library.likedSongs, isEmpty);
    expect(library.entries.single.toJson(), song.toJson());
    expect(library.localPlaylistIds, {'local:music'});
  });

  test('concurrent library writes keep all Likes, saves and playlist markers',
      () async {
    const otherSong = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: '12345678901', title: 'Second song');
    final another =
        MusicLibraryService.forProfile(database, database.profileId);
    await Future.wait([
      library.setSongLiked(song, liked: true),
      another.save(song),
      another.setSongLiked(song, liked: true),
      library.markLocalPlaylist('local:music'),
      another.setSongLiked(otherSong, liked: true),
    ]);
    expect(another.likedSongs.map((entry) => entry.id),
        unorderedEquals([song.id, otherSong.id]));
    expect(library.entries.single.id, song.id);
    expect(another.localPlaylistIds, {'local:music'});
  });

  test('Likes follow their original profile and persist on reopen', () async {
    final factory = newDatabaseFactoryMemory();
    var connection = await factory.openDatabase('music-likes');
    var store = SembastSqfDb(connection);
    await store.getProfiles();
    final original = store.profileId;
    final originalLibrary = MusicLibraryService.forProfile(store, original);
    final second = await store.createProfile('Second listener');
    await store.useProfile(second.id);
    await originalLibrary.setSongLiked(song, liked: true);
    expect(
        MusicLibraryService.forProfile(store, second.id).likedSongs, isEmpty);
    await store.close();

    connection = await factory.openDatabase('music-likes');
    store = SembastSqfDb(connection);
    addTearDown(store.close);
    await store.getProfiles();
    final restored = MusicLibraryService.forProfile(store, original);
    expect(restored.likedSongs.single.toJson(), song.toJson());
    expect(restored.entries, isEmpty);
    expect(MusicLibraryService.forProfile(store, second.id).isLiked(song.id),
        isFalse);
  });

  test('only Likes accept a display-only device song identity', () async {
    final deviceSong = MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'device:${'a' * 64}',
        title: 'Device song');
    await library.setSongLiked(deviceSong, liked: true);
    expect(library.likedSongs.single.toJson(), deviceSong.toJson());
    expect(library.entries, isEmpty);
    await expectLater(
        Future.sync(() => library.save(deviceSong)), throwsArgumentError);
    await library.setSongLiked(deviceSong, liked: false);
    expect(library.likedSongs, isEmpty);
  });

  test('fills imported song details in place and preserves existing metadata',
      () async {
    const imported = 'takeout0001';
    const named = 'takeout0002';
    await library.save(song);
    await library.markLocalPlaylist('local:my-music');
    await library.importSongs(const [
      MusicLibraryEntry(
          kind: MusicLibraryKind.song, id: imported, title: imported),
      MusicLibraryEntry(
          kind: MusicLibraryKind.song,
          id: named,
          title: 'Export title',
          subtitle: 'Export artist',
          album: 'Export album',
          durationSeconds: 100),
    ]);
    final details = [
      for (final id in [imported, named])
        MusicLibraryEntry(
          kind: MusicLibraryKind.song,
          id: id,
          title: 'Invidious title',
          subtitle: 'Invidious artist',
          artistCredits: const [
            MusicArtistCredit(
                name: 'Invidious artist', id: 'UC1234567890123456789012')
          ],
          album: 'Invidious album',
          durationSeconds: 180,
          usesVideoThumbnails: true,
          thumbnails: [
            ImageObject(
                null, 'https://i.ytimg.com/vi/$id/default.jpg', 120, 90),
            ImageObject(null,
                'https://i.ytimg.com/vi/$id/mqdefault.jpg?key=omit', 320, 180),
          ],
        ),
    ];
    expect(await library.fillSongDetails(details, isCurrent: () => true), 2);

    final reopened =
        MusicLibraryService.forProfile(database, database.profileId);
    expect(
        reopened.entries.map((entry) => entry.id), [song.id, imported, named]);
    final repaired = reopened.entries[1];
    expect(repaired.title, 'Invidious title');
    expect(repaired.subtitle, 'Invidious artist');
    expect(repaired.toVideo().musicMetadata!.artistCredits.single.id,
        'UC1234567890123456789012');
    expect(repaired.album, 'Invidious album');
    expect(repaired.durationSeconds, 180);
    expect(repaired.needsSongDetails, isFalse);
    expect(repaired.usesVideoThumbnails, isTrue);
    expect(repaired.thumbnails.single.url,
        'https://i.ytimg.com/vi/$imported/mqdefault.jpg');
    final alreadyNamed = reopened.entries[2];
    expect(alreadyNamed.title, 'Export title');
    expect(alreadyNamed.subtitle, 'Export artist');
    expect(alreadyNamed.artistCredits, isEmpty);
    expect(alreadyNamed.album, 'Export album');
    expect(alreadyNamed.durationSeconds, 100);
    expect(alreadyNamed.thumbnails, hasLength(1));
    expect(
        reopened.isMusicPlaylist(const Playlist(
            title: 'Music',
            playlistId: 'local:my-music',
            author: '',
            videoCount: 0)),
        isTrue);
  });

  test('a queued detail repair respects removal and session cancellation',
      () async {
    const imported = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: 'takeout0001', title: 'takeout0001');
    const details = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: 'takeout0001', title: 'Catalog title');
    await library.importSongs([imported]);
    final another =
        MusicLibraryService.forProfile(database, database.profileId);
    final removal = another.remove(imported.kind, imported.id);
    final repair = library.fillSongDetails([details], isCurrent: () => true);
    await removal;
    expect(await repair, 0);
    expect(library.entries, isEmpty);

    await library.importSongs([imported]);
    final stored = database.getSettings(musicLibrarySettingName)?.value;
    var current = true;
    final cancelled =
        library.fillSongDetails([details], isCurrent: () => current);
    current = false;
    expect(await cancelled, 0);
    expect(database.getSettings(musicLibrarySettingName)?.value, stored);
    expect(library.entries.single.needsSongDetails, isTrue);
  });

  test('captured library writes and notifications stay with their profile',
      () async {
    final originalId = database.profileId;
    final next = await database.createProfile('Another listener');
    final other = MusicLibraryService.forProfile(database, next.id);
    final same = MusicLibraryService.forProfile(database, originalId);
    var originalChanges = 0, sameChanges = 0, otherChanges = 0;
    library.changes.addListener(() => originalChanges++);
    same.changes.addListener(() => sameChanges++);
    other.changes.addListener(() => otherChanges++);

    final pending = library.save(song);
    await database.useProfile(next.id);
    await pending;
    await library.markLocalPlaylist('local:old-person-music');
    expect(library.profileId, originalId);
    expect(library.entries.single.id, song.id);
    expect(other.entries, isEmpty);
    expect(originalChanges, 2);
    expect(sameChanges, 2);
    expect(otherChanges, 0);

    await other.save(song);
    await library.remove(song.kind, song.id);
    expect(other.entries.single.id, song.id);
    expect(library.entries, isEmpty);
    expect(otherChanges, 1);
    expect(originalChanges, 3);
  });

  test('bookmark count limit rejects writes without losing saved music',
      () async {
    final stored = jsonEncode({
      'version': 1,
      'entries': [
        for (var index = 0; index < musicLibraryMaximumEntries; index++)
          MusicLibraryEntry(
                  kind: MusicLibraryKind.song,
                  id: 'song${index.toString().padLeft(7, '0')}',
                  title: 'Song $index')
              .toJson(),
      ],
      'playlists': [],
    });
    await database.saveSetting(SettingsValue(musicLibrarySettingName, stored));
    var changes = 0;
    library.changes.addListener(() => changes++);
    await expectLater(library.save(song), throwsStateError);
    expect(database.getSettings(musicLibrarySettingName)?.value, stored);
    expect(changes, 0);
    await library.remove(MusicLibraryKind.song, 'song0000000');
    await library.save(song);
    expect(library.entries, hasLength(musicLibraryMaximumEntries));
    expect(library.contains(song.kind, song.id), isTrue);
    expect(changes, 2);
  });

  test('library byte bound measures UTF-8 and preserves a rejected write',
      () async {
    MusicLibraryEntry largeEntry(int index) => MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'song${index.toString().padLeft(7, '0')}',
        title: 'é' * 1024,
        subtitle: 'é' * 1024,
        album: 'é' * 1024);
    final emptySize = utf8
        .encode(jsonEncode({
          'version': 1,
          'entries': [],
          'playlists': [],
        }))
        .length;
    final entrySize = utf8.encode(jsonEncode(largeEntry(0).toJson())).length;
    final count = (musicLibraryMaximumBytes - emptySize + 1) ~/ (entrySize + 1);
    final stored = jsonEncode({
      'version': 1,
      'entries': [
        for (var index = 0; index < count; index++) largeEntry(index).toJson()
      ],
      'playlists': [],
    });
    expect(utf8.encode(stored).length,
        lessThanOrEqualTo(musicLibraryMaximumBytes));
    expect(stored.length + entrySize, lessThan(musicLibraryMaximumBytes));
    await database.saveSetting(SettingsValue(musicLibrarySettingName, stored));
    var changes = 0;
    library.changes.addListener(() => changes++);
    await expectLater(library.save(largeEntry(count)), throwsStateError);
    expect(database.getSettings(musicLibrarySettingName)?.value, stored);
    expect(changes, 0);
  });

  test('music playlists exclude unrelated videos and unmarked empty lists',
      () async {
    const ordinary = Video(videoId: 'abcdefghijk', title: 'Ordinary video');
    const music = Video(
        videoId: '12345678901',
        title: 'Music',
        musicMetadata: MusicMetadata(title: 'Music', artist: 'Artist'));
    const empty = Playlist(
        title: 'Empty', playlistId: 'local:empty', author: '', videoCount: 0);
    expect(library.isMusicPlaylist(empty), isFalse);
    expect(
        library
            .isMusicPlaylist(empty.copyWith(videos: [ordinary], videoCount: 1)),
        isFalse);
    expect(
        library.isMusicPlaylist(
            empty.copyWith(videos: [ordinary, music], videoCount: 2)),
        isTrue);
    expect(
        library.isMusicPlaylist(empty.copyWith(
            playlistId: 'PLpublic', videos: [music], videoCount: 1)),
        isFalse);
    await library.markLocalPlaylist(empty.playlistId);
    expect(library.isMusicPlaylist(empty), isTrue);
    expect(
        library
            .isMusicPlaylist(empty.copyWith(videos: [ordinary], videoCount: 1)),
        isFalse);
  });

  test('damaged storage and malformed rows do not hide valid saved music',
      () async {
    for (final damaged in ['{', '[]', '{"version":2,"entries":[]}']) {
      await database
          .saveSetting(SettingsValue(musicLibrarySettingName, damaged));
      expect(library.entries, isEmpty);
    }
    await database.saveSetting(SettingsValue(
        musicLibrarySettingName,
        jsonEncode({
          'version': 1,
          'entries': [
            null,
            12,
            {...song.toJson(), 'id': '../private'},
            {...song.toJson(), 'id': 'abcdefghijk\n'},
            {...song.toJson(), 'kind': 'stream'},
            {...song.toJson(), 'title': []},
            song.toJson(),
          ],
          'playlists': [null, 'remote', 'local:music'],
        })));
    expect(library.entries.single.toJson(), song.toJson());
    await library.save(song);
    final repaired =
        jsonDecode(database.getSettings(musicLibrarySettingName)!.value) as Map;
    expect(repaired['entries'], hasLength(1));
    expect(repaired['playlists'], ['local:music']);
  });

  test('saving a song retains display metadata but drops playback secrets',
      () async {
    final video = Video(
        videoId: song.id,
        title: 'Upload title',
        dashUrl: 'https://stream.example/private-stream',
        musicMetadata: MusicMetadata(
            title: ' Catalog\nSong ',
            artist: 'Artist',
            album: 'Album',
            thumbnails: [
              ImageObject(
                  null,
                  'https://images.example/cover?token=secret-query#private',
                  512,
                  512),
              ImageObject(null, 'https://user:secret@example.com/cover', 1, 1),
              ImageObject(null, 'file:///private/cover.jpg', 1, 1),
            ]));
    await library.save(MusicLibraryEntry.song(video));
    final value = database.getSettings(musicLibrarySettingName)!.value;
    final entry = library.entries.single;
    expect(entry.title, 'Catalog Song');
    expect(entry.thumbnails.single.url, 'https://images.example/cover');
    expect(entry.toVideo().dashUrl, isNull);
    for (final secret in ['secret', 'private', 'file:', 'dashUrl']) {
      expect(value, isNot(contains(secret)));
    }
    expect(() => MusicLibraryEntry.song(const Video(videoId: 'abcdefghijk')),
        throwsArgumentError);
  });

  for (final url in [
    'https://private.example/vi/abcdefghijk/default.jpg',
    'https://private.example/invidious/vi/abcdefghijk/default.jpg',
    'http://private.example/vi/abcdefghijk/default.jpg',
    '/vi/abcdefghijk/default.jpg',
    'https://i.ytimg.com/vi/abcdefghijk/default.jpg',
  ]) {
    test('saving fallback artwork keeps video routing for $url', () async {
      final video = Video(
          videoId: song.id,
          videoThumbnails: [ImageObject(null, url, 320, 180)],
          musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'));
      await library.save(MusicLibraryEntry.song(video));
      final restored = library.entries.single.toVideo();
      expect(library.entries.single.usesVideoThumbnails, isTrue);
      expect(restored.videoThumbnails.single.url, url);
      expect(restored.musicMetadata!.thumbnails, isEmpty);
    });
  }

  test('saving playback from a nested instance keeps a portable song thumbnail',
      () async {
    const server = Server(url: 'https://private.example/invidious');
    final path = '/vi/${song.id}/hqdefault.jpg';
    final video = Video(
        videoId: song.id,
        playbackConnection: BackendPlayback(server),
        videoThumbnails: [
          ImageObject(null, '${server.url}$path?token=discard', 480, 360),
          ImageObject(null, 'https://other.example/invidious$path', 480, 360),
        ],
        musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'));
    await library.save(MusicLibraryEntry.song(video));
    final saved = library.entries.single;
    expect(saved.thumbnails.single.url, path);
    expect(saved.displayThumbnails.single.url, path);
    expect(saved.coverThumbnails, isEmpty);
  });

  test('saving a verified cover retains the separate same-song fallback',
      () async {
    const cover = 'https://lh3.googleusercontent.com/album-cover';
    const frame = '/vi/abcdefghijk/hqdefault.jpg';
    final video = Video(
      videoId: song.id,
      musicMetadata: MusicMetadata(
          title: song.title,
          artist: 'Artist',
          thumbnails: [ImageObject(null, cover, 256, 256)]),
      videoThumbnails: [
        ImageObject(null, '/vi/zzzzzzzzzzz/hqdefault.jpg', 1920, 1080),
        ImageObject(null, 'https://i.ytimg.com$frame?token=discard', 640, 480),
      ],
    );
    await library.save(MusicLibraryEntry.song(video));
    final stored = database.getSettings(musicLibrarySettingName)!.value;
    final row = MusicLibraryEntry.tryParse(
        (jsonDecode(stored)['entries'] as List).single)!;

    expect(row.displayThumbnails.map((image) => image.url), [cover, frame]);
    expect(row.coverThumbnails.single.url, cover);
    expect(library.coversBySongId[song.id]!.single.url, cover);
    expect(row.toVideo().musicMetadata!.thumbnails.single.url, cover);
    expect(stored, isNot(contains('zzzzzzzzzzz')));
    expect(stored, isNot(contains('discard')));
  });

  test('catalog bookmarks still reject unrecognized relative artwork',
      () async {
    await library.save(MusicLibraryEntry.artist(MusicArtist(
        id: 'UC0123456789012345678901',
        name: 'Artist',
        thumbnails: [
          ImageObject(null, '/account/private-cover', 320, 180),
          ImageObject(
              null, 'http://private.example/account/private-cover', 320, 180),
          ImageObject(
              null, '//user:secret@private.example/ggpht/cover', 320, 180),
        ])));
    expect(library.entries.single.thumbnails, isEmpty);
  });

  test('legacy protected covers retain video routing without losing labels',
      () async {
    const url = 'https://private.example/vi/abcdefghijk/default.jpg';
    final legacy = {
      ...song.toJson(),
      'thumbnails': [ImageObject(null, url, 320, 180).toJson()],
    }..remove('usesVideoThumbnails');
    await database.saveSetting(SettingsValue(
        musicLibrarySettingName,
        jsonEncode({
          'version': 1,
          'entries': [legacy],
          'playlists': []
        })));
    final restored = library.entries.single.toVideo();
    expect(restored.videoThumbnails.single.url, url);
    expect(restored.musicMetadata!.thumbnails, isEmpty);
    expect(restored.musicMetadata!.title, song.title);
    expect(restored.musicMetadata!.album, song.album);
  });

  test('mixed legacy song art survives saving and respects explicit fallback',
      () async {
    const frame = '/vi/abcdefghijk/default.jpg';
    const cover = 'https://lh3.googleusercontent.com/album-cover';
    final legacy = {
      ...song.toJson(),
      'thumbnails': [
        ImageObject(null, frame, 320, 180).toJson(),
        ImageObject(null, cover, 512, 512).toJson(),
      ],
    };
    await library.save(MusicLibraryEntry.tryParse(legacy)!);
    final restored =
        MusicLibraryService.forProfile(database, database.profileId);
    final entry = restored.entries.single;
    expect(entry.thumbnails.map((image) => image.url), [frame, cover]);
    expect(entry.usesVideoThumbnails, isFalse);
    expect(entry.coverThumbnails.single.url, cover);
    expect(entry.displayThumbnails.map((image) => image.url), [cover, frame]);
    expect(restored.coversBySongId[song.id]!.single.url, cover);

    await library.save(MusicLibraryEntry.tryParse({
      ...legacy,
      'usesVideoThumbnails': true,
    })!);
    expect(restored.entries.single.thumbnails, hasLength(2));
    expect(restored.entries.single.displayThumbnails.single.url, frame);
    expect(restored.entries.single.coverThumbnails, isEmpty);
    expect(restored.coversBySongId, isEmpty);
  });

  for (final isArtTrack in [false, true]) {
    test('saved stock artwork preserves Art Track provenance $isArtTrack',
        () async {
      const still = '/vi/abcdefghijk/hqdefault.jpg';
      const frame = '/vi/abcdefghijk/1.jpg';
      final track = MusicTrack(
          videoId: song.id,
          title: song.title,
          isArtTrack: isArtTrack,
          videoThumbnails: [
            ImageObject(null, '/vi/zzzzzzzzzzz/mqdefault.jpg', 640, 480),
            ImageObject(null, frame, 320, 180),
            ImageObject(null, still, 480, 360),
          ]);
      final expected = isArtTrack ? [still, frame] : [frame, still];
      expect(track.displayThumbnails.map((image) => image.url), expected);
      final video = track.toVideo();
      expect(video.musicMetadata!.isArtTrack, isArtTrack);
      await library.save(MusicLibraryEntry.song(video));

      final stored = database.getSettings(musicLibrarySettingName)!.value;
      final row = (jsonDecode(stored)['entries'] as List).single as Map;
      expect(row.containsKey('isArtTrack'), isArtTrack);
      final entry = MusicLibraryEntry.tryParse(row)!;
      expect(entry.isArtTrack, isArtTrack);
      expect(entry.displayThumbnails.map((image) => image.url), expected);
      expect(entry.coverThumbnails, isEmpty);
      expect(library.coversBySongId, isEmpty);
      final restored = Video.fromJson(jsonDecode(jsonEncode(entry.toVideo())));
      expect(restored.musicMetadata!.isArtTrack, isArtTrack);
      expect(restored.musicMetadata!.thumbnails, isEmpty);
    });
  }

  for (final url in [
    '/vi/abcdefghijk/default.jpg',
    '/ggpht/artist-portrait',
    'http://private.example/ggpht/artist-portrait',
  ]) {
    test('Invidious artist and playlist bookmarks retain artwork for $url',
        () async {
      final thumbnails = [
        ImageObject(null, '$url?token=secret#private', 320, 180)
      ];
      await library.save(MusicLibraryEntry.artist(MusicArtist(
          id: 'UC0123456789012345678901',
          name: 'Artist',
          thumbnails: thumbnails)));
      await library.save(MusicLibraryEntry.collection(
          MusicCollection(
              id: 'PLtest_music',
              title: 'Playlist',
              thumbnails: thumbnails,
              tracks: const []),
          album: false));

      expect(library.entries, hasLength(2));
      for (final entry in library.entries) {
        expect(entry.thumbnails.single.url, url);
        expect(entry.usesVideoThumbnails, isFalse);
      }
      expect(database.getSettings(musicLibrarySettingName)!.value,
          isNot(contains('secret')));
    });
  }

  for (final url in [
    'https://lh3.googleusercontent.com/cover',
    'https://yt3.googleusercontent.com/cover',
    'https://yt3.ggpht.com/cover',
    'https://i.ytimg.com/vi/abcdefghijk/default.jpg',
  ]) {
    test('legacy catalog artwork keeps its original source for $url', () {
      final legacy = {
        ...song.toJson(),
        'thumbnails': [ImageObject(null, url, 320, 180).toJson()],
      }..remove('usesVideoThumbnails');
      final saved = MusicLibraryEntry.tryParse(legacy)!;
      final restored = Video.fromJson(jsonDecode(jsonEncode(saved.toVideo())));
      expect(saved.thumbnails.single.url, url);
      if (url.contains('/vi/')) {
        expect(restored.musicMetadata!.thumbnails, isEmpty);
        expect(saved.coverThumbnails, isEmpty);
        expect(
            saved.displayThumbnails.single.url, '/vi/abcdefghijk/default.jpg');
      } else {
        expect(saved.usesVideoThumbnails, isFalse);
        expect(restored.musicMetadata!.thumbnails.single.url, url);
        expect(saved.coverThumbnails.single.url, url);
        expect(saved.displayThumbnails.single.url, url);
      }
    });
  }

  test('song art excludes unclassified proxy paths and external images', () {
    final row = MusicLibraryEntry(
        id: song.id,
        title: song.title,
        kind: MusicLibraryKind.song,
        thumbnails: [
          for (final url in [
            '/ggpht/unknown',
            'https://dearrow-thumb.ajay.app/api/v1/getThumbnail',
            'https://lh3.googleusercontent.com/vi/song/square.jpg',
            'https://yt3.ggpht.com/%ff',
            'https://private@lh3.googleusercontent.com/cover',
            'https://lh3.googleusercontent.com/cover=w512-h512',
          ])
            ImageObject(null, url, 512, 512),
        ]);
    expect(row.displayThumbnails.single.url,
        'https://lh3.googleusercontent.com/cover=w512-h512');
    expect(row.toJson()['thumbnails'], hasLength(6));
  });
}
