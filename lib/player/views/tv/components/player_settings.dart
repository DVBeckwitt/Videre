import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/states/tv_player_controls.dart';
import 'package:clipious/player/states/tv_player_settings.dart';
import 'package:clipious/player/states/video_player.dart';
import 'package:clipious/player/views/components/playback_speed_controls.dart';
import 'package:clipious/player/views/components/player_backend_picker.dart';
import 'package:clipious/player/views/components/subtitle_size_picker.dart';
import 'package:clipious/player/views/components/subtitle_timing_picker.dart';
import 'package:clipious/player/views/components/video_display_mode_picker.dart';
import 'package:clipious/player/views/components/watch_local_subtitle_actions.dart';
import 'package:clipious/player/views/tv/components/sleep_timer.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/views/tv/components/tv_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';

class TvPlayerSettings extends StatefulWidget {
  const TvPlayerSettings({super.key});

  @override
  State<TvPlayerSettings> createState() => _TvPlayerSettingsState();
}

class _TvPlayerSettingsState extends State<TvPlayerSettings> {
  late final Future<bool> _qualityPreparation =
      context.read<VideoPlayerCubit>().prepareVideoTracks();

  List<Widget> getContent(BuildContext context) {
    var cubit = context.read<TvPlayerSettingsCubit>();
    var player = context.read<PlayerCubit>();

    var locals = AppLocalizations.of(context)!;

    switch (cubit.state.selected) {
      case Tabs.video:
        return cubit.videoTrackNames
            .map((e) => TvSettingButton(
                  label: e,
                  onPressed: (selected) => cubit.player.selectVideoTrack(
                    cubit.player.getVideoTracks().indexWhere(
                        (label) => label.split(' - ').first == selected),
                    onQualityFailure: () {
                      if (context.mounted) {
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                            SnackBar(content: Text(locals.couldntLoadVideo)));
                      }
                    },
                  ),
                ))
            .toList();
      case Tabs.audio:
        return cubit.audioTrackNames
            .map((e) => TvSettingButton(
                  label: e,
                  onPressed: cubit.changeChangeAudioTrack,
                ))
            .toList();
      case Tabs.captions:
        final captions = cubit.availableCaptions;
        final subtitleScope = cubit.player.canManageLocalSubtitles
            ? captureWatchLocalSubtitleScope(cubit.player)
            : null;
        return [
          for (final (index, label) in captions.indexed)
            TvSettingButton(
              label: label,
              onPressed: (_) {
                if (subtitleScope?.call() != false &&
                    listEquals(captions, cubit.availableCaptions)) {
                  cubit.player.selectSubtitle(index);
                }
              },
            ),
        ];
      case Tabs.playbackSpeed:
        return [
          PlaybackSpeedControls(
            initialSpeed: cubit.player.getSpeed(),
            onChanged: cubit.player.setSpeed,
            initialPitchSemitones: cubit.player.getPitchSemitones(),
            onPitchChanged:
                !kIsWeb && defaultTargetPlatform == TargetPlatform.android
                    ? cubit.player.setPitchSemitones
                    : null,
            compact: true,
          ),
        ];
      case Tabs.sleepTimer:
        return [
          player.state.hasTimer
              ? TvSettingButton(
                  label: locals.cancelSleepTimer,
                  onPressed: (selected) {
                    player.cancelSleep();
                    context.read<TvPlayerControlsCubit>().hideSettings();
                  })
              : TvSleepTimer(
                  onSet: (sleepTimer) {
                    player.sleep(sleepTimer!);
                    context.read<TvPlayerControlsCubit>().hideSettings();
                  },
                )
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    var textTheme = Theme.of(context).textTheme;
    ColorScheme colors = Theme.of(context).colorScheme;
    TextStyle? settingStyle = textTheme.titleLarge;
    var settings = context.read<SettingsCubit>();
    return BlocProvider(
      create: (context) => TvPlayerSettingsCubit(const TvPlayerSettingsState(),
          context.read<VideoPlayerCubit>(), settings),
      child: FutureBuilder<bool>(
          future: _qualityPreparation,
          builder: (context, quality) =>
              BlocBuilder<TvPlayerSettingsCubit, TvPlayerSettingsState>(
                  builder: (context, playerState) {
                var cubit = context.read<TvPlayerSettingsCubit>();
                var settings = context.read<SettingsCubit>();
                final player = context.read<PlayerCubit>();

                return FocusScope(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: TvButton(
                                autofocus: true,
                                unfocusedColor:
                                    playerState.selected == Tabs.video
                                        ? colors.secondaryContainer
                                        : Colors.transparent,
                                onFocusChanged: cubit.videoButtonFocusChange,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 8.0, horizontal: 16),
                                  child: Text(
                                    locals.quality,
                                    style: settingStyle,
                                  ),
                                ),
                              ),
                            ),
                            Visibility(
                              visible: settings.state.useDash,
                              child: Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: TvButton(
                                  onFocusChanged: cubit.audioButtonFocusChange,
                                  unfocusedColor:
                                      playerState.selected == Tabs.audio
                                          ? colors.secondaryContainer
                                          : Colors.transparent,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 8.0, horizontal: 16),
                                    child:
                                        Text(locals.audio, style: settingStyle),
                                  ),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: TvButton(
                                onFocusChanged: cubit.captionsButtonFocusChange,
                                unfocusedColor:
                                    playerState.selected == Tabs.captions
                                        ? colors.secondaryContainer
                                        : Colors.transparent,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 8.0, horizontal: 16),
                                  child: Text(locals.subtitles,
                                      style: settingStyle),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: TvButton(
                                onFocusChanged:
                                    cubit.playbackSpeedButtonFocusChange,
                                unfocusedColor:
                                    playerState.selected == Tabs.playbackSpeed
                                        ? colors.secondaryContainer
                                        : Colors.transparent,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 8.0, horizontal: 16),
                                  child: Text(locals.playbackSpeed,
                                      style: settingStyle),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: TvButton(
                                onFocusChanged:
                                    cubit.sleepTimerButtonFocusChange,
                                unfocusedColor:
                                    playerState.selected == Tabs.sleepTimer
                                        ? colors.secondaryContainer
                                        : Colors.transparent,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 8.0, horizontal: 16),
                                  child: Text(locals.sleepTimer,
                                      style: settingStyle),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Wrap(
                        alignment: WrapAlignment.center,
                        children: [
                          if (cubit.player.hasSubtitleTracks)
                            Shortcuts(
                              shortcuts: {
                                for (final key in selectKeys)
                                  SingleActivator(key): const ActivateIntent(),
                              },
                              child: TextButton.icon(
                                key:
                                    const ValueKey('player-subtitle-size-open'),
                                onPressed: () =>
                                    showSubtitleSizePicker(context),
                                icon: const Icon(Icons.format_size),
                                label: Text(locals.subtitleFontSize),
                              ),
                            ),
                          if (cubit.player.hasSubtitleTracks &&
                              cubit.player.subtitleTimingTarget != null)
                            Shortcuts(
                              shortcuts: {
                                for (final key in selectKeys)
                                  SingleActivator(key): const ActivateIntent(),
                              },
                              child: TextButton.icon(
                                key: const ValueKey(
                                    'player-subtitle-timing-open'),
                                onPressed: () => showSubtitleTimingPicker(
                                    context, cubit.player),
                                icon: const Icon(Icons.timer_outlined),
                                label: Text(locals.subtitleTiming),
                              ),
                            ),
                          TextButton.icon(
                            key: const ValueKey('player-video-display-open'),
                            onPressed: () =>
                                showVideoDisplayModePicker(context),
                            icon: const Icon(Icons.aspect_ratio),
                            label: Text(locals.videoDisplay),
                          ),
                          if (context.select((PlayerCubit player) =>
                              canChoosePlayerBackend(player.state)))
                            TextButton.icon(
                              key: const ValueKey('player-backend-open'),
                              onPressed: () => showPlayerBackendPicker(context,
                                  player: context.read<PlayerCubit>()),
                              icon: const Icon(Icons.dns_outlined),
                              label: Text(locals.backendChoose),
                            ),
                        ],
                      ),
                      if (playerState.selected == Tabs.playbackSpeed)
                        Flexible(
                          child: Center(
                            heightFactor: 1,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxWidth: 640,
                                maxHeight: 320,
                              ),
                              child: Material(
                                color: colors.surface.withValues(alpha: 0.96),
                                borderRadius: BorderRadius.circular(24),
                                clipBehavior: Clip.antiAlias,
                                child: SingleChildScrollView(
                                  child: getContent(context).single,
                                ),
                              ),
                            ),
                          ),
                        )
                      else
                        Flexible(
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (playerState.selected == Tabs.video &&
                                    quality.data == false)
                                  Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Text(locals.couldntLoadVideo),
                                  ),
                                if (playerState.selected == Tabs.video &&
                                    cubit.player.isOnionPlayback)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 24, vertical: 8),
                                    child: Text(
                                      locals.onionVideoQualityHint,
                                      key: const ValueKey('onion-quality-help'),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                if (playerState.selected != Tabs.captions ||
                                    cubit.availableCaptions.isNotEmpty)
                                  SizedBox(
                                    height: 90,
                                    child: ListView(
                                      shrinkWrap: true,
                                      scrollDirection: Axis.horizontal,
                                      children: getContent(context)
                                          .map((e) => Center(child: e))
                                          .toList(),
                                    ),
                                  ),
                                if (playerState.selected == Tabs.captions &&
                                    cubit.player.canManageLocalSubtitles)
                                  WatchLocalSubtitleActions(
                                    key: ValueKey(player.state.currentQueueId),
                                    video: cubit.player,
                                    isCurrent: captureWatchLocalSubtitleScope(
                                        cubit.player),
                                    onChanged: () => setState(() {}),
                                    television: true,
                                  ),
                              ],
                            ),
                          ),
                        )
                    ],
                  ),
                );
              })),
    );
  }
}

class TvSettingButton extends StatelessWidget {
  final String label;
  final Function(String selected) onPressed;

  const TvSettingButton(
      {super.key, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    var textTheme = Theme.of(context).textTheme;
    return TvButton(
        unfocusedColor: Colors.transparent,
        onPressed: (context) => onPressed(label),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16),
          child: Text(label, style: textTheme.titleLarge),
        ));
  }
}
