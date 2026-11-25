import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../screens/music_playlist_reorder.dart';
import 'music_library_actions.dart';

enum _EditAction { reorder, toggleLock }

class MusicPlaylistEditActions extends StatelessWidget {
  const MusicPlaylistEditActions({
    super.key,
    required this.playlist,
    required this.reference,
  });

  final Playlist playlist;
  final PlaylistReference reference;

  Future<void> _edit(BuildContext context, _EditAction action) async {
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent || !reference.matchesOwner(db)) return;
    final playlists = service;
    if (action == _EditAction.reorder) {
      final entries = playlist.videos;
      final rows = [
        for (final video in entries)
          if (video.musicMetadata case final music?)
            (id: video.indexId!, title: music.title, artist: music.artist),
      ];
      final expectedOrder = [for (final video in entries) video.indexId!];
      await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => BlocBuilder<AppCubit, AppState>(
          bloc: session.app,
          builder: (context, _) => session.isCurrent
              ? MusicPlaylistReorder(
                  rows: rows,
                  onSave: (order) async {
                    var song = 0;
                    final changed = await playlists.reorderLocalPlaylist(
                      reference,
                      expectedOrder: expectedOrder,
                      order: [
                        for (final video in entries)
                          video.musicMetadata == null
                              ? video.indexId!
                              : order[song++],
                      ],
                      isCurrent: () => session.isCurrent,
                    );
                    if (changed) session.library.notifyChanged();
                    return changed;
                  },
                )
              : Scaffold(
                  appBar: AppBar(leading: const BackButton()),
                  body: Center(
                    child: Text(
                        AppLocalizations.of(context)!.musicSourceUnavailable),
                  ),
                ),
        ),
      ));
      return;
    }

    try {
      final changed = await playlists.setLocalPlaylistEditLocked(
        reference,
        locked: !playlist.isEditLocked,
        isCurrent: () => session.isCurrent,
      );
      if (changed) session.library.notifyChanged();
    } catch (_) {
      if (context.mounted && session.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context)!.musicLibraryActionError),
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final locked = playlist.isEditLocked;
    final canReorder = !locked &&
        playlist.videos
                .where((video) => video.musicMetadata != null)
                .take(2)
                .length ==
            2;
    return PopupMenuButton<_EditAction>(
      key: const ValueKey('music-playlist-edit'),
      tooltip:
          locked ? locals.musicPlaylistLocked : locals.musicPlaylistEditing,
      icon: Icon(locked ? Icons.lock_rounded : Icons.edit_outlined),
      onSelected: (action) => _edit(context, action),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: _EditAction.reorder,
          enabled: canReorder,
          child: Text(locals.musicPlaylistReorder),
        ),
        PopupMenuItem(
          value: _EditAction.toggleLock,
          child: Text(
              locked ? locals.musicPlaylistUnlock : locals.musicPlaylistLock),
        ),
      ],
    );
  }
}
