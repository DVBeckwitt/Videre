import 'package:clipious/utils/motion.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/app/views/components/player_placeholder.dart';
import 'package:clipious/player/views/components/video_retry_notice.dart';
import 'package:clipious/player/views/components/player.dart';
import 'package:clipious/podcasts/views/podcast_player_controls.dart';

import '../../../player/states/player.dart';
import '../../../player/views/components/mini_player_aware.dart';
import '../../../utils.dart';
import '../../states/app.dart';

@RoutePage()
class MainScreen extends StatelessWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final deviceType = getDeviceType();
      final orientation =
          context.select((PlayerCubit value) => value.state.orientation);

      final bool globalLoading =
          context.select((AppCubit value) => value.state.globalLoading);
      final playerHorizontalPosition = orientation == Orientation.landscape &&
              deviceType == DeviceType.tablet
          ? getFractionOfAvailableSpace(context, tabletMiniPlayerFraction)
          : const Size(0, 0);
      var colors = Theme.of(context).colorScheme;
      final podcasts = context.read<PlayerCubit>().podcasts;
      // Routed pages sit inside MiniPlayerAware's SafeArea. Their AppBars do
      // not cover the status inset, so give that inset a theme-owned fallback
      // when the expanded Music AppBar (with light icons) leaves the viewport.
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: (colors.brightness == Brightness.dark
                ? SystemUiOverlayStyle.light
                : SystemUiOverlayStyle.dark)
            .copyWith(
                statusBarColor: colors.surface,
                systemNavigationBarColor: colors.surface),
        child: ListenableBuilder(
          listenable: podcasts,
          builder: (context, _) => Container(
            color: colors.surface,
            child: Stack(
              children: [
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: MiniPlayerAware(
                    child: AutoRouter(),
                  ),
                ),
                if (!podcasts.active)
                  Positioned(
                      left: playerHorizontalPosition.width,
                      bottom: 0,
                      right: playerHorizontalPosition.width,
                      child: SafeArea(child: const PlayerPlaceHolder())),
                if (!podcasts.active) Player(constraints.maxHeight),
                if (podcasts.active && !globalLoading)
                  Positioned(
                      left: playerHorizontalPosition.width,
                      right: playerHorizontalPosition.width,
                      bottom: MediaQuery.viewInsetsOf(context).bottom,
                      child: SafeArea(
                          top: false,
                          child: PodcastPlaybackBar(controller: podcasts))),
                if (!globalLoading && !podcasts.active)
                  const Positioned.fill(child: PlayerRetryIndicator()),
                if (globalLoading)
                  Positioned(
                      child: Container(
                          color: colors.surface.withValues(alpha: 0.5),
                          child: const Center(
                            child: MotionLoadingIndicator(
                                child: CircularProgressIndicator()),
                          )))
              ],
            ),
          ),
        ),
      );
    });
  }
}
