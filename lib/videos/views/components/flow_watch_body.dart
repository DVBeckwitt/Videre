import 'dart:ui' show ImageFilter;

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../../comments/views/components/comments_container.dart';
import '../../../comments/states/comments.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../player/states/player.dart';
import '../../../player/views/components/watch_playback_actions.dart';
import '../../../player/views/components/player_modal_back_handler.dart';
import '../../../player/views/components/video_queue.dart';
import '../../../router.dart';
import '../../../settings/states/settings.dart';
import '../../../subscription_management/view/components/subscribe_button.dart';
import '../../../utils.dart';
import '../../../utils/views/components/channel_avatar.dart';
import '../../../utils/views/components/conditional_wrap.dart';
import '../../models/video.dart';
import '../../models/video_chapter.dart';
import 'add_to_playlist_button.dart';
import 'community_browse.dart';
import 'download_modal_sheet.dart';
import 'info.dart';
import 'recommended_videos.dart';
import 'video_dislike_metrics.dart';
import 'watch_notes_button.dart';
import 'watch_chapter_list.dart';

typedef FlowWatchPanelPresenter = void Function(
    String title, Widget child, bool scrollable);

/// Flow's continuous watch information, backed by Videre's existing actions.
class FlowWatchBody extends StatelessWidget {
  final Video video;
  final bool inPlayer;
  final bool queueDockVisible;
  final int? dislikes;
  final VoidCallback? onDownload;
  final IconData downloadIcon;
  final Widget? extraAction;
  final Future<void> Function(Duration)? onStartAt;
  final bool showRelated;
  final bool relatedGrid;
  final FlowWatchPanelPresenter? onOpenPanel;

  const FlowWatchBody({
    super.key,
    required this.video,
    this.inPlayer = false,
    this.queueDockVisible = false,
    this.dislikes,
    this.onDownload,
    this.downloadIcon = Icons.download_rounded,
    this.extraAction,
    this.onStartAt,
    this.showRelated = true,
    this.relatedGrid = false,
    this.onOpenPanel,
  });

