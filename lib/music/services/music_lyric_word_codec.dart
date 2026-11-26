import '../models/music_lyrics.dart';
import 'lrc_lyrics.dart';

// Each display span takes at least a six-character LRC tag and one text unit.
const _maxWords = maxLyricsCharacters ~/ 7;

List<List<int>> encodeStoredLyricWords(
    Map<int, List<MusicLyricWord>> wordsByCue) {
  final words = <List<int>>[];
  for (final entry in wordsByCue.entries) {
    for (final word in entry.value) {
      if (words.length == _maxWords) {
        throw const FormatException('Too many stored lyric word timings');
      }
      words.add([
        entry.key,
        word.start.inMicroseconds,
        word.startOffset,
        word.endOffset,
      ]);
    }
  }
  return words;
}

Map<int, List<MusicLyricWord>> decodeStoredLyricWords(
    Object? data, List<MusicLyricCue> cues) {
  if (data is! List || data.isEmpty || data.length > _maxWords) {
    return const {};
  }
  // Simultaneous cue texts share the same end boundary.
  final ends = List<Duration?>.filled(cues.length, null);
  for (var i = cues.length - 2; i >= 0; i--) {
    ends[i] =
        cues[i + 1].start == cues[i].start ? ends[i + 1] : cues[i + 1].start;
  }
  final result = <int, List<MusicLyricWord>>{};
  for (final entry in data) {
    if (entry
        case [final int cueIndex, final int time, final int from, final int to]
        when cueIndex >= 0 && cueIndex < cues.length) {
      final start = Duration(microseconds: time);
      final cue = cues[cueIndex];
      final end = ends[cueIndex];
      final words = result.putIfAbsent(cueIndex, () => []);
      if (start < cue.start ||
          (end != null && start >= end) ||
          from < 0 ||
          from >= to ||
          to > cue.text.length ||
          (words.isNotEmpty &&
              (start <= words.last.start || from < words.last.endOffset))) {
        return const {};
      }
      words.add((start: start, startOffset: from, endOffset: to));
    } else {
      return const {};
    }
  }
  return Map.unmodifiable(result.map((index, words) =>
      MapEntry(index, List<MusicLyricWord>.unmodifiable(words))));
}

Map<String, List<int>> encodeStoredLyricDisplayText(
    Map<int, String> textByCue) {
// Repeated timestamps can share a long block of continuation text.
  final displayText = <String, List<int>>{};
  var displayLength = 0;
  for (final entry in textByCue.entries) {
    displayText.putIfAbsent(entry.value, () {
      displayLength += entry.value.length;
      if (displayLength > maxLyricsCharacters) {
        throw const FormatException('Lyric correction is too large');
      }
      return [];
    }).add(entry.key);
  }
  return displayText;
}

Map<int, String> decodeStoredLyricDisplayText(
    Object? data, List<MusicLyricCue> cues) {
  if (data is! Map<String, dynamic> || data.length > cues.length) {
    return const {};
  }
  final result = <int, String>{};
  var length = 0;
  for (final entry in data.entries) {
    length += entry.key.length;
    final indices = entry.value;
    if (length > maxLyricsCharacters ||
        indices is! List ||
        indices.length > cues.length - result.length) {
      return const {};
    }
    final text = normalizeLyricsText(entry.key);
    final newline = text.indexOf('\n');
    final firstLine = (newline < 0 ? text : text.substring(0, newline)).trim();
    final verifiedLines = Set<String>.identity();
    for (final index in indices) {
      if (index is! int ||
          index < 0 ||
          index >= cues.length ||
          result.containsKey(index) ||
          (verifiedLines.add(cues[index].text) &&
              firstLine != cues[index].text)) {
        return const {};
      }
      result[index] = text;
    }
  }
  return Map.unmodifiable(result);
}

List<Duration> decodeStoredLyricBreaks(Object? data, int cueCount) {
  if (data is! List || data.length + cueCount > maxLrcCues) return const [];
  final breaks = <Duration>[];
  for (final time in data) {
    if (time is! int) return const [];
    final start = Duration(microseconds: time);
    if (breaks.isNotEmpty && start < breaks.last) return const [];
    breaks.add(start);
  }
  return List.unmodifiable(breaks);
}
