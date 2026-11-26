import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../player/states/player.dart';
import '../../models/local_music_track.dart';

class DeviceMusicCollectionQueueMenu extends StatelessWidget {
  const DeviceMusicCollectionQueueMenu({
    super.key,
    required this.currentTracks,
  });

  final List<LocalMusicTrack> Function() currentTracks;

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return PopupMenuButton<Future<void> Function()>(
      tooltip: locals.musicLibraryActions,
      onSelected: (enqueue) => unawaited(enqueue()),
      itemBuilder: (_) {
        final player = context.read<PlayerCubit?>();
        final generation =
            player != null && !player.isClosed && player.isLocalMusicSession
                ? player.playlistGeneration
                : null;

        void showError() {
          if (!context.mounted || currentTracks().isEmpty) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(locals.musicPlaybackError)),
          );
        }

        Future<void> enqueue({required bool next}) async {
          if (!context.mounted || player == null || generation == null) return;
          final tracks = currentTracks();
          if (tracks.isEmpty) return;
          try {
            if (!identical(player, context.read<PlayerCubit?>()) ||
                player.isClosed ||
                player.playlistGeneration != generation ||
                !await player.enqueueLocalMusicCopies(tracks, next: next)) {
              showError();
            }
          } catch (_) {
            showError();
          }
        }

        return [
          PopupMenuItem(
            enabled: generation != null,
            value: () => enqueue(next: true),
            child: Text(locals.playNext),
          ),
          PopupMenuItem(
            enabled: generation != null,
            value: () => enqueue(next: false),
            child: Text(locals.addToQueueList),
          ),
        ];
      },
    );
  }
}
