import '../models/music_lyrics.dart';

typedef LrcLine = ({Duration start, String text});
typedef EnhancedLrc = ({
  List<LrcLine> lines,
  Map<int, List<MusicLyricWord>> wordsByCue,
  Map<int, String> displayTextByCue,
  List<Duration> breakStarts,
});

const maxLyricsCharacters = 128 * 1024;
const maxLrcCues = 3000;

/// The minute, second and optional fractional groups inside an LRC timestamp.
const lrcTimestampPattern = r'(\d{1,3}):([0-5]\d)(?:[.:](\d{1,3}))?';

const EnhancedLrc _emptyLrc =
    (lines: [], wordsByCue: {}, displayTextByCue: {}, breakStarts: []);
final _startTag = RegExp('\\[$lrcTimestampPattern\\](\\s*)');
final _numericTimePrefix = RegExp(r'\[\s*[+-]?\d+\s*[:.]');
final _metadata = RegExp(r'^\[[a-zA-Z]{2,16}:.*\]$');
final _offsetPrefix = RegExp(r'^\[offset\s*:', caseSensitive: false);
final _offsetValue =
    RegExp(r'^\[offset\s*:\s*([+-]?\d{1,8})\s*\]$', caseSensitive: false);
final _plainTimeTag = RegExp(r'^\[\s*[+-]?\d+\s*[:.][^\]\n]*\]\s*');
final _wordTime = RegExp('<$lrcTimestampPattern>');
final _numericWordTimePrefix = RegExp(r'<\s*[+-]?\d+\s*[:.]');
final _controls = RegExp(
  r'[\u0000-\u0009\u000b-\u001f\u007f\u202a-\u202e\u2066-\u2069]',
);

String cleanLyricsText(String? input) => normalizeLyricsText(input).trim();

/// Sanitizes lyric text without removing its surrounding whitespace.
String normalizeLyricsText(String? input) {
  if (input == null || input.length > maxLyricsCharacters) return '';
  return input
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceFirst('\uFEFF', '')
      .replaceAll('\t', ' ')
      .replaceAll(_controls, '');
}

/// Reads line timestamps in LRC. Repeated lines at different timestamps are
/// separate cues. Untimed metadata and word timestamps aren't display text.
List<LrcLine> parseLrc(String? input, {bool requireTimedText = false}) =>
    _parseLrc(input, requireTimedText: requireTimedText).lines;

/// Reads Enhanced LRC words and blank timestamps alongside display cues.
/// Applies the embedded offset to lines, words and breaks.
/// Starts before playback zero keep their spacing for later timing adjustments.
EnhancedLrc parseEnhancedLrc(String? input, {Duration? playbackDuration}) =>
    _parseLrc(input, enhanced: true, playbackDuration: playbackDuration);

