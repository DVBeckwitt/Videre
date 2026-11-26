import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/videos/models/community_video_filter.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/globals.dart' show innerHorizontalPadding;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/states/item_list.dart';
import 'package:clipious/utils/views/components/placeholders.dart';
import 'package:clipious/utils/views/components/top_loading.dart';
import 'package:clipious/videos/views/components/video_in_list.dart';

import '../../../downloads/models/downloaded_video.dart';
import '../../../utils/models/paginated_list.dart';
import 'community_browse.dart';
import 'compact_video.dart';

const smallVideoAspectRatio = 0.76;
const smallVideoViewHeight = 140.0;

double smallVideoListHeight(BuildContext context) {
  final label = Theme.of(context).textTheme.labelSmall;
  final fontSize = label?.fontSize ?? 11;
  final extra = MediaQuery.textScalerOf(context).scale(fontSize) - fontSize;
  // Each compact card has a title and author beneath its fixed-size artwork.
  return smallVideoViewHeight +
      (extra > 0 ? (2 * extra * (label?.height ?? 1.45)).ceilToDouble() : 0);
}

class VideoList<T extends IdedVideo> extends StatelessWidget {
  final PaginatedList<T> paginatedVideoList;
  final String? tags;
  final bool animateDownload;
  final Axis scrollDirection;
  final bool small;
  final bool showMetrics;
  final bool allowModalSheet;
  final bool communityBrowse;
  final bool nestedScroll;
  final VideoCardLayout layout;
  final bool showChannel;
  final Function(BuildContext context, Video video)? showVideoModalSheet;
  final Function(BuildContext context, Video video)? openVideoOverride;

