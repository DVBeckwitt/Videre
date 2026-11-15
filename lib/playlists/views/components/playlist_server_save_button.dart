import 'package:flutter/material.dart';

import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../settings/models/db/server.dart';
import '../../../utils/views/components/selected_server.dart';
import '../../../videos/services/watch_history.dart';
import '../../models/playlist.dart';
import '../../models/playlist_reference.dart';
import '../../services/playlist_server_copy.dart';

class PlaylistServerSaveButton extends StatelessWidget {
  final Playlist playlist;
  final PlaylistReference reference;
  final bool enabled;
  const PlaylistServerSaveButton(
      {super.key,
      required this.playlist,
      required this.reference,
      this.enabled = true});

  @override
  Widget build(BuildContext context) {
    return SelectedServerBuilder(
        builder: (context, server) => _SaveButton(
            key: ValueKey(
                (playlist, server?.profileId, server?.accountId, server?.url)),
            server: server,
            playlist: playlist,
            reference: reference,
            enabled: enabled));
  }
}

class _SaveButton extends StatefulWidget {
  final Server? server;
  final Playlist playlist;
  final PlaylistReference reference;
  final bool enabled;
  const _SaveButton(
      {super.key,
      this.server,
      required this.playlist,
      required this.reference,
      required this.enabled});

  @override
  State<_SaveButton> createState() => _PlaylistServerSaveButtonState();
}

class _PlaylistServerSaveButtonState extends State<_SaveButton> {
  bool _busy = false;
  bool _saved = false;
  bool _unconfirmed = false;
  int _progress = 0;

  Future<void> _save(Server server) async {
    final playlist = widget.playlist;
    final source = widget.reference;
    final locals = AppLocalizations.of(context)!;
    if (_busy || !widget.enabled) return;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(locals.playlistCopyToServer),
        content: Text(_unconfirmed
            ? locals.playlistCopyCreateUnconfirmed
            : '${locals.playlistCopyServerHelp}\n${Uri.parse(server.url).host}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(locals.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(locals.playlistCopyToServer)),
        ],
      ),
    );
    if (proceed != true || !mounted || db.profileId != source.profileId) return;
    setState(() {
      _busy = true;
      _progress = 0;
    });
    try {
      await PlaylistServerCopy(
        database: db.forProfile(source.profileId),
        client: service,
        playlist: playlist,
        reference: source,
        server: server,
        ownerIsActive: () => mounted && db.profileId == source.profileId,
      ).save(onProgress: (saved, total) {
        if (mounted) setState(() => _progress = saved);
      });
      if (mounted && db.profileId == source.profileId) {
        setState(() {
          _saved = true;
          _unconfirmed = false;
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(locals.playlistCopySaved)));
      }
    } catch (error) {
      if (mounted && db.profileId == source.profileId) {
        _unconfirmed = error is PlaylistCreationUnconfirmed;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(_unconfirmed
                ? locals.playlistCopyCreateUnconfirmed
                : locals.playlistCopyFailed)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlist = widget.playlist;
    final locals = AppLocalizations.of(context)!;
    final server = widget.server;
    final signedIn = server != null && hasHistoryAccount(server);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          key: const ValueKey('playlist-save-server'),
          onPressed: signedIn &&
                  !_busy &&
                  !_saved &&
                  widget.enabled &&
                  playlist.videos.length == playlist.videoCount
              ? () => _save(server)
              : null,
          icon: Icon(_saved ? Icons.cloud_done : Icons.cloud_upload_outlined),
          label: Text(_busy
              ? locals.playlistCopyProgress(_progress, playlist.videoCount)
              : _saved
                  ? locals.playlistCopySaved
                  : locals.playlistCopyToServer),
        ),
        if (!signedIn) Text(locals.playlistCopySignIn),
      ],
    );
  }
}
