import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../models/media_event.dart';
import '../../states/player.dart';

/// Feedback while the current video details or playback are being retried.
class VideoRetryNotice extends StatelessWidget {
  final bool reconnecting;

  const VideoRetryNotice({super.key, this.reconnecting = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locals = AppLocalizations.of(context)!;
    return IgnorePointer(
      child: Semantics(
        liveRegion: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Material(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ExcludeSemantics(
                    child: SizedBox.square(
                      dimension: 16,
                      child: MotionLoadingIndicator(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      reconnecting
                          ? locals.reconnectingPlayback
                          : locals.retryingVideoDetails,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Sits in the player host stack so it can also show before a decoder mounts.
class PlayerRetryIndicator extends StatelessWidget {
  const PlayerRetryIndicator({super.key});

  static bool visibleFor(PlayerState state) =>
      (state.recoveringPlayback ||
          state.mediaEvent.type == MediaEventType.metadataRetry) &&
      state.mediaEvent.state != MediaState.error &&
      state.backendRecovery == null &&
      !state.isClosing &&
      !state.isPip;

  @override
  Widget build(BuildContext context) {
    final visible =
        context.select((PlayerCubit player) => visibleFor(player.state));
    final reconnecting =
        context.select((PlayerCubit player) => player.state.recoveringPlayback);
    if (!visible) return const SizedBox.shrink();
    return SafeArea(
      minimum: const EdgeInsets.all(12),
      child: Center(child: VideoRetryNotice(reconnecting: reconnecting)),
    );
  }
}
