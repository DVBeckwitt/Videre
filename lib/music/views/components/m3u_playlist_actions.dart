import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../playlists/models/playlist.dart';
import '../../models/device_playlist_track.dart';
import '../../services/local_music_library.dart';
import 'm3u_playlist_dialog.dart';
import 'music_library_actions.dart';

Future<String?> importDevicePlaylist(BuildContext context,
    {Playlist? existing}) {
  final session = MusicLibrarySession(context.read<AppCubit>());
  final owner = db.forProfile(session.library.profileId);
  final playlistService = service;
  final library = LocalMusicLibrary.instance;
  return showM3uImport(
    context,
    session: session,
    existingTitle: existing?.title,
    save: (title, rows, isCurrent) async {
      final videos =
          rows.map((row) => devicePlaylistVideo(row.track)!).toList();
      final identities = {
        for (final (index, video) in videos.indexed)
          video.videoId: rows[index].track,
      };
      bool canWrite() =>
          isCurrent() &&
          identities.entries.every((item) {
            final current =
                library.playlistTrackById(item.key, visibleOnly: true);
            final document = item.value.documentIdentity;
            return current != null &&
                (current.uri == item.value.uri ||
                    (document != null && current.documentIdentity == document));
          });
      final idsByTrack = {
        for (final entry in identities.entries)
          entry.value.playbackId: entry.key,
      };
      final idsByDocument = {
        for (final entry in identities.entries)
          if (entry.value.documentIdentity case final document?)
            document: entry.key,
      };
      String? resolveDeviceId(String id) {
        final track = library.playlistTrackById(id, visibleOnly: true);
        if (track == null) return null;
        return idsByTrack[track.playbackId] ??
            idsByDocument[track.documentIdentity];
      }

      final String id;
      if (existing == null) {
        final created = await playlistService.createLocalPlaylistWithEntries(
            title, videos,
            database: owner, isCurrent: canWrite);
        if (created == null) {
          throw StateError('The active device source changed');
        }
        id = created;
      } else {
        id = existing.playlistId;
        await playlistService.replaceLocalDevicePlaylistEntries(
            id, existing.videos, videos,
            database: owner,
            isCurrent: canWrite,
            resolveDeviceId: resolveDeviceId);
      }
      // Device projections have music metadata, so the Music Library
      // already recognizes a populated playlist without a separate marker.
      session.library.notifyChanged();
      return id;
    },
  );
}

enum _M3uAction { export, reimport }

class M3uPlaylistActions extends StatelessWidget {
  final Playlist playlist;

  const M3uPlaylistActions({super.key, required this.playlist});

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final ids = [
      for (final video in playlist.videos)
        devicePlaylistFileProof(video.videoId) == null ? null : video.videoId,
    ];
    final canExport = ids.any((id) => id != null);
    final canReimport = ids.every((id) => id != null);
    if (!canExport && !canReimport) return const SizedBox.shrink();
    return PopupMenuButton<_M3uAction>(
      key: const ValueKey('music-playlist-m3u-actions'),
      tooltip: locals.musicM3uActions,
      icon: const Icon(Icons.import_export),
      onSelected: (action) async {
        if (action == _M3uAction.reimport) {
          await importDevicePlaylist(context, existing: playlist);
          return;
        }
        final session = MusicLibrarySession(context.read<AppCubit>());
        await exportM3uPlaylist(
          context,
          session: session,
          title: playlist.title,
          deviceIds: ids,
          resolve: (index, id) {
            final track = LocalMusicLibrary.instance
                .playlistTrackById(id, visibleOnly: true);
            return track == null ? null : index.byTrack(track);
          },
        );
      },
      itemBuilder: (_) => [
        if (canExport)
          PopupMenuItem(
              value: _M3uAction.export, child: Text(locals.musicM3uExport)),
        if (canReimport)
          PopupMenuItem(
              value: _M3uAction.reimport, child: Text(locals.musicM3uReimport)),
      ],
    );
  }
}
