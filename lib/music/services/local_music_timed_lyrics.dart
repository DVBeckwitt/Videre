import '../models/music_lyrics.dart';

/// Decodes the structured sidecar returned by the Android library.
MusicLyrics? decodeLocalTimedLyrics(Object? value, {required String source}) {
  if (value is! List || value.isEmpty) return null;
  final cues = <MusicLyricCue>[];
  final wordsByCue = <int, List<MusicLyricWord>>{};
  final metadataByCue = <int, MusicLyricCueMetadata>{};
  for (final item in value) {
    if (item is! Map || item['startMs'] is! int || item['text'] is! String) {
      return null;
    }
    final milliseconds = item['startMs'] as int;
    final text = item['text'] as String;
    final start = Duration(milliseconds: milliseconds);
    if (milliseconds < 0 ||
        text.trim().isEmpty ||
        (cues.isNotEmpty && start < cues.last.start)) {
      return null;
    }
    final end = item['endMs'];
    if (end != null && (end is! int || end <= milliseconds)) return null;

    final words = _decodeWords(item['words'], text, start);
    if (words.isNotEmpty) wordsByCue[cues.length] = words;
    metadataByCue[cues.length] = MusicLyricCueMetadata(
      end: end is int ? Duration(milliseconds: end) : null,
      language: _nonemptyString(item['language']),
      voice: _nonemptyString(item['voice']),
      role: _nonemptyString(item['role']),
      translations: _decodeTranslations(item['translations']),
    );
    cues.add((start: start, text: text));
  }
  return MusicLyrics.synced(
    cues,
    source: source,
    wordsByCue: wordsByCue,
    metadataByCue: metadataByCue,
  );
}

List<MusicLyricWord> _decodeWords(
    Object? value, String text, Duration cueStart) {
  if (value is! List) return const [];
  final words = <MusicLyricWord>[];
  for (final item in value) {
    if (item is! Map) continue;
    final milliseconds = item['startMs'];
    final from = item['startOffset'];
    final to = item['endOffset'];
    if (milliseconds is! int ||
        from is! int ||
        to is! int ||
        from < 0 ||
        to <= from ||
        to > text.length) {
      continue;
    }
    final start = Duration(milliseconds: milliseconds);
    if (start < cueStart ||
        (words.isNotEmpty &&
            (start < words.last.start || from < words.last.endOffset))) {
      continue;
    }
    words.add((start: start, startOffset: from, endOffset: to));
  }
  return words;
}

List<MusicLyricTranslation> _decodeTranslations(Object? value) {
  if (value is! List) return const [];
  final translations = <MusicLyricTranslation>[];
  for (final item in value) {
    if (item is! Map) continue;
    final text = _nonemptyString(item['text']);
    if (text == null) continue;
    translations.add((text: text, language: _nonemptyString(item['language'])));
  }
  return translations;
}

String? _nonemptyString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;
