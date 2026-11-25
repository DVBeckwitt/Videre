import 'dart:convert';

import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:flutter/foundation.dart';

const musicLibrarySettingName = 'music-library-v1';
const musicPlaylistPinsSettingName = 'music-playlist-pins-v1';

class _ProfileChanges extends ChangeNotifier {
  Future<void> writes = Future.value();
  String? storedValue;
  Map<String, dynamic> data = {};
  List<MusicLibraryEntry>? entries;
  Map<String, List<ImageObject>>? coversBySongId;

  void changed() => notifyListeners();
}

/// A fixed person's local bookmarks, using the application's settings store.
class MusicLibraryService {
  static final _owners = Expando<Map<String, _ProfileChanges>>();
  final IDbClient _database;
  final _ProfileChanges _changes;

  MusicLibraryService.forProfile(IDbClient database, String profileId)
      : _database = database.forProfile(profileId),
        _changes = (_owners[database] ??= {})
            .putIfAbsent(profileId, _ProfileChanges.new);

  String get profileId => _database.profileId;
  Listenable get changes => _changes;

  Map<String, dynamic> _read() {
    final stored = _database.getSettings(musicLibrarySettingName)?.value;
    if (stored == _changes.storedValue) return _changes.data;
    _changes.storedValue = stored;
    _changes.data = {};
    _changes.entries = null;
    _changes.coversBySongId = null;
    try {
      final value = jsonDecode(stored ?? '{}');
      if (value is Map<String, dynamic> && value['version'] == 1) {
        _changes.data = value;
      }
    } on FormatException {
      // Ignore damaged local metadata; the next explicit write repairs it.
    }
    return _changes.data;
  }

  List<MusicLibraryEntry> get entries {
    final data = _read();
    return _changes.entries ??= List.unmodifiable(_entries(data));
  }

  /// Resolve a whole catalog page against one snapshot of this profile's
  /// saved song covers. The index changes with the stored library data.
  Map<String, List<ImageObject>> get coversBySongId {
    final bookmarks = entries;
    return _changes.coversBySongId ??= Map.unmodifiable({
      for (final entry in bookmarks)
        if (entry.kind == MusicLibraryKind.song)
          if (entry.coverThumbnails case final covers when covers.isNotEmpty)
            entry.id: List<ImageObject>.unmodifiable(covers),
    });
  }

  static List<MusicLibraryEntry> _entries(Map<String, dynamic> data) {
    final rows = data['entries'];
    final unique = <String, MusicLibraryEntry>{};
    if (rows is List) {
      for (final row in rows) {
        final entry = MusicLibraryEntry.tryParse(row);
        if (entry != null) unique['${entry.kind.name}:${entry.id}'] = entry;
      }
    }
    return unique.values.toList();
  }

  static Set<String> _playlists(Map<String, dynamic> data) {
    final rows = data['playlists'];
    return rows is List ? rows.whereType<String>().where(_localId).toSet() : {};
  }

  static bool _localId(String id) =>
      RegExp(r'^local:[A-Za-z0-9_-]{1,128}$').stringMatch(id) == id;

  bool contains(MusicLibraryKind kind, String id) =>
      entries.any((entry) => entry.kind == kind && entry.id == id);

  /// Explicit Music playlist membership, including nonempty imported lists.
  Set<String> get localPlaylistIds => Set.unmodifiable(_playlists(_read()));

  Set<String> _readPlaylistPins() {
    final stored = _database.getSettings(musicPlaylistPinsSettingName)?.value;
    if (stored == null || stored.length > musicLibraryMaximumBytes) return {};
    try {
      final rows = jsonDecode(stored);
      if (rows is List && rows.length <= musicLibraryMaximumEntries) {
        return rows.whereType<String>().where(_localId).toSet();
      }
    } on FormatException {
      // A damaged pin setting can be replaced without changing the library.
    }
    return {};
  }

  Set<String> get pinnedLocalPlaylistIds =>
      Set.unmodifiable(_readPlaylistPins());

  Future<void> setLocalPlaylistPinned(String id, {required bool pinned}) {
    if (!_localId(id)) throw ArgumentError('A local playlist is required');
    return _enqueueWrite(() async {
      final pins = _readPlaylistPins();
      final changed = pinned ? pins.add(id) : pins.remove(id);
      if (!changed) return;
      final value = jsonEncode(pins.toList());
      if (pins.length > musicLibraryMaximumEntries ||
          value.length > musicLibraryMaximumBytes) {
        throw StateError('The playlist pin list is full');
      }
      await _database
          .saveSetting(SettingsValue(musicPlaylistPinsSettingName, value));
      _changes.changed();
    });
  }

  bool isMusicPlaylist(Playlist playlist) =>
      playlist.isLocal &&
      (playlist.videos.any((video) => video.musicMetadata != null) ||
          (playlist.videos.isEmpty &&
              _playlists(_read()).contains(playlist.playlistId)));

  Future<void> save(MusicLibraryEntry entry) {
    final clean = MusicLibraryEntry.tryParse(entry.toJson());
    if (clean == null) throw ArgumentError('Invalid music bookmark');
    return _write((entries, _) {
      entries.removeWhere(
          (item) => item.kind == clean.kind && item.id == clean.id);
      entries.insert(0, clean);
    });
  }

