import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:flutter/material.dart';

/// Describes the current request, not a server-confirmed backend assignment.
class BackendRequestIndicator extends StatelessWidget {
  final BackendPlayback? playback;
  final bool overlay;
  final bool compact;

  const BackendRequestIndicator({
    super.key,
    required this.playback,
    this.overlay = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final snapshot = playback;
    final selector = snapshot?.server.backendSelector;
    if (snapshot == null || selector == null) return const SizedBox.shrink();
    final locals = AppLocalizations.of(context)!;
    final value = selector.selectedValue(snapshot.server);
    final name = value == null
        ? locals.backendDefault
        : selector.labelFor(value) ?? locals.backendCustom;
    final label = locals.backendRequested(name);
    final text = Text(
      label,
      maxLines: overlay ? (compact ? 1 : 2) : null,
      overflow: overlay ? TextOverflow.ellipsis : TextOverflow.clip,
      style: Theme.of(context)
          .textTheme
          .bodySmall
          ?.copyWith(color: overlay ? Colors.white : null),
    );
    return IgnorePointer(
      child: Semantics(
        liveRegion: true,
        child: overlay
            ? Align(
                alignment: AlignmentDirectional.topStart,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 420),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: text,
                ),
              )
            : text,
      ),
    );
  }
}
