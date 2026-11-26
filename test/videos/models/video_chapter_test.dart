import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const duration = Duration(seconds: 60);
  const description = '0:00 Creator intro\n0:10 Creator middle';
  test(
    'normalizes selected-instance chapters before using the description',
    () {
      final video = Video.fromJson({
        'videoId': 'chaptered',
        'description': description,
        'chapters': [
          {'title': ' Middle ', 'startTimeSeconds': '30.25'},
          {'title': 'Intro', 'startTimeSeconds': 0},
          {'title': 'Duplicate', 'startTimeSeconds': 30.25},
          {'title': 'At the end', 'startTimeSeconds': 60},
          {'title': 'Past the end', 'startTimeSeconds': 100},
          {'title': '', 'startTimeSeconds': 10},
          for (final invalid in [
            -0.001,
            '-1e-999',
            'NaN',
            'Infinity',
            'wrong',
            1e100
          ])
            {'title': 'Malformed', 'startTimeSeconds': invalid},
          false,
        ],
      });

      final chapters = video.chaptersFor(duration);
      expect(chapters.map((chapter) => chapter.title), ['Intro', 'Middle']);
      expect(chapters.map((chapter) => chapter.start), [
        Duration.zero,
        const Duration(milliseconds: 30250),
      ]);
      final restored = Video.fromJson(video.toJson());
      expect(restored.chaptersFor(duration).last.start, chapters.last.start);
    },
  );

  test(
    'uses creator chapters when supplied metadata has no playable entries',
    () {
      for (final metadata in [
        null,
        'incomplete',
        [
          {'title': 'After the video', 'startTimeSeconds': 100},
        ],
      ]) {
        final video = Video.fromJson({
          'videoId': 'chaptered',
          'description': description,
          'chapters': metadata,
        });

        expect(video.chaptersFor(duration).map((chapter) => chapter.title), [
          'Creator intro',
          'Creator middle',
        ]);
      }
    },
  );

  test(
    'reads chronological named markers and skips invalid description rows',
    () {
      const video = Video(
        videoId: 'chaptered',
        description: '0:15 Standalone timestamp\r\nChapters\r\n'
            '[0:00] – Intro\r\n'
            '0:02 Refer to the introduction\r\n'
            '0:01 Out of order\r\n'
            '0:02 Duplicate\r\n'
            '0:60 Invalid seconds\r\n'
            '5:00:90 Invalid hours and minutes timestamp\r\n'
            '0:12 -\r\n'
            '0:14 --\r\n'
            '12:00\r\n'
            'See 20:00 for a link\r\n'
            '• (1:00:00) — Demonstration\r\n'
            '1:01:00 Out of range',
      );

      final chapters = video.chaptersFor(const Duration(minutes: 61));
      expect(chapters.map((chapter) => (chapter.title, chapter.start)), [
        ('Intro', Duration.zero),
        ('Refer to the introduction', const Duration(seconds: 2)),
        ('Demonstration', const Duration(hours: 1)),
      ]);
    },
  );

  test(
    'requires a zero-based index with multiple named rows and a duration',
    () {
      for (final invalid in [
        '0:00 Intro\nSee 0:20 for a link',
        '0:05 Introduction\n0:30 Middle',
        '0:00 Intro\n1:00 End',
        '-0:00 Negative\n0:20 Middle',
        '0:00 Intro\n[0:30) Mismatched delimiters',
        '0:00 Intro\n0:02:99 Malformed',
      ]) {
        final video = Video(videoId: 'chaptered', description: invalid);
        expect(video.chaptersFor(duration), isEmpty, reason: invalid);
      }
      final video = Video(videoId: 'chaptered', description: description);
      expect(video.chaptersFor(Duration.zero), isEmpty);
    },
  );
}
