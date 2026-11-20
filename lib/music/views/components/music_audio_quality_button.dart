import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../player/models/local_music_playback.dart';
import '../../../player/models/music_audio_quality.dart';
import '../../../player/states/player.dart';
import '../../../player/views/components/player_modal_back_handler.dart';

class MusicAudioQualityButton extends StatelessWidget {
  final bool showLabel;

  const MusicAudioQualityButton({super.key, this.showLabel = false});

  static String _label(MusicAudioQuality quality) =>
      '${(quality.bitrate / 1000).round()} kbps · ${quality.codec}';

  Future<void> _open(BuildContext context) async {
    final player = context.read<PlayerCubit>();
    final locals = AppLocalizations.of(context)!;
    final current = player.state.currentlyPlaying;
    if (isLocalMusicPlaybackId(
        current?.videoId ?? player.state.offlineCurrentlyPlaying?.videoId)) {
      return;
    }
    final menu = player.musicAudioQuality;
    final saved = player.state.offlineCurrentlyPlaying != null ||
        current?.downloadPlaybackOnly == true;
    if (menu == null ||
        menu.videoId != current?.videoId ||
        menu.choices.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (context) => PlayerModalBackHandler(
            child: AlertDialog(
          title: Text(locals.musicAudioQuality),
          content: Text(saved || menu?.saved == true
              ? locals.musicAudioQualitySaved
              : locals.musicAudioQualityUnavailable),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context),
              child: Text(MaterialLocalizations.of(context).closeButtonLabel),
            ),
          ],
        )),
      );
      return;
    }
    final result = await showDialog<({MusicAudioQuality? quality})>(
      context: context,
      builder: (context) => PlayerModalBackHandler(
          child: SimpleDialog(
        title: Text(locals.musicAudioQuality),
        children: [
          for (final choice in [null, ...menu.choices])
            ListTile(
              autofocus: menu.selected == choice,
              selected: menu.selected == choice,
              title: Text(choice == null
                  ? locals.musicAudioQualityProfileDefault
                  : _label(choice)),
              subtitle: choice == null && menu.selected == null
                  ? menu.saved
                      ? Text(locals.musicAudioQualitySaved)
                      : menu.effective == null
                          ? null
                          : Text(_label(menu.effective!))
                  : null,
              trailing:
                  menu.selected == choice ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, (quality: choice)),
            ),
        ],
      )),
    );
    if (result == null ||
        !context.mounted ||
        player.isClosed ||
        !identical(menu, player.musicAudioQuality)) {
      return;
    }
    final switched = await menu.select(result.quality);
    if (!switched &&
        context.mounted &&
        !player.isClosed &&
        player.state.currentlyPlaying?.videoId == menu.videoId) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(locals.musicAudioQualityFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    const key = ValueKey('music-player-audio-quality');
    const icon = Icon(Icons.high_quality_outlined);
    final label = AppLocalizations.of(context)!.musicAudioQuality;
    if (showLabel) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 136),
        child: Tooltip(
          message: label,
          excludeFromSemantics: true,
          child: TextButton.icon(
            key: key,
            onPressed: () => _open(context),
            icon: icon,
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      );
    }
    return IconButton(
      key: key,
      tooltip: label,
      onPressed: () => _open(context),
      icon: icon,
    );
  }
}
