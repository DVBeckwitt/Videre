import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';
import '../models/music_library_entry.dart';
import '../models/music_rule_playlist.dart';

const musicRulePlaylistSettingName = 'music-rule-playlists-v1';

class _RulePlaylistChanges extends ChangeNotifier {
  Future<void> writes = Future.value();
  String? storedValue;
  List<MusicRulePlaylist> playlists = const [];

  void changed() => notifyListeners();
}

/// Profile-scoped definitions. Song membership is resolved from the library.
class MusicRulePlaylistStore {
  static final _owners = Expando<Map<String, _RulePlaylistChanges>>();

  MusicRulePlaylistStore.forProfile(IDbClient database, String profileId)
      : _database = database.forProfile(profileId),
        _changes = (_owners[database] ??= {})
            .putIfAbsent(profileId, _RulePlaylistChanges.new);

  final IDbClient _database;
  final _RulePlaylistChanges _changes;

  Listenable get changes => _changes;

  List<MusicRulePlaylist> get playlists {
    final stored = _database.getSettings(musicRulePlaylistSettingName)?.value;
    if (stored == _changes.storedValue) return _changes.playlists;
    _changes.storedValue = stored;
    _changes.playlists = const [];
    if (stored == null || stored.length > musicLibraryMaximumBytes) {
      return _changes.playlists;
    }
    try {
      final data = jsonDecode(stored);
      if (data is Map && data['version'] == 1 && data['playlists'] is List) {
        final seen = <String>{};
        _changes.playlists = List.unmodifiable([
          for (final row
              in (data['playlists'] as List).take(musicLibraryMaximumEntries))
            if (MusicRulePlaylist.tryParse(row) case final playlist?
                when seen.add(playlist.id))
              playlist,
        ]);
      }
    } on FormatException {
      // A damaged setting leaves the Music library usable.
    }
    return _changes.playlists;
  }

  Future<void> save(MusicRulePlaylist playlist,
      {MusicRulePlaylist? previous, required bool Function() isCurrent}) async {
    final clean = _validated(playlist);
    final expected = previous == null ? null : _validated(previous);
    if (expected != null && expected.id != clean.id) {
      throw ArgumentError('A rule playlist edit must keep its ID');
    }
    await _write(isCurrent, (rows) {
      if (expected == null) {
        if (rows.any((row) => row.id == clean.id)) {
          throw StateError('This rule playlist already exists');
        }
        rows.insert(0, clean);
      } else {
        rows[_currentIndex(rows, expected)] = clean;
      }
    });
  }

  Future<void> remove(MusicRulePlaylist playlist,
      {required bool Function() isCurrent}) async {
    final expected = _validated(playlist);
    await _write(isCurrent, (rows) {
      rows.removeAt(_currentIndex(rows, expected));
    });
  }

  static MusicRulePlaylist _validated(MusicRulePlaylist playlist) {
    final clean = MusicRulePlaylist.tryParse(playlist.toJson());
    if (clean == null) throw ArgumentError('Invalid rule playlist');
    return clean;
  }

  static int _currentIndex(
      List<MusicRulePlaylist> rows, MusicRulePlaylist expected) {
    final index = rows.indexWhere((playlist) => playlist.id == expected.id);
    if (index < 0 || !mapEquals(rows[index].toJson(), expected.toJson())) {
      throw StateError('This rule playlist has changed');
    }
    return index;
  }

  Future<void> _write(bool Function() isCurrent,
      void Function(List<MusicRulePlaylist>) update) {
    return _changes.writes = _changes.writes.catchError((_) {}).then((_) async {
      if (!isCurrent()) return;
      final rows = playlists.toList();
      update(rows);
      final value = jsonEncode({
        'version': 1,
        'playlists': rows.map((playlist) => playlist.toJson()).toList(),
      });
      if (rows.length > musicLibraryMaximumEntries ||
          utf8.encode(value).length > musicLibraryMaximumBytes) {
        throw StateError('The rule playlists are full');
      }
      await _database
          .saveSetting(SettingsValue(musicRulePlaylistSettingName, value));
      _changes.changed();
    });
  }
}
