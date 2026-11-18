import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/mini_player_controls.dart';
import 'package:clipious/player/views/components/mini_player_progress.dart';

import '../../../videos/models/video.dart';

class MiniPlayer extends StatelessWidget {
  final bool watchStyle;

  const MiniPlayer({super.key, this.watchStyle = false});

  @override
  Widget build(BuildContext context) {
    var textTheme = Theme.of(context).textTheme;
    if (watchStyle) {
      final locals = AppLocalizations.of(context)!;
      final state = context.select((PlayerCubit player) => (
            video: player.state.currentlyPlaying,
            playing: player.state.isPlaying,
          ));
      final player = context.read<PlayerCubit>();
      final finished = context.select((PlayerCubit player) =>
          player.duration > Duration.zero &&
          player.state.position >= player.duration);
      return Stack(
        children: [
          Positioned.fill(
            bottom: 2,
            child: Row(children: [
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Flexible(
                        child: Text(state.video?.title ?? '',
                            style: textTheme.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                    Flexible(
                        child: Text(state.video?.author ?? '',
                            style: textTheme.bodySmall?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('watch-mini-play'),
                tooltip: state.playing ? locals.musicPause : locals.musicPlay,
                onPressed: finished && !state.playing
                    ? () {
                        player.seek(Duration.zero);
                        player.play();
                      }
                    : player.togglePlaying,
                icon: Icon(state.playing
                    ? Icons.pause_rounded
                    : finished
                        ? Icons.replay_rounded
                        : Icons.play_arrow_rounded),
              ),
            ]),
          ),
          const Positioned(
              left: 0, right: 0, bottom: 0, child: MiniPlayerProgress()),
        ],
      );
    }

    return BlocBuilder<PlayerCubit, PlayerState>(
        buildWhen: (previous, current) => previous.isMini != current.isMini,
        builder: (context, controller) {
          return controller.isMini
              ? Row(children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Builder(builder: (context) {
                        return Builder(builder: (context) {
                          DownloadedVideo? offlineVid = context.select(
                              (PlayerCubit value) =>
                                  value.state.offlineCurrentlyPlaying);
                          Video? vid = context.select((PlayerCubit value) =>
                              value.state.currentlyPlaying);

                          String title = vid?.title ?? offlineVid?.title ?? '';
                          String author =
                              vid?.author ?? offlineVid?.author ?? '';

                          return Column(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              Flexible(
                                child: LayoutBuilder(
                                  builder: (context, constraints) => FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: SizedBox(
                                      width: constraints.maxWidth,
                                      child: Text(
                                        '$title - $author',
                                        maxLines: 1,
                                        textAlign: TextAlign.center,
                                        overflow: TextOverflow.ellipsis,
                                        style: textTheme.bodySmall,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const MiniPlayerControls(),
                              const MiniPlayerProgress(),
                            ],
                          );
                        });
                      }),
                    ),
                  ),
                ])
              : const SizedBox.shrink();
        });
  }
}
