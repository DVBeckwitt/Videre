import 'dart:math';

import 'package:clipious/utils/motion.dart';
import 'package:auto_route/auto_route.dart';
import 'package:clipious/router.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/states/video_in_list.dart';
import 'package:duration/duration.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';

import '../../../../globals.dart';
import '../../components/video_thumbnail.dart';

/// Keeps TV grid rows tall enough for the thumbnail and three text lines.
class TvVideoGridDelegate extends SliverGridDelegate {
  static const columns = 3;

  final double _metadataHeight;

  TvVideoGridDelegate(BuildContext context)
      : _metadataHeight = _measureMetadata(context);

  static double _measureMetadata(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(style: Theme.of(context).textTheme.bodyLarge),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    // Two title lines and one channel line, including the theme's line height.
    final height = painter.preferredLineHeight * 3;
    painter.dispose();
    return height;
  }

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final width = constraints.crossAxisExtent / columns;
    final thumbnailHeight = max(0.0, width - TvVideoItem._endPadding) * 9 / 16;
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      mainAxisExtent: max(width * 13 / 16, thumbnailHeight + _metadataHeight)
          .ceilToDouble(),
    ).getLayout(constraints);
  }

  @override
  bool shouldRelayout(covariant TvVideoGridDelegate oldDelegate) =>
      _metadataHeight != oldDelegate._metadataHeight;
}

class TvVideoItem extends StatelessWidget {
  static const _endPadding = 8.0;

  final Video video;
  final bool autoFocus;
  final void Function(bool focus)? onFocusChange;
  final Function(BuildContext context, Video video)? onSelect;

  const TvVideoItem(
      {super.key,
      required this.video,
      required this.autoFocus,
      this.onSelect,
      this.onFocusChange});

