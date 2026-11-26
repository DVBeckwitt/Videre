import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/videos/models/community_video_filter.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/community_browse.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/utils/states/item_list.dart';
import 'package:clipious/utils/views/components/placeholders.dart';
import 'package:clipious/videos/views/tv/components/video_item.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'tv_button.dart';

import '../../../../utils.dart';
import '../../../models/paginated_list.dart';

class TvHorizontalItemList<T> extends StatelessWidget {
  final PaginatedList<T> paginatedList;
  final Widget Function() getPlaceholder;
  final String? tags;
  final List<CommunityMatch> Function(T item)? communityMatch;
  final Widget Function(BuildContext context, int index, T item) buildItem;

  const TvHorizontalItemList(
      {super.key,
      this.tags,
      this.communityMatch,
      required this.paginatedList,
      required this.buildItem,
      required this.getPlaceholder});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) =>
          ItemListCubit<T>(ItemListState<T>(itemList: paginatedList)),
      child: BlocBuilder<ItemListCubit<T>, ItemListState<T>>(
        builder: (context, state) {
          var cubit = context.read<ItemListCubit<T>>();
          final locals = AppLocalizations.of(context)!;
          // filter items if possible
          List<T> items = state.items;
          if (items.isNotEmpty && items[0] is Video) {
            items = filteredVideos(state.items.cast()).cast();
          }

          final hasLocallyHiddenVideos = items.length < state.items.length;
          return CommunityBrowse<T>(
            items: items,
            match: communityMatch,
            builder: (context, items, hiddenNotice) {
              final canLoadMore = (state.itemList is SubscriptionVideoList ||
                      hasLocallyHiddenVideos ||
                      hiddenNotice != null) &&
                  (state.itemList.getHasMore() ||
                      state.error != ItemListErrors.none);
              final noticeCount = hiddenNotice == null ? 0 : 1;
              return Stack(
                children: [
                  if (state.loading)
                    const MotionLoadingIndicator(
                        child: LinearProgressIndicator(
                      minHeight: 3,
                    )),
                  state.error == ItemListErrors.nerdVpnApprovalPending &&
                          items.isEmpty &&
                          hiddenNotice == null
                      ? Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(locals.nerdVpnAccessPendingShort),
                        )
                      : !state.loading &&
                              items.isEmpty &&
                              !canLoadMore &&
                              hiddenNotice == null
                          ? const SizedBox.shrink()
                          : SizedBox(
                              height: 250,
                              child: ListView.builder(
                                scrollDirection: Axis.horizontal,
                                controller: cubit.scrollController,
                                itemCount: noticeCount +
                                    items.length +
                                    (state.loading
                                        ? 10
                                        : canLoadMore
                                            ? 1
                                            : 0),
                                itemBuilder: (context, index) {
                                  if (noticeCount != 0 && index == 0) {
                                    return SizedBox(
                                        width: 240,
                                        child: Center(child: hiddenNotice));
                                  }
                                  index -= noticeCount;
                                  if (!state.loading && index == items.length) {
                                    return SizedBox(
                                        width: 200,
                                        child: Center(
                                            child: TvButton(
                                                autofocus: items.isEmpty,
                                                onPressed: (_) => state.error ==
                                                        ItemListErrors.none
                                                    ? cubit.getMoreItems()
                                                    : cubit.retryItems(),
                                                child: Padding(
                                                    padding:
                                                        const EdgeInsets.all(
                                                            16),
                                                    child: Text(state.error ==
                                                            ItemListErrors.none
                                                        ? locals.loadMore
                                                        : locals.retry)))));
                                  }
                                  if (index >= items.length) {
                                    return getPlaceholder();
                                  }
                                  T e = items[index];
                                  return buildItem(context, index, e);
                                },
                              ),
                            ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class TvHorizontalVideoList extends StatelessWidget {
  final PaginatedList<Video> paginatedVideoList;
  final Function(BuildContext context, Video video)? onSelect;
  final String? tags;
  final int autoFocusedIndex;
  final bool communityBrowse;
  final void Function(Video video, int index, bool focus)? onItemFocus;

  const TvHorizontalVideoList(
      {super.key,
      this.tags,
      required this.paginatedVideoList,
      this.onSelect,
      this.communityBrowse = true,
      this.autoFocusedIndex = 0,
      this.onItemFocus});

  @override
  Widget build(BuildContext context) {
    return TvHorizontalItemList<Video>(
      getPlaceholder: () => const TvVideoItemPlaceHolder(),
      paginatedList: paginatedVideoList,
      communityMatch: communityBrowse ? videoCommunityMatches : null,
      buildItem: (context, index, e) => TvVideoItem(
        key: ValueKey('video-item-${e.videoId}'),
        video: e,
        showCommunityLabels: communityBrowse,
        autoFocus: index == autoFocusedIndex,
        onSelect: onSelect,
        onFocusChange: onItemFocus != null
            ? (focus) => onItemFocus!(e, index, focus)
            : null,
      ),
    );
  }
}
