import 'package:clipious/utils/motion.dart';
import 'package:auto_route/auto_route.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/views/components/navigation_switcher.dart';
import 'package:clipious/videos/states/video_in_list.dart';
import 'package:clipious/videos/views/components/offline_video_thumbnail.dart';
import 'package:clipious/videos/views/components/video_modal_sheet.dart';
import 'package:clipious/videos/views/components/video_thumbnail.dart';
import 'package:logging/logging.dart';

import '../../../downloads/models/downloaded_video.dart';
import '../../../utils.dart';
import '../../../utils/models/image_object.dart';
import '../../../utils/views/components/channel_avatar.dart';
import 'compact_video.dart';
import 'community_browse.dart';
import 'video_metrics.dart';
import 'video_duration_badge.dart';

final log = Logger('VideoInList');

enum VideoCardLayout { standard, flowFeed, flowRow, continueWatching }

// Fresh Flutter presentation based on Flow's VideoCardStacked hierarchy at
// 565d1f7a3da4ca8e54463b029f151ef87415858a. Playback, artwork routing and
// filtering remain Videre's; no upstream network or image-loading code is used.
class VideoListItem extends StatelessWidget {
  final Video? video;
  final DownloadedVideo? offlineVideo;
  final bool small;
  final bool showMetrics;
  final Function(BuildContext context, Video video)? showVideoModalSheet;
  final Function(BuildContext context, Video video)? openVideoOverride;
  final bool allowModalSheet;
  final bool showCommunityLabels;
  final VideoCardLayout layout;
  final bool showChannel;
  final Widget? resumeAction;

  const VideoListItem(
      {super.key,
      this.video,
      this.offlineVideo,
      animateDownload = false,
      this.small = false,
      this.showMetrics = true,
      this.showVideoModalSheet,
      this.allowModalSheet = true,
      this.showCommunityLabels = false,
      this.layout = VideoCardLayout.standard,
      this.showChannel = true,
      this.resumeAction,
      this.openVideoOverride})
      : assert(video == null || offlineVideo == null,
            'cannot provide both video and offline video\n');

  void openVideo(BuildContext context) {
    if (video != null) {
      if (openVideoOverride != null) {
        openVideoOverride!(context, video!);
      } else {
        var cubit = context.read<VideoInListCubit>();
        if (cubit.state.video!.filtered) {
          cubit.showVideoDetails();
        } else {
          if (!(cubit.state.video!.isUpcoming ?? false)) {
            final autoplay =
                context.read<SettingsCubit>().state.autoplayVideoOnLoad;
            AutoRouter.of(context).push(VideoRoute(
                videoId: video!.videoId, playNow: autoplay ? true : null));
          }
        }
      }
    } else if (offlineVideo != null) {
      context.read<PlayerCubit>().playOfflineVideos([offlineVideo!]);
    }
  }

  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    var locals = AppLocalizations.of(context)!;

    var textTheme = Theme.of(context).textTheme;

    TextStyle filterStyle = (textTheme.bodySmall ?? const TextStyle())
        .copyWith(color: colorScheme.secondary.withValues(alpha: 0.7));

    String title = video?.title ?? offlineVideo?.title ?? '';
    String author = video?.author ?? offlineVideo?.author ?? '';
    final flow = layout != VideoCardLayout.standard;
    final resume = layout == VideoCardLayout.continueWatching;
    final radius = small || resume ? 12.0 : 16.0;
    Widget thumbnail(Widget child) => showCommunityLabels && video != null
        ? labelVideoThumbnail(video!, child)
        : child;

