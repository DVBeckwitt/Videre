import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/podcasts/views/podcast_player_controls.dart';

class MiniPlayerAware extends StatelessWidget {
  final Widget child;

  const MiniPlayerAware({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Builder(
        builder: (
          context,
        ) {
          bool isHidden =
              context.select((PlayerCubit cubit) => cubit.state.isHidden);
          bool isClosing =
              context.select((PlayerCubit cubit) => cubit.state.isClosing);
          bool isMini =
              context.select((PlayerCubit cubit) => cubit.state.isMini);

          final podcasts = context.read<PlayerCubit>().podcasts;
          return ListenableBuilder(
            listenable: podcasts,
            builder: (context, _) => AnimatedContainer(
              padding: EdgeInsets.only(
                  bottom: podcasts.active
                      ? podcastBarHeight
                      : !isHidden && isMini && !isClosing
                          ? targetHeight
                          : 0),
              duration: AppMotion.duration(context),
              curve: Curves.easeInOutQuad,
              child: child,
            ),
          );
        },
      ),
    );
  }
}
