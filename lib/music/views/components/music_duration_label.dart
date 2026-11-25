import 'package:clipious/l10n/generated/app_localizations.dart';

/// Summarizes recording lengths. A paged collection can have more recordings
/// to load even when every length received so far is known.
String? musicDurationLabel(
  AppLocalizations locals,
  Iterable<int?> seconds, {
  bool complete = true,
}) {
  var hasEntries = false;
  var allKnown = complete;
  var total = 0;
  for (final length in seconds) {
    hasEntries = true;
    if (length == null || length <= 0) {
      allKnown = false;
    } else {
      total += length;
    }
  }
  if (!hasEntries) return null;
  if (total == 0) return locals.playlistDurationUnknown;
  final duration = formatMusicDuration(total);
  return allKnown
      ? locals.playlistTotalDuration(duration)
      : locals.playlistKnownDuration(duration);
}

String formatMusicDuration(int seconds) {
  final hours = seconds ~/ 3600;
  final minutes = (seconds ~/ 60 % 60).toString().padLeft(2, '0');
  final remainder = (seconds % 60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$remainder' : '$minutes:$remainder';
}
