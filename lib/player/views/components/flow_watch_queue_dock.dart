import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../settings/states/settings.dart';
import '../../../utils/models/image_object.dart';
import '../../../videos/models/video.dart';
import '../../../videos/views/components/video_thumbnail.dart';
import '../../models/playback_queue.dart';
import '../../states/player.dart';

/// Flow's QueueDockState, adapted to Videre's queue occurrence and paging order.
class FlowWatchQueue extends StatelessWidget {
  final Widget Function(BuildContext context, bool visible, Video? next)
      builder;

  const FlowWatchQueue({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerCubit>();
    final (entries, nextId, current) = context.select((PlayerCubit p) => (
          p.state.videos,
          p.state.playQueue.firstOrNull,
          p.state.currentlyPlaying,
        ));
    final repeat =
        context.select((SettingsCubit s) => s.state.playerRepeatMode);
    return ListenableBuilder(
      listenable: player.playlistLoadingRevision,
      builder: (context, _) {
        final visible = player.playlistReference != null
            ? entries.isNotEmpty
            : entries.length > 1;
        final next = switch (repeat) {
          PlayerRepeat.repeatOne => current,
          PlayerRepeat.repeatAll
              when nextId == null && player.playlistComplete =>
            entries.firstOrNull,
          _ => entries
              .where((entry) => playbackQueueId(entry) == nextId)
              .firstOrNull,
        };
        return builder(context, visible, next);
      },
    );
  }
}

/// Flow's PlaylistQueueDock keeps the actual next entry visible over the feed.
class FlowWatchQueueDock extends StatelessWidget {
  final Video? next;
  final VoidCallback onOpen;
  final bool inPane;

  const FlowWatchQueueDock(
      {super.key,
      required this.next,
      required this.onOpen,
      this.inPane = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locals = AppLocalizations.of(context)!;
    final shape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(inPane ? 16 : 24));
    final nextVideo = next;
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      shape: shape,
      elevation: inPane ? 0 : 3,
      child: InkWell(
        customBorder: shape,
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            if (nextVideo != null)
              SizedBox(
                width: 72,
                child: VideoThumbnailView(
                  videoId: nextVideo.videoId,
                  thumbnails: nextVideo.deArrowThumbnailUrl == null
                      ? ImageObject.getThumbnailUrlsByPreferredOrder(
                          nextVideo.videoThumbnails)
                      : [nextVideo.deArrowThumbnailUrl!],
                  images: nextVideo.deArrowThumbnailUrl == null
                      ? nextVideo.videoThumbnails
                      : null,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(locals.playNext,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  Text(nextVideo?.title ?? locals.videoQueue,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall),
                ],
              ),
            ),
            const SizedBox(width: 6),
            IconButton.filledTonal(
              tooltip: locals.videoQueue,
              onPressed: onOpen,
              icon: Icon(inPane
                  ? Icons.playlist_play_rounded
                  : Icons.keyboard_arrow_up_rounded),
            ),
          ]),
        ),
      ),
    );
  }
}
