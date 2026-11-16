import 'dart:io';

import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/takeout_import.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('Import must never create a network client');
}

void main() {
  TakeoutCollection parse(String text,
          {String name = 'music-library-songs.csv'}) =>
      TakeoutImport.parse([TakeoutFile(name: name, text: text)]).single;

  test('imports music library metadata, preserving order without artwork', () {
    final result = parse('Video ID,Song Title,Album Title,Artist Name\n'
        'abcdefghijk,First,Album,Artist\n'
        'zyxwvutsrqp,Second,Another,Other artist\n');
    expect(result.kind, TakeoutCollectionKind.musicLibrary);
    expect(result.songs.map((song) => song.id), ['abcdefghijk', 'zyxwvutsrqp']);
    expect(result.songs.first.kind, MusicLibraryKind.song);
    expect(result.songs.first.title, 'First');
    expect(result.songs.first.subtitle, 'Artist');
    expect(result.songs.first.album, 'Album');
    expect(result.songs.every((song) => song.thumbnails.isEmpty), isTrue);
    expect(result.metadataMissing, isFalse);
    expect(result.skippedRows, 0);
    expect(result.duplicateRows, 0);
  });

  test('reads BOM, CRLF, quoted commas, escaped quotes and multiline titles',
      () {
    final result = parse(
        '\ufeffVideo ID,Song Title,Artist Names,Album Title\r\n'
        'abcdefghijk,"A, ""quoted""\r\nname","Artist one, Artist two",Album\r\n');
    expect(result.songs.single.title, 'A, "quoted"  name');
    expect(result.songs.single.subtitle, 'Artist one, Artist two');
  });

  test('reads older playlist metadata before the video table', () {
    final result = parse(
        'Playlist ID,Channel ID,Title,Description\n'
        'PLexample,UCexample,My favorites,Description\n\n'
        'Video ID,Time Added\nabcdefghijk,2026-01-02T00:00:00Z\n',
        name: 'Takeout/YouTube and YouTube Music/playlists/My favorites.csv');
    expect(result.name, 'My favorites');
    expect(result.kind, TakeoutCollectionKind.playlist);
    expect(result.songs.single.id, 'abcdefghijk');
    expect(result.songs.single.title, 'abcdefghijk');
    expect(result.metadataMissing, isTrue);
  });

  test('distinguishes liked music, liked videos and the whole music library',
      () {
    const csv = 'Video ID,Time Added\nabcdefghijk,2026-01-01\n';
    final result = TakeoutImport.parse([
      const TakeoutFile(name: 'Liked Music.csv', text: csv),
      const TakeoutFile(name: 'Liked videos-videos.csv', text: csv),
      const TakeoutFile(name: 'music-library-songs.csv', text: csv),
    ]);
    expect(result.map((collection) => collection.kind), [
      TakeoutCollectionKind.likedMusic,
      TakeoutCollectionKind.likedVideos,
      TakeoutCollectionKind.musicLibrary,
    ]);
    expect(result[1].name, 'Liked videos');
  });

  test('counts invalid IDs and duplicates without changing valid song order',
      () {
    final result = parse('Video ID,Song Title,Artist Name\n'
        'abcdefghijk,First,Artist\n'
        'invalid,Invalid,Artist\n'
        ',Missing,Artist\n'
        'abcdefghijk,Duplicate,Another\n'
        'zyxwvutsrqp,Last,Artist\n\n');
    expect(result.songs.map((song) => song.title), ['First', 'Last']);
    expect(result.skippedRows, 2);
    expect(result.duplicateRows, 1);
  });

  test('does not mistake disliked or user-named playlists for built-in likes',
      () {
    const csv = 'Video ID,Time Added\nabcdefghijk,2026-01-01\n';
    final result = TakeoutImport.parse([
      const TakeoutFile(name: 'Disliked Music.csv', text: csv),
      const TakeoutFile(name: 'Disliked videos.csv', text: csv),
      const TakeoutFile(name: 'My liked songs.csv', text: csv),
    ]);
    expect(result.map((collection) => collection.kind),
        everyElement(TakeoutCollectionKind.playlist));
  });

  test('fills only missing playlist labels from matching local library IDs',
      () {
    final result = TakeoutImport.parse([
      const TakeoutFile(
          name: 'Liked Music.csv',
          text: 'Video ID,Song Title,Artist Name\n'
              'zyxwvutsrqp,Kept title,\n'
              'abcdefghijk,,Kept artist\n'
              '0123456789_,,\n'),
      const TakeoutFile(
          name: 'music-library-songs.csv',
          text: 'Video ID,Song Title,Artist Name,Album Title\n'
              'abcdefghijk,Library first,Library artist,Album first\n'
              'zyxwvutsrqp,Library last,Other artist,Album last\n'
              'qwertyuiopa,Not liked,Extra,Other album\n'),
    ]);
    final liked = result.first;
    expect(liked.songs.map((song) => song.id),
        ['zyxwvutsrqp', 'abcdefghijk', '0123456789_']);
    expect(liked.songs.map((song) => song.title),
        ['Kept title', 'Library first', '0123456789_']);
    expect(liked.songs.map((song) => song.subtitle),
        ['Other artist', 'Kept artist', '']);
    expect(liked.songs.map((song) => song.album),
        ['Album last', 'Album first', null]);
    expect(liked.metadataMissing, isTrue);
    expect(liked.songs.every((song) => song.thumbnails.isEmpty), isTrue);
  });

  test('fully matched local labels clear the missing-metadata notice', () {
    final result = TakeoutImport.parse([
      const TakeoutFile(
          name: 'Liked Music.csv', text: 'Video ID\nabcdefghijk\n'),
      const TakeoutFile(
          name: 'music-library-songs.csv',
          text: 'Video ID,Song Title,Artist Name\nabcdefghijk,Song,Artist\n'),
    ]);
    expect(result.first.metadataMissing, isFalse);
    expect(result.first.songs.single.title, 'Song');
  });

  test('disambiguates equally named collections without merging their songs',
      () {
    final result = TakeoutImport.parse([
      const TakeoutFile(
          name: 'one/playlists/Favorites.csv', text: 'Video ID\nabcdefghijk\n'),
      const TakeoutFile(
          name: 'two/playlists/Favorites.csv', text: 'Video ID\nzyxwvutsrqp\n'),
    ]);
    expect(result.map((collection) => collection.name),
        ['Favorites (1)', 'Favorites (2)']);
    expect(result.map((collection) => collection.songs.single.id),
        ['abcdefghijk', 'zyxwvutsrqp']);
  });

  test('parses supported watch URLs locally and never creates a network client',
      () {
    HttpOverrides.runZoned(() {
      final result = parse('Song URL,Song Title,Artist Names\n'
          'https://music.youtube.com/watch?v=abcdefghijk,Song,Artist\n'
          'https://www.youtube.com/watch?v=zyxwvutsrqp&list=LM,Other,Artist\n');
      expect(
          result.songs.map((song) => song.id), ['abcdefghijk', 'zyxwvutsrqp']);
      expect(result.songs.every((song) => song.thumbnails.isEmpty), isTrue);
    }, createHttpClient: _NoNetwork().createHttpClient);
  });

  for (final url in [
    'https://youtube.com.evil.test/watch?v=abcdefghijk',
    'https://youtube.com@evil.test/watch?v=abcdefghijk',
    'https://attacker@youtube.com/watch?v=abcdefghijk',
    'http://youtube.com/watch?v=abcdefghijk',
    'https://youtube.com:444/watch?v=abcdefghijk',
    'https://youtube.com/watch?v=abcdefghijk&v=zyxwvutsrqp',
    'https://youtube.com/watch?v=%FF',
    'https://youtube.com/watch?v=abcdefghijk#fragment',
    'https://youtube.com/watch/../watch?v=abcdefghijk',
    'https://youtube.com/embed/abcdefghijk',
    'https://example.test/abcdefghijk',
    'file:///abcdefghijk',
  ]) {
    test('does not import an ambiguous or unsupported URL: $url', () {
      final result = parse('Song URL,Song Title\n'
          'https://music.youtube.com/watch?v=zyxwvutsrqp,Valid\n'
          '$url,Rejected\n');
      expect(result.songs.single.id, 'zyxwvutsrqp');
      expect(result.skippedRows, 1);
    });
  }

  test('ignores unrelated CSVs instead of importing uploaded video metadata',
      () {
    final result = TakeoutImport.parse([
      const TakeoutFile(
          name: 'videos.csv', text: 'Video ID,Title\nabcdefghijk,Upload\n'),
      const TakeoutFile(
          name: 'subscriptions.csv',
          text: 'Channel ID,Channel Title\nUCexample,Channel\n'),
      const TakeoutFile(
          name: 'Liked Music.csv', text: 'Video ID\nzyxwvutsrqp\n'),
    ]);
    expect(result.single.songs.single.id, 'zyxwvutsrqp');
  });

  test('throws when no recognized song collection exists', () {
    expect(() => parse('Channel ID,Channel Title\nUCexample,Channel\n'),
        throwsFormatException);
  });

  for (final csv in [
    'Video ID,Song Title\nabcdefghijk,"Unclosed\n',
    'Video ID,Song Title\nabcdefghijk,Un"quoted\n',
    'Video ID,Song Title\nabcdefghijk,"Closed"suffix\n',
  ]) {
    test('rejects malformed quoting without silently dropping songs: $csv', () {
      expect(() => parse(csv), throwsFormatException);
    });
  }

  test('rejects duplicate recognized columns', () {
    expect(
        () => parse('Video ID,Video ID,Song Title\n'
            'abcdefghijk,zyxwvutsrqp,Ambiguous\n'),
        throwsFormatException);
  });

  test('rejects conflicting ID and URL columns', () {
    final result = parse('Video ID,Song URL,Song Title\n'
        'abcdefghijk,https://music.youtube.com/watch?v=abcdefghijk,Valid\n'
        'zyxwvutsrqp,https://music.youtube.com/watch?v=abcdefghijk,Conflict\n');
    expect(result.songs.single.title, 'Valid');
    expect(result.skippedRows, 1);
  });

  test('limits retained metadata to the existing music-library representation',
      () {
    final result = parse('Video ID,Song Title,Artist Name,Thumbnail URL\n'
        'abcdefghijk,${'🎵' * 1100},Artist\u0000Name,https://youtube.com/art\n');
    expect(result.songs.single.title.runes.length, 1024);
    expect(result.songs.single.subtitle, 'Artist Name');
    expect(result.songs.single.thumbnails, isEmpty);
    expect(MusicLibraryEntry.tryParse(result.songs.single.toJson()), isNotNull);
  });

  test('rejects more than the supported number of unique songs', () {
    final csv = StringBuffer('Video ID,Song Title\n');
    for (var i = 0; i <= musicLibraryMaximumEntries; i++) {
      csv.writeln('song${i.toString().padLeft(7, '0')},Song $i');
    }
    expect(() => parse(csv.toString()), throwsFormatException);
  });

  test('rejects an excessive number of input files', () {
    expect(
        () => TakeoutImport.parse(List.generate(
            257,
            (index) => TakeoutFile(
                name: '$index.csv', text: 'Video ID,Time Added\n'))),
        throwsFormatException);
  });

  test('rejects CSV input over its byte limit before parsing', () {
    expect(() => parse('x' * (16 * 1024 * 1024 + 1)), throwsFormatException);
  });

  test('rejects oversized fields and excessive columns', () {
    expect(() => parse('Video ID,Song Title\nabcdefghijk,${'x' * 65537}\n'),
        throwsFormatException);
    expect(
        () => parse('Video ID,Song Title\n'
            'abcdefghijk,${List.filled(128, 'field').join(',')}\n'),
        throwsFormatException);
  });

  test('rejects metadata that cannot fit in the saved Music library', () {
    final csv = StringBuffer('Video ID,Song Title,Artist Name,Album Title\n');
    final label = 'a' * 1000;
    for (var i = 0; i < 1800; i++) {
      csv.writeln('song${i.toString().padLeft(7, '0')},$label,$label,$label');
    }
    expect(() => parse(csv.toString()), throwsFormatException);
  });
}
