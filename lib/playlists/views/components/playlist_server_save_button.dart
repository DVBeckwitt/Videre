import 'dart:convert';

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
            // Music rebuilds track artwork and metadata while the same copy
            // is open. Only a changed source, copy content or account resets it.
            key: ValueKey((
              reference.key,
              playlist.title,
              playlist.videoCount,
              jsonEncode([for (final video in playlist.videos) video.videoId]),
              server?.profileId,
              server?.accountId,
              server?.url,
            )),
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
  PlaylistCopyNeedsConfirmation? _replacement;
  int _progress = 0;
  PlaylistTrackSaveFailure? _trackFailure;

  String _actionLabel(AppLocalizations locals) {
    if (_replacement != null) return locals.playlistCopyCreateNew;
    return _trackFailure == null
        ? locals.playlistCopyToServer
        : locals.playlistCopyResume;
  }

  String? _replacementMessage(AppLocalizations locals) =>
      switch (_replacement) {
        PlaylistCreationUnconfirmed() => locals.playlistCopyCreateUnconfirmed,
        PlaylistCopyMissing() => locals.playlistCopyDestinationMissing,
        null => null,
      };

  String _trackMessage(
      AppLocalizations locals, PlaylistTrackSaveFailure failure) {
    final playlist = widget.playlist;
    final video = playlist.videos[failure.index];
    final title = [video.musicMetadata?.title, video.title, video.videoId]
        .whereType<String>()
        .firstWhere((value) => value.trim().isNotEmpty,
            orElse: () => video.videoId);
    final position = failure.index + 1;
    final status = failure.statusCode;
    return status != null
        ? locals.playlistCopyTrackHttpFailed(
            position, playlist.videoCount, title, status)
        : locals.playlistCopyTrackFailed(position, playlist.videoCount, title);
  }

  Future<void> _save(Server server) async {
    final playlist = widget.playlist;
    final source = widget.reference;
    final locals = AppLocalizations.of(context)!;
    if (_busy || !widget.enabled) return;
    final failure = _trackFailure;
    final replacement = _replacement;
    final action = _actionLabel(locals);
    final detail = _replacementMessage(locals) ??
        (failure == null
            ? locals.playlistCopyServerHelp
            : _trackMessage(locals, failure));
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(action),
        content: Text('$detail\n${Uri.parse(server.url).host}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(locals.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action)),
        ],
      ),
    );
    if (proceed != true || !mounted || db.profileId != source.profileId) return;
    setState(() {
      _busy = true;
      _trackFailure = null;
      _replacement = null;
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
      ).save(
          confirmedReplacement: replacement,
          onProgress: (saved, total) {
            if (mounted) setState(() => _progress = saved);
          });
      if (mounted && db.profileId == source.profileId) {
        setState(() {
          _saved = true;
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(locals.playlistCopySaved)));
      }
    } catch (error) {
      if (mounted && db.profileId == source.profileId) {
        if (error is PlaylistCopyNeedsConfirmation) {
          _replacement = error;
        } else if (error is PlaylistTrackSaveFailure) {
          _trackFailure = error;
        } else {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(locals.playlistCopyFailed)));
        }
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
                  : _actionLabel(locals)),
        ),
        if (!signedIn) Text(locals.playlistCopySignIn),
        if (_replacementMessage(locals) case final message?)
          Semantics(liveRegion: true, child: Text(message)),
        if (_trackFailure case final failure?)
          Semantics(
              liveRegion: true, child: Text(_trackMessage(locals, failure))),
      ],
    );
  }
}
