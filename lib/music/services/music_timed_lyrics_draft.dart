import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/services/lrc_lyrics.dart';

final _lineTime = RegExp('\\[$lrcTimestampPattern\\]');
final _wordTime = RegExp('<$lrcTimestampPattern>');
final _wordOrTime = RegExp(
    '${_wordTime.pattern}|(?:(?!${_wordTime.pattern})\\S)+',
    unicode: true);
final _timeLikeWord = RegExp(r'<\s*[+-]?\d+\s*[:.]');
final _metadata = RegExp(r'^\[[a-zA-Z]{2,16}:.*\]$');
final _offset = RegExp(r'^\[offset:\s*([^\]]*)\]$', caseSensitive: false);
final _space = RegExp(r'\s*');

/// Validates authored text without silently omitting invalid lines or words.
String? validatedMusicTimedLyricsDraft(String text, Duration playbackDuration) {
  final source = cleanLyricsText(text);
  if (source.isEmpty || playbackDuration <= Duration.zero) return null;

  var expectedLines = 0;
  var expectedBreaks = 0;
  var expectedWords = 0;
  for (final raw in source.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (_metadata.hasMatch(line)) {
      final adjustment = _offset.firstMatch(line);
      if (adjustment != null && int.tryParse(adjustment[1]!.trim()) != 0) {
        return null;
      }
      continue;
    }

    final lineStarts = _lineStamps(line, 0).toList();
    if (lineStarts.isEmpty) return null;
    final body = line.substring(lineStarts.last.end);
    if (body.trim().isEmpty) {
      expectedBreaks += lineStarts.length;
      continue;
    }
    expectedLines += lineStarts.length;
    if (_timeLikeWord.hasMatch(body.replaceAll(_wordTime, ''))) return null;

    final words = _wordTime.allMatches(body).toList();
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      final isLast = i == words.length - 1;
      final end = isLast ? body.length : words[i + 1].start;
      if (body.substring(word.end, end).trim().isNotEmpty) {
        expectedWords++;
      } else {
        // Enhanced LRC can end a line with one bare end timestamp.
        if (!isLast || i == 0) return null;
        final endTime = lrcTimestampDuration(word);
        if (endTime <= lrcTimestampDuration(words[i - 1]) ||
            endTime > playbackDuration) {
          return null;
        }
      }
    }
  }

  final parsed = parseEnhancedLrc(source, playbackDuration: playbackDuration);
  if (parsed.lines.isEmpty ||
      parsed.lines.length != expectedLines ||
      parsed.breakStarts.length != expectedBreaks ||
      parsed.lines.last.start >= playbackDuration ||
      parsed.wordsByCue.values
              .fold(0, (count, words) => count + words.length) !=
          expectedWords) {
    return null;
  }
  return source;
}

/// Seeds editable text from the authorized lyric source shown in the reader.
String musicTimedLyricsDraftFrom(MusicLyrics lyrics,
    {bool includeWordTiming = true}) {
  final raw = lyrics.text;
  if (raw != null) return raw;
  final buffer = StringBuffer();
  final timed = lyrics.kind == MusicLyricsKind.synced;
  var breakIndex = 0;

  void writeBreak() {
    final start = lyrics.breakStarts[breakIndex++];
    buffer.writeln('[${formatMusicLyricsTimestamp(start)}]');
  }

  for (final (index, cue) in lyrics.cues.indexed) {
    while (breakIndex < lyrics.breakStarts.length &&
        lyrics.breakStarts[breakIndex] <= cue.start) {
      writeBreak();
    }
    if (timed) buffer.write('[${formatMusicLyricsTimestamp(cue.start)}]');
    final displayed = lyrics.displayTextByCue[index] ?? cue.text;
    final leftPadding = (displayed.length - displayed.trimLeft().length) -
        (cue.text.length - cue.text.trimLeft().length);
    final words = timed && includeWordTiming ? lyrics.wordsByCue[index] : null;
    var offset = 0;
    if (words != null) {
      for (final (wordIndex, word) in words.indexed) {
        // LRC drafts cannot represent negative starts. Keep the word that
        // was active at zero when earlier words share its printed time.
        if (wordIndex + 1 < words.length &&
            words[wordIndex + 1].start <= Duration.zero) {
          continue;
        }
        final start = leftPadding + word.startOffset;
        buffer.write(displayed.substring(offset, start));
        buffer.write('<${formatMusicLyricsTimestamp(word.start)}>');
        offset = start;
      }
    }
    buffer.writeln(displayed.substring(offset));
    if (buffer.length > maxLyricsCharacters) return '';
  }
  while (breakIndex < lyrics.breakStarts.length) {
    writeBreak();
    if (buffer.length > maxLyricsCharacters) return '';
  }
  final draft = buffer.toString();
  return draft.isEmpty ? draft : draft.substring(0, draft.length - 1);
}

