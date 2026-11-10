import 'package:clipious/utils/motion.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/states/playlist_in_list.dart';
import 'package:clipious/playlists/views/components/playlist_thumbnail.dart';
import 'package:clipious/router.dart';
import 'package:clipious/utils.dart';

import '../../states/playlist_list.dart';
import '../../models/playlist_reference.dart';
import '../../../app/states/app.dart';
import '../../../videos/models/video.dart';

const smallPlaylistAspectRatio = 1.54;

class PlaylistInList extends StatelessWidget {
  final Playlist playlist;
  final bool canDeleteVideos;
  final bool isTv;
  final bool small;
  final bool isTablet;
  final double thumbnailsHeight;
  final PlaylistReference? reference;
  final PlaylistReference? bookmarkOwner;
  final bool saved;

  const PlaylistInList(
      {super.key,
      required this.playlist,
      required this.canDeleteVideos,
      this.isTv = false,
      this.small = false,
      this.thumbnailsHeight = 95,
      this.isTablet = false,
      this.reference,
      this.bookmarkOwner,
      this.saved = false});

  Future<void> openPlayList(BuildContext context) async {
    final cubit = context.read<PlaylistListCubit?>();
    final PageRouteInfo route;
    if (isTv) {
      route = TvPlaylistRoute(
          playlist: playlist,
          reference: reference,
          bookmarkOwner: bookmarkOwner,
          canDeleteVideos: false);
    } else {
      route = PlaylistViewRoute(
          playlist: playlist,
          reference: reference,
          bookmarkOwner: bookmarkOwner,
          canDeleteVideos: canDeleteVideos);
    }
    await AutoRouter.of(context).push(route);
    if (cubit != null && !cubit.isClosed) await cubit.refreshPlaylists();
  }

  @override
  Widget build(BuildContext context) {
    ColorScheme colors = Theme.of(context).colorScheme;
    var textTheme = Theme.of(context).textTheme;
    var locals = AppLocalizations.of(context)!;
    final title = playlist.playlistId == localWatchLaterId
        ? locals.watchLater
        : playlist.title;
    final count = locals.nVideos(playlist.videoCount);
    final detail = saved
        ? '${locals.playlistSavedOnDevice} · $count'
        : playlist.isLocal
            ? '${locals.onDevice} · $count'
            : canDeleteVideos || bookmarkOwner != null
                ? '${locals.onServer} · $count'
                : count;

    return BlocProvider(
      create: (context) => PlaylistInListCubit(playlist, reference: reference),
      child: BlocBuilder<PlaylistInListCubit, Playlist>(
        builder: (context, state) {
          // Thumbnail transport follows the selected account. Do not send a
          // saved private playlist's preview IDs through a different account.
          final selectedAccount = reference?.kind == PlaylistSourceKind.account
              ? context.watch<AppCubit>().state.server
              : null;
          final selectedUrl = Uri.tryParse(selectedAccount?.url ?? '');
          final selectedOrigin = selectedUrl != null &&
                  const ['http', 'https'].contains(selectedUrl.scheme) &&
                  selectedUrl.host.isNotEmpty
              ? selectedUrl.origin
              : null;
          final videos = reference?.kind == PlaylistSourceKind.account &&
                  (selectedAccount?.accountId != reference?.accountId ||
                      selectedAccount?.profileId != reference?.profileId ||
                      selectedOrigin != reference?.origin)
              ? const <Video>[]
              : state.videos;
          if (isTablet) {
            return InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => openPlayList(context),
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                        height: thumbnailsHeight,
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: PlaylistThumbnails(
                            videos: videos,
                          ),
                        )),
                    Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                      style: TextStyle(color: colors.primary),
                    ),
                    Text(detail),
                  ],
                ),
              ),
            );
          } else if (isTv) {
            return Focus(
              onKeyEvent: (node, event) =>
                  onTvSelect(event, context, (_) => openPlayList(context)),
              autofocus: false,
              child: AspectRatio(
                aspectRatio: 16 / 13,
                child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Builder(builder: (ctx) {
                      final bool hasFocus = Focus.of(ctx).hasFocus;

                      return GestureDetector(
                        child: AnimatedScale(
                            curve: Curves.easeInOutQuad,
                            duration: AppMotion.duration(
                                context, animationDuration ~/ 2),
                            scale: hasFocus ? 1 : 0.9,
                            child: AnimatedContainer(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(15),
                                color: hasFocus
                                    ? colors.primaryContainer
                                    : colors.surface,
                              ),
                              duration: AppMotion.duration(context),
                              child: Padding(
                                padding: const EdgeInsets.all(8.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                        height: 140,
                                        child: PlaylistThumbnails(
                                          videos: videos,
                                        )),
                                    Expanded(
                                        child: Text(
                                      title,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.titleLarge
                                          ?.copyWith(color: colors.primary),
                                    )),
                                    Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 8.0),
                                        child: Text(detail)),
                                  ],
                                ),
                              ),
                            )),
                      );
                    })),
              ),
            );
          } else if (small) {
            return AspectRatio(
              aspectRatio: smallPlaylistAspectRatio,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => openPlayList(context),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    PlaylistThumbnails(
                      videos: videos,
                    ),
                    Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style:
                          textTheme.labelSmall?.copyWith(color: colors.primary),
                    ),
                  ],
                ),
              ),
            );
          } else {
            return InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => openPlayList(context),
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                        height: 95,
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: PlaylistThumbnails(
                            videos: videos,
                          ),
                        )),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          Text(
                            title,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 2,
                            style: TextStyle(color: colors.primary),
                          ),
                          Text(detail),
                        ],
                      ),
                    )
                  ],
                ),
              ),
            );
          }
        },
      ),
    );
  }
}
