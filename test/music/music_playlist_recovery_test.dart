import 'dart:convert';

import 'package:clipious/globals.dart';
import 'package:clipious/music/models/deleted_music_playlist.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_playlist_covers.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_progress.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

void main() {
  late DateTime now;
  late Service playlists;
  late MockClient client;
  final requests = <Uri>[];

  Service newService() => Service(httpClient: client, now: () => now);

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    now = DateTime.utc(2026, 1, 1);
    requests.clear();
    client = MockClient((request) async {
      requests.add(request.url);
      throw StateError('Unexpected playlist recovery request');
    });
    playlists = newService();
  });

  tearDown(() async {
    expect(requests, isEmpty);
    client.close();
    await db.close();
  });

  Future<String> create(String title, {bool music = true}) async {
    final id = (await playlists.createPlayList(title, 'local'))!;
    if (music) {
      await MusicLibraryService.forProfile(db, db.profileId)
          .markLocalPlaylist(id);
    }
    return id;
  }

  Iterable<String> activeIds() =>
      playlists.getLocalPlaylists().map((playlist) => playlist.playlistId);

  Iterable<String> deletedIds() => playlists
      .getRecentlyDeletedMusicPlaylists()
      .map((entry) => entry.playlist.playlistId);

  DeletedMusicPlaylist deleted(String id) => playlists
      .getRecentlyDeletedMusicPlaylists()
      .singleWhere((entry) => entry.playlist.playlistId == id);

  bool current() => true;

  String? cover(String id) =>
      MusicPlaylistCovers.forProfile(db, db.profileId).encodedCover(id);

  Future<void> seedCover(String id) async => db
      .saveSetting(SettingsValue(MusicPlaylistCovers.settingName(id), 'AQ=='));

  test('recovers adjacent playlists in saved order with exact stored entries',
      () async {
    final first = await create('First');
    const recording = Video(
        videoId: 'abcdefghijk',
        indexId: 'first-copy',
        title: 'Recording',
        musicMetadata: MusicMetadata(title: 'Recording', artist: 'Artist'));
    const clip = Video(videoId: 'lmnopqrstuv', indexId: 'clip', title: 'Clip');
    final repeated = Playlist(
        title: 'Repeated recordings',
        playlistId: 'local:repeated',
        author: '',
        description: 'Metadata and mixed entries',
        updated: 123,
        videoCount: 3,
        videos: [recording, clip, recording.copyWith(indexId: 'second-copy')]);
    await db.saveSetting(SettingsValue(
        localPlaylistsSetting,
        jsonEncode([
          ...playlists.getLocalPlaylists().map((playlist) => playlist.toJson()),
          repeated.toJson(),
        ])));
    final empty = await create('Empty Music playlist');
    final last = await create('Last');
    final original = playlists.getLocalPlaylists()[2];
    final reference = PlaylistReference.forPlaylist(repeated, db);
    final progress = PlaylistProgressService.forProfile(db, db.profileId);
    final entries = assignPlaylistEntryIds(repeated.videos);
    await progress.save(reference, entries.last, entries: entries, audio: true);
    await seedCover(repeated.playlistId);

    await playlists.deleteUserPlaylist(repeated.playlistId);
    expect(
        await playlists.deleteMusicPlaylist(empty, isCurrent: current), isTrue);
    expect(activeIds(), [localWatchLaterId, first, last]);
    expect(cover(repeated.playlistId), 'AQ==');
    final added = await create('Added after deletion');
    playlists = newService();

    expect(deletedIds(), unorderedEquals([repeated.playlistId, empty]));
    final selected = deleted(repeated.playlistId);
    expect(await playlists.restoreMusicPlaylist(selected, isCurrent: current),
        isTrue);
    expect(deletedIds(), [empty]);
    expect(activeIds(),
        [localWatchLaterId, first, repeated.playlistId, last, added]);
    expect(
        await playlists.restoreMusicPlaylist(deleted(empty),
            isCurrent: current),
        isTrue);
    expect(activeIds(),
        [localWatchLaterId, first, repeated.playlistId, empty, last, added]);
    final restored = playlists.getLocalPlaylists()[2];
    expect(jsonEncode(restored), jsonEncode(original));
    expect(restored.videos.map((video) => video.queueEntryId),
        original.videos.map((video) => video.queueEntryId));
    final checkpoint = progress.get(reference)!;
    final resumed = checkpoint.resolve(restored.videos)!;
    expect(resumed.video.indexId, 'second-copy');
    expect(resumed.missing, isFalse);
    expect(checkpoint.audio, isTrue);
    expect(cover(repeated.playlistId), 'AQ==');
    final library = MusicLibraryService.forProfile(db, db.profileId);
    expect(library.isMusicPlaylist(playlists.getLocalPlaylists()[3]), isTrue);
    expect(deletedIds(), isEmpty);
  });

  test('expires at 30 days and closes expired and permanent deletion slots',
      () async {
    final expired = await create('Old deletion');
    final videoOnly = await create('Video playlist', music: false);
    final first = await create('Remaining first');
    final retained = await create('Recent deletion');
    final last = await create('Remaining last');
    await seedCover(expired);
    await seedCover(retained);
    await playlists.deleteUserPlaylist(expired);
    final oldSelection = deleted(expired);
    now = now.add(const Duration(days: 1));
    await playlists.deleteUserPlaylist(retained);
    await playlists.deleteUserPlaylist(videoOnly);
    await playlists.deleteUserPlaylist(localWatchLaterId);
    expect(deletedIds(), [retained, expired]);

    now = oldSelection.expiresAt.subtract(const Duration(seconds: 1));
    expect(deletedIds(), [retained, expired]);
    now = oldSelection.expiresAt;
    expect(deletedIds(), [retained]);
    expect(
        await playlists.restoreMusicPlaylist(oldSelection, isCurrent: current),
        isFalse);
    expect(db.getSettings(deletedMusicPlaylistsSetting)!.value,
        isNot(contains(expired)));
    expect(cover(expired), isNull);
    expect(cover(retained), 'AQ==');
    expect(
        await playlists.restoreMusicPlaylist(deleted(retained),
            isCurrent: current),
        isTrue);
    expect(activeIds(), [localWatchLaterId, first, retained, last]);
  });

  test('recovery is profile local and omitted from portable backups', () async {
    final owner = db.profileId;
    final hidden = await create('Recently deleted');
    final active = await create('Active in backup');
    await seedCover(hidden);
    await playlists.deleteUserPlaylist(hidden);
    final selection = deleted(hidden);
    final backup = await db.exportBackup();
    expect(backup.sections['playlists']!.map((row) => row['playlistId']),
        [localWatchLaterId, active]);
    expect(backup.sections['settings']!.map((row) => row['name']),
        isNot(contains(deletedMusicPlaylistsSetting)));

    final other = await db.createProfile('Other person');
    await db.useProfile(other.id);
    expect(deletedIds(), isEmpty);
    expect(await playlists.restoreMusicPlaylist(selection, isCurrent: current),
        isFalse);
    await db.useProfile(owner);
    expect(deletedIds(), [hidden]);
    await db.restoreBackup(backup);
    expect(deletedIds(), [hidden]);
    await db.restoreBackup(backup, replace: true);
    expect(deletedIds(), isEmpty);
    expect(activeIds(), [localWatchLaterId, active]);
    expect(cover(hidden), isNull);
  });

  test('concurrent restores and old deletion selections cannot duplicate rows',
      () async {
    final id = await create('Recycled playlist');
    await playlists.deleteUserPlaylist(id);
    final selection = deleted(id);
    expect(
        await Future.wait([
          playlists.restoreMusicPlaylist(selection, isCurrent: current),
          newService().restoreMusicPlaylist(selection, isCurrent: current),
        ]),
        [true, false]);
    await playlists.deleteUserPlaylist(id);
    expect(await playlists.restoreMusicPlaylist(selection, isCurrent: current),
        isFalse);
    expect(
        await playlists.restoreMusicPlaylist(deleted(id),
            isCurrent: () => false),
        isFalse);
    expect(deletedIds(), [id]);
    expect(activeIds(), [localWatchLaterId]);
  });
}
