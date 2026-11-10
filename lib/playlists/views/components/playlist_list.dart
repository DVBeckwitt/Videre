import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/utils/views/components/motion_animation.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/states/playlist_list.dart';
import 'package:clipious/playlists/views/components/add_to_playlist_list.dart';
import 'package:clipious/playlists/views/components/playlist_in_list.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/models/paginated_list.dart';
import 'package:clipious/utils/views/components/device_widget.dart';
import 'package:clipious/utils/views/components/top_loading.dart';

import '../../../app/states/app.dart';
import '../../../globals.dart';
import '../../../utils/views/components/placeholders.dart';
import '../../models/playlist_reference.dart';
import '../../services/playlist_library_service.dart';

class PlaylistList extends StatelessWidget {
  final PaginatedList<Playlist> paginatedList;
  final bool canDeleteVideos;
  final bool small;
  final bool includeSavedPlaylists;

  const PlaylistList(
      {super.key,
      required this.paginatedList,
      required this.canDeleteVideos,
      this.small = false,
      this.includeSavedPlaylists = false});

  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    AppLocalizations locals = AppLocalizations.of(context)!;
    final appState =
        includeSavedPlaylists ? context.watch<AppCubit>().state : null;
    final library = includeSavedPlaylists
        ? PlaylistLibraryService.forProfile(db, db.profileId)
        : null;
    return BlocProvider(
      key: includeSavedPlaylists
          ? ValueKey((db.profileId, appState?.sessionRevision))
          : null,
      create: (BuildContext context) =>
          PlaylistListCubit(PlaylistListState(paginatedList: paginatedList)),
      child: BlocBuilder<PlaylistListCubit, PlaylistListState>(
        builder: (context, state) {
          var cubit = context.read<PlaylistListCubit>();
          var deviceType = getDeviceType();
          return ListenableBuilder(
            listenable:
                Listenable.merge([if (library != null) library.changes]),
            builder: (context, _) {
              final items =
                  library?.merge(state.playlists, server: appState?.server) ??
                      state.playlists.map(PlaylistLibraryItem.new).toList();
              bool editable(PlaylistLibraryItem item) =>
                  canDeleteVideos &&
                  !item.saved &&
                  item.reference?.kind != PlaylistSourceKind.public;
              return Stack(
                children: [
                  state.error.isNotEmpty && items.isEmpty
                      ? Container(
                          alignment: Alignment.center,
                          color: colorScheme.surface,
                          child: Visibility(
                              visible: state.error.isNotEmpty,
                              child: InkWell(
                                  onTap: () => cubit.getPlaylists(),
                                  child: Text(state.error == couldNotGetPlaylits
                                      ? locals.couldntFetchVideos
                                      : state.error))),
                        )
                      : Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: MotionAnimation.fadeIn(
                            child: RefreshIndicator(
                              onRefresh: () async {
                                if (!small &&
                                    state.paginatedList.hasRefresh()) {
                                  await cubit.refreshPlaylists();
                                }
                              },
                              child: DeviceWidget(
                                forcedTyped: small ? DeviceType.phone : null,
                                phone: ListView.builder(
                                    scrollDirection:
                                        small ? Axis.horizontal : Axis.vertical,
                                    controller: cubit.scrollController,
                                    itemBuilder: (context, index) => index >=
                                            items.length
                                        ? PlaylistPlaceHolder(small: small)
                                        : PlaylistInList(
                                            key: ValueKey(items[index].key),
                                            playlist: items[index].playlist,
                                            reference: items[index].reference,
                                            bookmarkOwner:
                                                items[index].bookmarkOwner,
                                            saved: items[index].saved,
                                            canDeleteVideos:
                                                editable(items[index]),
                                            small: small),
                                    // separatorBuilder: (context, index) => const Divider(),
                                    itemCount:
                                        items.length + (state.loading ? 7 : 0)),
                                tablet: GridView.builder(
                                    controller: cubit.scrollController,
                                    itemCount: items.length,
                                    gridDelegate:
                                        SliverGridDelegateWithFixedCrossAxisCount(
                                      childAspectRatio: 16 / 12,
                                      crossAxisCount: getGridCount(context),
                                    ),
                                    itemBuilder: (context, index) => index >=
                                            items.length
                                        ? const TvPlaylistPlaceHolder()
                                        : PlaylistInList(
                                            isTablet:
                                                deviceType == DeviceType.tablet,
                                            thumbnailsHeight: 160,
                                            key: ValueKey(items[index].key),
                                            playlist: items[index].playlist,
                                            reference: items[index].reference,
                                            bookmarkOwner:
                                                items[index].bookmarkOwner,
                                            saved: items[index].saved,
                                            canDeleteVideos:
                                                editable(items[index]),
                                            small: false)),
                              ),
                            ),
                          ),
                        ),
                  Visibility(
                      visible: state.loading && !small,
                      child: const TopListLoading()),
                  Visibility(
                      visible: !small && canDeleteVideos,
                      child: const Positioned(
                          bottom: 15, right: 15, child: AddPlayListButton()))
                ],
              );
            },
          );
        },
      ),
    );
  }
}