  const VideoList(
      {super.key,
      required this.paginatedVideoList,
      this.tags,
      this.animateDownload = false,
      this.scrollDirection = Axis.vertical,
      this.showMetrics = true,
      this.allowModalSheet = true,
      this.communityBrowse = false,
      this.nestedScroll = false,
      this.layout = VideoCardLayout.standard,
      this.showChannel = true,
      this.showVideoModalSheet,
      this.openVideoOverride,
      this.small = false});

  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    var locals = AppLocalizations.of(context)!;
    var textTheme = Theme.of(context).textTheme;
    return BlocProvider(
      create: (context) =>
          ItemListCubit<T>(ItemListState<T>(itemList: paginatedVideoList)),
      child: BlocBuilder<ItemListCubit<T>, ItemListState<T>>(
        builder: (context, state) {
          var cubit = context.read<ItemListCubit<T>>();
          final subscriptionFeed = state.itemList is SubscriptionVideoList;
          List<T> items = state.items;
          if (items.isNotEmpty && items[0] is Video) {
            items = filteredVideos(state.items.cast()).cast<T>();
          }

          final hasLocallyHiddenVideos = items.length < state.items.length;
          final gridCount = small || layout == VideoCardLayout.flowRow
              ? 1
              : getGridCount(context);
          final gap = small ? 8.0 : 5.0;
          return CommunityBrowse<T>(
            items: items,
            match: communityBrowse
                ? (item) =>
                    item is Video ? videoCommunityMatches(item) : const []
                : null,
            builder: (context, items, hiddenNotice) {
              final canLoadMore = (subscriptionFeed ||
                      hasLocallyHiddenVideos ||
                      hiddenNotice != null) &&
                  state.itemList.getHasMore();
              return NotificationListener<ScrollNotification>(
                onNotification: (notice) {
                  if (nestedScroll &&
                      notice.depth == 0 &&
                      notice is ScrollUpdateNotification) {
                    cubit.onScrollEvent(notice.metrics);
                  }
                  return false;
                },
                child: Stack(
                  alignment: Alignment.topCenter,
                  children: [
                    if (!small && state.loading) const TopListLoading(),
                    state.error != ItemListErrors.none &&
                            items.isEmpty &&
                            hiddenNotice == null
                        ? Container(
                            alignment: Alignment.center,
                            color: colorScheme.surface,
                            child: InkWell(
                                onTap:
                                    subscriptionFeed || hasLocallyHiddenVideos
                                        ? cubit.retryItems
                                        : cubit.getItems,
                                child: Text(
                                  state.error ==
                                          ItemListErrors.nerdVpnApprovalPending
                                      ? locals.nerdVpnAccessPendingShort
                                      : locals.couldntFetchVideos,
                                  style: small
                                      ? textTheme.labelSmall
                                      : textTheme.bodyMedium,
                                )),
                          )
                        : items.isEmpty &&
                                !state.loading &&
                                hiddenNotice == null
                            ? FilledButton.tonal(
                                onPressed: canLoadMore
                                    ? cubit.getMoreItems
                                    : cubit.refreshItems,
                                child: Text(canLoadMore
                                    ? locals.loadMore
                                    : locals.refresh))
                            : Padding(
                                padding:
                                    EdgeInsets.only(top: small ? 0.0 : 4.0),
                                child: RefreshIndicator(
                                  onRefresh: () async =>
                                      !small && state.itemList.hasRefresh()
                                          ? await cubit.refreshItems()
                                          : Future.delayed(Duration.zero),
                                  child: LayoutBuilder(
                                      builder: (context, constraints) {
                                    final cardWidth = (constraints.maxWidth -
                                            gap * (gridCount - 1)) /
                                        gridCount;
                                    final scale =
                                        MediaQuery.textScalerOf(context);
                                    final extent = switch (layout) {
                                      VideoCardLayout.flowRow =>
                                        compactVideoRowHeight(context) +
                                            innerHorizontalPadding,
                                      VideoCardLayout.flowFeed =>
                                        cardWidth * 9 / 16 +
                                            scale.scale(16) * 2.45 +
                                            scale.scale(12) * 1.5 +
                                            32,
                                      _ => small &&
                                              scrollDirection == Axis.horizontal
                                          ? smallVideoViewHeight /
                                              smallVideoAspectRatio
                                          : null,
                                    };
                                    return GridView(
                                      controller: nestedScroll
                                          ? null
                                          : cubit.scrollController,
                                      primary: nestedScroll ? true : null,
                                      scrollDirection: scrollDirection,
                                      gridDelegate:
                                          SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: gridCount,
                                        crossAxisSpacing: gap,
                                        mainAxisSpacing: gap,
                                        mainAxisExtent: extent,
                                        childAspectRatio: small
                                            ? smallVideoAspectRatio
                                            : getGridAspectRatio(context),
                                      ),
                                      children: [
                                        if (hiddenNotice != null)
                                          Center(child: hiddenNotice),
                                        ...items.map((v) {
                                          Video? onlineVideo;
                                          DownloadedVideo? offlineVideo;

                                          if (v is Video) {
                                            onlineVideo = v;
                                          }

                                          if (v is DownloadedVideo) {
                                            offlineVideo = v;
                                          }

                                          return VideoListItem(
                                            small: small,
                                            showMetrics: showMetrics,
                                            key: ValueKey(
                                                '${v.videoId}-${small.toString()}'),
                                            video: onlineVideo,
                                            offlineVideo: offlineVideo,
                                            animateDownload: animateDownload,
                                            showVideoModalSheet:
                                                showVideoModalSheet,
                                            allowModalSheet: allowModalSheet,
                                            openVideoOverride:
                                                openVideoOverride,
                                            showCommunityLabels:
                                                communityBrowse,
                                            layout: layout,
                                            showChannel: showChannel,
                                          );
                                        }),
                                        if (canLoadMore && !state.loading)
                                          Center(
                                            child: TextButton.icon(
                                                onPressed: state.error ==
                                                        ItemListErrors.none
                                                    ? cubit.getMoreItems
                                                    : cubit.retryItems,
                                                icon: const Icon(
                                                    Icons.expand_more),
                                                label: Text(state.error ==
                                                        ItemListErrors.none
                                                    ? locals.loadMore
                                                    : locals.retry)),
                                          ),
                                        if (state.loading)
                                          ...repeatWidget(
                                              () => VideoListItemPlaceHolder(
                                                    small: small,
                                                  ),
                                              count: 5 * gridCount)
                                      ],
                                    );
                                  }),
                                ),
                              )
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
