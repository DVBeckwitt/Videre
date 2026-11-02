/// Only resolution labels count as a quality, not stream IDs or bitrates.
int? videoQualityHeight(String label) {
  final match = RegExp(r'^(\d+)p', caseSensitive: false).firstMatch(label);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// Prefer the highest resolution at or below the requested height. If the
/// video offers only higher resolutions, use its lowest one. Ignore Auto.
int? preferredVideoQualityIndex(List<int?> heights, int? preferred) {
  if (preferred == null || preferred <= 0) return null;
  int? lower;
  int? lowest;
  for (var index = 0; index < heights.length; index++) {
    final height = heights[index];
    if (height == null || height <= 0) continue;
    if (lowest == null || height < heights[lowest]!) lowest = index;
    if (height <= preferred && (lower == null || height > heights[lower]!)) {
      lower = index;
    }
  }
  return lower ?? lowest;
}
