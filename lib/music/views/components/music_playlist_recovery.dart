import 'package:clipious/app/states/app.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/deleted_music_playlist.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/utils.dart' show selectKeys;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'music_library_actions.dart';

class MusicPlaylistDeleteButton extends StatelessWidget {
  final Playlist playlist;
  final VoidCallback? onDeleted;

  const MusicPlaylistDeleteButton(
      {super.key, required this.playlist, this.onDeleted});

  Future<void> _delete(BuildContext context) async {
    final session = MusicLibrarySession(context.read<AppCubit>());
    if (!session.isCurrent) return;
    final locals = AppLocalizations.of(context)!;
    final confirmed = await _showPlaylistDialog<bool>(
        context,
        (context) => AlertDialog(
              title:
                  Text(locals.musicDeleteLocalPlaylistQuestion(playlist.title)),
              content: Text(locals.musicDeletedPlaylistRetention(
                  musicPlaylistRecoveryRetention.inDays)),
              actions: [
                TextButton(
                    autofocus: isTv,
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(locals.cancel)),
                TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(locals.delete)),
              ],
            ));
    if (confirmed != true || !context.mounted || !session.isCurrent) return;
    try {
      if (await session.deletePlaylist(playlist.playlistId)) {
        if (context.mounted && session.isCurrent) onDeleted?.call();
        return;
      }
    } catch (_) {
      // Show the same error for a failed write or a stale playlist.
    }
    if (context.mounted && session.isCurrent) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(locals.musicLibraryActionError)));
    }
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
        onPressed: () => _delete(context),
        icon: const Icon(Icons.delete_outline),
        label: Text(AppLocalizations.of(context)!.musicDeleteLocalPlaylist),
      );
}

Future<void> showRecentlyDeletedMusicPlaylists(BuildContext context) async {
  final session = MusicLibrarySession(context.read<AppCubit>());
  if (!session.isCurrent) return;
  await _showPlaylistDialog<void>(
      context, (_) => _RecentlyDeletedPlaylists(session: session));
}

Future<T?> _showPlaylistDialog<T>(
        BuildContext context, WidgetBuilder builder) =>
    showDialog<T>(
      context: context,
      builder: (context) => PlayerModalBackHandler(
        child: Shortcuts(
          shortcuts: {
            for (final key in selectKeys)
              SingleActivator(key): const ActivateIntent(),
          },
          child: builder(context),
        ),
      ),
    );

class _RecentlyDeletedPlaylists extends StatefulWidget {
  final MusicLibrarySession session;

  const _RecentlyDeletedPlaylists({required this.session});

  @override
  State<_RecentlyDeletedPlaylists> createState() =>
      _RecentlyDeletedPlaylistsState();
}

class _RecentlyDeletedPlaylistsState extends State<_RecentlyDeletedPlaylists> {
  final _closeFocus = FocusNode();
  bool _restoring = false;
  String? _error;

  @override
  void dispose() {
    _closeFocus.dispose();
    super.dispose();
  }

  Future<void> _restore(DeletedMusicPlaylist selection) async {
    if (_restoring || !widget.session.isCurrent) return;
    final locals = AppLocalizations.of(context)!;
    setState(() {
      _restoring = true;
      _error = null;
    });
    String? error;
    try {
      if (!await widget.session.restorePlaylist(selection)) {
        error = locals.musicDeletedPlaylistUnavailable;
      }
    } catch (_) {
      error = locals.musicLibraryActionError;
    }
    if (!mounted) return;
    setState(() {
      _restoring = false;
      _error = error;
    });
    if (isTv && error == null) _closeFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final material = MaterialLocalizations.of(context);
    final session = widget.session;
    return BlocBuilder<AppCubit, AppState>(
      bloc: session.app,
      builder: (context, _) => ListenableBuilder(
        listenable: session.library.changes,
        builder: (context, _) {
          final playlists = session.isCurrent
              ? session.recentlyDeletedPlaylists
              : const <DeletedMusicPlaylist>[];
          return AlertDialog(
            title: Text(locals.musicRecentlyDeletedPlaylists),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (session.isCurrent)
                    if (playlists.isEmpty)
                      Text(locals.musicNoDeletedPlaylists)
                    else
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: playlists.length,
                          itemBuilder: (context, index) {
                            final item = playlists[index];
                            final title = item.playlist.title;
                            final date = material
                                .formatMediumDate(item.expiresAt.toLocal());
                            return ListTile(
                              key: ValueKey(item.deletionId),
                              contentPadding: EdgeInsets.zero,
                              title: Text(title,
                                  maxLines: 2, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                  locals.musicDeletedPlaylistExpires(date)),
                              trailing: Tooltip(
                                message: locals
                                    .musicRestoreDeletedPlaylistHint(title),
                                child: TextButton(
                                  autofocus: isTv && index == 0,
                                  onPressed: () => _restore(item),
                                  child:
                                      Text(locals.musicRestoreDeletedPlaylist),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  if (_error case final error? when session.isCurrent)
                    Semantics(liveRegion: true, child: Text(error)),
                ],
              ),
            ),
            actions: [
              TextButton(
                focusNode: _closeFocus,
                autofocus: isTv && playlists.isEmpty,
                onPressed: () => Navigator.pop(context),
                child: Text(material.closeButtonLabel),
              ),
            ],
          );
        },
      ),
    );
  }
}
