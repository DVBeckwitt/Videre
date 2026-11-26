import 'package:clipious/music/models/music_listening_event.dart';
import 'package:clipious/music/models/music_listening_recap.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:flutter_test/flutter_test.dart';

MusicListeningEvent _play(String id, DateTime at, {bool legacy = false}) =>
    MusicListeningEvent(
      id: id,
      entry: HistoryVideoCache(id, id, 'Artist', '')..created = at,
      source: MusicListeningSource.catalog,
      isLegacy: legacy,
    );

void main() {
  test('leap February groups recorded plays by local calendar day', () {
    final events = [
      _play(
        'january',
        DateTime(2024, 2, 1).subtract(const Duration(microseconds: 1)),
      ),
      _play('february-first', DateTime(2024, 2, 1)),
      _play(
        'leap-eve',
        DateTime(2024, 2, 29).subtract(const Duration(microseconds: 1)),
      ),
      _play('leap-start', DateTime(2024, 2, 29)),
      _play(
        'leap-end',
        DateTime(2024, 3, 1).subtract(const Duration(microseconds: 1)),
      ),
      _play('march', DateTime(2024, 3, 1)),
      _play('legacy', DateTime(2024, 2, 2), legacy: true),
    ];
    const february = MusicListeningRecapPeriod(2024, month: 2);
    final now = DateTime(2024, 3, 2);
    final recap = MusicListeningRecap.forPeriod(events, february, now: now)!;

    expect(
      MusicListeningRecap.recordedInPeriod(
        events,
        february,
        now: now,
      ).map((event) => event.id),
      ['february-first', 'leap-eve', 'leap-start', 'leap-end'],
    );
    expect(recap.rankings.plays, 4);
    expect(recap.dailyPlays, [1, ...List.filled(26, 0), 1, 2]);
    expect(recap.firstPlay, DateTime(2024, 2, 1));
    expect(
      recap.lastPlay,
      DateTime(2024, 3, 1).subtract(const Duration(microseconds: 1)),
    );
    expect(recap.toJson(), containsPair('month', 2));
    expect(recap.period.fileSuffix, '2024-02');

    final year = MusicListeningRecap.forYear(events, 2024, now: now)!;
    expect(year.rankings.plays, 6);
    expect(year.dailyPlays, isEmpty);
    expect(year.toJson().containsKey('month'), isFalse);
    expect(year.period.fileSuffix, '2024');
  });

  test('ordinary February excludes future plays and has 28 days', () {
    const february = MusicListeningRecapPeriod(2023, month: 2);
    final now = DateTime(2023, 2, 28, 12);
    final boundary = _play('now', now);
    final future = _play('future', now.add(const Duration(microseconds: 1)));
    final recap = MusicListeningRecap.forPeriod(
      [boundary, future],
      february,
      now: now,
    )!;

    expect(recap.dailyPlays, [...List.filled(27, 0), 1]);
    expect(recap.rankings.plays, 1);
    expect(MusicListeningRecap.forPeriod([future], february, now: now), isNull);
  });
}
