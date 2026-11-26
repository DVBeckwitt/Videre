import 'music_listening_event.dart';
import 'music_listening_rankings.dart';

/// A local calendar year, optionally narrowed to a single calendar month.
class MusicListeningRecapPeriod {
  const MusicListeningRecapPeriod(this.year, {this.month})
      : assert(month == null || (month >= 1 && month <= 12));

  final int year;
  final int? month;

  String get fileSuffix {
    final selectedMonth = month;
    return selectedMonth == null
        ? '$year'
        : '$year-${selectedMonth.toString().padLeft(2, '0')}';
  }
}

/// A calendar summary of the confirmed starts still in Music history.
/// The observed dates are endpoints, with no claim of continuous capture.
class MusicListeningRecap {
  MusicListeningRecap._(
    this.period,
    this.firstPlay,
    this.lastPlay,
    this.rankings,
    this.dailyPlays,
  );

  final MusicListeningRecapPeriod period;
  final DateTime firstPlay;
  final DateTime lastPlay;
  final MusicListeningRankings rankings;

  /// Monthly play counts in calendar order, including days with zero plays.
  final List<int> dailyPlays;

  int get year => period.year;

  int get songCount => rankings.rankedBy(MusicListeningRankBy.song).length;

  Iterable<MusicListeningRank> highlights(MusicListeningRankBy dimension) =>
      rankings.rankedBy(dimension).take(3);

  static bool _isRecorded(MusicListeningEvent event, DateTime now) =>
      !event.isLegacy && !event.playedAt.isAfter(now);

  static Iterable<MusicListeningEvent> recordedInPeriod(
    Iterable<MusicListeningEvent> events,
    MusicListeningRecapPeriod period, {
    required DateTime now,
  }) =>
      events.where((event) {
        if (!_isRecorded(event, now)) return false;
        final local = event.playedAt.toLocal();
        return local.year == period.year &&
            (period.month == null || local.month == period.month);
      });

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
    Iterable<MusicListeningEvent> events,
    int year, {
    required DateTime now,
  }) =>
      forPeriod(events, MusicListeningRecapPeriod(year), now: now);

  static MusicListeningRecap? forPeriod(
    Iterable<MusicListeningEvent> events,
    MusicListeningRecapPeriod period, {
    required DateTime now,
  }) {
    final month = period.month;
    final dailyPlays = month == null
        ? const <int>[]
        : List.filled(DateTime.utc(period.year, month + 1, 0).day, 0);
    final recorded = <MusicListeningEvent>[];
    DateTime? firstPlay;
    DateTime? lastPlay;
    for (final event in recordedInPeriod(events, period, now: now)) {
      final playedAt = event.playedAt.toLocal();
      recorded.add(event);
      if (month != null) dailyPlays[playedAt.day - 1]++;
      if (firstPlay == null || playedAt.isBefore(firstPlay)) {
        firstPlay = playedAt;
      }
      if (lastPlay == null || playedAt.isAfter(lastPlay)) lastPlay = playedAt;
    }
    if (firstPlay == null || lastPlay == null) return null;
    return MusicListeningRecap._(
      period,
      firstPlay,
      lastPlay,
      MusicListeningRankings.fromEvents(
        recorded,
        MusicListeningPeriod.allTime,
        now: now,
      ),
      List.unmodifiable(dailyPlays),
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
      if (period.month != null) 'month': period.month,
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
