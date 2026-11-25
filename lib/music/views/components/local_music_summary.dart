import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/pretty_bytes.dart';
import '../../models/local_music_browse.dart';
import 'music_duration_label.dart';

class LocalMusicSummary extends StatelessWidget {
  const LocalMusicSummary({super.key, required this.totals});

  final LocalMusicTotals totals;

  @override
  Widget build(BuildContext context) {
    if (totals.trackCount == 0) return const SizedBox.shrink();
    final locals = AppLocalizations.of(context)!;
    final duration = totals.durationMs;
    final size = totals.sizeBytes;
    final durationLabel = duration == null
        ? locals.playlistDurationUnknown
        : (totals.durationComplete
            ? locals.playlistTotalDuration
            : locals.playlistKnownDuration)(
            formatMusicDuration(duration ~/ 1000),
          );
    final sizeLabel = size == null
        ? locals.localMusicSizeUnknown
        : (totals.sizeComplete
            ? locals.localMusicTotalSize
            : locals.localMusicKnownSize)(prettyBytes(size.toDouble()));
    return DefaultTextStyle.merge(
      style: Theme.of(context).textTheme.bodySmall,
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        children: [Text(durationLabel), Text(sizeLabel)],
      ),
    );
  }
}