    return BlocProvider(
      create: (context) => VideoInListCubit(
          VideoInListState(video: video, offlineVideo: offlineVideo)),
      child: BlocBuilder<VideoInListCubit, VideoInListState>(
        builder: (context, state) => BlocListener<PlayerCubit, PlayerState>(
          listenWhen: (previous, current) =>
              state.video != null &&
              current.currentlyPlaying?.videoId == video!.videoId &&
              previous.position != current.position,
          listener: (context, state) =>
              context.read<VideoInListCubit>().updateProgress(),
          child: layout == VideoCardLayout.flowRow && state.video != null
              ? _compactCard(context, state.video!)
              : InkWell(
                  borderRadius: BorderRadius.circular(radius),
                  onTap: () => openVideo(context),
                  onLongPress: (video?.isUpcoming ?? false) ||
                          !allowModalSheet ||
                          state.video == null ||
                          state.video!.filtered
                      ? null
                      : () => showVideoModalSheet != null
                          ? showVideoModalSheet!(context, video!)
                          : VideoModalSheet.showVideoModalSheet(
                              context, video!),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      (state.video?.filtered ?? false)
                          ? AspectRatio(
                              aspectRatio: 16 / 9,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: colorScheme.secondaryContainer,
                                  borderRadius: BorderRadius.circular(radius),
                                ),
                                child: small
                                    ? Icon(
                                        Icons.visibility_off,
                                        size: 10,
                                        color: colorScheme.secondary,
                                      )
                                    : Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8.0),
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceAround,
                                          children: [
                                            Text(
                                              locals.videoFiltered,
                                              style: filterStyle,
                                            ),
                                            ...video!.matchedFilters
                                                .map((e) => Text(
                                                      e.localizedLabel(
                                                          locals, context),
                                                      style: filterStyle,
                                                    )),
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                  top: 16.0),
                                              child: Text(
                                                locals.videoFilterTapToReveal,
                                                style: filterStyle,
                                              ),
                                            )
                                          ],
                                        ),
                                      ),
                              ),
                            )
                          : video != null
                              ? thumbnail(VideoThumbnailView(
                                  musicThumbnails:
                                      video!.musicMetadata?.thumbnails,
                                  videoId: video!.videoId,
                                  images: video!.deArrowThumbnailUrl == null
                                      ? video!.videoThumbnails
                                      : null,
                                  thumbnails: video!.deArrowThumbnailUrl != null
                                      ? [video!.deArrowThumbnailUrl!]
                                      : ImageObject
                                          .getThumbnailUrlsByPreferredOrder(
                                              video!.videoThumbnails),
                                  decoration: BoxDecoration(
                                      color:
                                          colorScheme.surfaceContainerHighest,
                                      borderRadius:
                                          BorderRadius.circular(radius)),
                                  child: flow
                                      ? _FlowThumbnailStatus(
                                          video: video!,
                                          state: state,
                                          resume: resume,
                                        )
                                      : Padding(
                                          padding: const EdgeInsets.all(8.0),
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.end,
                                            children: video!.isUpcoming ?? false
                                                ? []
                                                : [
                                                    Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment.end,
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .center,
                                                      children: [
                                                        Expanded(
                                                          child:
                                                              NavigationSwitcher(
                                                            child: state.watched ||
                                                                    state.progress >
                                                                        0.05
                                                                ? Align(
                                                                    alignment:
                                                                        Alignment
                                                                            .centerRight,
                                                                    child:
                                                                        Padding(
                                                                      padding: const EdgeInsets
                                                                          .symmetric(
                                                                          horizontal:
                                                                              4.0,
                                                                          vertical:
                                                                              8),
                                                                      child:
                                                                          AnimatedContainer(
                                                                        curve: Curves
                                                                            .easeOutQuad,
                                                                        duration:
                                                                            AppMotion.duration(context),
                                                                        alignment:
                                                                            Alignment.centerLeft,
                                                                        constraints: state.watched
                                                                            ? const BoxConstraints(maxWidth: 20)
                                                                            : const BoxConstraints(maxWidth: 1200),
                                                                        width: double
                                                                            .infinity,
                                                                        height: state.watched
                                                                            ? 20
                                                                            : small
                                                                                ? 1
                                                                                : 5,
                                                                        decoration:
                                                                            BoxDecoration(
                                                                          color:
                                                                              colorScheme.secondaryContainer,
                                                                          borderRadius:
                                                                              BorderRadius.circular(20),
                                                                        ),
                                                                        child: AnimatedFractionallySizedBox(
                                                                            widthFactor: state.watched
                                                                                ? 1
                                                                                : state.progress > 0
                                                                                    ? state.progress
                                                                                    : 0,
                                                                            heightFactor: 1,
                                                                            duration: AppMotion.duration(context),
                                                                            curve: Curves.easeInOutQuad,
                                                                            child: Container(
                                                                              alignment: Alignment.center,
                                                                              decoration: BoxDecoration(
                                                                                color: state.watched ? colorScheme.primaryContainer : colorScheme.primary,
                                                                                borderRadius: BorderRadius.circular(20),
                                                                              ),
                                                                              child: AnimatedCrossFade(
                                                                                crossFadeState: state.watched ? CrossFadeState.showFirst : CrossFadeState.showSecond,
                                                                                duration: AppMotion.duration(context),
                                                                                secondChild: const SizedBox.shrink(),
                                                                                firstChild: Icon(
                                                                                  Icons.check,
                                                                                  size: 15,
                                                                                  color: colorScheme.primary,
                                                                                ),
                                                                              ),
                                                                            )),
                                                                      ),
                                                                    ),
                                                                  )
                                                                : const SizedBox
                                                                    .shrink(),
                                                          ),
                                                        ),
                                                        if ((video!.lengthSeconds ??
                                                                0) >
                                                            0)
                                                          Flexible(
                                                            flex: small ? 1 : 0,
                                                            child:
                                                                VideoDurationBadge(
                                                              lengthSeconds: video!
                                                                  .lengthSeconds,
                                                              compact: small,
                                                            ),
                                                          ),
                                                      ],
                                                    ),
                                                  ],
                                          ),
                                        ),
                                ))
                              : OfflineVideoThumbnail(video: offlineVideo!),
                      if (flow && video != null)
                        _FlowCardDetails(
                          video: video!,
                          state: state,
                          resume: resume,
                          resumeAction: resume ? resumeAction : null,
                          showChannel: showChannel,
                          showMetrics: showMetrics,
                          onMenu: allowModalSheet
                              ? (menuContext) => showVideoModalSheet != null
                                  ? showVideoModalSheet!(menuContext, video!)
                                  : VideoModalSheet.showVideoModalSheet(
                                      menuContext, video!)
                              : null,
                        )
                      else ...[
                        SizedBox(height: small ? 4 : 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.start,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.start,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    (state.video?.filtered ?? false)
                                        ? '**********'
                                        : title,
                                    textAlign: TextAlign.left,
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: small ? 1 : 2,
                                    style: (small
                                            ? textTheme.labelSmall
                                            : textTheme.titleSmall)
                                        ?.copyWith(
                                            color: colorScheme.onSurface,
                                            fontWeight: FontWeight.w600),
                                  ),
                                  if (showChannel)
                                    InkWell(
                                      onTap: () {
                                        AutoRouter.of(context).push(
                                            ChannelRoute(
                                                channelId: video?.authorId ??
                                                    offlineVideo?.authorUrl ??
                                                    ''));
                                      },
                                      child: Text(
                                        author,
                                        maxLines: 1,
                                        textAlign: TextAlign.left,
                                        overflow: TextOverflow.ellipsis,
                                        style: (small
                                                ? textTheme.labelSmall
                                                : textTheme.bodySmall)
                                            ?.copyWith(
                                                color: colorScheme
                                                    .onSurfaceVariant),
                                      ),
                                    ),
                                  if (showMetrics && !small && video != null)
                                    VideoMetrics(
                                      video: video,
                                      style: textTheme.bodySmall?.copyWith(
                                          color: colorScheme.onSurfaceVariant),
                                      showDuration: false,
                                      compact: true,
                                      iconSize: 13,
                                    )
                                ],
                              ),
                            ),
                            if (!(video?.isUpcoming ?? false) &&
                                allowModalSheet &&
                                !small &&
                                video != null)
                              IconButton(
                                tooltip: MaterialLocalizations.of(context)
                                    .moreButtonTooltip,
                                visualDensity: VisualDensity.standard,
                                onPressed: (state.video?.filtered ?? true)
                                    ? null
                                    : () => showVideoModalSheet != null
                                        ? showVideoModalSheet!(context, video!)
                                        : VideoModalSheet.showVideoModalSheet(
                                            context, video!),
                                icon: const Icon(Icons.more_vert, size: 22),
                              )
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _compactCard(BuildContext context, Video current) {
    final showMenu =
        allowModalSheet && !current.filtered && current.isUpcoming != true;
    void openMenu() {
      final callback = showVideoModalSheet;
      if (callback != null) {
        callback(context, current);
      } else {
        VideoModalSheet.showVideoModalSheet(context, current);
      }
    }

    // Flow VideoCardRow.kt uses the same video action on both presentations.
    return CompactVideo(
      video: current,
      showChannel: showChannel && !current.filtered,
      showCommunityLabels: showCommunityLabels,
      onTap: () => openVideo(context),
      onLongPress: showMenu ? openMenu : null,
      trailing: showMenu
          ? [
              IconButton(
                tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
                onPressed: openMenu,
                icon: const Icon(Icons.more_vert),
              ),
            ]
          : null,
    );
  }
}

