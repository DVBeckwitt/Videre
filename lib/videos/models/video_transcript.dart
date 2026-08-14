enum VideoTranscriptLineType { heading, regular }

class VideoTranscriptLine {
  final VideoTranscriptLineType type;
  final int startMs;
  final int endMs;
  final String text;

  const VideoTranscriptLine({
    required this.type,
    required this.startMs,
    required this.endMs,
    required this.text,
  });
}

class VideoTranscript {
  final String label;
  final String? languageCode;
  final List<VideoTranscriptLine> lines;

  const VideoTranscript({
    required this.label,
    required this.languageCode,
    required this.lines,
  });

  factory VideoTranscript.fromJson(Map<String, dynamic> json) {
    final transcriptValue = json['transcript'];
    if (transcriptValue is! Map) {
      throw const FormatException('Missing transcript object');
    }

    final transcript = transcriptValue;
    final body = transcript['body'];
    if (body is! List) {
      throw const FormatException('Missing transcript body');
    }

    final lines = <VideoTranscriptLine>[];
    for (final entryValue in body) {
      if (entryValue is! Map) continue;
      final entry = entryValue;
      final startMs = _parseMilliseconds(entry['startMs']);
      final endMs = _parseMilliseconds(entry['endMs']);
      final lineValue = entry['line'];
      if (startMs == null || endMs == null || lineValue is! String) continue;

      final text = _cleanText(lineValue);
      if (text.isEmpty || (lines.isNotEmpty && lines.last.text == text)) {
        continue;
      }

      lines.add(VideoTranscriptLine(
        type: entry['type'] == 'heading'
            ? VideoTranscriptLineType.heading
            : VideoTranscriptLineType.regular,
        startMs: startMs,
        endMs: endMs,
        text: text,
      ));
    }

    return VideoTranscript(
      label: transcript['label'] is String ? transcript['label'] as String : '',
      languageCode: transcript['languageCode'] is String
          ? transcript['languageCode'] as String
          : null,
      lines: lines,
    );
  }

  factory VideoTranscript.fromWebVtt(
    String webVtt, {
    required String label,
    String? languageCode,
  }) {
    final source = webVtt
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceFirst('\uFEFF', '');
    final sourceLines = source.split('\n');
    final transcriptLines = <VideoTranscriptLine>[];

    for (var index = 0; index < sourceLines.length; index++) {
      final timing = _parseTimingLine(sourceLines[index]);
      if (timing == null) continue;

      final cueText = <String>[];
      index++;
      while (
          index < sourceLines.length && sourceLines[index].trim().isNotEmpty) {
        if (_parseTimingLine(sourceLines[index]) != null) {
          index--;
          break;
        }
        cueText.add(sourceLines[index]);
        index++;
      }

      final text = _cleanText(cueText.join(' '));
      if (text.isEmpty ||
          (transcriptLines.isNotEmpty && transcriptLines.last.text == text)) {
        continue;
      }
      transcriptLines.add(VideoTranscriptLine(
        type: VideoTranscriptLineType.regular,
        startMs: timing.$1,
        endMs: timing.$2,
        text: text,
      ));
    }

    return VideoTranscript(
      label: label,
      languageCode: languageCode,
      lines: transcriptLines,
    );
  }

  String get plainText {
    final blocks = <String>[];
    final regularLines = <String>[];
    String? previousText;

    void flushRegularLines() {
      if (regularLines.isNotEmpty) {
        blocks.add(regularLines.join('\n'));
        regularLines.clear();
      }
    }

    for (final line in lines) {
      final text = _cleanText(line.text);
      if (text.isEmpty || text == previousText) continue;
      previousText = text;

      if (line.type == VideoTranscriptLineType.heading) {
        flushRegularLines();
        blocks.add(text);
      } else {
        regularLines.add(text);
      }
    }
    flushRegularLines();

    return blocks.join('\n\n').trimRight();
  }

  static int? _parseMilliseconds(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return num.tryParse(value)?.toInt();
    return null;
  }

  static (int, int)? _parseTimingLine(String line) {
    final separator = line.indexOf('-->');
    if (separator < 0) return null;

    final start = _parseTimestamp(line.substring(0, separator).trim());
    final endAndSettings = line.substring(separator + 3).trim();
    final endToken = endAndSettings.split(RegExp(r'\s+')).first;
    final end = _parseTimestamp(endToken);
    if (start == null || end == null) return null;
    return (start, end);
  }

  static int? _parseTimestamp(String value) {
    final match = RegExp(
      r'^(?:(\d+):)?(\d{1,2}):(\d{2})(?:[\.,](\d{1,3}))?$',
    ).firstMatch(value);
    if (match == null) return null;

    final hours = int.tryParse(match.group(1) ?? '0');
    final minutes = int.tryParse(match.group(2)!);
    final seconds = int.tryParse(match.group(3)!);
    if (hours == null || minutes == null || seconds == null) return null;
    if (minutes > 59 && match.group(1) != null || seconds > 59) return null;

    final fraction = match.group(4) ?? '';
    final milliseconds = fraction.isEmpty
        ? 0
        : int.parse(fraction.padRight(3, '0').substring(0, 3));
    return (((hours * 60) + minutes) * 60 + seconds) * 1000 + milliseconds;
  }

  static String _cleanText(String value) {
    var text = value.replaceAll(RegExp(r'<[^>]*>'), '');
    text = text.replaceAllMapped(RegExp(r'&#(\d+);'), (match) {
      final codePoint = int.tryParse(match.group(1)!);
      return codePoint == null ? match.group(0)! : _codePoint(codePoint, match);
    });
    text = text.replaceAllMapped(
      RegExp(r'&#[xX]([0-9a-fA-F]+);'),
      (match) {
        final codePoint = int.tryParse(match.group(1)!, radix: 16);
        return codePoint == null
            ? match.group(0)!
            : _codePoint(codePoint, match);
      },
    );
    text = text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _codePoint(int codePoint, Match match) {
    if (codePoint < 0 || codePoint > 0x10ffff) return match.group(0)!;
    return String.fromCharCode(codePoint);
  }
}
