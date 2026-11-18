import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/video_transcript_button.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'playback_speed_controls.dart';

/// Visible playback actions for Flow's expanded watch information surface.
/// Commands continue to reach the mounted Videre decoder through PlayerCubit.
class WatchPlaybackActions extends StatelessWidget {
  final Video video;

  const WatchPlaybackActions({super.key, required this.video});

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerCubit>();
    final state = context.watch<PlayerCubit>().state;
    final settings = context.watch<SettingsCubit>();
    final locals = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final profile = db.profileId;
    final generation = player.backendPlaybackGeneration;
    final queueId = state.currentQueueId;
    final audio = state.isAudio;

    bool current() =>
        !player.isClosed &&
        db.profileId == profile &&
        player.backendPlaybackGeneration == generation &&
        player.state.currentQueueId == queueId &&
        player.state.currentlyPlaying?.videoId == video.videoId &&
        player.state.isAudio == audio &&
        !player.state.isHidden &&
        !player.state.isClosing;

    final enabled = current();
    final pitchSupported =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final repeat = settings.state.playerRepeatMode;

    void openRate() => showPlaybackSpeedSheet(
          context,
          initialSpeed: player.state.speed,
          onChanged: (value) {
            if (current()) player.setSpeed(value);
          },
          initialPitchSemitones: player.state.pitchSemitones,
          onPitchChanged: pitchSupported
              ? (value) {
                  if (current()) player.setPitchSemitones(value);
                }
              : null,
        );

    final canSwitchMode = video.liveNow != true;
    return LayoutBuilder(builder: (_, constraints) {
      // The watch body can mount before the floating player reaches full width.
      // Reserve the row's height until all four touch targets fit.
      if (constraints.maxWidth < 4 * kMinInteractiveDimension) {
        return const SizedBox(height: kMinInteractiveDimension);
      }
      return Row(
        key: const ValueKey('watch-playback-actions'),
        children: [
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: MergeSemantics(
                child: Semantics(
                  toggled: audio,
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('watch-mode-toggle'),
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.surfaceContainerHighest,
                      foregroundColor: colors.onSurface,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      minimumSize: const Size(48, 32),
                      tapTargetSize: MaterialTapTargetSize.padded,
                      visualDensity: VisualDensity.standard,
                      textStyle: Theme.of(context).textTheme.labelMedium,
                    ),
                    onPressed: enabled && canSwitchMode
                        ? () {
                            if (current()) player.switchAudio(!audio);
                          }
                        : null,
                    icon: Icon(audio ? Icons.audiotrack : Icons.ondemand_video,
                        size: 18),
                    label: Text(audio ? locals.audio : locals.watchVideo,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ),
            ),
          ),
          VideoTranscriptButton(
              video: video, enabled: enabled, isCurrent: current),
          IconButton(
            key: const ValueKey('watch-speed-open'),
            tooltip:
                '${pitchSupported ? locals.playbackSpeedAndPitch : locals.playbackSpeed} · ${state.speed}×',
            icon: const Icon(Icons.speed),
            onPressed: enabled
                ? () {
                    if (current()) openRate();
                  }
                : null,
          ),
          IconButton(
            key: const ValueKey('watch-repeat'),
            tooltip: switch (repeat) {
              PlayerRepeat.noRepeat => locals.musicRepeatOff,
              PlayerRepeat.repeatAll => locals.musicRepeatAll,
              PlayerRepeat.repeatOne => locals.watchRepeatOne,
            },
            isSelected: repeat != PlayerRepeat.noRepeat,
            style: repeat == PlayerRepeat.noRepeat
                ? null
                : IconButton.styleFrom(
                    backgroundColor: colors.secondaryContainer),
            icon: Icon(repeat == PlayerRepeat.repeatOne
                ? Icons.repeat_one
                : Icons.repeat),
            onPressed: enabled
                ? () {
                    if (current()) settings.setNextRepeatMode();
                  }
                : null,
          ),
        ],
      );
    });
  }
}
