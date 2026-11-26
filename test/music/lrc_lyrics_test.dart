import 'package:clipious/music/services/lrc_lyrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LRC retains refrain occurrences and sorts millisecond timestamps', () {
    final cues = parseLrc(
      '\uFEFF[ar:Fixture]\r\n'
      '[00:25.12][00:45.120]Refrain\r\n'
      '[00:03.1]<00:03.1>First line\r\n'
      '[00:25.12]Another voice',
    );
    expect(cues.map((cue) => cue.start.inMilliseconds), [
      3100,
      25120,
      25120,
      45120,
    ]);
    expect(cues.map((cue) => cue.text), [
      'First line',
      'Refrain',
      'Another voice',
      'Refrain',
    ]);
  });

  test('Enhanced LRC preserves display text and sorted UTF-16 word ranges', () {
    const input = '[00:08.00]Plain line\n'
        '[00:02.00] <00:02.110> 👋 <00:02.5>世界<00:03:123>！ <00:04.40>\n'
        '[00:01.00]Count in';
    final (:lines, :wordsByCue, displayTextByCue: _, breakStarts: _) =
        parseEnhancedLrc(input);
    expect(lines, parseLrc(input));
    expect(lines.map((line) => line.text), [
      'Count in',
      '👋 世界！',
      'Plain line',
    ]);
    expect(wordsByCue.keys, [1]);
    final words = wordsByCue[1]!;
    expect(words.map((word) => word.start.inMilliseconds), [2110, 2500, 3123]);
    expect(words.map((word) => (word.startOffset, word.endOffset)), [
      (0, 2),
      (3, 5),
      (5, 6),
    ]);
    expect(
      words.map(
        (word) => lines[1].text.substring(word.startOffset, word.endOffset),
      ),
      ['👋', '世界', '！'],
    );
  });

  test('unsuitable word timestamps retain the existing line cues', () {
    const input = '[00:01]<00:00.90>Early <00:01.10>word\n'
        '[00:02]<00:02.1>Runs <00:02.09>backwards\n'
        '[00:03]<00:03.01>Same <00:03.01>time\n'
        '[00:04]<00:04.01>Bad <00:60.12>timestamp\n'
        '[00:05][00:09]<00:05.01>Repeat\n'
        '[00:06]<00:06.02>Overlaps <00:07>next line\n'
        '[00:07]Plain\n'
        '[00:10]<00:10.50>Reaches <00:11>playback end';
    final (:lines, :wordsByCue, displayTextByCue: _, breakStarts: _) =
        parseEnhancedLrc(
      input,
      playbackDuration: const Duration(seconds: 11),
    );
    expect(lines, parseLrc(input));
    expect(lines.where((line) => line.text == 'Repeat'), hasLength(2));
    expect(wordsByCue, isEmpty);
  });

  test('simultaneous lines can each carry independent word timing', () {
    const input = '[00:01]<00:01>Lead <00:01.5>voice\n'
        '[00:01]Chorus: <00:01.2>First <00:01.8>echo\n'
        '[00:02]Next';
    final (:lines, :wordsByCue, displayTextByCue: _, breakStarts: _) =
        parseEnhancedLrc(input);
    expect(wordsByCue.keys, [0, 1]);
    expect(
        wordsByCue[0]!.map((word) => word.start.inMilliseconds), [1000, 1500]);
    final chorus = wordsByCue[1]!.first;
    expect(
        lines[1].text.substring(chorus.startOffset, chorus.endOffset), 'First');
    expect(chorus.start.inMilliseconds, 1200);
  });

  test('continuation text follows file order across repeated and sorted cues',
      () {
    const source = '[ar:Fixture]\r\n'
        '[00:08]  <00:08>👋 <00:08.50>again  \r\n'
        '  Translation  \r\n'
        '\r\n'
        '[00:01] [00:15]Refrain\r\n'
        ' Refrain translation\r\n'
        '[ti:Fixture]\r\n'
        '[00:16]Last   ';
    final parsed = parseEnhancedLrc(source);
    expect(parsed.lines, parseLrc(source));
    expect(parsed.lines.map((cue) => cue.start.inSeconds), [1, 8, 15, 16]);
    expect(parsed.lines.map((cue) => cue.text),
        ['Refrain', '👋 again', 'Refrain', 'Last']);
    expect(parsed.displayTextByCue, {
      0: 'Refrain\n Refrain translation',
      1: '  👋 again  \n  Translation  \n',
      2: 'Refrain\n Refrain translation',
      3: 'Last   ',
    });
    final word = parsed.wordsByCue[1]!.last;
    expect(word, (
      start: const Duration(milliseconds: 8500),
      startOffset: 3,
      endOffset: 8,
    ));

    final local = parseLocalLrc(source);
    expect(local.cues, parsed.lines);
    expect(local.displayTextByCue, parsed.displayTextByCue);
    expect(local.wordsByCue, parsed.wordsByCue);
  });

  test('sync checks the adjusted cues against the playback duration', () {
    const text = '[offset:+500]\n[00:03.50]First line\n[OFFSET:500]';
    final cues = parseEnhancedLrc(text).lines;
    expect(cues.single.start, const Duration(seconds: 3));
    expect(lrcFitsDuration(cues, null), isFalse);
    expect(lrcFitsDuration(cues, 2), isFalse);
    expect(lrcFitsDuration(cues, 3), isTrue);
    expect(lrcFitsDuration([], 3), isFalse);
  });

  test('rejects excessive input and leaves lyric content as text', () {
    expect(parseLrc('x' * (maxLyricsCharacters + 1)), isEmpty);
    expect(cleanLyricsText('\uFEFFLine\r\n<example>\u0000'), 'Line\n<example>');
  });

  test('local LRC applies a file-wide offset and keeps pre-zero cue starts',
      () {
    final earlier = parseLocalLrc('[ar:Fixture]\n'
        '[00:00.050][00:02.125]Repeat\n'
        '[00:02.125]Another voice\n'
        '[OFFSET:+125]');
    expect(
        earlier.cues.map((cue) => cue.start.inMilliseconds), [-75, 2000, 2000]);
    expect(earlier.cues.map((cue) => cue.text),
        ['Repeat', 'Repeat', 'Another voice']);
    final later = parseLocalLrc('[offset: -250]\n[00:00.500]Line');
    expect(later.cues.single.start.inMilliseconds, 750);
  });

  test('local Enhanced LRC advances words and respects the track end', () {
    const input = '[offset:+500]\n'
        '[00:00.100]<00:00.100>One <00:00.400>two <00:00.800>three\n'
        '[00:02.500]<00:02.500>Last <00:04.500>past the end';
    final parsed =
        parseLocalLrc(input, playbackDuration: const Duration(seconds: 4));
    expect(parsed.cues.map((cue) => cue.start.inMilliseconds), [-400, 2000]);
    expect(parsed.cues.map((cue) => cue.text),
        ['One two three', 'Last past the end']);
    expect(parsed.wordsByCue.keys, [0]);
    expect(parsed.wordsByCue[0]!.map((word) => word.start.inMilliseconds),
        [-400, -100, 300]);
    expect(parsed.wordsByCue[0]!.map((word) => word.startOffset), [0, 4, 8]);
  });

  test('timed blanks retain adjusted starts without shifting display rows', () {
    const input = '[offset:+500]\n'
        '[00:06.500][00:09.000]\n'
        '[00:00.200]\n'
        '[00:01.500]<00:01.500>First <00:01.900>line\n'
        '\n'
        '[00:07.500]<00:07.500>Second <00:08.000>line';
    const duration = Duration(seconds: 7);
    final enhanced = parseEnhancedLrc(input, playbackDuration: duration);
    final local = parseLocalLrc(input, playbackDuration: duration);

    expect(
        enhanced.lines.map((cue) => cue.text), ['First line', 'Second line']);
    expect(enhanced.wordsByCue.keys, [0]);
    expect(enhanced.breakStarts.map((start) => start.inMilliseconds),
        [-300, 6000]);
    expect(local.cues, enhanced.lines);
    expect(local.wordsByCue, enhanced.wordsByCue);
    expect(local.breakStarts, enhanced.breakStarts);
    expect(
        parseLrc(input).map((cue) => cue.start.inMilliseconds), [1500, 7500]);
    expect(parseEnhancedLrc('[00:01]\n[00:02]').breakStarts, isEmpty);
  });

  test('breaks count toward the enhanced timestamp limit', () {
    final input = '[00:01]First\n${'[00:02]\n' * maxLrcCues}';
    expect(parseEnhancedLrc(input).lines, isEmpty);
    expect(parseLocalLrc(input).plain, 'First');
    expect(parseLrc(input).single.text, 'First');
  });

  test('local LRC retains readable text when timing is unsafe', () {
    for (final source in [
      '[offset:unknown]\n[00:01]Start\n[00:02]Finish',
      '[offset:+1]\n[00:01]Start\n[00:02]Finish\n[offset:-1]',
      '[00:01]<00:01.250>Start\n[00:99]Finish',
      'Start\n[00:02]Finish',
    ]) {
      final lyrics = parseLocalLrc(source);
      expect(lyrics.cues, isEmpty, reason: source);
      expect(lyrics.plain, 'Start\nFinish', reason: source);
    }
    expect(parseLocalLrc('[ti:Fixture]\n[offset:0]').plain, isEmpty);
  });
}
