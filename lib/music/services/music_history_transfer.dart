import 'dart:convert';

import '../../utils/backup.dart';
import '../../videos/models/db/history_video_cache.dart';
import '../models/music_listening_event.dart';

/// A local, portable snapshot of one profile's dated Music listening history.
class MusicHistoryTransfer {
  static const _format = 'videre-music-history';
  static const _version = 1;
  static final _csvSpecialCharacters = RegExp(r'[",\r\n]');

  static String encode(List<MusicListeningEvent> events) {
    final ordered = _latestFirst(events);
    final text = jsonEncode({
      'format': _format,
      'version': _version,
      'events': [for (final event in ordered) _portable(event.toJson())],
      'playCounts': _playCounts(ordered).toList(),
    });
    _checkSize(text);
    return text;
  }

  static String encodePlayCountsCsv(List<MusicListeningEvent> events) {
    const columns = ['trackId', 'title', 'artist', 'playCount'];
    final csv = StringBuffer('${columns.join(',')}\r\n');
    for (final row in _playCounts(_latestFirst(events))) {
      final fields = columns.map((column) {
        final value = row[column]?.toString() ?? '';
        return value.contains(_csvSpecialCharacters)
            ? '"${value.replaceAll('"', '""')}"'
            : value;
      });
      csv
        ..write(fields.join(','))
        ..write('\r\n');
    }
    final text = csv.toString();
    _checkSize(text);
    return text;
  }

  static List<MusicListeningEvent> _latestFirst(
    List<MusicListeningEvent> events,
  ) =>
      events.toList()
        ..sort((a, b) {
          final byDate = b.playedAt.compareTo(a.playedAt);
          return byDate != 0 ? byDate : a.id.compareTo(b.id);
        });

  static Iterable<Map<String, Object>> _playCounts(
    List<MusicListeningEvent> ordered,
  ) sync* {
    // Use the latest labels for each song in the count summary.
    final latest = <String, MusicListeningEvent>{};
    final counts = <String, int>{};
    for (final event in ordered) {
      latest.putIfAbsent(event.trackId, () => event);
      counts.update(event.trackId, (count) => count + 1, ifAbsent: () => 1);
    }
    for (final event in latest.values) {
      yield _playCount(event, counts[event.trackId]!);
    }
  }

  static Map<String, Object> _playCount(MusicListeningEvent event, int count) {
    final metadata = event.entry.musicMetadata;
    final title = metadata?.title.trim();
    final artist = metadata?.artist.trim();
    return {
      'trackId': event.trackId,
      'title': title == null || title.isEmpty ? event.entry.title : title,
      if ((artist == null || artist.isEmpty ? event.entry.author : artist)
          case final label?)
        'artist': label,
      'playCount': count,
    };
  }

  static List<MusicListeningEvent> decode(String text) {
    _checkSize(text);
    // Validate every row before handing any of them to the merge transaction.
    try {
      final data = jsonDecode(text) as Map<String, dynamic>;
      if (data['version'] != _version) throw const FormatException();
      return switch (data['format']) {
        _format => _events(data['events'] as List),
        'videre'
            when data['musicListeningEvents'] != null ||
                data['musicHistory'] != null =>
          [
            ..._events((data['musicListeningEvents'] ?? []) as List),
            for (final row in (data['musicHistory'] ?? []) as List)
              _legacy(row as Map<String, dynamic>),
          ],
        _ => throw const FormatException(),
      };
    } on TypeError {
      throw const FormatException('Invalid Music history file.');
    } on ArgumentError {
      throw const FormatException('Invalid Music history file.');
    }
  }

  static List<MusicListeningEvent> _events(List rows) => [
        for (final row in rows)
          MusicListeningEvent.fromJson(_portable(row as Map<String, dynamic>)),
      ];

  static MusicListeningEvent _legacy(Map<String, dynamic> row) {
    final legacy = MusicListeningEvent.legacy(HistoryVideoCache.fromJson(row));
    return MusicListeningEvent.fromJson(_portable(legacy.toJson()));
  }

  static Map<String, dynamic> _portable(Map<String, dynamic> row) {
    final clean = UserBackup.portableMusicListeningEvent(row)
      ..remove('playlist');
    final entry = (clean['entry'] as Map<String, dynamic>)..['thumbnail'] = '';
    if (entry['musicMetadata'] case final Map<String, dynamic> metadata) {
      metadata.remove('thumbnails');
    }
    return clean;
  }

  static void _checkSize(String text) {
    if (text.length > UserBackup.maxBytes ||
        utf8.encode(text).length > UserBackup.maxBytes) {
      throw const MusicHistoryFileTooLarge();
    }
  }
}

class MusicHistoryFileTooLarge implements Exception {
  const MusicHistoryFileTooLarge();
}