EnhancedLrc _parseLrc(
  String? input, {
  bool enhanced = false,
  bool requireTimedText = false,
  Duration? playbackDuration,
}) {
  final source = normalizeLyricsText(input);
  if (source.trim().isEmpty) return _emptyLrc;
  final lines = <LrcLine>[];
  final breaks = <Duration>[];
  final wordsByInputIndex = <int, List<MusicLyricWord>>{};
  final displayByInputIndex = <int, String>{};
  final continuation = StringBuffer();
  int? displayStart;

  void finishDisplayText() {
    if (displayStart case final start?) {
      final text = continuation.toString();
      if (text != lines[start].text) {
        for (var index = start; index < lines.length; index++) {
          displayByInputIndex[index] = text;
        }
      }
      displayStart = null;
      continuation.clear();
    }
  }

  int? advanceMilliseconds;
  final sourceLines = source.split('\n');
  if (sourceLines.last.isEmpty) sourceLines.removeLast();
  for (final raw in sourceLines) {
    final line = raw.trimLeft();
    final trimmed = line.trimRight();
    if (_offsetPrefix.hasMatch(trimmed)) {
      if (enhanced) {
        final value =
            int.tryParse(_offsetValue.firstMatch(trimmed)?.group(1) ?? '');
        if (value == null ||
            (advanceMilliseconds != null && advanceMilliseconds != value)) {
          return _emptyLrc;
        }
        advanceMilliseconds = value;
      }
      continue;
    }
    if (_metadata.hasMatch(trimmed)) continue;
    final starts = <Duration>[];
    var offset = 0;
    var textStart = 0;
    while (true) {
      final tag = _startTag.matchAsPrefix(line, offset);
      if (tag == null) break;
      if (lines.length + breaks.length + starts.length >= maxLrcCues) {
        return _emptyLrc;
      }
      starts.add(lrcTimestampDuration(tag));
      offset = tag.end;
      textStart = offset - tag.group(4)!.length;
    }
    if (_numericTimePrefix.matchAsPrefix(line, offset) != null) {
      return _emptyLrc;
    }
    if (starts.isEmpty) {
      if (displayStart != null) {
        continuation.write('\n');
        continuation.write(raw.replaceAll(_wordTime, ''));
      } else if (requireTimedText && line.isNotEmpty) {
        return _emptyLrc;
      }
      continue;
    }
    finishDisplayText();
    final taggedText = line.substring(textStart);
    final rawText = taggedText.replaceAll(_wordTime, '');
    final text = rawText.trim();
    if (text.isEmpty) {
      if (enhanced) breaks.addAll(starts);
      continue;
    }
    // Absolute word timestamps cannot be assigned to multiple refrain times.
    if (enhanced) {
      if (starts.length == 1) {
        final words = _parseWords(taggedText, rawText, starts.single);
        if (words.isNotEmpty) wordsByInputIndex[lines.length] = words;
      }
      displayStart = lines.length;
      continuation.write(rawText);
    }
    for (final start in starts) {
      lines.add((start: start, text: text));
    }
  }
  finishDisplayText();
  if (lines.isEmpty) return _emptyLrc;

  // A positive LRC offset advances every timestamp by the same amount.
  final advance = Duration(milliseconds: advanceMilliseconds ?? 0);
  final adjustedBreaks = [for (final start in breaks) start - advance]..sort();
  if (playbackDuration != null) {
    adjustedBreaks.removeWhere((start) => start > playbackDuration);
  }
  final breakStarts = List<Duration>.unmodifiable(adjustedBreaks);
  // Include original index in the ordering so simultaneous lines retain order.
  final ordered = lines.indexed.toList()
    ..sort((a, b) {
      final timing = a.$2.start.compareTo(b.$2.start);
      return timing == 0 ? a.$1.compareTo(b.$1) : timing;
    });
  final sortedLines = List<LrcLine>.unmodifiable(
    ordered.map((entry) {
      final cue = entry.$2;
      return advance == Duration.zero
          ? cue
          : (start: cue.start - advance, text: cue.text);
    }),
  );
  final displayTextByCue = Map<int, String>.unmodifiable({
    for (final (index, (inputIndex, _)) in ordered.indexed)
      if (displayByInputIndex[inputIndex] case final text?) index: text,
  });
  if (wordsByInputIndex.isEmpty) {
    return (
      lines: sortedLines,
      wordsByCue: const {},
      displayTextByCue: displayTextByCue,
      breakStarts: breakStarts,
    );
  }

  final wordsByCue = <int, List<MusicLyricWord>>{};
  var nextCueIndex = 0;
  for (final (index, (inputIndex, line)) in ordered.indexed) {
    // Simultaneous lines are active together and share the same time window.
    while (nextCueIndex < ordered.length &&
        ordered[nextCueIndex].$2.start <= line.start) {
      nextCueIndex++;
    }
    final inputWords = wordsByInputIndex[inputIndex];
    if (inputWords == null) continue;
    final lastWord = inputWords.last.start - advance;
    if ((playbackDuration != null && lastWord >= playbackDuration) ||
        (nextCueIndex < ordered.length &&
            inputWords.last.start >= ordered[nextCueIndex].$2.start)) {
      continue;
    }
    wordsByCue[index] = advance == Duration.zero
        ? inputWords
        : List.unmodifiable(inputWords.map((word) => (
              start: word.start - advance,
              startOffset: word.startOffset,
              endOffset: word.endOffset,
            )));
  }
  return (
    lines: sortedLines,
    wordsByCue: Map.unmodifiable(wordsByCue),
    displayTextByCue: displayTextByCue,
    breakStarts: breakStarts,
  );
}

