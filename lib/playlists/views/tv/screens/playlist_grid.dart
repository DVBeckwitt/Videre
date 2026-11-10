import 'package:clipious/utils/motion.dart';
import 'package:auto_route/annotations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/states/playlist_list.dart';
import 'package:clipious/playlists/views/components/playlist_in_list.dart';
import 'package:clipious/utils/models/paginated_list.dart';
import 'package:clipious/utils/views/components/placeholders.dart';
import 'package:clipious/utils/views/tv/components/tv_overscan.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/playlists/services/playlist_library_service.dart';

@RoutePage()
class TvPlaylistGridScreen extends StatelessWidget {
  final PaginatedList<Playlist> playlistList;
  final String? tags;
  final bool includeSavedPlaylists;

  const TvPlaylistGridScreen(
      {super.key,
      required this.playlistList,
      this.tags,
      this.includeSavedPlaylists = false});

  @override
  Widget build(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    var textTheme = Theme.of(context).textTheme;
    final appState =
        includeSavedPlaylists ? context.watch<AppCubit>().state : null;
    final library = includeSavedPlaylists
        ? PlaylistLibraryService.forProfile(db, db.profileId)
        : null;
    return BlocProvider(
      key: includeSavedPlaylists
          ? ValueKey((db.profileId, appState?.sessionRevision))
          : null,
      create: (context) =>
          PlaylistListCubit(PlaylistListState(paginatedList: playlistList)),
      child: Scaffold(
        body: TvOverscan(
          child: BlocBuilder<PlaylistListCubit, PlaylistListState>(
              builder: (context, state) {
            var cubit = context.read<PlaylistListCubit>();

            return ListenableBuilder(
              listenable:
                  Listenable.merge([if (library != null) library.changes]),
              builder: (context, _) {
                final items =
                    library?.merge(state.playlists, server: appState?.server) ??
                        state.playlists.map(PlaylistLibraryItem.new).toList();
                return Column(
                  children: [
                    Row(
                      children: [
                        Text(
                          locals.playlists,
                          style: textTheme.titleLarge,
                        ),
                        state.loading
                            ? const Padding(
                                padding: EdgeInsets.all(8.0),
                                child: SizedBox(
                                    width: 15,
                                    height: 15,
                                    child: MotionLoadingIndicator(
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2))),
                              )
                            : const SizedBox.shrink()
                      ],
                    ),
                    Expanded(
                        child: GridView.count(
                      controller: cubit.scrollController,
                      childAspectRatio: 16 / 13,
                      crossAxisCount: 3,
                      children: [
                        ...items.map((e) => PlaylistInList(
                            key: ValueKey(e.key),
                            playlist: e.playlist,
                            reference: e.reference,
                            bookmarkOwner: e.bookmarkOwner,
                            saved: e.saved,
                            canDeleteVideos: false,
                            isTv: true)),
                        if (state.loading)
                          ...repeatWidget(() => const TvPlaylistPlaceHolder(),
                              count: 10)
                      ],
                    ))
                  ],
                );
              },
            );
          }),
        ),
      ),
    );
  }
}