  /// Merge a local song list without replacing bookmarks or fetching metadata.
  Future<int> importSongs(Iterable<MusicLibraryEntry> songs) async {
    final incoming = <String, MusicLibraryEntry>{};
    final videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');
    for (final song in songs) {
      if (song.kind != MusicLibraryKind.song ||
          videoId.stringMatch(song.id) != song.id) {
        throw ArgumentError('Invalid imported song');
      }
      // Never turn a URL supplied by an import into a request for artwork.
      final clean = MusicLibraryEntry.tryParse({
        'kind': MusicLibraryKind.song.name,
        'id': song.id,
        'title': song.title,
        'subtitle': song.subtitle,
        'album': song.album,
        'durationSeconds': song.durationSeconds,
      });
      if (clean == null) throw ArgumentError('Invalid imported song');
      incoming.putIfAbsent(clean.id, () => clean);
      if (incoming.length > musicLibraryMaximumEntries) {
        throw StateError('The music library is full');
      }
    }
    if (incoming.isEmpty) return 0;
    var imported = 0;
    await _write((entries, _) {
      final existing = entries
          .where((entry) => entry.kind == MusicLibraryKind.song)
          .map((entry) => entry.id)
          .toSet();
      for (final song in incoming.values) {
        if (existing.add(song.id)) {
          entries.add(song);
          imported++;
        }
      }
    });
    return imported;
  }

  Future<void> remove(MusicLibraryKind kind, String id) =>
      _write((entries, _) =>
          entries.removeWhere((entry) => entry.kind == kind && entry.id == id));

  /// Fill missing display fields in place using verified catalog details.
  Future<int> fillSongDetails(Iterable<MusicLibraryEntry> details,
      {required bool Function() isCurrent}) async {
    if (!isCurrent()) return 0;
    final incoming = <String, MusicLibraryEntry>{};
    for (final detail in details) {
      final clean = MusicLibraryEntry.tryParse(detail.toJson());
      if (clean != null && clean.kind == MusicLibraryKind.song) {
        incoming.putIfAbsent(clean.id, () => clean);
      }
    }
    if (incoming.isEmpty) return 0;

    var updated = 0;
    await _write((entries, _) {
      if (!isCurrent()) return;
      for (var index = 0; index < entries.length; index++) {
        final entry = entries[index];
        final detail = incoming[entry.id];
        if (detail == null || !entry.needsSongDetails) continue;

        final title = entry.title == entry.id ? detail.title : entry.title;
        final artist =
            entry.subtitle.isEmpty ? detail.subtitle : entry.subtitle;
        final useDetailCredits = entry.artistCredits.isEmpty &&
            detail.artistCredits.isNotEmpty &&
            artist == detail.subtitle;
        final album = entry.album ?? detail.album;
        final duration = entry.durationSeconds ?? detail.durationSeconds;
        final isArtTrack = entry.isArtTrack || detail.isArtTrack;
        ImageObject? artwork;
        final detailCovers = detail.coverThumbnails;
        if ((entry.thumbnails.isEmpty ||
                entry.coverThumbnails.isEmpty && detailCovers.isNotEmpty) &&
            detail.thumbnails.isNotEmpty) {
          // Keep one rendition per repaired entry and preserve its source.
          final images =
              detailCovers.isEmpty ? detail.thumbnails : detailCovers;
          final url = ImageObject.getThumbnailUrlsForSize(images,
                  width: 320, height: 180)
              .first;
          artwork = images.firstWhere((image) => image.url == url);
        }
        if (title == entry.title &&
            artist == entry.subtitle &&
            !useDetailCredits &&
            album == entry.album &&
            duration == entry.durationSeconds &&
            isArtTrack == entry.isArtTrack &&
            artwork == null) {
          continue;
        }
        entries[index] = MusicLibraryEntry(
          kind: entry.kind,
          id: entry.id,
          title: title,
          subtitle: artist,
          artistCredits:
              useDetailCredits ? detail.artistCredits : entry.artistCredits,
          album: album,
          albumPlaylistId: entry.albumPlaylistId,
          durationSeconds: duration,
          isArtTrack: isArtTrack,
          thumbnails: artwork == null ? entry.thumbnails : [artwork],
          usesVideoThumbnails: artwork == null
              ? entry.usesVideoThumbnails
              : detail.usesVideoThumbnails,
        );
        updated++;
      }
    }, shouldWrite: () => updated > 0);
    return updated;
  }

  Future<void> markLocalPlaylist(String id) {
    if (!_localId(id)) throw ArgumentError('A local playlist is required');
    return _write((_, playlists) => playlists.add(id));
  }

  /// Existing playlist writes also invalidate the Music surface for this owner.
  void notifyChanged() => _changes.changed();

  Future<void> _enqueueWrite(Future<void> Function() write) =>
      _changes.writes = _changes.writes.catchError((_) {}).then((_) => write());

  Future<void> _write(
      void Function(List<MusicLibraryEntry>, Set<String>) update,
      {bool Function()? shouldWrite}) {
    return _enqueueWrite(() async {
      final data = _read();
      final entries = _entries(data);
      final playlists = _playlists(data);
      update(entries, playlists);
      if (shouldWrite?.call() == false) return;
      final value = jsonEncode({
        'version': 1,
        'entries': entries.map((entry) => entry.toJson()).toList(),
        'playlists': playlists.toList(),
      });
      if (entries.length > musicLibraryMaximumEntries ||
          playlists.length > musicLibraryMaximumEntries ||
          utf8.encode(value).length > musicLibraryMaximumBytes) {
        throw StateError('The music library is full');
      }
      await _database
          .saveSetting(SettingsValue(musicLibrarySettingName, value));
      _changes.changed();
    });
  }
}