  static void _showPanel(BuildContext context, Widget child,
      {bool tall = false}) {
    showSafeModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => PlayerModalBackHandler(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .72,
          ),
          child: tall
              ? SizedBox(
                  height: MediaQuery.sizeOf(context).height * .72, child: child)
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  child: child,
                ),
        ),
      ),
    );
  }

  static void showQueue(BuildContext context) =>
      _showPanel(context, const VideoQueue(), tall: true);

  void _openPanel(BuildContext context, String title, Widget child,
      {bool scrollable = true}) {
    if (onOpenPanel case final present?) {
      present(title, child, scrollable);
    } else {
      _showPanel(context, child, tall: !scrollable);
    }
  }

  void _openComments(BuildContext context, Widget comments) {
    final player = context.read<PlayerCubit>();
    if (inPlayer && player.state.currentlyPlaying?.videoId != video.videoId) {
      return;
    }

    // The wide Watch pane already closes when its queue occurrence changes.
    final panel = inPlayer && onOpenPanel == null
        ? BlocListener<PlayerCubit, PlayerState>(
            bloc: player,
            listenWhen: (_, state) =>
                state.currentlyPlaying?.videoId != video.videoId,
            listener: (context, _) {
              final route = ModalRoute.of(context);
              if (route == null || !route.isActive) return;
              if (route.isCurrent) {
                route.navigator?.pop();
              } else {
                route.navigator?.removeRoute(route);
              }
            },
            child: comments,
          )
        : comments;

    _openPanel(context, AppLocalizations.of(context)!.comments, panel,
        scrollable: false);
  }

  void _openChapters(BuildContext context, List<VideoChapter> chapters) {
    final player = context.read<PlayerCubit>();
    final generation = player.playbackOccurrenceRevision;
    final queueId = player.state.currentQueueId;
    final profile = db.profileId;

    bool isCurrent() {
      final state = player.state;
      return !player.isClosed &&
          db.profileId == profile &&
          player.playbackOccurrenceRevision == generation &&
          state.currentQueueId == queueId &&
          state.currentlyPlaying?.videoId == video.videoId &&
          !state.isAudio &&
          !state.isHidden &&
          !state.isClosing;
    }

    if (!isCurrent()) return;
    _openPanel(
      context,
      AppLocalizations.of(context)!.videoChapters,
      WatchChapterList(
        player: player,
        chapters: chapters,
        isCurrent: isCurrent,
        showHeading: onOpenPanel == null,
      ),
      scrollable: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locals = AppLocalizations.of(context)!;
    final distractionFree = context
        .select((SettingsCubit cubit) => cubit.state.distractionFreeMode);
    final showDislikes = context
        .select((SettingsCubit cubit) => cubit.state.useReturnYoutubeDislike);
    final channelId = video.authorId;
    final channel = video.author ?? '';
    final title = video.title ?? '';
    final viewCount = video.viewCount;
    final chapters =
        inPlayer && video.liveNow != true && video.isUpcoming != true
            ? video.chaptersFor(Duration(seconds: video.lengthSeconds ?? 0))
            : const <VideoChapter>[];
    final metadata = [
      if (viewCount != null && viewCount > 0)
        video.viewCountText ?? compactCurrency.format(viewCount),
      if (video.publishedText?.isNotEmpty == true) video.publishedText!,
      if (video.liveNow == true) locals.streamIsLive,
      '…${MaterialLocalizations.of(context).moreButtonTooltip.toLowerCase()}',
    ].join(' · ');

    void openDescription() => _openPanel(
          context,
          locals.info,
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            VideoInfo(video: video, titleAndChannelInfo: false),
          ]),
        );

    Widget reactionButtons(int? count) => AddToPlayListButton(
          videoId: video.videoId,
          video: video,
          type: AddToPlayListButtonType.watch,
          inPlayer: inPlayer,
          reactionMetric: count == null
              ? null
              : DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.thumb_down_outlined, size: 18),
                      const SizedBox(width: 7),
                      Text(NumberFormat.compact(
                              locale:
                                  Localizations.localeOf(context).toString())
                          .format(count)),
                    ]),
                  ),
                ),
        );

    final avatar = InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: channelId == null || channelId.isEmpty
          ? null
          : () {
              if (inPlayer) context.read<PlayerCubit>().showMiniPlayer();
              AutoRouter.of(context).push(ChannelRoute(channelId: channelId));
            },
      child: Row(children: [
        ChannelAvatar(name: channel, images: video.authorThumbnails, size: 44),
        const SizedBox(width: 10),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(channel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(fontSize: 16)),
            if (video.subCountText?.isNotEmpty == true)
              Text(video.subCountText!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
      ]),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (inPlayer) ...[
            WatchPlaybackActions(video: video),
            const SizedBox(height: 12),
          ],
          VideoChannelCommunityLabels(
              authorId: channelId, authorUrl: video.authorUrl),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
                child: InkWell(
              key: const ValueKey('watch-open-description'),
              onTap: openDescription,
              // Flow's VideoInfoSection also copies the title on a long press.
              onLongPress: title.isEmpty
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: title));
                      await HapticFeedback.selectionClick();
                    },
              child: Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              height: 1.25)),
                      const SizedBox(height: 4),
                      Text(metadata,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ]),
              ),
            )),
            if (inPlayer) ...[
              if (chapters.isNotEmpty)
                IconButton(
                  key: const ValueKey('watch-open-chapters'),
                  tooltip: locals.videoChapters,
                  icon: const Icon(Icons.segment_rounded),
                  onPressed: () => _openChapters(context, chapters),
                ),
              if (!queueDockVisible)
                IconButton(
                  key: const ValueKey('watch-open-queue'),
                  tooltip: locals.videoQueue,
                  icon: const Icon(Icons.playlist_play_rounded),
                  onPressed: () => _openPanel(
                      context, locals.videoQueue, const VideoQueue(),
                      scrollable: false),
                ),
            ],
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: avatar),
            if (channelId != null && channelId.isNotEmpty) ...[
              const SizedBox(width: 8),
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SubscribeButton(
                      key: ValueKey(channelId),
                      channelId: channelId,
                      subCount: '',
                      watchStyle: true),
                ),
              ),
            ],
          ]),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              if (inPlayer)
                VideoDislikeMetrics(
                  key: ValueKey(video.videoId),
                  video: video,
                  builder: (context, count) => reactionButtons(count),
                )
              else
                reactionButtons(showDislikes ? dislikes : null),
              const SizedBox(width: 8),
              WatchNotesButton(
                videoId: video.videoId,
                labeled: true,
                onStartAt: onStartAt,
              ),
              const SizedBox(width: 8),
              _WatchAction(
                icon: downloadIcon,
                label: locals.download,
                onPressed: onDownload ??
                    () => DownloadModalSheet.showVideoModalSheet(context, video,
                        inPlayer: inPlayer),
              ),
              const SizedBox(width: 8),
              _WatchAction(
                icon: Icons.share_outlined,
                label: locals.share,
                onPressed: () => showSharingSheet(context, video,
                    showTimestampOption: inPlayer, inPlayer: inPlayer),
              ),
              if (extraAction case final action?) action,
            ]),
          ),
          if (!distractionFree) ...[
            const SizedBox(height: 16),
            _FlowCommentsPreview(
              key: ValueKey(video.videoId),
              video: video,
              onOpen: _openComments,
            ),
            if (showRelated) ...[
              const SizedBox(height: 14),
              RecommendedVideos(
                video: video,
                watchStyle: true,
                activeWatch: inPlayer,
                watchGrid: relatedGrid,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Translates Flow's CommentsPreview.kt with the selected instance's first page.
/// Reuse a completed top page when opening or switching back to that sort.
class _FlowCommentsPreview extends StatelessWidget {
  final Video video;
  final void Function(BuildContext context, Widget comments) onOpen;

  const _FlowCommentsPreview(
      {super.key, required this.video, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locals = AppLocalizations.of(context)!;
    final blurPreview = context
        .select((SettingsCubit cubit) => cubit.state.hideCommentsByDefault);
    return BlocProvider(
      create: (_) => CommentsCubit(
        CommentsState.init(video: video, source: 'youtube', sortBy: 'top'),
      ),
      child: BlocBuilder<CommentsCubit, CommentsState>(
        builder: (context, state) {
          final page = !state.loadingComments && state.error.isEmpty
              ? state.comments
              : null;
          final count = page?.commentCount;
          final first = page?.comments.firstOrNull;
          final snippet = first?.content.trim() ?? '';
          return Material(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              key: const ValueKey('watch-open-comments'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => onOpen(
                context,
                CommentsContainer(
                    video: video, topPage: page, watchStyle: true),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text(
                          count != null && count > 0
                              ? '${locals.comments} · ${compactCurrency.format(count)}'
                              : locals.comments,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded, size: 20),
                    ]),
                    if (first != null && snippet.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      ConditionalWrap(
                        wrapIf: blurPreview,
                        wrapper: (child) => ExcludeSemantics(
                          child: ClipRect(
                            child: ImageFiltered(
                              imageFilter:
                                  ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                              child: child,
                            ),
                          ),
                        ),
                        child: Row(children: [
                          ChannelAvatar(
                            name: first.author,
                            images: first.authorThumbnails,
                            size: 24,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(snippet,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                          ),
                        ]),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _WatchAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const _WatchAction(
      {required this.icon, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FilledButton.tonalIcon(
      style: FilledButton.styleFrom(
        backgroundColor: colors.surfaceContainerHighest,
        foregroundColor: colors.onSurface,
        padding: const EdgeInsets.symmetric(horizontal: 14),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(label),
    );
  }
}
