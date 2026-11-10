import 'package:clipious/utils/motion.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_swipe_action_cell/core/cell.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/videos/views/components/compact_video.dart';

import '../../../globals.dart';
import 'playlist_loading_notice.dart';

class VideoQueue extends StatefulWidget {
  const VideoQueue({super.key});

  @override
  State<VideoQueue> createState() => _VideoQueueState();
}

class _VideoQueueState extends State<VideoQueue> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _playVideo(PlayerCubit controller, int index) async {
    await controller.skipToVideo(index);
    // A restored queue can be opened before its player has been shown.
    if (!controller.isClosed &&
        controller.state.isHidden &&
        !controller.state.isClosing) {
      controller.showMiniPlayer();
    }
  }

  Widget _queueVideo(BuildContext context, int index, IdedVideo video) {
    var controller = context.read<PlayerCubit>();
    var state = controller.state;
    final offline = video is DownloadedVideo ? video : null;
    final isPlaying = playbackQueueId(video) == state.currentQueueId;

    return SwipeActionCell(
      key: ValueKey(playbackQueueId(video)),
      trailingActions: isPlaying
          ? []
          : [
              SwipeAction(
                  performsFirstActionWithFullSwipe: true,
                  onTap: (handler) async {
                    await handler(true);
                    return controller
                        .removeVideoFromQueue(playbackQueueId(video));
                  },
                  color: Colors.red.shade400,
                  icon: const Icon(
                    Icons.clear,
                    color: Colors.white,
                  ))
            ],
      child: CompactVideo(
        onTap: isPlaying ? () {} : () => _playVideo(controller, index),
        video: video is Video ? video : null,
        offlineVideo: offline,
        highlighted: isPlaying,
        trailing: [
          if (offline?.audioOnly ?? false)
            Icon(Icons.audiotrack,
                color: Theme.of(context).colorScheme.secondary),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    var controller = context.read<PlayerCubit>();
    final hasVideos = context.select((PlayerCubit player) =>
        player.state.videos.isNotEmpty ||
        player.state.offlineVideos.isNotEmpty);
    return hasVideos
        ? BlocConsumer<PlayerCubit, PlayerState>(
            listenWhen: (previous, current) =>
                previous.currentQueueId != current.currentQueueId,
            listener: (context, state) {
              List<IdedVideo> videos = (state.videos.isNotEmpty
                  ? state.videos
                  : state.offlineVideos);
              if (!_scrollController.hasClients || videos.isEmpty) return;

              final index = videos.indexWhere((element) =>
                  playbackQueueId(element) == state.currentQueueId);
              if (index < 0) return;
              final offset =
                  ((index - 1) * (compactVideoHeight + innerHorizontalPadding))
                      .clamp(0.0, _scrollController.position.maxScrollExtent);
              if (offset == _scrollController.offset) return;
              AppMotion.scrollTo(context, _scrollController, offset,
                  duration: animationDuration * 4);
            },
            buildWhen: (previous, current) =>
                previous.videos != current.videos ||
                previous.offlineVideos != current.offlineVideos ||
                previous.currentlyPlaying != current.currentlyPlaying ||
                previous.offlineCurrentlyPlaying !=
                    current.offlineCurrentlyPlaying,
            builder: (context, state) => ReorderableListView.builder(
                footer: const PlaylistLoadingNotice(),
                scrollController: _scrollController,
                itemCount: state.videos.isNotEmpty
                    ? state.videos.length
                    : state.offlineVideos.length,
                onReorder: controller.onQueueReorder,
                itemBuilder: (context, index) => _queueVideo(
                    context,
                    index,
                    state.videos.isNotEmpty
                        ? state.videos[index]
                        : state.offlineVideos[index])),
          )
        : Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.queue_music, size: 48),
                  const SizedBox(height: 16),
                  Text(AppLocalizations.of(context)!.videoQueueEmpty,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(AppLocalizations.of(context)!.videoQueueEmptyDescription,
                      textAlign: TextAlign.center),
                ],
              ),
            ),
          );
  }
}
