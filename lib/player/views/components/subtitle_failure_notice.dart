import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../states/video_player.dart';

class SubtitleFailureOverlay extends StatelessWidget {
  final VideoPlayerCubit player;
  final Widget child;
  final bool autofocus;

  const SubtitleFailureOverlay({
    super.key,
    required this.player,
    required this.child,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return LayoutBuilder(builder: (context, constraints) {
      // Keep the failure available when the user expands the mini player.
      if (constraints.maxWidth < 280 || constraints.maxHeight < 100) {
        return child;
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          child,
          BlocBuilder<VideoPlayerCubit, VideoPlayerState>(
            bloc: player,
            buildWhen: (previous, current) =>
                previous.subtitleFailed != current.subtitleFailed,
            builder: (context, state) {
              if (!state.subtitleFailed) return const SizedBox.shrink();
              return FocusScope(
                autofocus: autofocus,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(8),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 600),
                        child: Row(
                          children: [
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: Semantics(
                                  liveRegion: true,
                                  child: Text(
                                    locals.subtitlesUnavailable,
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 12),
                                  ),
                                ),
                              ),
                            ),
                            TextButton(
                              key: const ValueKey('subtitle-retry'),
                              autofocus: autofocus,
                              onPressed: player.retrySubtitles,
                              style: TextButton.styleFrom(
                                  foregroundColor: Colors.white),
                              child: Text(locals.retry),
                            ),
                            IconButton(
                              key: const ValueKey('subtitle-dismiss'),
                              tooltip: MaterialLocalizations.of(context)
                                  .closeButtonTooltip,
                              onPressed: player.dismissSubtitleFailure,
                              icon:
                                  const Icon(Icons.close, color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      );
    });
  }
}
