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

  test('local LRC applies a file-wide millisecond offset and clamps to zero',
      () {
    final earlier = parseLocalLrc('[ar:Fixture]\n'
        '[00:00.050][00:02.125]Repeat\n'
        '[00:02.125]Another voice\n'
        '[OFFSET:+125]');
    expect(
        earlier.cues.map((cue) => cue.start.inMilliseconds), [0, 2000, 2000]);
    expect(earlier.cues.map((cue) => cue.text),
        ['Repeat', 'Repeat', 'Another voice']);
    final later = parseLocalLrc('[offset: -250]\n[00:00.500]Line');
    expect(later.cues.single.start.inMilliseconds, 750);
  });

  test('local LRC retains readable text when timing is unsafe', () {
    for (final source in [
      '[offset:unknown]\n[00:01]Start\n[00:02]Finish',
      '[offset:+1]\n[00:01]Start\n[00:02]Finish\n[offset:-1]',
      '[00:01]<00:01.250>Start\n[00:99]Finish',
      '[00:01]Start\nFinish',
    ]) {
      final lyrics = parseLocalLrc(source);
      expect(lyrics.cues, isEmpty, reason: source);
      expect(lyrics.plain, 'Start\nFinish', reason: source);
    }
    expect(parseLocalLrc('[ti:Fixture]\n[offset:0]').plain, isEmpty);
  });
}
