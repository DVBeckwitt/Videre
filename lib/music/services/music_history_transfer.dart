import 'dart:convert';

import '../../utils/backup.dart';
import '../../videos/models/db/history_video_cache.dart';
import '../models/music_listening_event.dart';

/// A local, portable snapshot of one profile's dated Music listening history.
class MusicHistoryTransfer {
  static const _format = 'videre-music-history';
  static const _version = 1;

  static String encode(List<MusicListeningEvent> events) {
    // Use the latest labels for each song in the count summary.
    final ordered = events.toList()
      ..sort((a, b) {
        final byDate = b.playedAt.compareTo(a.playedAt);
        return byDate != 0 ? byDate : a.id.compareTo(b.id);
      });
    final latest = <String, MusicListeningEvent>{};
    final counts = <String, int>{};
    final rows = [for (final event in ordered) _portable(event.toJson())];
    for (final event in ordered) {
      latest.putIfAbsent(event.trackId, () => event);
      counts.update(event.trackId, (count) => count + 1, ifAbsent: () => 1);
    }
    final text = jsonEncode({
      'format': _format,
      'version': _version,
      'events': rows,
      'playCounts': [
        for (final event in latest.values)
          _playCount(event, counts[event.trackId]!),
      ],
    });
    _checkSize(text);
    return text;
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
