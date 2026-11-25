typedef LrcLine = ({Duration start, String text});

const maxLyricsCharacters = 128 * 1024;
const _maxCues = 3000;
final _startTag = RegExp(r'\[(\d{1,3}):([0-5]\d)(?:[.:](\d{1,3}))?\]\s*');
final _numericTimePrefix = RegExp(r'\[\s*[+-]?\d+\s*[:.]');
final _metadata = RegExp(r'^\[[a-zA-Z]{2,16}:.*\]$');
final _offsetPrefix = RegExp(r'^\[offset\s*:', caseSensitive: false);
final _offsetValue =
    RegExp(r'^\[offset\s*:\s*([+-]?\d{1,8})\s*\]$', caseSensitive: false);
final _plainTimeTag = RegExp(r'^\[\s*[+-]?\d+\s*[:.][^\]\n]*\]\s*');
final _wordTime = RegExp(r'<\d{1,3}:[0-5]\d(?:[.:]\d{1,3})?>');
final _controls =
    RegExp(r'[\u0000-\u0009\u000b-\u001f\u007f\u202a-\u202e\u2066-\u2069]');

String cleanLyricsText(String? input) {
  if (input == null || input.length > maxLyricsCharacters) return '';
  return input
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceFirst('\uFEFF', '')
      .replaceAll('\t', ' ')
      .replaceAll(_controls, '')
      .trim();
}

/// Reads line timestamps in LRC. Repeated lines at different timestamps are
/// separate cues. Untimed metadata and word timestamps aren't display text.
List<LrcLine> parseLrc(String? input, {bool requireTimedText = false}) {
  final source = cleanLyricsText(input);
  if (source.isEmpty) return const [];
  final lines = <LrcLine>[];
  for (final raw in source.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || _metadata.hasMatch(line)) continue;
    final starts = <Duration>[];
    var offset = 0;
    while (true) {
      final tag = _startTag.matchAsPrefix(line, offset);
      if (tag == null) break;
      if (lines.length + starts.length >= _maxCues) return const [];
      final fraction = (tag.group(3) ?? '').padRight(3, '0');
      starts.add(Duration(
          minutes: int.parse(tag.group(1)!),
          seconds: int.parse(tag.group(2)!),
          milliseconds: int.parse(fraction)));
      offset = tag.end;
    }
    if (_numericTimePrefix.matchAsPrefix(line, offset) != null) return const [];
    if (starts.isEmpty) {
      if (requireTimedText) return const [];
      continue;
    }
    final text = line.substring(offset).replaceAll(_wordTime, '').trim();
    if (text.isEmpty) continue;
    for (final start in starts) {
      lines.add((start: start, text: text));
    }
  }
  // Include original index in the ordering so simultaneous lines retain order.
  final ordered = lines.indexed.toList()
    ..sort((a, b) {
      final timing = a.$2.start.compareTo(b.$2.start);
      return timing == 0 ? a.$1.compareTo(b.$1) : timing;
    });
  return List.unmodifiable(ordered.map((entry) => entry.$2));
}

/// A local file may contain both an LRC timeline and readable fallback text.
({List<LrcLine> cues, String plain}) parseLocalLrc(String? input) {
  final source = cleanLyricsText(input);
  if (source.isEmpty) return (cues: const [], plain: '');
  int? offset;
  var validOffset = true;
  final plainLines = <String>[];
  for (final raw in source.split('\n')) {
    var line = raw.trim();
    if (_offsetPrefix.hasMatch(line)) {
      final match = _offsetValue.firstMatch(line);
      final value = match == null ? null : int.parse(match.group(1)!);
      if (value == null || (offset != null && offset != value)) {
        validOffset = false;
      }
      offset = value;
      continue;
    }
    if (_metadata.hasMatch(line)) continue;
    while (true) {
      final tag = _plainTimeTag.firstMatch(line);
      if (tag == null) break;
      line = line.substring(tag.end);
    }
    plainLines.add(line.replaceAll(_wordTime, '').trim());
  }
  final plain = plainLines.join('\n').trim();
  if (!validOffset) return (cues: const [], plain: plain);
  final cues = parseLrc(source, requireTimedText: true);
  if (offset == null || offset == 0) return (cues: cues, plain: plain);
  // A positive LRC offset advances the cue relative to the audio.
  final shifted = cues.map((cue) {
    final milliseconds = cue.start.inMilliseconds - offset!;
    return (
      start: Duration(milliseconds: milliseconds < 0 ? 0 : milliseconds),
      text: cue.text,
    );
  });
  return (cues: List.unmodifiable(shifted), plain: plain);
}

/// Treat unsupported timestamp adjustments as plain text rather than seeking
/// with timing the parser has not applied.
bool lrcCanSynchronize(String input, List<LrcLine> cues, int? durationSeconds) {
  if (durationSeconds == null || durationSeconds <= 0 || cues.isEmpty) {
    return false;
  }
  final offsets = RegExp(r'^\s*\[offset:\s*([^\]]*)\]',
          multiLine: true, caseSensitive: false)
      .allMatches(input);
  return offsets.every((entry) => int.tryParse(entry.group(1)!.trim()) == 0) &&
      cues.last.start <= Duration(seconds: durationSeconds);
}
