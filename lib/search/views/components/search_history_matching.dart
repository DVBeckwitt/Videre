// Port of Flow's SearchHistoryMatching.kt at 565d1f7a (GPL-3.0).
// See docs/flow-video-ui-sources.md for the upstream source and license.

const searchHistoryInitialRows = 8;

/// Match what was typed, keeping prefix matches ahead of substring matches.
List<String> recentOrMatchingSearches(List<String> history, String typed) {
  final query = typed.trim().toLowerCase();
  if (query.isEmpty) return history;
  final prefix = <String>[];
  final rest = <String>[];
  for (final item in history) {
    final text = item.toLowerCase();
    if (text.startsWith(query)) {
      prefix.add(item);
    } else if (text.contains(query)) {
      rest.add(item);
    }
  }
  return [...prefix, ...rest].take(searchHistoryInitialRows).toList();
}
