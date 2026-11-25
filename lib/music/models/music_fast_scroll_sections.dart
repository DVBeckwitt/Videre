import 'dart:math' as math;

import 'package:flutter/widgets.dart' show StringCharacters;

typedef MusicFastScrollSection = ({int index, String label});

/// Builds jump targets in the order in which the rows are displayed.
/// Section indices are zero-based. Range labels use inclusive row numbers.
List<MusicFastScrollSection> musicFastScrollSections<T>(
  List<T> rows, {
  required String Function(int first, int last) rangeLabel,
  String? Function(T row)? sectionLabel,
  required String unknownLabel,
}) {
  if (rows.length < 30) return const [];
  if (sectionLabel != null) {
    final categories = _categorySections(rows, sectionLabel, unknownLabel);
    if (categories.length > 1) return categories;
  }

  final rangeSize = math.max(5, (rows.length / 20).ceil());
  return [
    for (var index = 0; index < rows.length; index += rangeSize)
      (
        index: index,
        label: rangeLabel(index + 1, math.min(index + rangeSize, rows.length)),
      ),
  ];
}

List<MusicFastScrollSection> _categorySections<T>(
  List<T> rows,
  String? Function(T row) sectionLabel,
  String unknownLabel,
) {
  final sections = <MusicFastScrollSection>[];
  final seen = <String>{};
  for (final (index, row) in rows.indexed) {
    final label = sectionLabel(row) ?? unknownLabel;
    if (sections.isNotEmpty && sections.last.label == label) continue;
    // A repeated label would promise one jump target for multiple row ranges.
    if (!seen.add(label)) return const [];
    sections.add((index: index, label: label));
  }
  return sections;
}

/// Returns an initial from the same normalized text used to sort a row.
String? musicFastScrollInitial(String? normalizedSortText) {
  if (normalizedSortText == null || normalizedSortText.isEmpty) return null;
  final initial = normalizedSortText.characters.first;
  // Natural sorting compares the whole number, so leading digits may recur.
  if (initial.length == 1) {
    final code = initial.codeUnitAt(0);
    if (code >= 0x30 && code <= 0x39) return '0–9';
  }
  return initial.trim().isEmpty ? null : initial.toUpperCase();
}
