import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_swipe_action_cell/core/cell.dart';
import 'package:clipious/playlists/views/components/playlist_thumbnail.dart';
import 'package:clipious/utils/views/components/placeholders.dart';
import 'package:clipious/videos/views/components/compact_video.dart';

import '../../../globals.dart';
import '../../states/playlist.dart';
import 'playlist_playback_actions.dart';

class PlaylistInnerView extends StatelessWidget {
  final bool canDeleteVideos;
  final Function(BuildContext context, Video video) removeVideoFromPlaylist;
  final Function(BuildContext context, Video video) openVideo;
  const PlaylistInnerView(
      {super.key,
      required this.canDeleteVideos,
      required this.removeVideoFromPlaylist,
      required this.openVideo});

  @override
  Widget build(BuildContext context) {
    final cubit = context.watch<PlaylistCubit>();
    final state = cubit.state;
    final videos = state.playlist.videos.where((v) => !v.filterHide).toList();
    final current = context.select((PlayerCubit player) =>
        (player.playlistReference, player.state.currentQueueId));
    final locals = AppLocalizations.of(context)!;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: tabletMaxVideoWidth),
        // Let the header scroll with the entries on short or landscape screens.
        child: ListView.builder(
          controller: cubit.scrollController,
          padding:
              const EdgeInsets.symmetric(horizontal: innerHorizontalPadding),
          itemCount: videos.length + 1 + (state.loading ? 3 : 0),
          itemBuilder: (context, index) {
            if (index == 0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PlaylistThumbnails(videos: state.playlist.videos),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: PlaylistPlaybackActions(),
                  ),
                ],
              );
            }
            if (index > videos.length) return const CompactVideoPlaceHolder();
            final video = videos[index - 1];
            final entryId = playbackQueueId(video);
            final playing =
                current.$1 == cubit.reference && current.$2 == entryId;
            return SwipeActionCell(
              key: ValueKey('swipe-$entryId'),
              trailingActions: canDeleteVideos
                  ? [
                      SwipeAction(
                        icon: const Icon(Icons.delete, color: Colors.white),
                        performsFirstActionWithFullSwipe: false,
                        onTap: (handler) async {
                          // Keep the row visible until the server confirms removal.
                          await handler(false);
                          if (context.mounted) {
                            await removeVideoFromPlaylist(context, video);
                          }
                        },
                      ),
                    ]
                  : null,
              child: Semantics(
                selected: playing,
                label: playing ? locals.musicNowPlaying : null,
                child: CompactVideo(
                  key: ValueKey(entryId),
                  video: video,
                  highlighted: playing,
                  onTap: !cubit.canPlayEntries ||
                          video.filtered ||
                          video.isUpcoming == true
                      ? null
                      : () => openVideo(context, video),
                  trailing: [
                    PlaylistEntryMenu(
                      video: video,
                      onRemove: canDeleteVideos
                          ? () async => removeVideoFromPlaylist(context, video)
                          : null,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