class _FlowThumbnailStatus extends StatelessWidget {
  final Video video;
  final VideoInListState state;
  final bool resume;

  const _FlowThumbnailStatus({
    required this.video,
    required this.state,
    required this.resume,
  });

  @override
  Widget build(BuildContext context) {
    if (video.isUpcoming == true) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final progress = state.progress.isFinite
        ? state.progress.clamp(0.0, 1.0).toDouble()
        : 0.0;
    final duration = video.lengthSeconds ?? 0;
    return Stack(
      children: [
        PositionedDirectional(
          end: 4,
          bottom: 4,
          child: VideoDurationBadge(
            lengthSeconds:
                resume ? (duration * (1 - progress)).ceil() : duration,
            compact: true,
          ),
        ),
        if (state.watched)
          PositionedDirectional(
            start: 8,
            bottom: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(Icons.check,
                    color: colors.onPrimaryContainer, size: 14),
              ),
            ),
          )
        else if (progress > 0)
          PositionedDirectional(
            start: 0,
            end: 0,
            bottom: 0,
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              color: colors.primary,
              backgroundColor: Colors.black38,
            ),
          ),
      ],
    );
  }
}

class _FlowCardDetails extends StatelessWidget {
  final Video video;
  final VideoInListState state;
  final bool resume;
  final Widget? resumeAction;
  final bool showMetrics;
  final bool showChannel;
  final void Function(BuildContext)? onMenu;

