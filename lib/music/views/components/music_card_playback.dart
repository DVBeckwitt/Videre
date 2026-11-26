import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_card_origin.dart';
import 'package:clipious/player/states/player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

bool? watchMusicCardPlaying(BuildContext context, MusicCardOrigin origin) =>
    context.select((PlayerCubit? player) => player?.musicCardPlaying(origin));

void activateMusicCard(
    BuildContext context, MusicCardOrigin origin, VoidCallback onStart) {
  if (context.mounted &&
      context.read<PlayerCubit?>()?.toggleMusicCard(origin) != true) {
    onStart();
  }
}

Widget? musicCardPlaybackIcon(bool? playing) => playing == null
    ? null
    : ExcludeSemantics(
        child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
      );

String? musicCardPlaybackHint(BuildContext context, bool? playing) {
  if (playing == null) return null;
  final locals = AppLocalizations.of(context)!;
  return playing ? locals.musicPause : locals.musicResume;
}
