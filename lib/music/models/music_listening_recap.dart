import 'music_listening_event.dart';
import 'music_listening_rankings.dart';

/// A calendar-year summary of the confirmed starts still in Music history.
/// The observed dates are endpoints, with no claim of continuous capture.
class MusicListeningRecap {
  MusicListeningRecap._(
      this.year, this.firstPlay, this.lastPlay, this.rankings);

  final int year;
  final DateTime firstPlay;
  final DateTime lastPlay;
  final MusicListeningRankings rankings;

  int get songCount => rankings.rankedBy(MusicListeningRankBy.song).length;

  Iterable<MusicListeningRank> highlights(MusicListeningRankBy dimension) =>
      rankings.rankedBy(dimension).take(3);

  static bool _isRecorded(MusicListeningEvent event, DateTime now) =>
      !event.isLegacy && !event.playedAt.isAfter(now);

  static List<int> availableYears(Iterable<MusicListeningEvent> events,
      {required DateTime now}) {
    final years = {
      for (final event in events)
        if (_isRecorded(event, now)) event.playedAt.toLocal().year,
    };
    if (years.isEmpty) return [now.toLocal().year];
    return years.toList()..sort((a, b) => b.compareTo(a));
  }

  static MusicListeningRecap? forYear(
      Iterable<MusicListeningEvent> events, int year,
      {required DateTime now}) {
    final recorded = <MusicListeningEvent>[];
    DateTime? firstPlay;
    DateTime? lastPlay;
    for (final event in events) {
      final playedAt = event.playedAt.toLocal();
      if (playedAt.year != year || !_isRecorded(event, now)) continue;
      recorded.add(event);
      if (firstPlay == null || playedAt.isBefore(firstPlay)) {
        firstPlay = playedAt;
      }
      if (lastPlay == null || playedAt.isAfter(lastPlay)) lastPlay = playedAt;
    }
    if (firstPlay == null || lastPlay == null) return null;
    return MusicListeningRecap._(
      year,
      firstPlay,
      lastPlay,
      MusicListeningRankings.fromEvents(recorded, MusicListeningPeriod.allTime,
          now: now),
    );
  }

  /// Export only the aggregate and display labels visible on the recap.
  Map<String, Object?> toJson() {
    String calendarDate(DateTime value) =>
        value.toIso8601String().split('T')[0];
    List<Map<String, Object?>> ranks(MusicListeningRankBy dimension) => [
          for (final rank in highlights(dimension))
            {
              'title': rank.title,
              if (rank.subtitle != null) 'subtitle': rank.subtitle,
              'recordedPlays': rank.plays,
            },
        ];

    return {
      'format': 'videre-music-recap',
      'version': 1,
      'year': year,
      'coverage': {
        'basis': 'recorded-events-only',
        'firstRecordedDate': calendarDate(firstPlay),
        'lastRecordedDate': calendarDate(lastPlay),
      },
      'recordedPlays': rankings.plays,
      'distinctSongs': songCount,
      'topSongs': ranks(MusicListeningRankBy.song),
      'topArtists': ranks(MusicListeningRankBy.artist),
    };
  }
}
