import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/video_transcript_button.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'playback_speed_controls.dart';
import 'player_backend_picker.dart';
import 'player_modal_back_handler.dart';

enum _WatchAction { pitch, repeat, shuffle, backend }

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

    void openRate({required bool pitch}) => showPlaybackSpeedSheet(
          context,
          initialSpeed: player.state.speed,
          onChanged: (value) {
            if (current()) player.setSpeed(value);
          },
          initialPitchSemitones: player.state.pitchSemitones,
          onPitchChanged: pitch
              ? (value) {
                  if (current()) player.setPitchSemitones(value);
                }
              : null,
          showSpeed: !pitch,
        );

    Future<void> openMore() async {
      if (!current()) return;
      final choice = await showSafeModalBottomSheet<_WatchAction>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => PlayerModalBackHandler(
          child: SingleChildScrollView(
            key: const ValueKey('watch-more-menu'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  key: const ValueKey('watch-pitch-open'),
                  leading: const Icon(Icons.tune_rounded),
                  title: Text(locals.playbackPitch),
                  enabled: pitchSupported,
                  onTap: pitchSupported
                      ? () => Navigator.pop(sheetContext, _WatchAction.pitch)
                      : null,
                ),
                ListTile(
                  key: const ValueKey('watch-repeat'),
                  leading: Icon(repeat == PlayerRepeat.repeatOne
                      ? Icons.repeat_one
                      : Icons.repeat),
                  title: Text(switch (repeat) {
                    PlayerRepeat.noRepeat => locals.musicRepeatOff,
                    PlayerRepeat.repeatAll => locals.musicRepeatAll,
                    PlayerRepeat.repeatOne => locals.watchRepeatOne,
                  }),
                  selected: repeat != PlayerRepeat.noRepeat,
                  onTap: () => Navigator.pop(sheetContext, _WatchAction.repeat),
                ),
                if (state.hasQueue)
                  ListTile(
                    key: const ValueKey('watch-shuffle'),
                    leading: const Icon(Icons.shuffle),
                    title: Text(locals.musicShuffle),
                    selected: settings.state.playerShuffleMode,
                    onTap: () =>
                        Navigator.pop(sheetContext, _WatchAction.shuffle),
                  ),
                if (canChoosePlayerBackend(state))
                  ListTile(
                    key: const ValueKey('player-backend-shortcut'),
                    leading: const Icon(Icons.dns_outlined),
                    title: Text(locals.backendChoose),
                    onTap: () =>
                        Navigator.pop(sheetContext, _WatchAction.backend),
                  ),
              ],
            ),
          ),
        ),
      );
      // Keep the opening playback identity even if the toolbar rebuilt.
      if (!context.mounted || !current()) return;
      switch (choice) {
        case _WatchAction.pitch:
          if (pitchSupported) openRate(pitch: true);
          break;
        case _WatchAction.repeat:
          settings.setNextRepeatMode();
          break;
        case _WatchAction.shuffle:
          settings.toggleShuffle();
          player.generatePlayQueue();
          break;
        case _WatchAction.backend:
          showPlayerBackendPicker(context, player: player);
          break;
        case null:
          break;
      }
    }

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
            tooltip: '${locals.playbackSpeed}: ${state.speed}×',
            icon: const Icon(Icons.speed),
            onPressed: enabled
                ? () {
                    if (current()) openRate(pitch: false);
                  }
                : null,
          ),
          IconButton(
            key: const ValueKey('watch-more-open'),
            tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
            icon: const Icon(Icons.more_horiz),
            onPressed: enabled ? openMore : null,
          ),
        ],
      );
    });
  }
}
