import 'package:auto_route/auto_route.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/videos/views/components/download_modal_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/notifications/views/components/bell_icon.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/views/components/playlist_inner_view.dart';
import 'package:clipious/playlists/views/tablet/playlist_inner_view.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/utils.dart';

import '../../../globals.dart';
import '../../../settings/models/db/server.dart';
import '../../../utils/models/sharelink.dart';
import '../../../utils/views/components/device_widget.dart';
import '../../../utils/views/components/selected_server.dart';
import '../../models/playlist.dart';
import '../../models/playlist_reference.dart';
import '../../states/playlist.dart';
import '../components/playlist_bookmark_button.dart';
import '../components/playlist_information.dart';

@RoutePage()
class PlaylistViewScreen extends StatelessWidget {
  final Playlist playlist;
  final bool canDeleteVideos;
  final PlaylistReference? reference;
  final PlaylistReference? bookmarkOwner;

  const PlaylistViewScreen(
      {super.key,
      required this.playlist,
      required this.canDeleteVideos,
      this.reference,
      this.bookmarkOwner});

  /// Cached previews need the same owner as fresh metadata, including before
  /// the first page arrives. A missing owner must not use the selected backend.
  Widget scopeArtwork(PlaylistReference? source, Widget child) {
    if (source?.kind != PlaylistSourceKind.account) return child;
    Server? owner;
    if (source!.profileId == db.profileId) {
      try {
        owner = source.resolveServer(db);
      } on StateError {
        // Deleted or moved accounts leave the detail view without artwork.
      }
    }
    return ServerScope(server: owner, child: child);
  }

  void deletePlayList(BuildContext context) {
    var cubit = context.read<PlaylistCubit>();
    var locals = AppLocalizations.of(context)!;
    okCancelDialog(context, locals.deletePlayListQ, locals.irreversibleAction,
        () async {
      try {
        await cubit.deletePlaylist();
        if (context.mounted) Navigator.of(context).pop();
      } catch (error) {
        if (context.mounted) {
          showAlertDialog(context, locals.error, [
            Text(error is InvidiousServiceError ? error.message : locals.error)
          ]);
        }
      }
    });
  }

  Future<void> openVideo(BuildContext context, Video video) =>
      context.read<PlaylistCubit>().playEntry(video);

  Future<void> downloadPlaylist(BuildContext context) async {
    final cubit = context.read<PlaylistCubit>();
    final state = cubit.state;
    if (state.loading || !cubit.canPlayEntries || !cubit.loader.complete) {
      return;
    }
    final locals = AppLocalizations.of(context)!;
    try {
      final options = await DownloadModalSheet.showPlaylistOptions(context);
      if (options == null || !context.mounted || !cubit.canPlayEntries) return;
      final videos = {
        for (final video in state.playlist.videos)
          if (!video.filterHide) video.videoId: video,
      };
      final count = await context.read<DownloadManagerCubit>().addDownloads(
          videos.keys,
          quality: options.quality,
          audioOnly: options.audioOnly,
          container: options.container,
          videosById: videos);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text('${locals.downloadQueued}: ${locals.nVideos(count)}')));
      }
    } catch (error) {
      if (context.mounted) {
        showAlertDialog(context, locals.error, [Text(error.toString())]);
      }
    }
  }

  Future<void> removeVideoFromPlayList(BuildContext context, Video v) async {
    if (canDeleteVideos) {
      var locals = AppLocalizations.of(context)!;
      var cubit = context.read<PlaylistCubit>();
      try {
        await cubit.removeVideoFromPlayList(v);
      } catch (err) {
        if (context.mounted) {
          showAlertDialog(context, locals.error, [
            Text(err is InvidiousServiceError ? err.message : locals.error)
          ]);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ColorScheme colors = Theme.of(context).colorScheme;
    var locals = AppLocalizations.of(context)!;
    var player = context.read<PlayerCubit>();
    return BlocProvider(
      create: (context) => PlaylistCubit(
          PlaylistState(playlist: playlist), player,
          reference: reference, bookmarkOwner: bookmarkOwner),
      child: BlocBuilder<PlaylistCubit, PlaylistState>(
        builder: (context, playlistState) {
          final cubit = context.read<PlaylistCubit>();
          final source = cubit.reference;
          final canRemove = canDeleteVideos && !playlistState.playlist.isEditLocked;
          final hasEntries = playlistState.loading ||
              playlistState.error.isNotEmpty ||
              playlistState.playlist.videos.isNotEmpty;
          final headerActions = <Widget>[
            IconButton(
              tooltip: locals.downloadPlaylist,
              onPressed: playlistState.loading ||
                      !cubit.canPlayEntries ||
                      !cubit.loader.complete ||
                      playlistState.playlist.videos.isEmpty
                  ? null
                  : () => downloadPlaylist(context),
              icon: const Icon(Icons.download),
            ),
            if (!canDeleteVideos && source != null)
              PlaylistBookmarkButton(
                playlist: playlistState.playlist,
                reference: source,
                compact: true,
              ),
            if (source?.kind == PlaylistSourceKind.public)
              IconButton(
                tooltip: locals.share,
                onPressed: () => showSharingSheet(
                    context, PublicPlaylistShareLinks(source!.playlistId)),
                icon: const Icon(Icons.share_outlined),
              ),
            if ((canRemove || bookmarkOwner != null) &&
                playlist.playlistId != localWatchLaterId)
              IconButton(
                tooltip: locals.delete,
                onPressed: () => deletePlayList(context),
                icon: const Icon(Icons.delete_outline),
              ),
            if (!canDeleteVideos && !playlist.isLocal)
              BellIcon(
                  itemId: playlist.playlistId, type: BellIconType.playlist),
          ];
          return scopeArtwork(
              source,
              Scaffold(
                  appBar: AppBar(
                    title: hasEntries
                        ? null
                        : Text(playlist.playlistId == localWatchLaterId
                            ? locals.watchLater
                            : playlistState.playlist.title),
                  ),
                  backgroundColor: colors.surface,
                  body: SafeArea(
                      bottom: false,
                      child: hasEntries
                          ? DeviceWidget(
                              phone: PlaylistInnerView(
                                canDeleteVideos: canRemove,
                                openVideo: openVideo,
                                headerActions: headerActions,
                                removeVideoFromPlaylist:
                                    removeVideoFromPlayList,
                              ),
                              tablet: TabletPlaylistInnerView(
                                canDeleteVideos: canRemove,
                                openVideo: openVideo,
                                headerActions: headerActions,
                                removeVideoFromPlaylist:
                                    removeVideoFromPlayList,
                              ))
                          : ListView(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: innerHorizontalPadding),
                              children: [
                                  const PlaylistInformation(),
                                  Wrap(children: headerActions),
                                  Center(child: Text(locals.noVideoInPlayList)),
                                ]))));
        },
      ),
    );
  }
}
