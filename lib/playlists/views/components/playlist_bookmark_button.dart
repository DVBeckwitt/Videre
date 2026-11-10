import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../models/playlist.dart';
import '../../models/playlist_reference.dart';
import '../../models/saved_playlist.dart';
import '../../services/playlist_library_service.dart';

class PlaylistBookmarkButton extends StatefulWidget {
  final Playlist playlist;
  final PlaylistReference reference;
  final bool compact;

  const PlaylistBookmarkButton({
    super.key,
    required this.playlist,
    required this.reference,
    this.compact = false,
  });

  @override
  State<PlaylistBookmarkButton> createState() => _PlaylistBookmarkButtonState();
}

class _PlaylistBookmarkButtonState extends State<PlaylistBookmarkButton> {
  bool _busy = false;

  Future<void> _toggle(PlaylistLibraryService library, bool saved) async {
    final app = context.read<AppCubit>();
    final initial = app.state;
    final reference = widget.reference;
    bool current() =>
        mounted &&
        !app.isClosed &&
        !app.state.globalLoading &&
        !app.state.sessionRecoveryRequired &&
        app.state.sessionRevision == initial.sessionRevision &&
        db.profileId == reference.profileId;
    if (_busy || !current()) return;
    setState(() => _busy = true);
    try {
      if (saved) {
        await library.remove(reference);
      } else {
        await library
            .save(SavedPlaylist.fromPlaylist(widget.playlist, reference));
      }
    } catch (_) {
      if (mounted && current()) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.playlistSaveError)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.reference.kind == PlaylistSourceKind.local) {
      return const SizedBox.shrink();
    }
    return BlocBuilder<AppCubit, AppState>(builder: (context, state) {
      if (widget.reference.profileId != db.profileId) {
        return const SizedBox.shrink();
      }
      final library = PlaylistLibraryService.forProfile(db, db.profileId);
      return ListenableBuilder(
        listenable: library.changes,
        builder: (context, _) {
          final saved = library.contains(widget.reference);
          final locals = AppLocalizations.of(context)!;
          final label = saved ? locals.playlistSaved : locals.playlistSave;
          final hint = saved ? locals.playlistRemoveSaved : locals.playlistSave;
          final enabled =
              !_busy && !state.globalLoading && !state.sessionRecoveryRequired;
          final icon = _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(saved ? Icons.bookmark : Icons.bookmark_border);
          return Semantics(
            toggled: saved,
            child: widget.compact
                ? IconButton(
                    key: const ValueKey('playlist-bookmark'),
                    tooltip: hint,
                    onPressed: enabled ? () => _toggle(library, saved) : null,
                    icon: icon,
                  )
                : Tooltip(
                    message: hint,
                    child: OutlinedButton.icon(
                      key: const ValueKey('playlist-bookmark'),
                      onPressed: enabled ? () => _toggle(library, saved) : null,
                      icon: icon,
                      label: Text(label),
                    ),
                  ),
          );
        },
      );
    });
  }
}
