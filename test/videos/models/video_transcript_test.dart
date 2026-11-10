import 'package:clipious/videos/models/video_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VideoTranscript.fromJson', () {
    test('parses usable lines and skips malformed or duplicate entries', () {
      final transcript = VideoTranscript.fromJson({
        'transcript': {
          'label': 'English (auto-generated)',
          'languageCode': 'en',
          'body': [
            {
              'type': 'regular',
              'startMs': 0.0,
              'endMs': '1500',
              'line': '  First   line  ',
            },
            {
              'type': 'regular',
              'startMs': '1500.9',
              'endMs': 2000,
              'line': 'First line',
            },
            {
              'type': 'heading',
              'startMs': '2000',
              'endMs': 2500.7,
              'line': ' Section title ',
            },
            {
              'type': 'unexpected',
              'startMs': 2500,
              'endMs': 3000,
              'line': 'Last line',
            },
            {'type': 'regular', 'startMs': 'bad', 'line': 'Malformed'},
            {
              'type': 'regular',
              'startMs': 3000,
              'endMs': 3500,
              'line': '   ',
            },
            'not a cue',
          ],
        },
      });

      expect(transcript.label, 'English (auto-generated)');
      expect(transcript.languageCode, 'en');
      expect(transcript.lines, hasLength(3));
      expect(transcript.lines[0].type, VideoTranscriptLineType.regular);
      expect(transcript.lines[0].startMs, 0);
      expect(transcript.lines[0].endMs, 1500);
      expect(transcript.lines[0].text, 'First line');
      expect(transcript.lines[1].type, VideoTranscriptLineType.heading);
      expect(transcript.lines[1].startMs, 2000);
      expect(transcript.lines[1].endMs, 2500);
      expect(transcript.lines[2].type, VideoTranscriptLineType.regular);
    });

    test('throws only when the transcript structure is unusable', () {
      expect(
        () => VideoTranscript.fromJson({'transcript': 'invalid'}),
        throwsFormatException,
      );
      expect(
        () => VideoTranscript.fromJson({
          'transcript': {'body': 'invalid'},
        }),
        throwsFormatException,
      );
    });

    test('rejects nonfinite, negative and overflowing timings', () {
      final transcript = VideoTranscript.fromJson({
        'transcript': {
          'body': [
            for (final start in [double.nan, 'Infinity', -1, 1e100])
              {'startMs': start, 'endMs': 1000, 'line': 'Invalid start'},
            for (final end in [double.infinity, 'NaN', -1, 1e100])
              {'startMs': 0, 'endMs': end, 'line': 'Invalid end'},
            {'startMs': 1, 'endMs': 2, 'line': 'Valid'},
          ],
        },
      });

      expect(transcript.lines, hasLength(1));
      expect(transcript.lines.single.text, 'Valid');
    });

    test('retains zero-span section markers for the transcript reader', () {
      final transcript = VideoTranscript.fromJson({
        'transcript': {
          'body': [
            {
              'type': 'heading',
              'startMs': 0,
              'endMs': 0,
              'line': 'Introduction',
            },
            {'startMs': 0, 'endMs': 1000, 'line': 'First spoken line'},
          ],
        },
      });

      expect(transcript.lines, hasLength(2));
      expect(transcript.lines.first.type, VideoTranscriptLineType.heading);
      expect(transcript.plainText, 'Introduction\n\nFirst spoken line');
      expect(transcript.toWebVtt(), isNot(contains('Introduction')));
    });

    test('keeps repeated text at separate times when requested for playback',
        () {
      final transcript = VideoTranscript.fromJson({
        'transcript': {
          'body': [
            {'startMs': 1000, 'endMs': 2000, 'line': 'Repeated lyric'},
            {'startMs': 3000, 'endMs': 4000, 'line': 'Repeated lyric'},
          ],
        },
      }, preserveRepeatedLines: true);

      expect(transcript.lines, hasLength(2));
      expect(transcript.toWebVtt(), contains('00:00:03.000 --> 00:00:04.000'));
      expect(transcript.plainText, 'Repeated lyric');
    });
  });

  group('VideoTranscript.fromWebVtt', () {
    test('parses cues, markup, entities, settings, and timing variants', () {
      final transcript = VideoTranscript.fromWebVtt(
        'WEBVTT\r\n'
        '\r\n'
        'NOTE this block is ignored\r\n'
        'Nothing to see here\r\n'
        '\r\n'
        'cue-one\r\n'
        '00:01.250 --> 00:03,500 align:start position:10%\r\n'
        'Hello <b>world</b> &amp;\r\n'
        'friends &#39;today&#39;\r\n'
        '\r\n'
        'cue-two\r\n'
        '01:02:03.004 --> 01:02:05.006\r\n'
        'Long &lt;cue&gt; &#x41; &#66; &quot;quoted&quot;\r\n'
        '\r\n'
        'duplicate\r\n'
        '01:02:05.006 --> 01:02:06.000\r\n'
        'Long &lt;cue&gt; A B &quot;quoted&quot;\r\n',
        label: 'English',
        languageCode: 'en',
      );

      expect(transcript.label, 'English');
      expect(transcript.languageCode, 'en');
      expect(transcript.lines, hasLength(2));
      expect(transcript.lines[0].startMs, 1250);
      expect(transcript.lines[0].endMs, 3500);
      expect(transcript.lines[0].text, "Hello world & friends 'today'");
      expect(transcript.lines[1].startMs, 3723004);
      expect(transcript.lines[1].endMs, 3725006);
      expect(transcript.lines[1].text, 'Long <cue> A B "quoted"');
    });

    test('preserves repeated intervals and excludes invalid ones from playback',
        () {
      final transcript = VideoTranscript.fromWebVtt(
        'WEBVTT\n\n'
        '00:00.000 --> 00:01.000\nAgain\n\n'
        '00:02.000 --> 00:03.000\nAgain\n\n'
        '00:04.000 --> 00:04.000\nZero duration\n\n'
        '00:05.000 --> 00:04.000\nReversed\n\n'
        '99999999999:00:00.000 --> 99999999999:00:01.000\nOverflow\n',
        label: 'English',
        preserveRepeatedLines: true,
      );

      expect(transcript.lines, hasLength(4));
      expect(transcript.lines[1].startMs, 2000);
      expect(transcript.toWebVtt(), contains('00:00:02.000 --> 00:00:03.000'));
      expect(transcript.toWebVtt(), isNot(contains('Zero duration')));
      expect(transcript.toWebVtt(), isNot(contains('Reversed')));
    });
  });

  group('toWebVtt', () {
    for (final source in ['structured', 'WebVTT']) {
      test('$source decodes caption entities once and preserves bidi marks',
          () {
        const text = 'A&nbsp;B &lrm;English &rlm;Hebrew '
            '&amp;lt;tag&amp;gt; &#38;lt;numeric&#38;gt; &amp;nbsp; <b>Bold</b>';
        final transcript = source == 'structured'
            ? VideoTranscript.fromJson({
                'transcript': {
                  'body': [
                    {'startMs': 0, 'endMs': 1000, 'line': text},
                  ],
                },
              }, preserveRepeatedLines: true)
            : VideoTranscript.fromWebVtt(
                'WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n$text\n\n',
                label: 'English',
                preserveRepeatedLines: true,
              );

        expect(transcript.lines.single.text,
            'A\u00a0B \u200eEnglish \u200fHebrew &lt;tag&gt; &lt;numeric&gt; &nbsp; Bold');
        expect(
            transcript.toWebVtt(),
            'WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n'
            'A\u00a0B \u200eEnglish \u200fHebrew '
            '&amp;lt;tag&amp;gt; &amp;lt;numeric&amp;gt; &amp;nbsp; Bold\n\n');
      });
    }

    test('omits headings and escapes decoded text for subtitle rendering', () {
      final transcript = VideoTranscript.fromJson({
        'transcript': {
          'body': [
            {
              'type': 'heading',
              'startMs': 0,
              'endMs': 1000,
              'line': 'Section heading',
            },
            {
              'type': 'regular',
              'startMs': 3723004,
              'endMs': 3725006,
              'line':
                  'A &lt;cue&gt; &amp; &lt;img src="https://example.test/a"&gt;',
            },
          ],
        },
      }, preserveRepeatedLines: true);

      expect(
          transcript.toWebVtt(),
          'WEBVTT\n\n'
          '01:02:03.004 --> 01:02:05.006\n'
          'A &lt;cue&gt; &amp; &lt;img src="https://example.test/a"&gt;\n\n');
    });

    test('throws when there are no playable regular cues', () {
      final transcript = VideoTranscript(
        label: 'English',
        languageCode: 'en',
        lines: [
          VideoTranscriptLine(
              type: VideoTranscriptLineType.heading,
              startMs: 0,
              endMs: 1000,
              text: 'Heading'),
          for (final (start, end, text) in [
            (-1, 1000, 'Negative'),
            (0, 0, 'Zero'),
            (2000, 1000, 'Reversed'),
            (0, 0x7fffffffffffffff, 'Overflow'),
            (0, 1000, '   '),
          ])
            VideoTranscriptLine(
                type: VideoTranscriptLineType.regular,
                startMs: start,
                endMs: end,
                text: text),
        ],
      );

      expect(transcript.toWebVtt, throwsFormatException);
    });

    test('bounds 10 ms autogenerated markers by the next spoken cue', () {
      // Shape observed from the live Invidious transcript for M7lc1UVf-VE.
      final transcript = VideoTranscript.fromJson({
        'transcript': {
          'autoGenerated': true,
          'body': [
            {'startMs': 12070, 'endMs': 12080, 'line': 'First spoken line'},
            {
              'type': 'heading',
              'startMs': 13000,
              'endMs': 14000,
              'line': 'Heading',
            },
            {'startMs': 14470, 'endMs': 15340, 'line': 'A real duration'},
            {'startMs': 16310, 'endMs': 16320, 'line': 'Final marker'},
          ],
        },
      }, preserveRepeatedLines: true);

      expect(transcript.autoGenerated, isTrue);
      expect(transcript.lines.first.endMs, 12080);
      expect(
          transcript.toWebVtt(),
          'WEBVTT\n\n'
          '00:00:12.070 --> 00:00:14.470\nFirst spoken line\n\n'
          '00:00:14.470 --> 00:00:15.340\nA real duration\n\n'
          '00:00:16.310 --> 00:00:16.320\nFinal marker\n\n');
    });

    test('preserves short manual cues and out-of-order autogenerated cues', () {
      VideoTranscript transcript(bool automatic) => VideoTranscript.fromJson({
            'transcript': {
              'autoGenerated': automatic,
              'body': [
                {'startMs': 2000, 'endMs': 2010, 'line': 'Later'},
                {'startMs': 1000, 'endMs': 1010, 'line': 'Earlier'},
                {'startMs': 1000, 'endMs': 1010, 'line': 'Same time'},
              ],
            },
          }, preserveRepeatedLines: true);

      expect(transcript(true).toWebVtt(), transcript(false).toWebVtt());
      final manual = VideoTranscript.fromWebVtt(
        'WEBVTT\n\n'
        '00:00:01.000 --> 00:00:01.010\nShort\n\n'
        '00:00:02.000 --> 00:00:03.000\nLater\n',
        label: 'English',
        preserveRepeatedLines: true,
      );
      expect(manual.toWebVtt(), contains('00:00:01.000 --> 00:00:01.010'));
    });
  });

  group('plainText', () {
    for (final source in ['structured', 'WebVTT']) {
      test('$source copy preserves literal markup and nested entities', () {
        const input = '&lt;code&gt; &amp;lt;tag&amp;gt; '
            '&#38;lt;numeric&#38;gt; A&nbsp;B <b>Bold</b>';
        const expected = '<code> &lt;tag&gt; &lt;numeric&gt; A\u00a0B Bold';
        final transcript = source == 'structured'
            ? VideoTranscript.fromJson({
                'transcript': {
                  'body': [
                    {'startMs': 0, 'endMs': 1000, 'line': input},
                  ],
                },
              })
            : VideoTranscript.fromWebVtt(
                'WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n$input\n\n',
                label: 'English',
              );

        expect(transcript.lines.single.text, expected);
        expect(transcript.plainText, expected);
      });
    }

    test('omits timestamps and separates headings with blank lines', () {
      final transcript = VideoTranscript(
        label: 'English',
        languageCode: 'en',
        lines: [
          VideoTranscriptLine(
            type: VideoTranscriptLineType.regular,
            startMs: 0,
            endMs: 1000,
            text: 'First line  ',
          ),
          VideoTranscriptLine(
            type: VideoTranscriptLineType.heading,
            startMs: 1000,
            endMs: 2000,
            text: 'Heading',
          ),
          VideoTranscriptLine(
            type: VideoTranscriptLineType.regular,
            startMs: 2000,
            endMs: 3000,
            text: 'After heading',
          ),
          VideoTranscriptLine(
            type: VideoTranscriptLineType.regular,
            startMs: 3000,
            endMs: 4000,
            text: 'After heading',
          ),
        ],
      );

      expect(transcript.plainText, 'First line\n\nHeading\n\nAfter heading');
      expect(transcript.plainText, isNot(contains('0:')));
      expect(transcript.plainText, transcript.plainText.trimRight());
    });

    test('returns an empty string when no usable lines exist', () {
      final transcript = VideoTranscript(
        label: 'English',
        languageCode: 'en',
        lines: [
          VideoTranscriptLine(
            type: VideoTranscriptLineType.regular,
            startMs: 0,
            endMs: 1,
            text: '   ',
          ),
        ],
      );

      expect(transcript.plainText, isEmpty);
    });
  });
}
