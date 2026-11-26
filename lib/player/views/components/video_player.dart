import 'package:clipious/main.dart' show isTv;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/player/states/video_player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:river_player/river_player.dart';

import '../../../videos/models/video.dart';
import '../../states/interfaces/media_player.dart';
import '../../states/player.dart';
import 'fullscreen_video_zoom.dart';

class VideoPlayer extends StatefulWidget {
  final Video? video;
  final DownloadedVideo? offlineVideo;
  final bool miniPlayer;
  final bool? playNow;
  final bool? disableControls;
  final Duration? startAt;

  const VideoPlayer(
      {super.key,
      this.video,
      required this.miniPlayer,
      this.playNow,
      this.disableControls,
      this.offlineVideo,
      this.startAt})
      : assert(video == null || offlineVideo == null,
            'cannot provide both video and offline video\n');

  @override
  State<VideoPlayer> createState() => _VideoPlayerState();
}

class _VideoPlayerState extends State<VideoPlayer> {
  final GlobalKey _betterPlayerKey = GlobalKey();
  final _zoom = FullscreenVideoZoom();

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    Color overFlowTextColor =
        Theme.of(context).textTheme.bodyMedium?.color ?? Colors.black;

    var player = context.read<PlayerCubit>();
    var settings = context.read<SettingsCubit>();
    final displayMode =
        context.select((SettingsCubit cubit) => cubit.state.videoDisplayMode);
    final canZoom = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        !isTv &&
        context.select((PlayerCubit cubit) =>
            cubit.state.fullScreenState == FullScreenState.fullScreen &&
            !cubit.state.isPip &&
            !cubit.state.isMini);

    return BlocProvider(
      create: (context) => VideoPlayerCubit(
          VideoPlayerState(
              startAt: widget.startAt,
              overFlowTextColor: overFlowTextColor,
              colors: colorScheme,
              key: _betterPlayerKey,
              video: widget.video,
              offlineVideo: widget.offlineVideo,
              disableControls: widget.disableControls),
          player,
          settings),
      child: BlocBuilder<VideoPlayerCubit, VideoPlayerState>(
        builder: (context, playerState) {
          var cubit = context.read<VideoPlayerCubit>();
          return MultiBlocListener(
            listeners: [
              BlocListener<PlayerCubit, PlayerState>(
                listenWhen: (previous, current) =>
                    previous.mediaCommand != current.mediaCommand &&
                    current.mediaCommand != null,
                listener: (context, state) =>
                    cubit.handleCommand(state.mediaCommand!),
              ),
              BlocListener<PlayerCubit, PlayerState>(
                listenWhen: (previous, current) =>
                    previous.fullScreenState != current.fullScreenState ||
                    previous.isPip != current.isPip ||
                    previous.isMini != current.isMini ||
                    previous.currentQueueId != current.currentQueueId,
                listener: (context, state) => _zoom.reset(),
              ),
              BlocListener<SettingsCubit, SettingsState>(
                listenWhen: (previous, current) =>
                    previous.videoDisplayMode != current.videoDisplayMode,
                listener: (context, state) => _zoom.reset(),
              ),
            ],
            child: cubit.videoController == null
                ? const SizedBox.shrink()
                : FullscreenVideoZoomScope(
                    zoom: canZoom ? _zoom : null,
                    child: BetterPlayer(
                      controller: cubit.videoController!,
                      key: _betterPlayerKey,
                      fit: displayMode.boxFit,
                      videoAspectRatio: displayMode.aspectRatio,
                      videoSurfaceBuilder: _zoom.buildSurface,
                    ),
                  ),
          );
        },
      ),
    );
  }
}
