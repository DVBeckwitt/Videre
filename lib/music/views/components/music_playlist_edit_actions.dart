import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../screens/music_playlist_reorder.dart';
import 'music_library_actions.dart';
import 'music_playlist_duplicates_dialog.dart';
import 'music_playlist_undo.dart';

enum _EditAction { reorder, findDuplicates, toggleLock }

class MusicPlaylistEditActions extends StatelessWidget {
  const MusicPlaylistEditActions({
    super.key,
    required this.playlist,
    required this.reference,
    this.allowReorder = true,
  });

  final Playlist playlist;
  final PlaylistReference reference;
  final bool allowReorder;

  Future<void> _findDuplicates(
      BuildContext context, MusicLibrarySession session) async {
    if (playlist.isEditLocked) return;
    final entries = playlist.videos;
    final playlists = service;
    final selected = await showDialog<Set<String>>(
      context: context,
      builder: (_) => MusicPlaylistDuplicatesDialog(
        entries: entries,
        titleFor: (song) =>
            session.library.savedSong(song.videoId)?.savedTitle ??
            song.musicMetadata!.title,
      ),
    );
    if (!context.mounted || !session.isCurrent || selected == null) return;

    final locals = AppLocalizations.of(context)!;
    try {
      final undo = await playlists.removeLocalPlaylistSongs(
        reference,
        entryIds: selected,
        expectedEntries: entries,
        isCurrent: () => context.mounted && session.isCurrent,
      );
      if (undo != null) session.library.notifyChanged();
      if (!context.mounted || !session.isCurrent) return;
      if (undo == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(locals.musicPlaylistDuplicatesChanged),
        ));
        return;
      }
      showMusicPlaylistUndo(
        context,
        session,
        message: locals.musicPlaylistSongsRemoved,
        undo: () => playlists.undoLocalPlaylistSongRemoval(
          undo,
          isCurrent: () => session.isCurrent,
        ),
      );
    } catch (_) {
      if (context.mounted && session.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(locals.musicLibraryActionError),
        ));
      }
    }
  }

  Future<void> _edit(BuildContext context, _EditAction action) async {
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent || !reference.matchesOwner(db)) return;
    if (action == _EditAction.findDuplicates) {
      await _findDuplicates(context, session);
      return;
    }
    final playlists = service;
    if (action == _EditAction.reorder) {
      if (!allowReorder || playlist.isEditLocked) return;
      final entries = playlist.videos;
      final rows = [
        for (final video in entries)
          if (video.musicMetadata case final music?)
            (id: video.indexId!, title: music.title, artist: music.artist),
      ];
      final expectedOrder = [for (final video in entries) video.indexId!];
      List<String>? savedOrder;
      await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => BlocBuilder<AppCubit, AppState>(
          bloc: session.app,
          builder: (context, _) => session.isCurrent
              ? MusicPlaylistReorder(
                  rows: rows,
                  onSave: (order) async {
                    var song = 0;
                    final proposedOrder = [
                      for (final video in entries)
                        video.musicMetadata == null
                            ? video.indexId!
                            : order[song++],
                    ];
                    final changed = await playlists.reorderLocalPlaylist(
                      reference,
                      expectedOrder: expectedOrder,
                      order: proposedOrder,
                      isCurrent: () => session.isCurrent,
                    );
                    if (changed) {
                      savedOrder = proposedOrder;
                      session.library.notifyChanged();
                    }
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
      final reordered = savedOrder;
      if (!context.mounted || reordered == null || !session.isCurrent) return;
      showMusicPlaylistUndo(
        context,
        session,
        message: AppLocalizations.of(context)!.musicPlaylistReordered,
        undo: () => playlists.reorderLocalPlaylist(
          reference,
          expectedOrder: reordered,
          order: expectedOrder,
          isCurrent: () => session.isCurrent,
        ),
      );
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
    final canEditSongs = !locked &&
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
          enabled: allowReorder && canEditSongs,
          child: Text(locals.musicPlaylistReorder),
        ),
        PopupMenuItem(
          value: _EditAction.findDuplicates,
          enabled: canEditSongs,
          child: Text(locals.musicPlaylistFindDuplicates),
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
