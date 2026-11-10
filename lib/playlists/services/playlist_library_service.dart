import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sembast/sembast.dart';

import '../../settings/models/db/server.dart';
import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';
import '../../utils/sembast_sqflite_database.dart';
import '../models/playlist.dart';
import '../models/playlist_reference.dart';
import '../models/saved_playlist.dart';

const playlistLibrarySettingName = 'saved-playlists-v1';

class _PlaylistLibraryChanges extends ChangeNotifier {
  Future<void> writes = Future.value();

  void changed() => notifyListeners();
}

class PlaylistLibraryItem {
  final Playlist playlist;
  final PlaylistReference? reference;

  /// Ownership of an instance's bookmark, separate from the public source.
  final PlaylistReference? bookmarkOwner;
  final bool saved;

  const PlaylistLibraryItem(this.playlist,
      {this.reference, this.bookmarkOwner, this.saved = false});

  String get key => reference?.key ?? playlist.playlistId;
}

/// Bookmarks stay with the person who initiated the write, even after a switch.
class PlaylistLibraryService {
  static final _owners = Expando<Map<String, _PlaylistLibraryChanges>>();
  final IDbClient _database;
  final _PlaylistLibraryChanges _changes;

  PlaylistLibraryService.forProfile(IDbClient database, String profileId)
      : _database = database.forProfile(profileId),
        _changes = (_owners[_registryKey(database)] ??= {})
            .putIfAbsent(profileId, _PlaylistLibraryChanges.new);

  static Object _registryKey(IDbClient database) =>
      database is SembastSqfDb ? database.db : database;

  static void notifyProfileChanged(IDbClient database, String profileId) =>
      _owners[_registryKey(database)]?[profileId]?.changed();

  String get profileId => _database.profileId;
  Listenable get changes => _changes;

  List<SavedPlaylist> get entries => SavedPlaylist.decodeLibrary(
      _database.getSettings(playlistLibrarySettingName)?.value, profileId);

  bool contains(PlaylistReference reference) =>
      entries.any((entry) => entry.reference.key == reference.key);

  Future<void> save(SavedPlaylist entry) {
    final clean = SavedPlaylist.tryParse(entry.toJson());
    if (clean == null || clean.reference.profileId != profileId) {
      throw ArgumentError('The bookmark belongs to a different profile');
    }
    return _write((entries) {
      entries.removeWhere((item) => item.reference.key == clean.reference.key);
      entries.insert(0, clean);
    });
  }

  Future<void> remove(PlaylistReference reference) {
    if (reference.profileId != profileId) {
      throw ArgumentError('The bookmark belongs to a different profile');
    }
    return _write((entries) =>
        entries.removeWhere((entry) => entry.reference.key == reference.key));
  }

  /// Only library views call this; editable playlist pickers keep their own list.
  List<PlaylistLibraryItem> merge(List<Playlist> playlists, {Server? server}) {
    final result = <PlaylistLibraryItem>[];
    final existing = <String>{};
    for (final playlist in playlists) {
      PlaylistReference? reference;
      PlaylistReference? bookmarkOwner;
      try {
        reference =
            PlaylistReference.forPlaylist(playlist, _database, server: server);
        if (reference.kind == PlaylistSourceKind.public &&
            playlist.type == invidiousPlaylist &&
            server != null &&
            server.profileId == profileId) {
          bookmarkOwner = PlaylistReference.fromJson({
            'kind': PlaylistSourceKind.account.name,
            'playlistId': playlist.playlistId,
            'profileId': profileId,
            'accountId': server.accountId,
            'origin': Uri.parse(server.url).origin,
          });
        }
      } on ArgumentError {
        // A remote list without its account must not be mistaken for a bookmark.
      } on StateError {
        // Account removal can race a library response; opening still revalidates.
      } on FormatException {
        // Reject malformed source identities without hiding other library rows.
      }
      if (reference != null) existing.add(reference.key);
      result.add(PlaylistLibraryItem(playlist,
          reference: reference, bookmarkOwner: bookmarkOwner));
    }
    for (final entry in entries) {
      if (existing.add(entry.reference.key)) {
        result.add(PlaylistLibraryItem(entry.toPlaylist(),
            reference: entry.reference, saved: true));
      }
    }
    return result;
  }

  Future<void> _write(void Function(List<SavedPlaylist>) update) {
    return _changes.writes = _changes.writes.catchError((_) {}).then((_) async {
      String updated(List<SavedPlaylist> current) {
        final next = current.toList();
        update(next);
        final value = jsonEncode({
          'version': 1,
          'entries': next.map((entry) => entry.toJson()).toList(),
        });
        if (next.length > playlistLibraryMaximumEntries ||
            utf8.encode(value).length > playlistLibraryMaximumBytes) {
          throw StateError('The saved playlist library is full');
        }
        return value;
      }

      final database = _database;
      if (database is SembastSqfDb) {
        // Backup restore also writes this record transactionally. Read only
        // after acquiring the transaction so neither operation loses the other.
        await database.db.transaction((txn) async {
          final record =
              database.settingsStore.record(playlistLibrarySettingName);
          final stored = (await record.get(txn))?['value'];
          final value = updated(SavedPlaylist.decodeLibrary(
              stored is String ? stored : null, profileId));
          await record.put(
              txn, SettingsValue(playlistLibrarySettingName, value).toJson());
        });
      } else {
        await database.saveSetting(
            SettingsValue(playlistLibrarySettingName, updated(entries)));
      }
      _changes.changed();
    });
  }
}
