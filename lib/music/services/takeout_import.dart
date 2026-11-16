import 'dart:convert';

import 'package:clipious/music/models/music_library_entry.dart';

class TakeoutFile {
  final String name;
  final String text;

  const TakeoutFile({required this.name, required this.text});
}

enum TakeoutCollectionKind { likedMusic, likedVideos, musicLibrary, playlist }

class TakeoutCollection {
  final String name;
  final List<MusicLibraryEntry> songs;
  final int skippedRows;
  final int duplicateRows;
  final bool metadataMissing;
  final TakeoutCollectionKind kind;

  const TakeoutCollection({
    required this.name,
    required this.songs,
    required this.skippedRows,
    required this.duplicateRows,
    required this.metadataMissing,
    required this.kind,
  });
}

class TakeoutImport {
  static const maxFiles = 256;
  static const maxBytes = 16 * 1024 * 1024;
  static const _maxRows = 100000;
  static final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');
  static final _watchUrl = RegExp(
      r'^https://(?:(?:www|music|m)\.)?youtube\.com/watch\?',
      caseSensitive: false);

  /// Reads exported identifiers and labels only. URLs are never opened, and
  /// exported artwork, account data and playback URLs are never retained.
  static List<TakeoutCollection> parse(List<TakeoutFile> files) {
    if (files.length > maxFiles) {
      throw const FormatException('The export contains too many CSV files.');
    }
    var bytes = 0;
    for (final file in files) {
      if (file.text.length > maxBytes) {
        throw const FormatException('The CSV data exceeds 16 MiB.');
      }
      bytes += utf8.encode(file.text).length;
      if (bytes > maxBytes) {
        throw const FormatException('The CSV data exceeds 16 MiB.');
      }
    }
    var rows = 0;
    final collections = <TakeoutCollection>[];
    for (final file in files) {
      final collection = _parseFile(file, () {
        if (++rows > _maxRows) {
          throw const FormatException('The export contains too many CSV rows.');
        }
      });
      if (collection != null) collections.add(collection);
    }
    if (collections.isEmpty) {
      throw const FormatException(
          'No supported Music library or playlist CSV was found.');
    }
    // An exported liked playlist often contains IDs only. Join labels from the
    // same archive's Music library, never from a remote metadata service.
    final metadata = <String, MusicLibraryEntry>{};
    final names = <String, int>{};
    for (final collection in collections) {
      names.update(collection.name.toLowerCase(), (count) => count + 1,
          ifAbsent: () => 1);
      if (collection.kind == TakeoutCollectionKind.musicLibrary) {
        for (final song in collection.songs) {
          metadata.putIfAbsent(song.id, () => song);
        }
      }
    }
    final occurrences = <String, int>{};
    return List.unmodifiable(collections.map((collection) {
      final songs = collection.songs.map((song) {
        final label = metadata[song.id];
        if (label == null ||
            collection.kind == TakeoutCollectionKind.musicLibrary) {
          return song;
        }
        return MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: song.id,
            title: song.title == song.id ? label.title : song.title,
            subtitle: song.subtitle.isEmpty ? label.subtitle : song.subtitle,
            album: song.album ?? label.album);
      }).toList(growable: false);
      _validateSize(songs);
      var name = collection.name;
      if (names[name.toLowerCase()]! > 1) {
        final occurrence = occurrences.update(name.toLowerCase(), (n) => n + 1,
            ifAbsent: () => 1);
        name = '$name ($occurrence)';
      }
      return TakeoutCollection(
          name: name,
          songs: List.unmodifiable(songs),
          skippedRows: collection.skippedRows,
          duplicateRows: collection.duplicateRows,
          metadataMissing: songs
              .any((song) => song.title == song.id || song.subtitle.isEmpty),
          kind: collection.kind);
    }));
  }

  static TakeoutCollection? _parseFile(
      TakeoutFile file, void Function() count) {
    final sourceName = file.name.replaceAll('\\', '/');
    var name = sourceName
        .split('/')
        .last
        .replaceFirst(RegExp(r'\.csv$', caseSensitive: false), '')
        .replaceFirst(RegExp(r'-videos$', caseSensitive: false), '');
    name = _text(name, limit: 120);
    if (name.isEmpty) name = 'Imported songs';
    final kind = _kind(sourceName);
    final allowBareId = kind != TakeoutCollectionKind.playlist ||
        sourceName.toLowerCase().contains('/playlists/');
    final records = _csv(file.text, count).iterator;
    List<String>? first;
    while (records.moveNext()) {
      if (records.current.any((field) => field.trim().isNotEmpty)) {
        first = records.current;
        break;
      }
    }
    if (first == null) return null;
    var header = _Header.read(first, allowBareId: allowBareId);
    if (header == null && first.map(_column).contains('playlistid')) {
      // Older exports put a playlist metadata table before the video table.
      final titleColumn = first.map(_column).toList().indexOf('title');
      var metadataRead = false;
      for (var i = 0; i < 8 && records.moveNext(); i++) {
        final row = records.current;
        if (row.every((field) => field.trim().isEmpty)) continue;
        header = _Header.read(row, allowBareId: true);
        if (header != null) break;
        if (!metadataRead && titleColumn >= 0 && titleColumn < row.length) {
          final title = _text(row[titleColumn], limit: 120);
          if (title.isNotEmpty) name = title;
        }
        metadataRead = true;
      }
    }
    if (header == null) return null;
    final songs = <String, MusicLibraryEntry>{};
    var skipped = 0;
    var duplicates = 0;
    var metadataMissing = false;
    while (records.moveNext()) {
      final row = records.current;
      if (row.every((field) => field.trim().isEmpty)) continue;
      final rawId = header.field(row, header.id).trim();
      final rawUrl = header.field(row, header.url).trim();
      final id = _id(rawId.isEmpty ? rawUrl : rawId);
      if (id == null ||
          (rawId.isNotEmpty && rawUrl.isNotEmpty && _id(rawUrl) != id)) {
        skipped++;
        continue;
      }
      if (songs.containsKey(id)) {
        duplicates++;
        continue;
      }
      final title = _text(header.field(row, header.title));
      final artist = _text(header.field(row, header.artist));
      final album = _text(header.field(row, header.album));
      metadataMissing |= title.isEmpty || artist.isEmpty;
      songs[id] = MusicLibraryEntry(
          kind: MusicLibraryKind.song,
          id: id,
          title: title.isEmpty ? id : title,
          subtitle: artist,
          album: album.isEmpty ? null : album);
      if (songs.length > musicLibraryMaximumEntries) {
        throw const FormatException(
            'A collection contains more than 10,000 songs.');
      }
    }
    final entries = songs.values.toList(growable: false);
    return TakeoutCollection(
        name: name,
        songs: List.unmodifiable(entries),
        skippedRows: skipped,
        duplicateRows: duplicates,
        metadataMissing: metadataMissing,
        kind: kind == TakeoutCollectionKind.playlist ? _kind(name) : kind);
  }

  static void _validateSize(List<MusicLibraryEntry> songs) {
    final stored = jsonEncode({
      'version': 1,
      'entries': songs.map((entry) => entry.toJson()).toList(),
      'playlists': <String>[]
    });
    if (utf8.encode(stored).length > musicLibraryMaximumBytes) {
      throw const FormatException(
          'The collection exceeds the library size limit.');
    }
  }

  static TakeoutCollectionKind _kind(String name) {
    final words = name
        .split(RegExp(r'[/\\]'))
        .last
        .replaceFirst(RegExp(r'\.csv$', caseSensitive: false), '')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z]'), '');
    if (const {
      'likedmusic',
      'likedmusicvideos',
      'likedsongs',
      'likedsongsvideos'
    }.contains(words)) {
      return TakeoutCollectionKind.likedMusic;
    }
    if (const {'likedvideos', 'likedvideosvideos'}.contains(words)) {
      return TakeoutCollectionKind.likedVideos;
    }
    if (words == 'musiclibrarysongs') {
      return TakeoutCollectionKind.musicLibrary;
    }
    return TakeoutCollectionKind.playlist;
  }

  static String? _id(String value) {
    if (_videoId.stringMatch(value) == value) return value;
    if (value.length > 2048 || !_watchUrl.hasMatch(value)) return null;
    try {
      final uri = Uri.tryParse(value);
      if (uri == null || uri.path != '/watch' || uri.fragment.isNotEmpty) {
        return null;
      }
      final ids = uri.queryParametersAll['v'];
      if (ids == null || ids.length != 1) return null;
      return _videoId.stringMatch(ids.single) == ids.single ? ids.single : null;
    } on FormatException {
      return null;
    }
  }

  static String _text(String value, {int limit = 1024}) =>
      String.fromCharCodes(value
          .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
          .trim()
          .runes
          .take(limit));

  static String _column(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]'), '');

  static Iterable<List<String>> _csv(String text, void Function() count) sync* {
    var field = StringBuffer();
    var row = <String>[];
    var quoted = false;
    var closedQuote = false;
    var pending = false;
    void append(String value) {
      field.write(value);
      if (field.length > 65536) {
        throw const FormatException('A CSV field is too large.');
      }
    }

    void finishField() {
      row.add(field.toString());
      if (row.length > 128) {
        throw const FormatException('A CSV row contains too many columns.');
      }
      field = StringBuffer();
      closedQuote = false;
    }

    for (var i = text.startsWith('\ufeff') ? 1 : 0; i < text.length; i++) {
      final char = text[i];
      pending = true;
      if (quoted) {
        if (char == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            append('"');
            i++;
          } else {
            quoted = false;
            closedQuote = true;
          }
        } else {
          append(char);
        }
      } else if (char == ',') {
        finishField();
      } else if (char == '\n' || char == '\r') {
        if (char == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        finishField();
        count();
        yield row;
        row = [];
        pending = false;
      } else if (!closedQuote && char == '"' && field.isEmpty) {
        quoted = true;
      } else if (closedQuote || char == '"') {
        throw const FormatException(
            'The CSV contains malformed quoted fields.');
      } else {
        append(char);
      }
    }
    if (quoted) {
      throw const FormatException(
          'The CSV contains an unfinished quoted field.');
    }
    if (pending) {
      finishField();
      count();
      yield row;
    }
  }
}

class _Header {
  final int id, url, title, artist, album;

  const _Header(this.id, this.url, this.title, this.artist, this.album);

  String field(List<String> row, int index) =>
      index < 0 || index >= row.length ? '' : row[index];

  static _Header? read(List<String> row, {required bool allowBareId}) {
    final columns = row.map(TakeoutImport._column).toList();
    final identified =
        columns.contains('videoid') || columns.contains('songurl');
    final music = columns.contains('songurl') || columns.contains('songtitle');
    final playlist = columns.contains('timeadded') ||
        columns.contains('playlistvideocreationtimestamp');
    if (!identified || (!music && !playlist && !allowBareId)) return null;
    int index(Set<String> names) {
      final matches = [
        for (var i = 0; i < columns.length; i++)
          if (names.contains(columns[i])) i
      ];
      if (matches.length > 1) {
        throw const FormatException(
            'The CSV contains ambiguous duplicate columns.');
      }
      return matches.isEmpty ? -1 : matches.single;
    }

    return _Header(
        index({'videoid'}),
        index({'songurl'}),
        index({'songtitle', 'title'}),
        index({'artistname', 'artistnames'}),
        index({'albumtitle'}));
  }
}
