import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../player/models/music_audio_quality.dart';
import '../../../player/states/player.dart';

class MusicAudioQualityButton extends StatelessWidget {
  const MusicAudioQualityButton({super.key});

  static String _label(MusicAudioQuality quality) =>
      '${(quality.bitrate / 1000).round()} kbps · ${quality.codec}';

  Future<void> _open(BuildContext context) async {
    final player = context.read<PlayerCubit>();
    final locals = AppLocalizations.of(context)!;
    final current = player.state.currentlyPlaying;
    final menu = player.musicAudioQuality;
    final saved = player.state.offlineCurrentlyPlaying != null ||
        current?.downloadPlaybackOnly == true;
    if (menu == null ||
        menu.videoId != current?.videoId ||
        menu.choices.isEmpty) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
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
        ),
      );
      return;
    }
    final result = await showDialog<({MusicAudioQuality? quality})>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(locals.musicAudioQuality),
        children: [
          for (final choice in [null, ...menu.choices])
            ListTile(
              autofocus: menu.selected == choice,
              selected: menu.selected == choice,
              title: Text(choice == null
                  ? locals.musicAudioQualityAuto
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
      ),
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
  Widget build(BuildContext context) => IconButton(
        key: const ValueKey('music-player-audio-quality'),
        tooltip: AppLocalizations.of(context)!.musicAudioQuality,
        onPressed: () => _open(context),
        icon: const Icon(Icons.high_quality_outlined),
      );
}
