import 'package:clipious/l10n/generated/app_localizations.dart';

/// Summarizes recording lengths. A paged collection can have more recordings
/// to load even when every length received so far is known.
String? musicDurationLabel(AppLocalizations locals, Iterable<int?> seconds,
    {bool complete = true}) {
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
  final hours = total ~/ 3600;
  final minutes = (total ~/ 60 % 60).toString().padLeft(2, '0');
  final remainder = (total % 60).toString().padLeft(2, '0');
  final duration =
      hours > 0 ? '$hours:$minutes:$remainder' : '$minutes:$remainder';
  return allKnown
      ? locals.playlistTotalDuration(duration)
      : locals.playlistKnownDuration(duration);
}
