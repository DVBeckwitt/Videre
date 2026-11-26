import 'dart:convert';

import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';
import '../../utils/sembast_sqflite_database.dart';
import '../models/local_music_album_editions.dart';

export '../models/local_music_album_editions.dart';

class _EditionWrites {
  late Future<void> pending = Future.value();
}

/// Saves album-browsing preferences in the listener's fixed profile.
class LocalMusicAlbumEditions {
  static const _setting = 'music-local-album-editions-v1';
  static final _owners = Expando<Map<String, _EditionWrites>>();

  final IDbClient _database;
  final _EditionWrites _writes;

  LocalMusicAlbumEditions(IDbClient database, String profileId)
      : _database = database.forProfile(profileId),
        _writes = (_owners[_databaseIdentity(database)] ??= {})
            .putIfAbsent(profileId, _EditionWrites.new);

  static Object _databaseIdentity(IDbClient database) =>
      database is SembastSqfDb ? database.db : database;

  List<LocalMusicAlbumEditionGroup> get groups {
    final stored = _database.getSettings(_setting)?.value;
    if (stored == null) return const [];
    final Object? value;
    try {
      value = jsonDecode(stored);
    } on FormatException {
      return const [];
    }
    if (value is! List) return const [];

    final groups = <LocalMusicAlbumEditionGroup>[];
    final assigned = <String>{};
    for (final row in value) {
      if (row is! Map ||
          row['albums'] is! List ||
          row['preferred'] is! String) {
        continue;
      }
      final keys = row['albums'] as List;
      final typed = keys.whereType<String>().toList();
      if (typed.length != keys.length || typed.any(assigned.contains)) continue;
      final group = LocalMusicAlbumEditionGroup.tryCreate(
          typed, row['preferred'] as String);
      if (group == null) continue;
      groups.add(group);
      assigned.addAll(group.albumKeys);
    }
    return List.unmodifiable(groups);
  }

  /// Replaces an observed group if it still matches, or creates a new group.
  /// Fewer than two members dissolves an existing group.
  Future<bool> save({
    required LocalMusicAlbumEditionGroup? previous,
    required List<String> albumKeys,
    required String preferredKey,
    required bool Function() isCurrent,
  }) {
    final replacement =
        LocalMusicAlbumEditionGroup.tryCreate(albumKeys, preferredKey);
    if (replacement == previous ||
        (replacement == null && albumKeys.length >= 2)) {
      return Future.value(false);
    }

    final write = _writes.pending.then((_) async {
      if (!isCurrent()) return false;
      final saved = groups.toList();
      final index = previous == null ? saved.length : saved.indexOf(previous);
      if (index < 0) return false;
      if (previous != null) saved.removeAt(index);
      if (replacement != null) {
        final assigned = saved.expand((group) => group.albumKeys).toSet();
        if (replacement.albumKeys.any(assigned.contains)) return false;
        saved.insert(index, replacement);
      }
      final value = jsonEncode([
        for (final group in saved)
          {'albums': group.albumKeys, 'preferred': group.preferredKey},
      ]);
      if (!isCurrent()) return false;
      await _database.saveSetting(SettingsValue(_setting, value));
      return true;
    });
    _writes.pending =
        write.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return write;
  }
}
