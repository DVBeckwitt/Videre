import '../../playlists/models/playlist_reference.dart';
import '../../videos/models/db/history_video_cache.dart';

enum MusicListeningSource { catalog, download, device }

/// One confirmed Music playback start, or the one timestamp retained by the
/// previous recency-only history for a song.
class MusicListeningEvent {
  final String id;
  final String trackId;
  final DateTime playedAt;
  final MusicListeningSource source;
  final HistoryVideoCache entry;
  final bool isLegacy;
  final PlaylistReference? playlist;

  /// Observed playback time. Earlier history has no elapsed measurement.
  final Duration? elapsed;

  MusicListeningEvent({
    required this.id,
    required this.entry,
    required this.source,
    this.isLegacy = false,
    this.playlist,
    this.elapsed,
  })  : trackId = entry.videoId,
        playedAt = entry.created.toUtc();

  factory MusicListeningEvent.legacy(HistoryVideoCache entry) =>
      MusicListeningEvent(
        id: legacyId(entry.videoId, entry.created),
        entry: entry,
        source: entry.playedFromDownload
            ? MusicListeningSource.download
            : MusicListeningSource.catalog,
        isLegacy: true,
      );

  static String legacyId(String trackId, DateTime playedAt) =>
      'legacy:$trackId:${playedAt.microsecondsSinceEpoch}';

  factory MusicListeningEvent.fromJson(Map<String, dynamic> json) {
    final entry = HistoryVideoCache.fromJson(
        Map<String, dynamic>.from(json['entry'] as Map));
    final playedAt = DateTime.parse(json['playedAt'] as String).toUtc();
    final source = MusicListeningSource.values.byName(json['source'] as String);
    final elapsed = json['elapsedMicroseconds'];
    if (entry.videoId != json['trackId'] ||
        entry.created.toUtc() != playedAt ||
        entry.videoId.startsWith('device:') !=
            (source == MusicListeningSource.device) ||
        (elapsed != null && (elapsed is! int || elapsed < 0))) {
      throw const FormatException('Inconsistent Music listening event');
    }
    return MusicListeningEvent(
      id: json['id'] as String,
      entry: entry,
      source: source,
      isLegacy: json['isLegacy'] as bool? ?? false,
      playlist: PlaylistReference.tryParse(json['playlist']),
      elapsed: elapsed is int ? Duration(microseconds: elapsed) : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'trackId': trackId,
        'playedAt': playedAt.toIso8601String(),
        'source': source.name,
        'entry': {...entry.toJson(), 'created': playedAt.toIso8601String()},
        if (isLegacy) 'isLegacy': true,
        if (playlist != null) 'playlist': playlist!.toJson(),
        if (elapsed != null) 'elapsedMicroseconds': elapsed!.inMicroseconds,
      };
}
