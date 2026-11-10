import 'dart:ui';

import 'package:auto_route/auto_route.dart';
import 'package:carousel_slider/carousel_slider.dart';
import 'package:clipious/app/views/tv/screens/tv_home.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/router.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/utils/views/tv/components/tv_overscan.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/video_thumbnail.dart';
import 'package:clipious/videos/views/tv/components/video_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../models/playlist.dart';
import '../../../states/playlist.dart';
import '../../components/playlist_bookmark_button.dart';
import '../../components/playlist_playback_actions.dart';
import '../../screens/playlist.dart';

@RoutePage()
class TvPlaylistScreen extends PlaylistViewScreen {
  const TvPlaylistScreen(
      {super.key,
      required super.playlist,
      required super.canDeleteVideos,
      super.reference,
      super.bookmarkOwner});

  Future<void> _play(BuildContext context,
      {Video? video,
      bool resume = false,
      bool acceptMissing = false,
      bool fromBeginning = false,
      bool? audio}) async {
    final request = await context.read<PlaylistCubit>().playbackRequest(
        video: video,
        resume: resume,
        acceptMissing: acceptMissing,
        fromBeginning: fromBeginning,
        audio: audio);
    if (request == null || !context.mounted) return;
    await AutoRouter.of(context).push(TvPlayerRoute(
        videos: request.videos,
        playlistReference: request.reference,
        playlistLoader: request.loader,
        startIndex: request.startIndex,
        startAt: request.startAt,
        audio: request.audio));
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final player = context.read<PlayerCubit>();
    final textTheme = Theme.of(context).textTheme;
    return BlocProvider(
      create: (context) => PlaylistCubit(
          PlaylistState(playlist: playlist), player,
          reference: reference, bookmarkOwner: bookmarkOwner),
      child: Scaffold(
        body: Shortcuts(
          shortcuts: {
            LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
          },
          child: BlocBuilder<PlaylistCubit, PlaylistState>(
            builder: (context, state) {
              final cubit = context.read<PlaylistCubit>();
              final videos = state.playlist.videos
                  .where((video) => !video.filterHide)
                  .toList();
              final imageHeight =
                  (MediaQuery.sizeOf(context).height * .3).clamp(0.0, 240.0);
              return scopeArtwork(
                  cubit.reference,
                  Stack(children: [
                    if (videos.isNotEmpty)
                      CarouselSlider.builder(
                        itemCount: videos.length,
                        itemBuilder: (context, index, _) {
                          final video = videos[index];
                          return VideoThumbnailView(
                              musicThumbnails: video.musicMetadata?.thumbnails,
                              images: video.deArrowThumbnailUrl == null
                                  ? video.videoThumbnails
                                  : null,
                              videoId: video.videoId,
                              decoration: const BoxDecoration(),
                              thumbnails: video.thumbnails);
                        },
                        options: CarouselOptions(
                          autoPlayCurve: Curves.easeInOutQuad,
                          viewportFraction: 1,
                          enableInfiniteScroll: videos.length > 1,
                          enlargeCenterPage: true,
                          autoPlayInterval: const Duration(seconds: 5),
                          autoPlay: state.showImage && videos.length > 1,
                        ),
                      ),
                    AnimatedPositioned(
                      duration: AppMotion.duration(context),
                      curve: Curves.easeInOutQuad,
                      top: state.showImage ? imageHeight : 0,
                      left: 0,
                      bottom: 0,
                      right: 0,
                      child: BackdropFilter(
                        filter: ImageFilter.blur(
                            sigmaX: state.showImage ? 0 : overlayBlur,
                            sigmaY: state.showImage ? 0 : overlayBlur),
                        child: TvOverscan(
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              color: colors.surface
                                  .withValues(alpha: overlayBackgroundOpacity),
                            ),
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Expanded(
                                    child: Text(
                                      playlist.playlistId == localWatchLaterId
                                          ? locals.watchLater
                                          : state.playlist.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.headlineMedium,
                                    ),
                                  ),
                                  if (!canDeleteVideos &&
                                      cubit.reference != null)
                                    PlaylistBookmarkButton(
                                        playlist: state.playlist,
                                        reference: cubit.reference!),
                                  if ((canDeleteVideos ||
                                          bookmarkOwner != null) &&
                                      playlist.playlistId != localWatchLaterId)
                                    IconButton(
                                      tooltip: locals.delete,
                                      onPressed: () => deletePlayList(context),
                                      icon: const Icon(Icons.delete),
                                    ),
                                ]),
                                Text(locals.nVideos(state.playlist.videoCount)),
                                Focus(
                                  onFocusChange: (focused) {
                                    if (focused) cubit.setShowImage(true);
                                  },
                                  child: PlaylistPlaybackActions(
                                    autofocus: true,
                                    onPlayFromBeginning: (audio) => _play(
                                        context,
                                        fromBeginning: true,
                                        audio: audio),
                                    onResume: (acceptMissing) => _play(context,
                                        resume: true,
                                        acceptMissing: acceptMissing),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Expanded(
                                  child: videos.isEmpty
                                      ? Center(
                                          child: Text(locals.noVideoInPlayList))
                                      : GridView.builder(
                                          controller: cubit.scrollController,
                                          gridDelegate:
                                              const SliverGridDelegateWithFixedCrossAxisCount(
                                                  crossAxisCount: 3,
                                                  childAspectRatio: 16 / 15),
                                          itemCount: videos.length,
                                          itemBuilder: (context, index) {
                                            final video = videos[index];
                                            return Column(
                                              key: ValueKey(video.queueEntryId),
                                              children: [
                                                Expanded(
                                                  child: TvVideoItem(
                                                    video: video,
                                                    autoFocus: false,
                                                    onFocusChange: (focused) {
                                                      if (focused) {
                                                        cubit.setShowImage(
                                                            false);
                                                      }
                                                    },
                                                    onSelect: (_, selected) =>
                                                        _play(context,
                                                            video: selected),
                                                  ),
                                                ),
                                                TextButton.icon(
                                                  onPressed: () =>
                                                      AutoRouter.of(context)
                                                          .push(TvVideoRoute(
                                                              videoId: video
                                                                  .videoId)),
                                                  icon: const Icon(
                                                      Icons.info_outline),
                                                  label: Text(locals
                                                      .playlistViewDetails),
                                                ),
                                              ],
                                            );
                                          },
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ]));
            },
          ),
        ),
      ),
    );
  }
}
