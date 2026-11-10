import 'package:auto_route/auto_route.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/router.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/add_to_queue_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../states/playlist.dart';

/// The same actions serve touch layouts and the TV playlist header.
class PlaylistPlaybackActions extends StatelessWidget {
  final Future<void> Function(bool? audio)? onPlayFromBeginning;
  final Future<void> Function(bool acceptMissing)? onResume;
  final bool autofocus;

  const PlaylistPlaybackActions({
    super.key,
    this.onPlayFromBeginning,
    this.onResume,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final cubit = context.watch<PlaylistCubit>();
    final state = cubit.state;
    final locals = AppLocalizations.of(context)!;
    final play = onPlayFromBeginning ?? cubit.play;
    final resume = onResume ??
        (acceptMissing) => cubit.resume(acceptMissing: acceptMissing);
    return ValueListenableBuilder<int>(
      valueListenable: playbackHistoryRevision,
      builder: (context, _, __) {
        final videos = cubit.playableVideos;
        final canPlay = cubit.reference != null && videos.isNotEmpty;
        final target = cubit.resumeTarget;
        final checkpoint = cubit.checkpoint;
        final missingWithoutReplacement = cubit.loader.complete &&
            checkpoint != null &&
            !checkpoint.completed &&
            target == null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (missingWithoutReplacement || target?.missing == true)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(locals.playlistResumeUnavailable),
              ),
            if (target != null) ...[
              Text(
                '${target.video.title ?? target.video.videoId} · ${prettyDurationCustom(cubit.resumePosition)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (target != null)
                  FilledButton.icon(
                    key: const ValueKey('playlist-resume'),
                    autofocus: autofocus,
                    onPressed: canPlay
                        ? () => _runPlaylistAction(
                            context, () => resume(target.missing))
                        : null,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(target.missing
                        ? locals.playlistContinueNext
                        : locals.playlistResume),
                  ),
                OutlinedButton.icon(
                  key: const ValueKey('playlist-play-from-beginning'),
                  autofocus: autofocus && target == null,
                  onPressed: canPlay
                      ? () => _runPlaylistAction(context, () => play(null))
                      : null,
                  icon: const Icon(Icons.restart_alt),
                  label: Text(locals.playlistPlayFromBeginning),
                ),
                IconButton.outlined(
                  tooltip: locals.playlistPlayAudio,
                  onPressed: canPlay
                      ? () => _runPlaylistAction(context, () => play(true))
                      : null,
                  icon: const Icon(Icons.audiotrack),
                ),
                if (videos.isNotEmpty)
                  IntrinsicWidth(
                    child: AddToQueueButton(videos: videos),
                  ),
              ],
            ),
            if (state.loading)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Semantics(
                  label: locals.playlistLoading,
                  child: MotionLoadingIndicator(
                    child: LinearProgressIndicator(
                      value:
                          state.loadingProgress > 0 && state.loadingProgress < 1
                              ? state.loadingProgress
                              : null,
                    ),
                  ),
                ),
              ),
            if (state.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(locals.playlistLoadFailed),
                    TextButton.icon(
                      key: const ValueKey('playlist-retry'),
                      onPressed: state.loading
                          ? null
                          : () =>
                              _runPlaylistAction(context, cubit.getAllVideos),
                      icon: const Icon(Icons.refresh),
                      label: Text(locals.retry),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

Future<void> _runPlaylistAction(
    BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (_) {
    if (context.mounted) {
      final locals = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(locals.couldntFetchVideos)));
    }
  }
}

class PlaylistEntryMenu extends StatelessWidget {
  final Video video;
  final Future<void> Function()? onRemove;

  const PlaylistEntryMenu({super.key, required this.video, this.onRemove});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
        onPressed: () =>
            showPlaylistEntryActions(context, video, onRemove: onRemove),
        icon: const Icon(Icons.more_vert),
      );
}

Future<void> showPlaylistEntryActions(BuildContext context, Video video,
    {Future<void> Function()? onRemove}) async {
  final locals = AppLocalizations.of(context)!;
  final player = context.read<PlayerCubit>();
  final canQueue = context.read<PlaylistCubit>().canPlayEntries &&
      !video.filtered &&
      !video.filterHide &&
      video.isUpcoming != true;
  await showSafeModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(locals.playlistViewDetails),
            onTap: () {
              Navigator.of(sheetContext).pop();
              AutoRouter.of(context)
                  .push(VideoRoute(videoId: video.videoId, playNow: false));
            },
          ),
          ListTile(
            enabled: canQueue,
            leading: const Icon(Icons.playlist_add),
            title: Text(locals.addToQueueList),
            onTap: () {
              Navigator.of(sheetContext).pop();
              player.queueVideos([video]);
            },
          ),
          if (onRemove != null)
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(locals.removeFromPlayList),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _runPlaylistAction(context, onRemove);
              },
            ),
        ],
      ),
    ),
  );
}