  KeyEventResult openVideo(
      BuildContext context, Video e, FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent &&
        isOk(event.logicalKey, physicalKeyboardKey: event.physicalKey)) {
      if (e.filtered) {
        var cubit = context.read<VideoInListCubit>();
        cubit.showVideoDetails();
        return KeyEventResult.handled;
      }
      if (onSelect != null) {
        onSelect!(context, e);
      } else {
        if (!(video.isUpcoming ?? false)) {
          AutoRouter.of(context).push(TvVideoRoute(videoId: e.videoId));
        }
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    ColorScheme colors = Theme.of(context).colorScheme;
    TextTheme textTheme = Theme.of(context).textTheme;
    var locals = AppLocalizations.of(context)!;
    TextStyle filterStyle = (textTheme.bodySmall ?? const TextStyle())
        .copyWith(color: colors.secondary.withValues(alpha: 0.7));
    final premiereTimestamp = video.premiereTimestamp;
    final untilPremiere = video.isUpcoming == true && premiereTimestamp != null
        ? DateTime.fromMillisecondsSinceEpoch(premiereTimestamp * 1000)
            .difference(DateTime.now())
        : Duration.zero;

    return BlocProvider(
      create: (context) =>
          VideoInListCubit(VideoInListState(video: video, offlineVideo: null)),
      child: BlocBuilder<VideoInListCubit, VideoInListState>(
        builder: (context, state) => DefaultTextStyle(
          style: textTheme.bodyLarge!,
          child: Padding(
            padding: const EdgeInsets.only(right: _endPadding),
            child: Focus(
                onFocusChange: onFocusChange,
                onKeyEvent: (node, event) =>
                    openVideo(context, state.video!, node, event),
                autofocus: autoFocus,
                child: Builder(builder: (ctx) {
                  final FocusNode focusNode = Focus.of(ctx);
                  final bool hasFocus = focusNode.hasFocus;
                  return GestureDetector(
                    child: AnimatedScale(
                      curve: Curves.easeInOutQuad,
                      duration:
                          AppMotion.duration(context, animationDuration ~/ 2),
                      scale: hasFocus ? 1 : 0.9,
                      child: AnimatedContainer(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(15),
                            color: colors.primaryContainer
                                .withValues(alpha: hasFocus ? 1 : 0),
                          ),
                          duration: AppMotion.duration(context),
                          child: AspectRatio(
                            aspectRatio: 16 / 13,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.start,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                (state.video?.filtered ?? false)
                                    ? AspectRatio(
                                        aspectRatio: 16 / 9,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: colors.secondaryContainer,
                                            borderRadius:
                                                BorderRadius.circular(10),
                                          ),
                                          padding: const EdgeInsets.all(5),
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceAround,
                                            children: [
                                              Text(
                                                locals.videoFiltered,
                                                style: filterStyle,
                                              ),
                                              ...video.matchedFilters
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
                                      )
                                    : Flexible(
                                        // Give the text its actual line height,
                                        // including fallback font metrics.
                                        child: VideoThumbnailView(
                                            musicThumbnails:
                                                video.musicMetadata?.thumbnails,
                                            videoId: video.videoId,
                                            images: video.deArrowThumbnailUrl ==
                                                    null
                                                ? video.videoThumbnails
                                                : null,
                                            thumbnails: video.thumbnails,
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.all(8.0),
                                              child: Container(
                                                alignment:
                                                    Alignment.bottomRight,
                                                child: Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.end,
                                                  children:
                                                      untilPremiere >
                                                              Duration.zero
                                                          ? [
                                                              Text(locals.premieresIn(
                                                                  prettyDuration(
                                                                      untilPremiere,
                                                                      maxUnits:
                                                                          1))),
                                                            ]
                                                          : [
                                                              if (state.progress >
                                                                      0.05 &&
                                                                  !state
                                                                      .watched)
                                                                Expanded(
                                                                  child:
                                                                      Container(
                                                                    margin: const EdgeInsets
                                                                        .only(
                                                                        right:
                                                                            8),
                                                                    alignment:
                                                                        Alignment
                                                                            .centerLeft,
                                                                    height: 5,
                                                                    width: double
                                                                        .infinity,
                                                                    decoration:
                                                                        BoxDecoration(
                                                                      color: colors
                                                                          .secondaryContainer,
                                                                      borderRadius:
                                                                          BorderRadius.circular(
                                                                              20),
                                                                    ),
                                                                    child:
                                                                        FractionallySizedBox(
                                                                      widthFactor:
                                                                          state
                                                                              .progress,
                                                                      heightFactor:
                                                                          1,
                                                                      child:
                                                                          Container(
                                                                        decoration:
                                                                            BoxDecoration(
                                                                          color: state.watched
                                                                              ? colors.primaryContainer
                                                                              : colors.primary,
                                                                          borderRadius:
                                                                              BorderRadius.circular(20),
                                                                        ),
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                              if (state.watched)
                                                                Container(
                                                                  margin:
                                                                      const EdgeInsets
                                                                          .only(
                                                                          right:
                                                                              8),
                                                                  padding:
                                                                      const EdgeInsets
                                                                          .all(
                                                                          5),
                                                                  decoration: BoxDecoration(
                                                                      color: colors
                                                                          .primaryContainer,
                                                                      shape: BoxShape
                                                                          .circle),
                                                                  child: Icon(
                                                                    Icons.check,
                                                                    size: 15,
                                                                    color: colors
                                                                        .primary,
                                                                  ),
                                                                ),
                                                              if (video
                                                                      .lengthSeconds !=
                                                                  null)
                                                                Container(
                                                                  decoration: BoxDecoration(
                                                                      color: Colors
                                                                          .black
                                                                          .withValues(
                                                                              alpha:
                                                                                  0.5),
                                                                      borderRadius:
                                                                          BorderRadius.circular(
                                                                              5)),
                                                                  child:
                                                                      Padding(
                                                                    padding:
                                                                        const EdgeInsets
                                                                            .all(
                                                                            3.0),
                                                                    child: Text(
                                                                      prettyDurationCustom(Duration(
                                                                          seconds:
                                                                              video.lengthSeconds ?? 0)),
                                                                      style: textTheme
                                                                          .bodySmall
                                                                          ?.copyWith(
                                                                              color: Colors.white),
                                                                    ),
                                                                  ),
                                                                ),
                                                            ],
                                                ),
                                              ),
                                            ))),
                                Padding(
                                  padding: const EdgeInsets.only(left: 8.0),
                                  child: Text(
                                    (state.video?.filtered ?? false)
                                        ? '**********'
                                        : video.title ?? '',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: colors.primary),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(left: 8.0),
                                  child: Text(
                                    video.author ?? '',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: colors.secondary),
                                  ),
                                ),
                              ],
                            ),
                          )),
                    ),
                  );
                })),
          ),
        ),
      ),
    );
  }
}
