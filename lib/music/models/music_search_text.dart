import 'package:diacritic/diacritic.dart';

String normalizeMusicSearchText(String text) =>
    removeDiacritics(text.toLowerCase());

List<String> musicSearchTerms(String query) {
  final normalized = normalizeMusicSearchText(query.trim());
  return normalized.isEmpty ? const [] : normalized.split(RegExp(r'\s+'));
}
