import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/playlists/views/components/playlist_thumbnail.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/views/components/placeholders.dart';
import 'package:clipious/videos/views/components/video_in_list.dart';
import 'package:clipious/videos/states/video_in_list.dart';

import '../../../globals.dart';
import '../../states/playlist.dart';
import '../components/playlist_playback_actions.dart';

class TabletPlaylistInnerView extends StatelessWidget {
  final bool canDeleteVideos;
  final Function(BuildContext context, Video video) removeVideoFromPlaylist;
  final Function(BuildContext context, Video video) openVideo;

  const TabletPlaylistInnerView(
      {super.key,
      required this.canDeleteVideos,
      required this.removeVideoFromPlaylist,
      required this.openVideo});

  void showVideoModalSheet(BuildContext context, Video video) {
    video = context.read<VideoInListCubit>().state.video ?? video;
    showPlaylistEntryActions(context, video,
        onRemove: canDeleteVideos
            ? () async => removeVideoFromPlaylist(context, video)
            : null);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final cubit = context.watch<PlaylistCubit>();
    final state = cubit.state;
    final videos = state.playlist.videos.where((v) => !v.filterHide).toList();
    final current = context.select((PlayerCubit player) =>
        (player.playlistReference, player.state.currentQueueId));
    return LayoutBuilder(builder: (context, constraints) {
      final headerWidth = (constraints.maxWidth * 0.38).clamp(240.0, 375.0);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: headerWidth,
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PlaylistThumbnails(videos: state.playlist.videos),
                  const PlaylistPlaybackActions(),
                ],
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(builder: (context, listConstraints) {
              final columns =
                  (listConstraints.maxWidth / 260).floor().clamp(1, 4);
              return GridView.builder(
                controller: cubit.scrollController,
                padding: const EdgeInsets.only(right: innerHorizontalPadding),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: getGridAspectRatio(context),
                ),
                itemCount: videos.length + (state.loading ? columns : 0),
                itemBuilder: (context, index) {
                  if (index >= videos.length) {
                    return const VideoListItemPlaceHolder();
                  }
                  final video = videos[index];
                  final entryId = playbackQueueId(video);
                  final playing =
                      current.$1 == cubit.reference && current.$2 == entryId;
                  return DecoratedBox(
                    key: ValueKey(entryId),
                    decoration: BoxDecoration(
                      color: playing ? colors.secondaryContainer : null,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Semantics(
                      selected: playing,
                      child: VideoListItem(
                        key: ValueKey('video-$entryId'),
                        video: video,
                        showMetrics: false,
                        showVideoModalSheet: showVideoModalSheet,
                        allowModalSheet: true,
                        openVideoOverride: (context, video) {
                          final row = context.read<VideoInListCubit>();
                          final selected = row.state.video;
                          if (!cubit.canPlayEntries || selected == null) return;
                          if (selected.filtered) {
                            row.showVideoDetails();
                          } else if (!selected.filterHide &&
                              selected.isUpcoming != true) {
                            openVideo(context, selected);
                          }
                        },
                      ),
                    ),
                  );
                },
              );
            }),
          ),
        ],
      );
    });
  }
}
