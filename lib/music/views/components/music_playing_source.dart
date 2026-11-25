import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/music/views/screens/music_device_album.dart';
import 'package:clipious/music/views/screens/music_library.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/views/screens/playlist.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

enum _SourceKind { album, queueAlbum, playlist }

typedef _DeviceAlbum = ({
  String? selectionId,
  String playbackId,
  String albumKey,
  String title,
});

typedef _SourceTarget = ({
  _SourceKind kind,
  Object identity,
  String title,
  Widget page,
});

/// The release ID encoded in a public queue reference, if present.
String? musicQueueAlbumId(PlaylistReference? source) =>
    source?.kind == PlaylistSourceKind.public
        ? validMusicAlbumPlaylistId(source?.playlistId)
        : null;

bool _sameSession(AppState current, AppState original) =>
    !current.globalLoading &&
    !current.sessionRecoveryRequired &&
    current.profileId == db.profileId &&
    current.profileId == original.profileId &&
    current.sessionRevision == original.sessionRevision &&
    current.server == original.server;

_DeviceAlbum? _deviceAlbum(PlayerCubit player) {
  final state = player.state;
  if (state.isClosing || state.isHidden || player.openingMusicEntry != null) {
    return null;
  }
  final library = LocalMusicLibrary.instance;
  final selection = library.selectionId;
  if (!library.acceptsSessionSelection(selection)) return null;
  final id = (state.currentlyPlaying ?? state.offlineCurrentlyPlaying)?.videoId;
  final track = localMusicTrackForPlayback(id);
  final key = track?.albumKey;
  final title = track?.album?.trim();
  if (track == null || key == null || title == null || title.isEmpty) {
    return null;
  }
  return (
    selectionId: selection,
    playbackId: track.playbackId,
    albumKey: key,
    title: title,
  );
}

Widget _devicePage(_DeviceAlbum album) => MusicDeviceAlbumPage(
    selectionId: album.selectionId,
    playbackId: album.playbackId,
    albumKey: album.albumKey);

/// Holding the mini player opens the album at the exact current device file.
VoidCallback? openDeviceAlbumAction(BuildContext context, PlayerCubit player) {
  final app = context.read<AppCubit?>();
  final album = _deviceAlbum(player);
  if (app == null ||
      album == null ||
      app.state.globalLoading ||
      app.state.sessionRecoveryRequired ||
      app.state.profileId != db.profileId) {
    return null;
  }
  final session = app.state;
  final generation = player.playlistGeneration;
  final occurrence = player.state.currentQueueId;
  return () {
    if (!context.mounted ||
        app.isClosed ||
        player.isClosed ||
        !_sameSession(app.state, session) ||
        player.playlistGeneration != generation ||
        player.state.currentQueueId != occurrence ||
        _deviceAlbum(player) != album) {
      return;
    }
    unawaited(MusicScreen.openPlayingSource(context, _devicePage(album),
        television: false));
  };
}

/// Opens only collections whose identity is known from the live playback.
class MusicPlayingSource extends StatelessWidget {
  final MusicMetadata music;
  final String? occurrence;
  final bool television;

  const MusicPlayingSource({
    super.key,
    required this.music,
    required this.occurrence,
    required this.television,
  });

  PlaylistReference? _playlist(PlayerCubit player, AppState session) {
    final source = player.playlistReference;
    if (source == null ||
        source.profileId != session.profileId ||
        source.profileId != db.profileId ||
        PlaylistReference.tryParse(source.toJson()) == null) {
      return null;
    }
    if (source.kind == PlaylistSourceKind.account) {
      try {
        final account = source.resolveServer(db);
        if (account == null ||
            account.accountId != session.server?.accountId ||
            account.url != session.server?.url) {
          return null;
        }
      } on StateError {
        return null;
      }
    }
    return source;
  }

  Widget _playlistPage(PlaylistReference source, String title) {
    final id = source.playlistId;
    if (source.kind == PlaylistSourceKind.local) {
      return MusicLibraryPage(source: source);
    }
    if (source.kind == PlaylistSourceKind.public &&
        RegExp(r'^(PL|RD|OLAK5uy_)[A-Za-z0-9_-]+$').hasMatch(id)) {
      return MusicScreen(playlistId: id);
    }
    // The generic loader retains the typed account reference and reopens its
    // original collection independently of the current queue edits.
    return PlaylistViewScreen(
      playlist:
          Playlist(playlistId: id, title: title, author: '', videoCount: 0),
      reference: source,
      canDeleteVideos: false,
    );
  }

