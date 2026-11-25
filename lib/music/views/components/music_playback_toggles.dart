import 'package:clipious/app/states/app.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
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
  });

  final Key controlKey;
  final ButtonStyle? style;
  final bool enabled;
  final Color? selectedBackgroundColor;

  // The compact player and queue can both target the same pending write.
  static final _writing = Expando<bool>();

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerCubit>();
    final generation = player.playlistGeneration;
    final app = context.read<AppCubit>();
    final session = app.state;
    final settings = context.watch<SettingsCubit>();
    final shuffled = settings.state.playerShuffleMode;
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

    return IconButton(
      key: controlKey,
      tooltip: AppLocalizations.of(context)!.musicShuffle,
      isSelected: shuffled,
      style: _toggleStyle(context, shuffled, style, selectedBackgroundColor),
      onPressed: enabled && player.state.hasQueue
          ? () async {
              if (!current() || _writing[settings] == true) return;
              _writing[settings] = true;
              try {
                await settings.setShuffle(!settings.state.playerShuffleMode);
                if (current()) player.generatePlayQueue();
              } finally {
                _writing[settings] = null;
              }
            }
          : null,
      icon: const Icon(Icons.shuffle),
    );
  }
}