/// Converts groups 1–3 from a match of [lrcTimestampPattern] into a time.
Duration lrcTimestampDuration(Match tag) => Duration(
      minutes: int.parse(tag.group(1)!),
      seconds: int.parse(tag.group(2)!),
      milliseconds: int.parse((tag.group(3) ?? '').padRight(3, '0')),
    );

List<MusicLyricWord> _parseWords(
  String taggedText,
  String rawText,
  Duration lineStart,
) {
  final tags = _wordTime.allMatches(taggedText).toList(growable: false);
  if (tags.isEmpty || _numericWordTimePrefix.hasMatch(rawText)) return const [];

  final words = <MusicLyricWord>[];
  final leadingWhitespace = rawText.length - rawText.trimLeft().length;
  var offset = tags.first.start - leadingWhitespace;
  Duration? previousStart;
  for (final (index, tag) in tags.indexed) {
    final start = lrcTimestampDuration(tag);
    if (start < lineStart ||
        (previousStart != null && start <= previousStart)) {
      return const [];
    }
    final nextOffset =
        index + 1 < tags.length ? tags[index + 1].start : taggedText.length;
    final segment = taggedText.substring(tag.end, nextOffset);
    final leftTrimmed = segment.trimLeft();
    final word = leftTrimmed.trimRight();
    if (word.isNotEmpty) {
      final startOffset = offset + segment.length - leftTrimmed.length;
      words.add((
        start: start,
        startOffset: startOffset,
        endOffset: startOffset + word.length,
      ));
    }
    offset += segment.length;
    previousStart = start;
  }
  return List.unmodifiable(words);
}

/// A local file may contain both an LRC timeline and readable fallback text.
({
  List<LrcLine> cues,
  String plain,
  Map<int, List<MusicLyricWord>> wordsByCue,
  Map<int, String> displayTextByCue,
  List<Duration> breakStarts,
}) parseLocalLrc(String? input, {Duration? playbackDuration}) {
  final source = cleanLyricsText(input);
  if (source.isEmpty) {
    return (
      cues: const [],
      plain: '',
      wordsByCue: const {},
      displayTextByCue: const {},
      breakStarts: const [],
    );
  }
  final plainLines = <String>[];
  for (final raw in source.split('\n')) {
    var line = raw.trim();
    if (_offsetPrefix.hasMatch(line) || _metadata.hasMatch(line)) continue;
    while (true) {
      final tag = _plainTimeTag.firstMatch(line);
      if (tag == null) break;
      line = line.substring(tag.end);
    }
    plainLines.add(line.replaceAll(_wordTime, '').trim());
  }
  final plain = plainLines.join('\n').trim();
  final parsed = _parseLrc(
    input,
    requireTimedText: true,
    enhanced: true,
    playbackDuration: playbackDuration,
  );
  return (
    cues: parsed.lines,
    plain: plain,
    wordsByCue: parsed.wordsByCue,
    displayTextByCue: parsed.displayTextByCue,
    breakStarts: parsed.breakStarts,
  );
}

bool lrcFitsDuration(List<LrcLine> cues, int? durationSeconds) =>
    durationSeconds != null &&
    durationSeconds > 0 &&
    cues.isNotEmpty &&
    cues.last.start <= Duration(seconds: durationSeconds);