  List<_SourceTarget> _targets(
      PlayerCubit player, AppState session, AppLocalizations locals) {
    final state = player.state;
    if (session.globalLoading ||
        session.sessionRecoveryRequired ||
        session.profileId != db.profileId ||
        state.isClosing ||
        state.isHidden ||
        player.openingMusicEntry != null ||
        state.currentQueueId == null) {
      return const [];
    }
    if (_deviceAlbum(player) case final device?) {
      return [
        (
          kind: _SourceKind.album,
          identity: device,
          title: device.title,
          page: _devicePage(device),
        ),
      ];
    }
    final source = _playlist(player, session);
    final queueAlbumId = musicQueueAlbumId(source);
    final sourceTitle = player.musicQueueTitle ??
        source?.displayTitle ??
        (queueAlbumId == null
            ? locals.musicOpenPlaylist
            : locals.musicOpenAlbum);
    final current = state.currentlyPlaying?.musicMetadata ??
        state.offlineCurrentlyPlaying?.musicMetadata;
    final albumId = current?.albumPlaylistId;
    final sameAlbum = albumId != null && albumId == queueAlbumId;
    final albumTitle = current?.album?.trim();
    return [
      if (albumId != null)
        (
          kind: _SourceKind.album,
          identity: albumId,
          title: albumTitle?.isNotEmpty == true
              ? albumTitle!
              : (sameAlbum ? sourceTitle : locals.musicOpenAlbum),
          page: MusicScreen(playlistId: albumId),
        ),
      if (source != null && !sameAlbum)
        (
          kind: queueAlbumId == null
              ? _SourceKind.playlist
              : _SourceKind.queueAlbum,
          identity: source,
          title: sourceTitle,
          page: _playlistPage(source, sourceTitle),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerCubit>();
    final app = context.watch<AppCubit>();
    final locals = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: Listenable.merge([
        LocalMusicLibrary.instance,
        player.playlistLoadingRevision,
      ]),
      builder: (context, _) {
        final session = app.state;
        final generation = player.playlistGeneration;
        final state = player.state;
        final opening = player.openingMusicEntry;
        final displayed =
            opening ?? state.currentlyPlaying ?? state.offlineCurrentlyPlaying;
        if (displayed == null || playbackQueueId(displayed) != occurrence) {
          return const SizedBox.shrink();
        }
        final mounted = state.currentQueueId;
        final targets = _targets(player, session, locals);
        final colors = Theme.of(context).colorScheme;
        final style = Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: colors.onSurfaceVariant);
        final album = music.album?.trim();
        Widget metadataLabel(String value) => Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(value,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: style));
        final albumLabel =
            album == null || album.isEmpty ? null : metadataLabel(album);
        if (opening != null) {
          final origin = _sameSession(session, session)
              ? _playlist(player, session)
              : null;
          final originTitle = origin == null
              ? null
              : (player.musicQueueTitle ?? origin.displayTitle)?.trim();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (albumLabel != null) albumLabel,
              if (originTitle != null &&
                  originTitle.isNotEmpty &&
                  originTitle != album)
                metadataLabel(originTitle),
            ],
          );
        }
        if (targets.isEmpty) return albumLabel ?? const SizedBox.shrink();

        Future<void> open(_SourceTarget target) async {
          if (!context.mounted ||
              app.isClosed ||
              player.isClosed ||
              !_sameSession(app.state, session) ||
              player.playlistGeneration != generation ||
              player.state.currentQueueId != mounted) {
            return;
          }
          final latest = _targets(player, app.state, locals)
              .where((candidate) =>
                  candidate.kind == target.kind &&
                  candidate.identity == target.identity)
              .firstOrNull;
          if (latest != null) {
            await MusicScreen.openPlayingSource(context, latest.page,
                television: television);
          }
        }

        final first = targets.first;
        final multiple = targets.length > 1;
        String actionLabel(_SourceTarget target) => switch (target.kind) {
              _SourceKind.album => locals.musicOpenAlbum,
              _SourceKind.queueAlbum when !multiple => locals.musicOpenAlbum,
              _ => locals.musicOpenPlaylist,
            };

        final buttonStyle = TextButton.styleFrom(
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            alignment: AlignmentDirectional.centerStart,
            foregroundColor: colors.onSurfaceVariant);
        final label = Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
              child: Text(first.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
          const SizedBox(width: 4),
          Icon(
              multiple
                  ? Icons.expand_more_rounded
                  : Icons.chevron_right_rounded,
              size: 18),
        ]);
        Widget choiceLabel(_SourceTarget target) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(actionLabel(target)),
                if (target.title != actionLabel(target))
                  Text(target.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
              ],
            );
        const key = ValueKey('music-playing-source');
        final sourceButton = Align(
          alignment: AlignmentDirectional.centerStart,
          child: multiple
              ? PopupMenuButton<Future<void> Function()>(
                  key: key,
                  tooltip: locals.musicOpenSource,
                  style: buttonStyle,
                  onSelected: (command) => unawaited(command()),
                  itemBuilder: (_) => [
                    for (final (index, target) in targets.indexed)
                      PopupMenuItem<Future<void> Function()>(
                        value: () => open(target),
                        child: index == 0
                            ? PlayerModalBackHandler(
                                priority: 5, child: choiceLabel(target))
                            : choiceLabel(target),
                      ),
                  ],
                  child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: label),
                )
              : Tooltip(
                  message: '${actionLabel(first)} · ${first.title}',
                  child: TextButton(
                    key: key,
                    style: buttonStyle,
                    onPressed: () => unawaited(open(first)),
                    child: label,
                  ),
                ),
        );
        if (albumLabel == null ||
            first.kind != _SourceKind.queueAlbum ||
            album == first.title) {
          return sourceButton;
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [albumLabel, sourceButton],
        );
      },
    );
  }
}
