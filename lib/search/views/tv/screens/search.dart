import 'package:clipious/utils/motion.dart';
import 'package:auto_route/auto_route.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/community_browse.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/views/components/playlist_in_list.dart';
import 'package:clipious/router.dart';
import 'package:clipious/search/models/search_type.dart';
import 'package:clipious/utils/models/paginated_list.dart';
import 'package:clipious/utils/views/components/placeholders.dart';
import 'package:clipious/utils/views/tv/components/tv_button.dart';
import 'package:clipious/utils/views/tv/components/tv_horizontal_item_list.dart';
import 'package:clipious/utils/views/tv/components/tv_horizontal_paginated_list.dart';
import 'package:clipious/utils/views/tv/components/tv_overscan.dart';
import 'package:clipious/utils/views/tv/components/tv_text_field.dart';

import '../../../../channels/models/channel.dart';
import '../../../../globals.dart';
import '../../../../settings/states/settings.dart';
import '../../../states/search.dart';
import '../../../states/tv_search.dart';
import '../../components/pasted_link_dialog.dart';
import '../../screens/search.dart';

@RoutePage()
class TvSearchScreen extends StatelessWidget {
  final String? query;
  final bool? searchNow;

  const TvSearchScreen({super.key, this.query, this.searchNow});

  Widget buildSuggestion(
      BuildContext context, bool isHistory, String suggestion) {
    ColorScheme colors = Theme.of(context).colorScheme;
    var searchCubit = context.read<SearchCubit>();

    return TvButton(
        onPressed: (context) => searchCubit.setSearchQuery(suggestion),
        focusedColor: colors.secondaryContainer,
        unfocusedColor: Colors.transparent,
        child: isHistory
            ? Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16),
                child: Row(children: [
                  const Icon(Icons.history),
                  Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        suggestion,
                      ))
                ]),
              )
            : Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16),
                child: Text(suggestion),
              ));
  }

  @override
  Widget build(BuildContext context) {
    TextTheme textTheme = Theme.of(context).textTheme;
    var locals = AppLocalizations.of(context)!;

    var colors = Theme.of(context).colorScheme;

    var settings = context.read<SettingsCubit>();
    return Scaffold(
      body: TvOverscan(
        child: DefaultTextStyle(
          style: textTheme.bodyLarge!,
          child: MultiBlocProvider(
            providers: [
              BlocProvider(
                create: (context) => TvSearchCubit(const TvSearchState()),
              ),
              BlocProvider(
                create: (context) => SearchCubit(
                    SearchState.init(query: query, searchNow: searchNow),
                    settings,
                    chooseOpen: () => choosePastedLinkAction(context),
                    isLinkSourceActive: () => isPastedLinkSourceActive(context),
                    showSuggestionsWithResults: true),
              )
            ],
            child: BlocBuilder<SearchCubit, SearchState>(
                builder: (context, search) {
              final searchCubit = context.read<SearchCubit>();
              final query = searchCubit.submittedQuery;
              final scope = searchCubit.resultScope;
              return BlocBuilder<TvSearchCubit, TvSearchState>(
                builder: (context, _) {
                  final tvCubit = context.read<TvSearchCubit>();
                  final tv = tvCubit.resultsFor(scope);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        locals.search,
                        style: textTheme.titleLarge,
                      ),
                      TvTextField(
                        leading: Icon(
                          Icons.search,
                          color: colors.secondary,
                        ),
                        controller: search.queryController,
                        autofocus: true,
                        autocorrect: true,
                        focusNode: tvCubit.searchFocus,
                        onSubmitted: (value) async {
                          // The full-screen TV keyboard calls this immediately
                          // before popping. Let its search route regain focus.
                          if (ModalRoute.of(context)?.isCurrent == false) {
                            await WidgetsBinding.instance.endOfFrame;
                            if (!context.mounted || searchCubit.isClosed) {
                              return;
                            }
                          }
                          await searchCubit.search(value);
                          if (!searchCubit.isClosed) {
                            searchCubit.getSuggestions(hideResult: false);
                          }
                        },
                        textInputAction: TextInputAction.search,
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 20),
                          child: search.showResults
                              ? FocusScope(
                                  key: ValueKey(scope),
                                  onKeyEvent: tvCubit.handleResultScopeKeyEvent,
                                  canRequestFocus: true,
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        width: 200,
                                        child: ListView(
                                          shrinkWrap: true,
                                          children: search.queryController.value
                                                  .text.isEmpty
                                              ? search.searchHistory
                                                  .map((e) => buildSuggestion(
                                                      context, true, e))
                                                  .toList()
                                              : search.suggestions
                                                  .map((e) => buildSuggestion(
                                                      context, false, e))
                                                  .toList(),
                                        ),
                                      ),
                                      Expanded(
                                          child: SingleChildScrollView(
                                        controller: tvCubit.scrollController,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Visibility(
                                                visible: tv.hasVideos,
                                                child: Text(
                                                  locals.videos,
                                                  style: textTheme.titleLarge,
                                                )),
                                            Focus(
                                                focusNode: tvCubit.resultFocus,
                                                onFocusChange: (focused) {
                                                  if (focused) {
                                                    AppMotion.scrollTo(
                                                        context,
                                                        tvCubit
                                                            .scrollController,
                                                        0);
                                                  }
                                                },
                                                child: TvHorizontalVideoList(
                                                    paginatedVideoList:
                                                        PageBasedPaginatedList<
                                                            Video>(
                                                  getItemsFunc: (page,
                                                          maxResults) =>
                                                      service
                                                          .search(query,
                                                              page: page,
                                                              type: SearchType
                                                                  .video)
                                                          .then((value) {
                                                    if (page == 1 &&
                                                        searchCubit
                                                            .isShowingResultsFor(
                                                                scope)) {
                                                      tvCubit.setHasVideo(
                                                          scope,
                                                          value.videos
                                                              .isNotEmpty);
                                                    }
                                                    return value.videos;
                                                  }),
                                                  maxResults: searchPageSize,
                                                ))),
                                            Visibility(
                                                visible: tv.hasChannels,
                                                child: Text(
                                                  locals.channels,
                                                  style: textTheme.titleLarge,
                                                )),
                                            SizedBox(
                                              height: 60,
                                              child:
                                                  TvHorizontalPaginatedListView<
                                                      Channel>(
                                                communityMatch:
                                                    channelCommunityMatches,
                                                getPlaceHolder: () =>
                                                    const Padding(
                                                  padding: EdgeInsets.all(8.0),
                                                  child: TvChannelPlaceholder(),
                                                ),
                                                paginatedList:
                                                    PageBasedPaginatedList<
                                                        Channel>(
                                                  getItemsFunc: (page,
                                                          maxResults) =>
                                                      service
                                                          .search(query,
                                                              page: page,
                                                              type: SearchType
                                                                  .channel)
                                                          .then((value) {
                                                    if (page == 1 &&
                                                        searchCubit
                                                            .isShowingResultsFor(
                                                                scope)) {
                                                      tvCubit.setHasChannels(
                                                          scope,
                                                          value.channels
                                                              .isNotEmpty);
                                                    }
                                                    return value.channels;
                                                  }),
                                                  maxResults: searchPageSize,
                                                ),
                                                startItems: const [],
                                                itemBuilder: (e) => Padding(
                                                  padding:
                                                      const EdgeInsets.all(8.0),
                                                  child: TvButton(
                                                    onPressed: (context) =>
                                                        openChannel(context, e),
                                                    borderRadius: 20,
                                                    child: Padding(
                                                      padding:
                                                          const EdgeInsets.all(
                                                              8.0),
                                                      child: Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          Text(e.author),
                                                          VideoChannelCommunityLabels(
                                                            authorId:
                                                                e.authorId,
                                                            authorUrl:
                                                                e.authorUrl,
                                                            compact: true,
                                                            interactive: false,
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                            Visibility(
                                                visible: tv.hasPlaylists,
                                                child: Text(
                                                  locals.playlists,
                                                  style: textTheme.titleLarge,
                                                )),
                                            TvHorizontalItemList<Playlist>(
                                              getPlaceholder: () =>
                                                  const TvPlaylistPlaceHolder(),
                                              paginatedList:
                                                  PageBasedPaginatedList<
                                                      Playlist>(
                                                getItemsFunc:
                                                    (page, maxResults) =>
                                                        service
                                                            .search(query,
                                                                page: page,
                                                                type: SearchType
                                                                    .playlist)
                                                            .then((value) {
                                                  if (page == 1 &&
                                                      searchCubit
                                                          .isShowingResultsFor(
                                                              scope)) {
                                                    tvCubit.setHasPlaylists(
                                                        scope,
                                                        value.playlists
                                                            .isNotEmpty);
                                                  }
                                                  return value.playlists;
                                                }),
                                                maxResults: searchPageSize,
                                              ),
                                              buildItem: (context, index,
                                                      item) =>
                                                  Padding(
                                                      padding:
                                                          const EdgeInsets.all(
                                                              8.0),
                                                      child: PlaylistInList(
                                                        playlist: item,
                                                        canDeleteVideos: false,
                                                        isTv: true,
                                                        // cameFromSearch: true,
                                                      )),
                                            ),
                                          ],
                                        ),
                                      ))
                                    ],
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                      )
                    ],
                  );
                },
              );
            }),
          ),
        ),
      ),
    );
  }

  openChannel(BuildContext context, Channel c) {
    AutoRouter.of(context).push(TvChannelRoute(channelId: c.authorId));
  }
}
