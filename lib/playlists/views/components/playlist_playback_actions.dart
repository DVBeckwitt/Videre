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

import '../../models/playlist.dart';
import '../../models/playlist_reference.dart';
import '../../states/playlist.dart';
import 'playlist_information.dart';
import 'playlist_server_save_button.dart';

/// The same actions serve touch layouts and the TV playlist header.
class PlaylistPlaybackActions extends StatelessWidget {
  final Future<void> Function(bool? audio)? onPlayFromBeginning;
  final Future<void> Function(bool acceptMissing)? onResume;
  final bool autofocus;
  final bool connected;
  final List<Widget> secondaryActions;

  const PlaylistPlaybackActions({
    super.key,
    this.onPlayFromBeginning,
    this.onResume,
    this.autofocus = false,
    this.connected = false,
    this.secondaryActions = const [],
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
        final start = canPlay
            ? () => _runPlaylistAction(context, () => play(null))
            : null;
        final audio = IconButton.outlined(
          tooltip: locals.playlistPlayAudio,
          onPressed: canPlay
              ? () => _runPlaylistAction(context, () => play(true))
              : null,
          icon: const Icon(Icons.audiotrack),
        );
        final queue = videos.isEmpty
            ? null
            : IntrinsicWidth(child: AddToQueueButton(videos: videos));
        final resumeAction = target == null
            ? null
            : FilledButton.icon(
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
              );
        final reference = cubit.reference;
        final description = state.playlist.description?.trim() ?? '';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            PlaylistInformation(compact: connected, showServerCopy: !connected),
            if (connected && description.isNotEmpty)
              _PlaylistDescription(
                  key: ValueKey(description), description: description),
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
            if (connected) ...[
              if (resumeAction != null) resumeAction,
              const SizedBox(height: 6),
              _PlaylistPrimaryActions(
                playLabel: target == null
                    ? locals.downloadsPlayAll
                    : locals.playlistPlayFromBeginning,
                onPlay: start,
                onShuffle: canPlay
                    ? () => _runPlaylistAction(context, cubit.playShuffled)
                    : null,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ...secondaryActions,
                  if (queue != null) queue,
                  audio,
                ],
              ),
              if (reference != null &&
                  (state.playlist.isLocal ||
                      reference.kind == PlaylistSourceKind.public))
                PlaylistServerSaveButton(
                  playlist: state.playlist,
                  reference: reference,
                  enabled: cubit.loader.complete && cubit.canPlayEntries,
                ),
            ] else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (resumeAction != null) resumeAction,
                  OutlinedButton.icon(
                    key: const ValueKey('playlist-play-from-beginning'),
                    autofocus: autofocus && target == null,
                    onPressed: start,
                    icon: const Icon(Icons.restart_alt),
                    label: Text(locals.playlistPlayFromBeginning),
                  ),
                  audio,
                  if (queue != null) queue,
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

// Layout translated from Flow's FlowActionButtonPair.kt at 565d1f7a.
class _PlaylistPrimaryActions extends StatelessWidget {
  final String playLabel;
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;

  const _PlaylistPrimaryActions({
    required this.playLabel,
    required this.onPlay,
    required this.onShuffle,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final locals = AppLocalizations.of(context)!;
    const outer = Radius.circular(28);
    const inner = Radius.circular(5);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: OutlinedButton.icon(
              key: const ValueKey('playlist-play-from-beginning'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 54),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                foregroundColor: colors.onPrimary,
                backgroundColor: colors.primary,
                disabledBackgroundColor:
                    colors.onSurface.withValues(alpha: 0.12),
                side: BorderSide.none,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadiusDirectional.horizontal(
                      start: outer, end: inner),
                ),
              ),
              onPressed: onPlay,
              icon: const Icon(Icons.play_arrow_rounded),
              label:
                  Text(playLabel, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: FilledButton.tonalIcon(
              key: const ValueKey('playlist-shuffle'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 54),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadiusDirectional.horizontal(
                      start: inner, end: outer),
                ),
              ),
              onPressed: onShuffle,
              icon: const Icon(Icons.shuffle_rounded),
              label: Text(locals.musicShuffle,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaylistDescription extends StatefulWidget {
  final String description;

  const _PlaylistDescription({super.key, required this.description});

  @override
  State<_PlaylistDescription> createState() => _PlaylistDescriptionState();
}

class _PlaylistDescriptionState extends State<_PlaylistDescription> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      expanded: _expanded,
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            widget.description,
            maxLines: _expanded ? null : 2,
            overflow: _expanded ? null : TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ),
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
