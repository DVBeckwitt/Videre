import 'package:clipious/utils/motion.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/videos/views/components/compact_video.dart';

import '../../../globals.dart';
import 'playlist_loading_notice.dart';
import 'player_modal_back_handler.dart';

class VideoQueue extends StatefulWidget {
  const VideoQueue({super.key});

  @override
  State<VideoQueue> createState() => _VideoQueueState();
}

class _VideoQueueState extends State<VideoQueue> {
  final _scrollController = ScrollController();
  ({
    int from,
    String? current,
    int generation,
    List<String> order,
    List<String> upcoming
  })? _drag;

  List<IdedVideo> _entries(PlayerState state) {
    final source = state.videos.isNotEmpty ? state.videos : state.offlineVideos;
    if (state.currentQueueId == null) return source;
    // Flow's queue sheet shows playback order. Use the same occurrence
    // traversal as Videre's Music queue, including shuffle and Play next.
    return playbackQueueTraversal(source,
        played: state.playedVideos,
        current: state.currentQueueId,
        upcoming: state.playQueue);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _playVideo(PlayerCubit controller, String id) async {
    if (controller.state.currentQueueId != null) {
      await controller.selectQueueOccurrence(id);
      return;
    }
    final index = _entries(controller.state)
        .indexWhere((item) => playbackQueueId(item) == id);
    if (index < 0) return;
    await controller.skipToVideo(index);
    // A restored queue can be opened before its player has been shown.
    if (!controller.isClosed &&
        controller.state.isHidden &&
        !controller.state.isClosing) {
      controller.showMiniPlayer();
    }
  }

  Future<void> _confirmRemove(
      BuildContext context, PlayerCubit controller, IdedVideo video) async {
    final id = playbackQueueId(video);
    final generation = controller.playlistGeneration;
    final profile = db.profileId;
    final locals = AppLocalizations.of(context)!;
    final title =
        video is Video ? video.title : (video as DownloadedVideo).title;
    final remove = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (dialogContext) => PlayerModalBackHandler(
        priority: 5,
        child: AlertDialog(
          title: Text(locals.delete),
          content: Text(title ?? ''),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(locals.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(locals.delete),
            ),
          ],
        ),
      ),
    );
    // Playback may advance, or the queue/profile may change while the dialog
    // is open. Never remove the newly active occurrence or a replacement queue.
    if (remove == true &&
        mounted &&
        !controller.isClosed &&
        db.profileId == profile &&
        controller.playlistGeneration == generation &&
        controller.state.currentQueueId != id &&
        _entries(controller.state).any((item) => playbackQueueId(item) == id)) {
      controller.removeVideoFromQueue(id);
    }
  }

  Widget _queueVideo(BuildContext context, int index, IdedVideo video,
      {required bool canMove}) {
    var controller = context.read<PlayerCubit>();
    var state = controller.state;
    final offline = video is DownloadedVideo ? video : null;
    final id = playbackQueueId(video);
    final isPlaying = id == state.currentQueueId;

    final row = CompactVideo(
      onTap: isPlaying ? null : () => _playVideo(controller, id),
      onLongPress:
          isPlaying ? null : () => _confirmRemove(context, controller, video),
      video: video is Video ? video : null,
      offlineVideo: offline,
      highlighted: isPlaying,
      trailing: [
        if (offline?.audioOnly ?? false)
          Icon(Icons.audiotrack,
              color: Theme.of(context).colorScheme.secondary),
        if (canMove)
          ReorderableDragStartListener(
            index: index,
            child: Tooltip(
              message: AppLocalizations.of(context)!.musicQueueReorder,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.drag_handle_rounded),
              ),
            ),
          ),
      ],
    );
    return KeyedSubtree(key: ValueKey(id), child: row);
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
              final videos = _entries(state);
              if (!_scrollController.hasClients || videos.isEmpty) return;

              final index = videos.indexWhere((element) =>
                  playbackQueueId(element) == state.currentQueueId);
              if (index < 0) return;
              final offset = ((index - 1) *
                      (compactVideoRowHeight(context) + innerHorizontalPadding))
                  .clamp(0.0, _scrollController.position.maxScrollExtent);
              if (offset == _scrollController.offset) return;
              AppMotion.scrollTo(context, _scrollController, offset,
                  duration: animationDuration * 4);
            },
            buildWhen: (previous, current) =>
                previous.videos != current.videos ||
                previous.offlineVideos != current.offlineVideos ||
                previous.currentQueueId != current.currentQueueId ||
                previous.playedVideos != current.playedVideos ||
                !listEquals(
                    previous.playQueue.toList(), current.playQueue.toList()),
            builder: (context, state) {
              final entries = _entries(state);
              final order = entries.map(playbackQueueId).toList();
              final upcoming = state.playQueue.toList();
              final current = state.currentQueueId;
              final generation = controller.playlistGeneration;
              return ReorderableListView.builder(
                buildDefaultDragHandles: false,
                footer: const PlaylistLoadingNotice(),
                scrollController: _scrollController,
                itemCount: entries.length,
                onReorderStart: (index) => _drag = (
                  from: index,
                  current: current,
                  generation: generation,
                  order: order,
                  upcoming: upcoming
                ),
                onReorder: (from, to) {
                  final drag = _drag;
                  _drag = null;
                  final latest = controller.state;
                  final expected = drag?.order ?? order;
                  if ((drag != null && drag.from != from) ||
                      latest.currentQueueId !=
                          (drag == null ? current : drag.current) ||
                      controller.playlistGeneration !=
                          (drag?.generation ?? generation) ||
                      !listEquals(
                          _entries(latest).map(playbackQueueId).toList(),
                          expected) ||
                      !listEquals(latest.playQueue.toList(),
                          drag?.upcoming ?? upcoming) ||
                      from < 0 ||
                      from >= expected.length ||
                      to < 0 ||
                      to > expected.length) {
                    return;
                  }
                  if (latest.currentQueueId == null) {
                    controller.onQueueReorder(from, to);
                    return;
                  }
                  final slot = to > from ? to - 1 : to;
                  if (slot == from) return;
                  final remaining = [...expected];
                  final moved = remaining.removeAt(from);
                  final before =
                      remaining.skip(slot).where(upcoming.contains).firstOrNull;
                  controller.moveQueueOccurrence(moved, beforeId: before);
                },
                itemBuilder: (context, index) => _queueVideo(
                    context, index, entries[index],
                    canMove: current == null
                        ? entries.length > 1
                        : upcoming.length > 1 &&
                            upcoming.contains(order[index])),
              );
            },
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
