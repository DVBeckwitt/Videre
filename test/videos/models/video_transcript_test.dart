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
  });

  group('plainText', () {
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
