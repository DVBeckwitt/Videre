import 'package:flutter/material.dart';

import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/interfaces/db.dart';
import '../../models/db/progress.dart';
import '../../services/watch_history.dart';

/// The compact thumbnail uses the same profile-owned progress and watched
/// decisions as full-size video cards. It never issues a network request.
class VideoWatchProgress extends StatefulWidget {
  final String videoId;

  const VideoWatchProgress({super.key, required this.videoId});

  @override
  State<VideoWatchProgress> createState() => _VideoWatchProgressState();
}

class _VideoWatchProgressState extends State<VideoWatchProgress> {
  late final IDbClient _database = db.forProfile(db.profileId);

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: playbackHistoryRevision,
        builder: (context, _, child) {
          final value = _database.getVideoPlaybackProgress(widget.videoId);
          final progress = value.progress.isFinite
              ? value.progress.clamp(0.0, 1.0).toDouble()
              : 0.0;
          final watched = WatchRepository.forDatabase(_database)
                  ?.isWatched(widget.videoId) ??
              progress >= watchedProgressThreshold;
          if (!watched && progress == 0) return const SizedBox.shrink();
          final locals = AppLocalizations.of(context)!;
          final colors = Theme.of(context).colorScheme;
          return IgnorePointer(
            child: Semantics(
              label: watched
                  ? locals.watchedStatus
                  : locals.videoWatchProgress((progress * 100).round()),
              excludeSemantics: true,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (watched)
                    Positioned(
                      left: 4,
                      top: 4,
                      child: DecoratedBox(
                        key: ValueKey('video-watched-${widget.videoId}'),
                        decoration: BoxDecoration(
                          color: colors.primaryContainer,
                          shape: BoxShape.circle,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(Icons.check,
                              size: 12, color: colors.onPrimaryContainer),
                        ),
                      ),
                    ),
                  if (progress > 0)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        key: ValueKey('video-watch-progress-${widget.videoId}'),
                        value: progress,
                        minHeight: 3,
                        backgroundColor: colors.secondaryContainer,
                        color: colors.primary,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      );
}
