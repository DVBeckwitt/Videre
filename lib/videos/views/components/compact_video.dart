import 'package:clipious/utils/motion.dart';
import 'dart:math' as math;
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/videos/states/compact_video.dart';
import 'package:clipious/videos/views/components/video_thumbnail.dart';

import 'offline_video_thumbnail.dart';
import 'community_browse.dart';
import 'video_duration_badge.dart';
import 'video_watch_progress.dart';

const double compactVideoHeight = 70;

double compactVideoRowHeight(BuildContext context) {
  final textTheme = Theme.of(context).textTheme;
  final scaler = MediaQuery.textScalerOf(context);
  // Paragraph layout rounds individual line boxes; reserve their rounded
  // heights separately so fractional text scales cannot overflow the row.
  final titleLine =
      (scaler.scale(textTheme.titleSmall?.fontSize ?? 14) * 1.2).ceilToDouble();
  final authorLine =
      (scaler.scale(textTheme.bodySmall?.fontSize ?? 12) * 1.2).ceilToDouble();
  return math.max(compactVideoHeight, titleLine * 2 + authorLine + 18);
}

class CompactVideo extends StatelessWidget {
  final Function()? onTap;
  final VoidCallback? onLongPress;
  final bool showChannel;
  final bool showCommunityLabels;
  final bool musicArtwork;
  final Video? video;
  final DownloadedVideo? offlineVideo;
  final bool? highlighted;
  final List<Widget>? trailing;

  const CompactVideo(
      {super.key,
      this.onTap,
      this.onLongPress,
      this.showChannel = true,
      this.showCommunityLabels = false,
      this.musicArtwork = false,
      this.video,
      this.trailing,
      this.highlighted,
      this.offlineVideo})
      : assert(video == null || offlineVideo == null,
            'cannot provide both video and offline video\n');

  @override
  Widget build(BuildContext context) {
    ColorScheme colors = Theme.of(context).colorScheme;
    var textTheme = Theme.of(context).textTheme;

    String title = video?.title ?? offlineVideo?.title ?? '';
    String author = video?.author ?? offlineVideo?.author ?? '';
    String videoId = video?.videoId ?? offlineVideo?.videoId ?? '';
    // Keep artwork stable while allowing two readable title lines at large text.
    final height = compactVideoRowHeight(context);
    Widget labelArtwork(Widget child) => showCommunityLabels && video != null
        ? labelVideoThumbnail(video!, child)
        : child;

    return BlocProvider(
      create: (context) =>
          CompactVideoCubit(CompactVideoState(offlineVideo: offlineVideo)),
      child: BlocBuilder<CompactVideoCubit, CompactVideoState>(
          builder: (context, state) {
        return InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.only(bottom: innerHorizontalPadding),
              child: SizedBox(
                height: height,
                child: Stack(
                  children: [
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: AnimatedFractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        duration:
                            AppMotion.duration(context, animationDuration * 2),
                        widthFactor: (highlighted ?? false) ? 1 : 0,
                        curve: Curves.easeInOutQuad,
                        child: AnimatedContainer(
                          decoration: BoxDecoration(
                              color: (highlighted ?? false)
                                  ? colors.secondaryContainer
                                  : colors.surface,
                              borderRadius: BorderRadius.circular(14)),
                          duration: AppMotion.duration(
                              context, animationDuration * 2),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Row(
                        children: [
                          SizedBox(
                            width: compactVideoHeight * 16 / 9,
                            child: labelArtwork(video?.filtered ?? false
                                ? AspectRatio(
                                    aspectRatio: 16 / 9,
                                    child: Container(
                                      decoration: BoxDecoration(
                                          color: colors.secondaryContainer,
                                          borderRadius:
                                              BorderRadius.circular(14)),
                                      child: Icon(Icons.visibility_off_outlined,
                                          color: colors.secondary
                                              .withValues(alpha: 0.7),
                                          size: 15),
                                    ),
                                  )
                                : video != null
                                    ? VideoThumbnailView(
                                        musicArtwork: musicArtwork,
                                        musicThumbnails:
                                            video!.musicMetadata?.thumbnails,
                                        images:
                                            video!.deArrowThumbnailUrl == null
                                                ? video!.videoThumbnails
                                                : null,
                                        videoId: videoId,
                                        thumbnails: video
                                                    ?.deArrowThumbnailUrl !=
                                                null
                                            ? [video!.deArrowThumbnailUrl!]
                                            : ImageObject
                                                .getThumbnailUrlsByPreferredOrder(
                                                    video?.videoThumbnails),
                                        child: video!.isUpcoming == true
                                            ? null
                                            : Stack(
                                                fit: StackFit.expand,
                                                children: [
                                                  Align(
                                                    alignment:
                                                        Alignment.bottomRight,
                                                    child: Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                              bottom: 4),
                                                      child: VideoDurationBadge(
                                                        lengthSeconds: video!
                                                            .lengthSeconds,
                                                        compact: true,
                                                      ),
                                                    ),
                                                  ),
                                                  VideoWatchProgress(
                                                      videoId: videoId),
                                                ],
                                              ))
                                    : offlineVideo != null
                                        ? OfflineVideoThumbnail(
                                            video: offlineVideo!,
                                          )
                                        : const SizedBox.shrink()),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    video?.filtered ?? false
                                        ? '**********'
                                        : title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: textTheme.titleSmall?.copyWith(
                                        color: colors.onSurface,
                                        height: 1.2,
                                        fontWeight: FontWeight.w600),
                                  ),
                                  if (showChannel && author.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      author,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.bodySmall?.copyWith(
                                          color: colors.onSurfaceVariant,
                                          height: 1.2),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          ...trailing ?? []
                        ],
                      ),
                    )
                  ],
                ),
              ),
            ));
      }),
    );
  }
}
