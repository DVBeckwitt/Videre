import 'package:clipious/app/states/app.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/music_queue_shuffle.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

ButtonStyle? _toggleStyle(BuildContext context, bool selected,
        ButtonStyle? style, Color? selectedBackgroundColor) =>
    selected
        ? IconButton.styleFrom(
                backgroundColor: selectedBackgroundColor ??
                    Theme.of(context).colorScheme.secondaryContainer)
            .merge(style)
        : style;

class MusicRepeatButton extends StatelessWidget {
  const MusicRepeatButton({
    super.key,
    required this.controlKey,
    this.style,
    this.enabled = true,
    this.selectedBackgroundColor,
  });

  final Key controlKey;
  final ButtonStyle? style;
  final bool enabled;
  final Color? selectedBackgroundColor;

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsCubit>();
    final repeat = settings.state.playerRepeatMode;
    final selected = repeat != PlayerRepeat.noRepeat;
    return IconButton(
      key: controlKey,
      tooltip: switch (repeat) {
        PlayerRepeat.noRepeat => locals.musicRepeatOff,
        PlayerRepeat.repeatAll => locals.musicRepeatAll,
        PlayerRepeat.repeatOne => locals.musicRepeatOne,
      },
      isSelected: selected,
      style: _toggleStyle(context, selected, style, selectedBackgroundColor),
      onPressed: enabled ? settings.setNextRepeatMode : null,
      icon: Icon(
          repeat == PlayerRepeat.repeatOne ? Icons.repeat_one : Icons.repeat),
    );
  }
}

class MusicShuffleButton extends StatelessWidget {
  const MusicShuffleButton({
    super.key,
    required this.controlKey,
    this.style,
    this.enabled = true,
    this.selectedBackgroundColor,
    this.showQueueOptions = false,
  });

  final Key controlKey;
  final ButtonStyle? style;
  final bool enabled;
  final Color? selectedBackgroundColor;
  final bool showQueueOptions;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerCubit>();
    final generation = player.playlistGeneration;
    final occurrence = player.playbackOccurrenceRevision;
    final selectionRequest = player.musicSelectionRequestRevision;
    final app = context.read<AppCubit>();
    final session = app.state;
    final settings = context.watch<SettingsCubit>();
    final shuffled = player.musicQueueShuffled;
    final locals = AppLocalizations.of(context)!;
    bool current() =>
        !player.isClosed &&
        !settings.isClosed &&
        !app.isClosed &&
        !app.state.globalLoading &&
        !app.state.sessionRecoveryRequired &&
        app.state.sessionRevision == session.sessionRevision &&
        app.state.profileId == session.profileId &&
        app.state.server == session.server &&
        player.playlistGeneration == generation &&
        !player.state.isClosing &&
        player.state.hasQueue;

    Future<void> toggleShuffle() async {
      if (!current() ||
          player.playbackOccurrenceRevision != occurrence ||
          player.musicSelectionRequestRevision != selectionRequest) {
        return;
      }
      await player.toggleMusicQueueShuffle(expectedShuffled: shuffled);
    }

    final canToggle = enabled && player.canToggleMusicQueueShuffle;
    final canOpen = enabled && player.state.hasQueue;
    final buttonStyle =
        _toggleStyle(context, shuffled, style, selectedBackgroundColor);
    if (showQueueOptions) {
      return PopupMenuButton<Future<void> Function()>(
        key: controlKey,
        tooltip: locals.musicQueueShuffleOptions,
        enabled: canOpen,
        style: buttonStyle,
        icon: const Icon(Icons.shuffle),
        onSelected: (command) => command(),
        itemBuilder: (_) {
          final occurrence = player.playbackOccurrenceRevision;
          final selectionRequest = player.musicSelectionRequestRevision;
          final canShuffle = current() && player.canShuffleMusicQueueUpcoming;
          return [
            PopupMenuItem(
              enabled: canToggle,
              value: toggleShuffle,
              child: Text(shuffled
                  ? locals.musicQueueSongShuffleOff
                  : locals.musicQueueSongShuffleOn),
            ),
            const PopupMenuDivider(),
            for (final (shuffle, label) in [
              (MusicQueueShuffle.albums, locals.musicQueueShuffleAlbums),
              (MusicQueueShuffle.folders, locals.musicQueueShuffleFolders),
              (
                MusicQueueShuffle.fewerRepeats,
                locals.musicQueueShuffleFewerRepeats
              ),
            ])
              PopupMenuItem(
                enabled: canShuffle,
                value: () async {
                  if (context.mounted &&
                      current() &&
                      player.playbackOccurrenceRevision == occurrence &&
                      player.musicSelectionRequestRevision ==
                          selectionRequest) {
                    player.shuffleMusicQueueUpcoming(shuffle);
                  }
                },
                child: Text(label),
              ),
          ];
        },
      );
    }

    return IconButton(
      key: controlKey,
      tooltip: locals.musicShuffle,
      isSelected: shuffled,
      style: buttonStyle,
      onPressed: canToggle ? toggleShuffle : null,
      icon: const Icon(Icons.shuffle),
    );
  }
}
