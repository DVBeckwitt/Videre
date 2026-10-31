import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/views/components/playback_speed_controls.dart';
import 'package:clipious/player/views/components/player_backend_picker.dart';
import 'package:clipious/videos/views/components/video_transcript_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/utils/views/components/multi_value_switch.dart';

import '../../../settings/states/settings.dart';
import '../../states/player.dart';

const ButtonStyle buttonStyle =
    ButtonStyle(visualDensity: VisualDensity.compact);

class MiniPlayerControls extends StatelessWidget {
  const MiniPlayerControls({super.key});

  @override
  Widget build(BuildContext context) {
    ColorScheme colors = Theme.of(context).colorScheme;

    var player = context.read<PlayerCubit>();
    bool isMini = context.select((PlayerCubit value) => value.state.isMini);
    bool hasQueue = context.select((PlayerCubit value) => value.state.hasQueue);
    bool isPlaying =
        context.select((PlayerCubit value) => value.state.isPlaying);

    bool isPausedAndDone = context
                .select((PlayerCubit value) => value.state.position)
                .inMilliseconds >
            player.duration.inMilliseconds * 0.99 &&
        context.select((SettingsCubit value) =>
            value.state.playerRepeatMode == PlayerRepeat.noRepeat);

    return Padding(
      padding: isMini ? EdgeInsets.zero : const EdgeInsets.all(8.0),
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (isMini)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Visibility(
                  visible: hasQueue,
                  child: IconButton(
                      style: buttonStyle,
                      onPressed: player.playPrevious,
                      icon: const Icon(
                        Icons.skip_previous,
                      )),
                ),
                IconButton(
                    onPressed: player.rewind,
                    style: buttonStyle,
                    icon: const Icon(
                      Icons.fast_rewind,
                    )),
                IconButton(
                    onPressed: isPausedAndDone
                        ? () {
                            player.seek(Duration.zero);
                            player.play();
                          }
                        : player.togglePlay,
                    style: buttonStyle,
                    icon: Icon(
                      isPlaying
                          ? Icons.pause
                          : isPausedAndDone
                              ? Icons.refresh
                              : Icons.play_arrow,
                    )),
                IconButton(
                    onPressed: player.fastForward,
                    style: buttonStyle,
                    icon: const Icon(
                      Icons.fast_forward,
                    )),
                Visibility(
                  visible: hasQueue,
                  child: IconButton(
                      onPressed: player.playNext,
                      style: buttonStyle,
                      icon: const Icon(
                        Icons.skip_next,
                      )),
                )
              ],
            ),
          if (!isMini)
            Builder(builder: (context) {
              var playerRepeatMode =
                  context.select((SettingsCubit s) => s.state.playerRepeatMode);
              var shuffleMode = context
                  .select((SettingsCubit s) => s.state.playerShuffleMode);
              var cubit = context.read<SettingsCubit>();
              var isAudio =
                  context.select((PlayerCubit value) => value.state.isAudio);
              var video = context
                  .select((PlayerCubit value) => value.state.currentlyPlaying);

              var hasAudio = context.select((PlayerCubit value) =>
                  !(value.state.currentlyPlaying?.liveNow ?? false));

              return Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Visibility(
                    // only for online videos
                    visible: player.state.currentlyPlaying != null && hasAudio,
                    child: MultiValueSwitch(
                      left: Icons.ondemand_video,
                      right: Icons.audiotrack,
                      onChange: (selected) => player.switchAudio(
                          selected == MultiValueSwitchPosition.right),
                      position: isAudio
                          ? MultiValueSwitchPosition.right
                          : MultiValueSwitchPosition.left,
                    ),
                  ),
                  Expanded(child: Container()),
                  if (context.select((PlayerCubit player) =>
                      canChoosePlayerBackend(player.state)))
                    IconButton(
                      key: const ValueKey('player-backend-shortcut'),
                      style: buttonStyle,
                      tooltip: AppLocalizations.of(context)!.backendChoose,
                      icon: const Icon(Icons.dns_outlined),
                      onPressed: () =>
                          showPlayerBackendPicker(context, player: player),
                    ),
                  IconButton(
                    key: const ValueKey('playback-speed-open'),
                    style: buttonStyle,
                    tooltip: AppLocalizations.of(context)!.playbackSpeed,
                    icon: const Icon(Icons.speed),
                    onPressed: () => showPlaybackSpeedSheet(
                      context,
                      initialSpeed: player.state.speed,
                      onChanged: player.setSpeed,
                      initialPitchSemitones: player.state.pitchSemitones,
                      onPitchChanged: !kIsWeb &&
                              defaultTargetPlatform == TargetPlatform.android
                          ? player.setPitchSemitones
                          : null,
                    ),
                  ),
                  if (video != null && video.captions.isNotEmpty)
                    VideoTranscriptButton(video: video),
                  IconButton(
                      style: buttonStyle,
                      onPressed: cubit.setNextRepeatMode,
                      color: playerRepeatMode == PlayerRepeat.noRepeat
                          ? null
                          : colors.primary,
                      icon: Icon(
                        playerRepeatMode == PlayerRepeat.repeatOne
                            ? Icons.repeat_one
                            : Icons.repeat,
                      )),
                  if (hasQueue)
                    IconButton(
                      onPressed: () {
                        cubit.toggleShuffle();
                        player.generatePlayQueue();
                      },
                      style: buttonStyle,
                      icon: const Icon(Icons.shuffle),
                      color: shuffleMode ? colors.primary : null,
                    ),
                ],
              );
            })
        ],
      ),
    );
  }
}
