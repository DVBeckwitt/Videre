import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../playlists/models/playlist_reference.dart';
import '../../../videos/models/video.dart';
import '../../services/music_visibility.dart';
import 'music_library_actions.dart';

class MusicPlaylistHiddenSongs extends StatelessWidget {
  final PlaylistReference playlist;
  final MusicVisibility visibility;
  final List<Video> songs;

  const MusicPlaylistHiddenSongs({
    super.key,
    required this.playlist,
    required this.visibility,
    required this.songs,
  });

  Future<void> _show(BuildContext context) async {
    final session = MusicLibrarySession(context.read<AppCubit>());
    final messenger = ScaffoldMessenger.of(context);
    await session.showDialog<void>(context, (context) {
      final locals = AppLocalizations.of(context)!;
      return ListenableBuilder(
        listenable: visibility,
        builder: (context, _) => AlertDialog(
          title: Text(locals.musicShowPlaylistHiddenSongs),
          scrollable: true,
          content: ListBody(children: [
            for (final song in songs)
              if (visibility.isHiddenInPlaylist(playlist, song.videoId))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(song.musicMetadata?.title ?? song.videoId),
                  subtitle: Text(locals.musicPlaylistHiddenSong),
                  trailing: IconButton(
                    icon: const Icon(Icons.restore_rounded),
                    tooltip: locals.musicRestorePlaylistSong,
                    onPressed: () async {
                      if (!session.isCurrent) return;
                      try {
                        await visibility.setHiddenInPlaylist(
                            playlist, song.videoId, false);
                      } catch (_) {
                        if (messenger.mounted && session.isCurrent) {
                          messenger.showSnackBar(SnackBar(
                              content: Text(locals.musicLibraryActionError)));
                        }
                      }
                    },
                  ),
                ),
          ]),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(MaterialLocalizations.of(context).closeButtonLabel),
            ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (songs.isEmpty) return const SizedBox.shrink();
    return TextButton.icon(
      icon: const Icon(Icons.visibility_off_outlined),
      label: Text(AppLocalizations.of(context)!.musicShowPlaylistHiddenSongs),
      onPressed: () => _show(context),
    );
  }
}
