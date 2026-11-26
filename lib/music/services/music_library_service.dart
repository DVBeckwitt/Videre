import 'dart:convert';

import 'package:clipious/music/models/local_music_artist.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_identity.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/foundation.dart';

const musicLibrarySettingName = 'music-library-v1';
const musicPlaylistPinsSettingName = 'music-playlist-pins-v1';
const musicArtistAliasesSettingName = 'music-artist-aliases-v1';

class _ProfileChanges extends ChangeNotifier {
  Future<void> writes = Future.value();
  final songMetadataRefreshes = <String, Object>{};
  String? storedValue;
  Map<String, dynamic> data = {};
  List<MusicLibraryEntry>? entries;
  Map<String, MusicLibraryEntry>? songsById;
  Map<String, MusicLibraryEntry>? likes;
  Map<String, List<ImageObject>>? coversBySongId;
  String? storedArtistAliases;
  Map<String, String> artistAliases = {};

  void changed() => notifyListeners();
}

/// A fixed person's local bookmarks and Likes.
class MusicLibraryService {
  static final _owners = Expando<Map<String, _ProfileChanges>>();
  static final _songId = RegExp(r'^[A-Za-z0-9_-]{11}$');
  final IDbClient _database;
  final _ProfileChanges _changes;

  MusicLibraryService.forProfile(IDbClient database, String profileId)
      : _database = database.forProfile(profileId),
        _changes =
            (_owners[database is SembastSqfDb ? database.db : database] ??= {})
                .putIfAbsent(profileId, _ProfileChanges.new);

  String get profileId => _database.profileId;
  Listenable get changes => _changes;

  Map<String, String> _readArtistAliases() {
    final stored = _database.getSettings(musicArtistAliasesSettingName)?.value;
    if (_changes.storedArtistAliases == stored) return _changes.artistAliases;
    _changes.storedArtistAliases = stored;
    final aliases = _changes.artistAliases = {};
    if (stored == null ||
        stored.length > musicLibraryMaximumBytes ||
        utf8.encode(stored).length > musicLibraryMaximumBytes) {
      return aliases;
    }
    try {
      final rows = jsonDecode(stored);
      if (rows is Map<String, dynamic> &&
          rows.length <= musicLibraryMaximumEntries) {
        for (final row in rows.entries) {
          final alias = row.value;
          if (alias is! String ||
              MusicArtistIdentity.fromStorageKey(row.key) == null) {
            continue;
          }
          if (normalizeMusicArtistAlias(alias) case final name?) {
            aliases[row.key] = name;
          }
        }
      }
    } on FormatException {
      // Ignore damaged local aliases until the next explicit edit.
    }
    return aliases;
  }

  String? artistAlias(MusicArtistIdentity identity) =>
      _readArtistAliases()[identity.storageKey];

  String artistDisplayName(MusicArtistIdentity identity, String original) =>
      artistAlias(identity) ?? original;

  String catalogArtistByline(String fallback, List<MusicArtistCredit> credits) {
    if (credits.isEmpty) return fallback;
    final aliases = _readArtistAliases();
    if (aliases.isEmpty) return fallback;
    var changed = false;
    final names = <String>[];
    for (final credit in credits) {
      final id = credit.id;
      final alias = id == null
          ? null
          : aliases[MusicArtistIdentity.catalog(id).storageKey];
      changed = changed || alias != null;
      names.add(alias ?? credit.name);
    }
    return changed ? names.join(', ') : fallback;
  }

  String? deviceArtistByline(LocalMusicTrack track) {
    final aliases = _readArtistAliases();
    if (aliases.isEmpty) return track.artist;
    var changed = false;
    final names = <String>[];
    for (final credit in localMusicArtistCredits(track)) {
      if (!credit.roles.contains(LocalMusicArtistRole.trackArtist)) continue;
      final alias = aliases[MusicArtistIdentity.device(credit.key).storageKey];
      changed = changed || alias != null;
      names.add(alias ?? credit.name);
    }
    return changed ? names.join(', ') : track.artist;
  }

