import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/minimize_on_swipe_down.dart';
import 'package:clipious/utils.dart';

import '../../models/video.dart';
import '../components/info.dart';

@RoutePage()
class VideoInfoTab extends StatelessWidget {
  final Video? video;
  final int? dislikes;
  final bool titleAndChannelInfo;

  const VideoInfoTab(
      {super.key, this.video, this.dislikes, this.titleAndChannelInfo = true});

  @override
  Widget build(BuildContext context) {
    return video == null
        ? const SizedBox.shrink()
        : MinimizeOnSwipeDown(
            enabled: getDeviceType() == DeviceType.phone,
            scrollable: true,
            onSwipeDown: () {
              context.read<PlayerCubit>().showMiniPlayer();
              AutoRouter.of(context).maybePop();
            },
            child: VideoInfo(
              video: video!,
              dislikes: dislikes,
              titleAndChannelInfo: titleAndChannelInfo,
            ),
          );
  }
}
