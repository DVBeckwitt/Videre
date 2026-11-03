import 'package:flutter/material.dart';

import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/views/tv/components/tv_button.dart';
import '../../models/db/progress.dart';
import '../../models/video.dart';

class WatchStatusButton extends StatefulWidget {
  final Video video;
  final bool television;
  final VoidCallback? afterChange;

  const WatchStatusButton(
      {super.key,
      required this.video,
      this.television = false,
      this.afterChange});

  @override
  State<WatchStatusButton> createState() => _WatchStatusButtonState();
}

class _WatchStatusButtonState extends State<WatchStatusButton> {
  bool _saving = false;

  Future<void> _toggle() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await service.markVideoWatched(
          widget.video, !service.isVideoWatched(widget.video.videoId));
      if (mounted) widget.afterChange?.call();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.itemlistErrorGeneric)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
      valueListenable: playbackHistoryRevision,
      builder: (context, _, child) {
        final watched = service.isVideoWatched(widget.video.videoId);
        final locals = AppLocalizations.of(context)!;
        final label = watched ? locals.markUnwatched : locals.markWatched;
        final icon = watched ? Icons.remove_done : Icons.done;
        if (widget.television) {
          return TvButton(
              onPressed: _saving ? null : (_) => _toggle(),
              child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon),
                    const SizedBox(width: 8),
                    Text(label),
                  ])));
        }
        return Column(mainAxisSize: MainAxisSize.min, children: [
          IconButton.filledTonal(
              tooltip: label,
              onPressed: _saving ? null : _toggle,
              icon: Icon(icon)),
          Text(label),
        ]);
      });
}
