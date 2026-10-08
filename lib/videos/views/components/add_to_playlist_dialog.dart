import 'package:clipious/utils.dart';
import 'package:flutter/material.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:logging/logging.dart';

import '../../../playlists/models/playlist.dart';
import '../../../playlists/views/components/add_to_playlist_list.dart';

final log = Logger('AddToPlaylistView');

class AddToPlaylistDialog extends StatefulWidget {
  final String videoId;
  final List<Playlist> playlists;
  final Function(String selectedPlaylistId) onAdd;

  const AddToPlaylistDialog(
      {super.key,
      required this.videoId,
      required this.playlists,
      required this.onAdd});

  static Future<bool?> showAddToPlaylistDialog(BuildContext context,
      {required String videoId,
      required List<Playlist> playlists,
      required Function(String selectedPlaylistId) onAdd}) {
    return showSafeModalBottomSheet<bool>(
        showDragHandle: true,
        isScrollControlled: true,
        context: context,
        builder: (BuildContext context) {
          return AddToPlaylistDialog(
            videoId: videoId,
            playlists: playlists,
            onAdd: onAdd,
          );
        });
  }

  @override
  State<AddToPlaylistDialog> createState() => _AddToPlaylistDialogState();
}

class _AddToPlaylistDialogState extends State<AddToPlaylistDialog> {
  bool saving = false;

  addToPlaylist(BuildContext context, String playlistId) async {
    if (saving || !mounted) return;
    setState(() => saving = true);
    var locals = AppLocalizations.of(context)!;
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final route = ModalRoute.of(context);
    try {
      await widget.onAdd(playlistId);
      if (!context.mounted) return;
      scaffoldMessenger.showSnackBar(SnackBar(
        content: Text(locals.videoAddedToPlaylist),
        duration: const Duration(seconds: 3),
      ));

      if (route?.isCurrent == true) {
        Navigator.pop(context, true);
      }
    } catch (err) {
      if (!context.mounted) return;
      scaffoldMessenger.showSnackBar(SnackBar(
        content: Text(locals.errorAddingVideoToPlaylist),
        duration: const Duration(seconds: 3),
      ));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  newPlaylistAndAdd(BuildContext context) {
    if (saving || !mounted) return;
    showDialog<String>(
        context: context,
        useRootNavigator: false,
        builder: (BuildContext ctx) => Dialog(
              child: AddPlayListForm(
                  afterAdd: (playlistId) => addToPlaylist(context, playlistId)),
            ));
  }

  @override
  Widget build(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(locals.selectPlaylist),
        Expanded(
          child: ListView(
            children: widget.playlists.map((p) {
              bool inPlaylist =
                  p.videos.any((element) => element.videoId == widget.videoId);
              return FilledButton.tonal(
                  onPressed: inPlaylist || saving
                      ? null
                      : () => addToPlaylist(context, p.playlistId),
                  child: Row(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: SizedBox(
                            width: 20,
                            child: inPlaylist
                                ? const Icon(
                                    Icons.check,
                                    size: 15,
                                  )
                                : const SizedBox.shrink()),
                      ),
                      Expanded(
                          child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.playlistId == localWatchLaterId
                              ? locals.watchLater
                              : p.title),
                          Text(p.isLocal ? locals.onDevice : locals.onServer,
                              style: Theme.of(context).textTheme.labelSmall),
                        ],
                      )),
                    ],
                  ));
            }).toList(),
          ),
        ),
        FilledButton.tonal(
          onPressed: saving ? null : () => newPlaylistAndAdd(context),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [const Icon(Icons.add), Text(locals.createNewPlaylist)],
          ),
        )
      ]),
    );
  }
}
