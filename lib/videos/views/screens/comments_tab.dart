import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/minimize_on_swipe_down.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/comments/views/components/comments_container.dart';

import '../../models/video.dart';

@RoutePage()
class CommentsTab extends StatelessWidget {
  final Video? video;
  const CommentsTab({super.key, this.video});

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
            child: CommentsContainer(video: video!),
          );
  }
}
