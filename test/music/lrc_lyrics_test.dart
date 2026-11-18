import 'package:clipious/music/services/lrc_lyrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LRC retains refrain occurrences and sorts millisecond timestamps', () {
    final cues = parseLrc('\uFEFF[ar:Fixture]\r\n'
        '[00:25.12][00:45.120]Refrain\r\n'
        '[00:03.1]<00:03.1>First line\r\n'
        '[00:25.12]Another voice');
    expect(cues.map((cue) => cue.start.inMilliseconds),
        [3100, 25120, 25120, 45120]);
    expect(cues.map((cue) => cue.text),
        ['First line', 'Refrain', 'Another voice', 'Refrain']);
  });

  test('sync requires playback duration and supported LRC metadata', () {
    const text = '[offset:150]\n[00:03.50]First line';
    expect(lrcCanSynchronize(text, parseLrc(text), 10), isFalse);
    const zero = '[offset:+0]\n[00:03.50]First line';
    final cues = parseLrc(zero);
    expect(lrcCanSynchronize(zero, cues, null), isFalse);
    expect(lrcCanSynchronize(zero, cues, 2), isFalse);
    expect(lrcCanSynchronize(zero, cues, 10), isTrue);
    expect(lrcCanSynchronize('[offset:]\n$zero', cues, 10), isFalse);
  });

  test('rejects excessive input and leaves lyric content as text', () {
    expect(parseLrc('x' * (maxLyricsCharacters + 1)), isEmpty);
    expect(cleanLyricsText('\uFEFFLine\r\n<example>\u0000'), 'Line\n<example>');
  });
}