  const _FlowCardDetails({
    required this.video,
    required this.state,
    required this.resume,
    required this.resumeAction,
    required this.showMetrics,
    required this.showChannel,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final author = video.author?.trim() ?? '';
    final date = video.publishedText?.trim() ?? '';
    final views = video.viewCount ?? 0;
    final locals = AppLocalizations.of(context)!;
    final filtered = state.video?.filtered ?? false;
    final canOpenChannel = !filtered && video.authorId?.isNotEmpty == true;
    final byline = [
      if (showChannel && author.isNotEmpty) author,
      if (!resume && showMetrics && views > 0) compactCurrency.format(views),
      if (!resume && showMetrics && video.liveNow == true)
        locals.streamIsLive
      else if (!resume &&
          showMetrics &&
          date.isNotEmpty &&
          !date.startsWith('0'))
        date,
    ].join('  •  ');
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
          resume ? 0 : 12, resume ? 6 : 12, 0, resume ? 4 : 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showChannel && !resume && !filtered && author.isNotEmpty)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: Semantics(
                label: author,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: canOpenChannel
                      ? () => context.router
                          .push(ChannelRoute(channelId: video.authorId!))
                      : null,
                  child: SizedBox.square(
                    dimension: 48,
                    child: Center(
                      child: ChannelAvatar(
                          name: author,
                          images: video.authorThumbnails,
                          size: 40),
                    ),
                  ),
                ),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  filtered ? '**********' : video.title ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: (resume
                          ? theme.textTheme.bodyMedium
                          : theme.textTheme.titleMedium)
                      ?.copyWith(
                          color: colors.onSurface,
                          fontWeight:
                              resume ? FontWeight.w600 : FontWeight.w500,
                          height: 1.22),
                ),
                if (byline.isNotEmpty && !filtered) ...[
                  const SizedBox(height: 4),
                  Text(byline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant)),
                ],
              ],
            ),
          ),
          if (resumeAction case final action?)
            action
          else if (onMenu != null && video.isUpcoming != true)
            IconButton(
              tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
              visualDensity: VisualDensity.standard,
              alignment: Alignment.topCenter,
              onPressed: filtered ? null : () => onMenu!(context),
              icon: const Icon(Icons.more_vert, size: 22),
            ),
        ],
      ),
    );
  }
}