String formatMusicLyricsTimestamp(Duration position) {
  if (position < Duration.zero) return '00:00.000';
  final minutes = position.inMinutes.toString().padLeft(2, '0');
  final seconds = position.inSeconds.remainder(60).toString().padLeft(2, '0');
  final milliseconds =
      position.inMilliseconds.remainder(1000).toString().padLeft(3, '0');
  return '$minutes:$seconds.$milliseconds';
}

typedef MusicTimedLyricsEdit = ({String text, int caretOffset});
typedef _TextRange = ({int start, int end});

/// Times the current line or word, replacing a timestamp that it already has.
MusicTimedLyricsEdit? stampMusicTimedLyricsDraft(
  String text, {
  required int caretOffset,
  required Duration position,
  required Duration playbackDuration,
  required bool word,
}) {
  if (text.length > maxLyricsCharacters ||
      playbackDuration.inMilliseconds < 1) {
    return null;
  }
  final stampTime = Duration(
    milliseconds:
        position.inMilliseconds.clamp(0, playbackDuration.inMilliseconds - 1),
  );
  if (stampTime.inMinutes > 999) return null;
  final time = formatMusicLyricsTimestamp(stampTime);
  final stamp = word ? '<$time>' : '[$time]';

  final caret = caretOffset.clamp(0, text.length);
  final lineStart = caret == 0 ? 0 : text.lastIndexOf('\n', caret - 1) + 1;
  final nextLine = text.indexOf('\n', caret);
  final line =
      text.substring(lineStart, nextLine == -1 ? text.length : nextLine);
  final indent = _space.matchAsPrefix(line)!.end;
  final range = word
      ? _wordRange(line, indent, caret - lineStart)
      : _lineRange(line, indent);
  final from = lineStart + range.start;
  final to = lineStart + range.end;
  final delta = stamp.length - (to - from);
  if (text.length + delta > maxLyricsCharacters) return null;
  return (
    text: text.replaceRange(from, to, stamp),
    caretOffset: caret >= to ? caret + delta : from + stamp.length,
  );
}

Iterable<Match> _lineStamps(String line, int start) sync* {
  var offset = start;
  while (true) {
    final tag = _lineTime.matchAsPrefix(line, offset);
    if (tag == null) break;
    yield tag;
    offset = _space.matchAsPrefix(line, tag.end)!.end;
  }
}

_TextRange _lineRange(String line, int indent) =>
    (start: indent, end: _lineTime.matchAsPrefix(line, indent)?.end ?? indent);

_TextRange _wordRange(String line, int indent, int caret) {
  var contentStart = indent;
  for (final tag in _lineStamps(line, indent)) {
    contentStart = _space.matchAsPrefix(line, tag.end)!.end;
  }
  final offset = caret.clamp(contentStart, line.length);
  RegExpMatch? precedingTime;
  for (final part in _wordOrTime.allMatches(line, contentStart)) {
    if (_wordTime.matchAsPrefix(line, part.start) != null) {
      if (offset >= part.start && offset < part.end) {
        return (start: part.start, end: part.end);
      }
      precedingTime = part;
    } else {
      if (offset <= part.end) {
        return precedingTime == null
            ? (start: part.start, end: part.start)
            : (start: precedingTime.start, end: precedingTime.end);
      }
      precedingTime = null;
    }
  }
  return (start: offset, end: offset);
}