  /// Null removes only this display preference. The original credit is
  /// still the source for matching, navigation, and export.
  Future<bool> setArtistAlias(MusicArtistIdentity identity, String? alias,
      {required bool Function() isCurrent}) async {
    if (!identity.isValid) throw ArgumentError('Invalid artist identity');
    final normalized = normalizeMusicArtistAlias(alias);
    if (alias != null && normalized == null) {
      throw ArgumentError('Invalid artist alias');
    }
    var accepted = false;
    await _enqueueWrite(() async {
      if (!isCurrent()) return;
      accepted = true;
      final current = _readArtistAliases();
      final key = identity.storageKey;
      if (current[key] == normalized) return;
      final aliases = Map.of(current);
      if (normalized == null) {
        aliases.remove(key);
      } else {
        aliases[key] = normalized;
      }
      final value = jsonEncode(aliases);
      if (aliases.length > musicLibraryMaximumEntries ||
          utf8.encode(value).length > musicLibraryMaximumBytes) {
        throw StateError('The artist alias list is full');
      }
      await _database
          .saveSetting(SettingsValue(musicArtistAliasesSettingName, value));
      _changes.changed();
    });
    return accepted;
  }

  Map<String, dynamic> _read() {
    final stored = _database.getSettings(musicLibrarySettingName)?.value;
    if (stored == _changes.storedValue) return _changes.data;
    _changes.storedValue = stored;
    _changes.data = {};
    _changes.entries = null;
    _changes.songsById = null;
    _changes.likes = null;
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

  MusicLibraryEntry? savedSong(String songId) {
    final bookmarks = entries;
    final songs = _changes.songsById ??= {
      for (final entry in bookmarks)
        if (entry.kind == MusicLibraryKind.song) entry.id: entry,
    };
    return songs[songId];
  }

  List<MusicLibraryEntry> get likedSongs =>
      List.unmodifiable(_likedSongs().values);

  bool isLiked(String id) => _likedSongs().containsKey(id);

  Map<String, MusicLibraryEntry> _likedSongs() {
    final data = _read();
    return _changes.likes ??= _likes(data);
  }

  static Map<String, MusicLibraryEntry> _likes(Map<String, dynamic> data) {
    final rows = data['likes'];
    return {
      if (rows is List)
        for (final row in rows)
          if (MusicLibraryEntry.tryParseLikedSong(row) case final song?)
            song.id: song,
    };
  }

  Future<void> setSongLiked(MusicLibraryEntry song,
      {required bool liked, bool Function()? isCurrent}) {
    final clean = MusicLibraryEntry.tryParseLikedSong(song.toJson());
    if (clean == null) throw ArgumentError('Invalid liked song');
    var changed = false;
    return _write(null,
        updateLikes: (songs) {
          if (isCurrent?.call() == false) return;
          final index = songs.indexWhere((item) => item.id == clean.id);
          if (liked == (index >= 0)) return;
          if (liked) {
            songs.insert(0, clean);
          } else {
            songs.removeAt(index);
          }
          changed = true;
        },
        shouldWrite: () => changed);
  }

  Future<bool> removeLikedSongs(Iterable<String> songIds,
      {required bool Function() isCurrent}) async {
    final ids = songIds.toSet();
    if (ids.isEmpty) return false;
    var changed = false;
    await _write(null,
        updateLikes: (songs) {
          if (!isCurrent()) return;
          final count = songs.length;
          songs.removeWhere((song) => ids.contains(song.id));
          changed = songs.length != count;
        },
        shouldWrite: () => changed);
    return changed;
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

  Future<void> save(MusicLibraryEntry entry) =>
      _save(entry, replaceExisting: true);

  /// Insert a new bookmark while preserving any existing entry and its order.
  Future<bool> saveIfAbsent(MusicLibraryEntry entry) =>
      _save(entry, replaceExisting: false);

  Future<bool> _save(MusicLibraryEntry entry, {required bool replaceExisting}) {
    final clean = MusicLibraryEntry.tryParse(entry.toJson());
    if (clean == null) throw ArgumentError('Invalid music bookmark');
    var changed = false;
    return _write((entries, _) {
      final index = entries
          .indexWhere((item) => item.kind == clean.kind && item.id == clean.id);
      if (index >= 0 && !replaceExisting) return;
      final savedTitle = index < 0 ? null : entries.removeAt(index).savedTitle;
      entries.insert(
          0,
          savedTitle == clean.savedTitle
              ? clean
              : clean.withSavedTitle(savedTitle));
      changed = true;
    }, shouldWrite: () => changed, replacedSongIds: [
      if (clean.kind == MusicLibraryKind.song) clean.id,
    ]).then((_) => changed);
  }

  /// Change a saved song's display title in place. Null restores its metadata
  /// title. The song must still belong to this profile when the write starts.
  Future<bool> setSavedSongTitle(String songId, String? title,
      {required bool Function() isCurrent}) async {
    final clean = normalizeSavedSongTitle(title);
    if (title != null && clean == null) {
      throw ArgumentError('Invalid saved song title');
    }
    var found = false;
    var changed = false;
    await _write((entries, _) {
      if (!isCurrent()) return;
      final index = entries.indexWhere(
          (entry) => entry.kind == MusicLibraryKind.song && entry.id == songId);
      if (index < 0) return;
      found = true;
      final entry = entries[index];
      final savedTitle = clean == entry.title ? null : clean;
      if (savedTitle == entry.savedTitle) return;
      entries[index] = entry.withSavedTitle(savedTitle);
      changed = true;
    }, shouldWrite: () => changed);
    return found;
  }

  /// Merge a local song list without replacing bookmarks or fetching metadata.
  Future<int> importSongs(Iterable<MusicLibraryEntry> songs,
      {bool asLikes = false}) async {
    final incoming = <String, MusicLibraryEntry>{};
    for (final song in songs) {
      if (song.kind != MusicLibraryKind.song ||
          _songId.stringMatch(song.id) != song.id) {
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
    if (asLikes) {
      await _write(null,
          updateLikes: (likes) {
            final existing = likes.map((song) => song.id).toSet();
            for (final song in incoming.values) {
              if (!existing.add(song.id)) continue;
              likes.add(song);
              imported++;
            }
          },
          shouldWrite: () => imported > 0);
      return imported;
    }
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

  Future<void> remove(MusicLibraryKind kind, String id) => _write(
      (entries, _) =>
          entries.removeWhere((entry) => entry.kind == kind && entry.id == id),
      replacedSongIds: [if (kind == MusicLibraryKind.song) id]);

  Future<bool> removeSavedSongs(Iterable<String> ids,
      {required bool Function() isCurrent}) async {
    final selected = ids.toSet();
    if (selected.isEmpty) return false;
    var removed = false;
    await _write((entries, _) {
      if (!isCurrent()) return;
      final count = entries.length;
      entries.removeWhere((entry) =>
          entry.kind == MusicLibraryKind.song && selected.contains(entry.id));
      removed = count - entries.length == selected.length;
    }, shouldWrite: () => removed, replacedSongIds: selected);
    return removed;
  }

  bool canRefreshSongMetadata(String id) =>
      _songId.stringMatch(id) == id && contains(MusicLibraryKind.song, id);

  /// Apply fresh catalog details to the same bookmark, in its saved position.
  /// Returns false when the request or bookmark was superseded.
  Future<bool> refreshSongMetadata(String id,
      {required Future<MusicLibraryEntry?> Function(bool Function()) load,
      required bool Function() isCurrent}) async {
    if (!isCurrent() || !canRefreshSongMetadata(id)) return false;
    final request = Object();
    final pending = _changes.songMetadataRefreshes;
    pending[id] = request;
    bool current() => isCurrent() && identical(pending[id], request);

    try {
      final response = await load(current);
      if (!current()) return false;
      final details = MusicLibraryEntry.tryParse(response?.toJson());
      if (details == null ||
          details.kind != MusicLibraryKind.song ||
          details.id != id) {
        throw StateError('Song metadata unavailable');
      }

      var accepted = false;
      var changed = false;
      await _write((entries, _) {
        if (!current()) return;
        final index = entries.indexWhere(
            (entry) => entry.kind == MusicLibraryKind.song && entry.id == id);
        if (index < 0) return;

        final entry = entries[index];
        final refreshed = _withRefreshedSongMetadata(entry, details);
        accepted = true;
        if (jsonEncode(entry.toJson()) == jsonEncode(refreshed.toJson())) {
          return;
        }
        entries[index] = refreshed;
        changed = true;
      }, shouldWrite: () => changed);
      return accepted && current();
    } catch (_) {
      if (!current()) return false;
      rethrow;
    } finally {
      if (identical(pending[id], request)) pending.remove(id);
    }
  }

  static MusicLibraryEntry _withRefreshedSongMetadata(
      MusicLibraryEntry entry, MusicLibraryEntry details) {
    final savedArtist = entry.artistCredits.singleOrNull?.id;
    // The video endpoint supplies an uploader. Keep richer artist credits
    // and established links when that response cannot confirm their identity.
    final useFreshArtist = details.subtitle.isNotEmpty &&
        entry.artistCredits.length <= 1 &&
        (savedArtist == null ||
            savedArtist == details.artistCredits.singleOrNull?.id);
    final useFreshArtwork =
        details.thumbnails.isNotEmpty && entry.coverThumbnails.isEmpty;
    return MusicLibraryEntry(
      kind: entry.kind,
      id: entry.id,
      title: details.title,
      savedTitle: entry.savedTitle,
      subtitle: useFreshArtist ? details.subtitle : entry.subtitle,
      artistCredits:
          useFreshArtist ? details.artistCredits : entry.artistCredits,
      album: entry.albumPlaylistId == null
          ? details.album ?? entry.album
          : entry.album ?? details.album,
      albumPlaylistId: entry.albumPlaylistId,
      durationSeconds: details.durationSeconds ?? entry.durationSeconds,
      thumbnails: useFreshArtwork ? details.thumbnails : entry.thumbnails,
      usesVideoThumbnails: useFreshArtwork
          ? details.usesVideoThumbnails
          : entry.usesVideoThumbnails,
      isArtTrack: entry.isArtTrack || details.isArtTrack,
    );
  }

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
          savedTitle: entry.savedTitle,
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
      void Function(List<MusicLibraryEntry>, Set<String>)? updateLibrary,
      {void Function(List<MusicLibraryEntry>)? updateLikes,
      bool Function()? shouldWrite,
      Iterable<String> replacedSongIds = const []}) {
    return _enqueueWrite(() async {
      final data = _read();
      final entries = _entries(data);
      final playlists = _playlists(data);
      final likes = _likes(data).values.toList();
      updateLibrary?.call(entries, playlists);
      updateLikes?.call(likes);
      if (shouldWrite?.call() == false) return;
      final value = jsonEncode({
        'version': 1,
        'entries': entries.map((entry) => entry.toJson()).toList(),
        'playlists': playlists.toList(),
        if (likes.isNotEmpty)
          'likes': likes.map((entry) => entry.toJson()).toList(),
      });
      if (entries.length > musicLibraryMaximumEntries ||
          playlists.length > musicLibraryMaximumEntries ||
          likes.length > musicLibraryMaximumEntries ||
          utf8.encode(value).length > musicLibraryMaximumBytes) {
        throw StateError('The music library is full');
      }
      await _database
          .saveSetting(SettingsValue(musicLibrarySettingName, value));
      for (final id in replacedSongIds) {
        _changes.songMetadataRefreshes.remove(id);
      }
      _changes.changed();
    });
  }
}
