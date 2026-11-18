import 'package:clipious/music/views/components/music_playback_artwork.dart';
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/player/views/components/player_controls.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/videos/views/components/offline_video_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../downloads/models/downloaded_video.dart';
import '../../../videos/models/video.dart';
import '../../../videos/views/components/video_thumbnail.dart';
import '../../states/audio_player.dart';
import '../../states/player.dart';

class AudioPlayer extends StatelessWidget {
  final Video? video;
  final DownloadedVideo? offlineVideo;
  final bool miniPlayer;

  const AudioPlayer(
      {super.key, this.video, required this.miniPlayer, this.offlineVideo})
      : assert(video == null || offlineVideo == null,
            'cannot provide both video and offline video\n');

  @override
  Widget build(BuildContext context) {
    var player = context.read<PlayerCubit>();
    var settings = context.read<SettingsCubit>();

    return BlocProvider(
      create: (context) => AudioPlayerCubit(
          AudioPlayerState(offlineVideo: offlineVideo, video: video),
          player,
          settings),
      child: BlocBuilder<AudioPlayerCubit, AudioPlayerState>(
        builder: (context, playerState) =>
            BlocListener<PlayerCubit, PlayerState>(
          listenWhen: (previous, current) =>
              previous.mediaCommand != current.mediaCommand &&
              current.mediaCommand != null,
          listener: (context, state) => context
              .read<AudioPlayerCubit>()
              .handleCommand(state.mediaCommand!),
          child: Padding(
            padding: EdgeInsets.all(miniPlayer ? 8 : 0.0),
            child: Stack(
              alignment: Alignment.topCenter,
              children: [
                if ((video?.musicMetadata ?? offlineVideo?.musicMetadata)
                    case final music?)
                  if (context.select((PlayerCubit cubit) =>
                      cubit.state.isPip ||
                      cubit.state.fullScreenState ==
                          FullScreenState.fullScreen))
                    AspectRatio(
                        aspectRatio: 16 / 9,
                        child: MusicPlaybackArtwork(
                            music: music, video: video, offline: offlineVideo))
                  else
                    // Music has its own visible artwork. This mounted decoder
                    // stays offstage until fullscreen or picture-in-picture.
                    const SizedBox.shrink()
                else if (video case final source?)
                  VideoThumbnailView(
                    images: source.deArrowThumbnailUrl == null
                        ? source.videoThumbnails
                        : null,
                    decoration: const BoxDecoration(),
                    videoId: source.videoId,
                    thumbnails: source.thumbnails,
                  )
                else if (offlineVideo case final source?)
                  OfflineVideoThumbnail(
                      borderRadius: 0,
                      key: ValueKey(source.videoId),
                      video: source),
                PlayerControls(
                    mediaPlayerCubit: context.read<AudioPlayerCubit>())
              ],
            ),
          ),
        ),
      ),
    );
  }
}
