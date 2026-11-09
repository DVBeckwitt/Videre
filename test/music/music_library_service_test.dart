import 'dart:convert';

import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/playlists/models/playlist.dart';
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
      durationSeconds: 185);

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    library = MusicLibraryService.forProfile(database, database.profileId);
  });

  tearDown(() async => database.close());

  test('bookmarks and explicit empty playlists persist after database reopen',
      () async {
    final factory = newDatabaseFactoryMemory();
    var connection = await factory.openDatabase('music-library');
    var store = SembastSqfDb(connection);
    var saved = MusicLibraryService.forProfile(store, store.profileId);
    await saved.save(song);
    await saved.markLocalPlaylist('local:music');
    await store.close();

    connection = await factory.openDatabase('music-library');
    store = SembastSqfDb(connection);
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
    await store.close();
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
      expect(saved.usesVideoThumbnails, isFalse);
      expect(restored.musicMetadata!.thumbnails.single.url, url);
    });
  }
}
