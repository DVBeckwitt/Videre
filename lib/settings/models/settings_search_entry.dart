import 'package:diacritic/diacritic.dart';
import 'package:flutter/widgets.dart';

class SettingsSearchEntry {
  final String id;
  final String title;
  final String category;
  final String? description;
  final List<String> keywords;
  final Widget Function(BuildContext, FocusNode) destination;

  const SettingsSearchEntry({
    required this.id,
    required this.title,
    required this.category,
    this.description,
    this.keywords = const [],
    required this.destination,
  });
}

final _wordSeparator = RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true);

List<String> _words(String text) => removeDiacritics(text.toLowerCase())
    .split(_wordSeparator)
    .where((word) => word.isNotEmpty)
    .toList();

List<SettingsSearchEntry> searchSettings(
    String query, List<SettingsSearchEntry> entries) {
  final terms = _words(query).toSet();
  if (terms.isEmpty) return [];

  final matches = <({SettingsSearchEntry entry, int score, int index})>[];
  for (final (index, entry) in entries.indexed) {
    final titleWords = _words(entry.title);
    final title = titleWords.join(' ');
    final keywords = entry.keywords.expand(_words).join(' ');
    final description = _words(entry.description ?? '').join(' ');
    final category = _words(entry.category).join(' ');
    var score = 0;
    for (final term in terms) {
      final termScore = switch (term) {
        _ when titleWords.contains(term) => 12,
        _ when titleWords.any((word) => word.startsWith(term)) => 9,
        _ when title.contains(term) => 7,
        _ when keywords.contains(term) => 5,
        _ when description.contains(term) => 3,
        _ when category.contains(term) => 1,
        _ => 0,
      };
      if (termScore == 0) {
        score = 0;
        break;
      }
      score += termScore;
    }
    if (score > 0) matches.add((entry: entry, score: score, index: index));
  }
  matches.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore == 0 ? a.index.compareTo(b.index) : byScore;
  });
  return matches.map((match) => match.entry).toList();
}
