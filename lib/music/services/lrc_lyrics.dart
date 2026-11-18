typedef LrcLine = ({Duration start, String text});

const maxLyricsCharacters = 128 * 1024;
const _maxCues = 3000;
final _startTag = RegExp(r'\[(\d{1,3}):([0-5]\d)(?:[.:](\d{1,3}))?\]\s*');
final _numericTimePrefix = RegExp(r'\[\s*[+-]?\d+\s*[:.]');
final _metadata = RegExp(r'^\[[a-zA-Z]{2,16}:.*\]$');
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
List<LrcLine> parseLrc(String? input) {
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
    if (starts.isEmpty) continue;
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
