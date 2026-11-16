import 'dart:convert';

import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';

const podcastProgressSettingName = 'podcast-progress-v1';
const podcastProgressMaximumEntries = 2000;
const podcastProgressMaximumBytes = 1024 * 1024;
const _maximumTime = Duration(days: 7);
final _episodeId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

class PodcastProgress {
  final Duration position;
  final Duration duration;
  final bool completed;

  const PodcastProgress({
    required this.position,
    required this.duration,
    required this.completed,
  });

  Map<String, Object> _toJson() => {
        'positionMs': completed ? 0 : position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'completed': completed,
      };

  static PodcastProgress? _parse(Object? value) {
    if (value is! Map) return null;
    final position = value['positionMs'];
    final duration = value['durationMs'];
    final completed = value['completed'];
    if (position is! int ||
        duration is! int ||
        completed is! bool ||
        position < 0 ||
        duration < 0 ||
        position > _maximumTime.inMilliseconds ||
        duration > _maximumTime.inMilliseconds) {
      return null;
    }
    return PodcastProgress(
        position: Duration(milliseconds: completed ? 0 : position),
        duration: Duration(milliseconds: duration),
        completed: completed);
  }
}

class _ProgressWrites {
  Future<void> pending = Future.value();
}

/// Local listening positions captured against one fixed profile. Share the
/// root database when constructing views so their writes retain call order.
class PodcastProgressStore {
  static final _owners = Expando<Map<String, _ProgressWrites>>();
  final IDbClient _database;
  final _ProgressWrites _writes;

  PodcastProgressStore.forProfile(IDbClient database, String profileId)
      : _database = database.forProfile(profileId),
        _writes = (_owners[database] ??= {})
            .putIfAbsent(profileId, _ProgressWrites.new);

  Future<PodcastProgress?> read(String episodeId) async {
    if (!_validId(episodeId)) return null;
    // A replacement controller must see the stop checkpoint queued by its
    // predecessor, including when the underlying database write is delayed.
    await _writes.pending.catchError((Object _) {});
    return _read()[episodeId];
  }

  Future<void> save(String episodeId, PodcastProgress progress) {
    if (!_validId(episodeId) ||
        progress.position.isNegative ||
        progress.duration.isNegative ||
        progress.position > _maximumTime ||
        progress.duration > _maximumTime) {
      return Future.error(ArgumentError('Invalid podcast listening position'));
    }
    return _writes.pending =
        _writes.pending.catchError((Object _) {}).then((_) async {
      final entries = _read();
      entries.remove(episodeId);
      entries[episodeId] = progress;
      while (entries.length > podcastProgressMaximumEntries) {
        entries.remove(entries.keys.first);
      }
      // Only identifiers and timing data survive a rewrite of damaged or
      // hand-edited metadata. Publisher URLs are never part of this store.
      final value = jsonEncode({
        'version': 1,
        'entries': entries.map((id, item) => MapEntry(id, item._toJson())),
      });
      await _database
          .saveSetting(SettingsValue(podcastProgressSettingName, value));
    });
  }

  Map<String, PodcastProgress> _read() {
    final stored = _database.getSettings(podcastProgressSettingName)?.value;
    if (stored == null ||
        stored.length > podcastProgressMaximumBytes ||
        utf8.encode(stored).length > podcastProgressMaximumBytes) {
      return {};
    }
    try {
      final data = jsonDecode(stored);
      if (data is! Map || data['version'] != 1 || data['entries'] is! Map) {
        return {};
      }
      final entries = <String, PodcastProgress>{};
      for (final entry in (data['entries'] as Map).entries) {
        if (entry.key is! String || !_validId(entry.key as String)) continue;
        final progress = PodcastProgress._parse(entry.value);
        if (progress == null) continue;
        entries[entry.key as String] = progress;
        if (entries.length > podcastProgressMaximumEntries) {
          entries.remove(entries.keys.first);
        }
      }
      return entries;
    } on FormatException {
      return {};
    }
  }

  static bool _validId(String id) => _episodeId.stringMatch(id) == id;
}
