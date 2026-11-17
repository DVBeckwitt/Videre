import 'package:clipious/utils/motion.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/community_browse.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../utils.dart';
import '../../../models/paginated_list.dart';
import '../../../states/paginated_list_view.dart';
import 'tv_button.dart';

class TvHorizontalPaginatedListView<T> extends StatelessWidget {
  final PaginatedList<T> paginatedList;
  final List<T>? startItems;
  final List<CommunityMatch> Function(T item)? communityMatch;
  final Widget Function(T item) itemBuilder;
  final Widget Function() getPlaceHolder;

  const TvHorizontalPaginatedListView(
      {super.key,
      required this.paginatedList,
      required this.itemBuilder,
      this.startItems,
      this.communityMatch,
      required this.getPlaceHolder});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => PaginatedListCubit(
          PaginatedListViewController.init<T>(
              paginatedList: paginatedList, startItems: startItems)),
      child: BlocBuilder<PaginatedListCubit<T>, PaginatedListViewController<T>>(
          builder: (context, state) {
        var cubit = context.read<PaginatedListCubit<T>>();
        // filter items if possible
        List<T> items = state.items;
        if (items.isNotEmpty && items[0] is Video) {
          items = filteredVideos(state.items.cast()).cast();
        }
        return CommunityBrowse<T>(
          items: items,
          match: communityMatch,
          compactNotice: true,
          builder: (context, items, hiddenNotice) {
            final noticeCount = hiddenNotice == null ? 0 : 1;
            final canLoadMore = hiddenNotice != null &&
                !state.loading &&
                !state.hasError &&
                state.paginatedList.getHasMore();
            return Stack(
              children: [
                state.loading
                    ? const MotionLoadingIndicator(
                        child: LinearProgressIndicator(
                        minHeight: 3,
                      ))
                    : const SizedBox.shrink(),
                ListView.builder(
                  controller: cubit.scrollController,
                  scrollDirection: Axis.horizontal,
                  itemCount: noticeCount +
                      items.length +
                      (state.loading
                          ? 10
                          : canLoadMore
                              ? 1
                              : 0),
                  itemBuilder: (BuildContext context, int index) {
                    if (noticeCount != 0 && index == 0) {
                      return SizedBox(
                          width: 280, child: Center(child: hiddenNotice));
                    }
                    index -= noticeCount;
                    if (index < items.length) return itemBuilder(items[index]);
                    if (state.loading) return getPlaceHolder();
                    return TvButton(
                      onPressed: (_) => cubit.getMoreItems(),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(AppLocalizations.of(context)!.loadMore),
                      ),
                    );
                  },
                ),
                if (state.hasError)
                  Align(
                    alignment: items.isEmpty && hiddenNotice == null
                        ? Alignment.center
                        : Alignment.bottomCenter,
                    child: FilledButton.icon(
                      onPressed: cubit.retry,
                      icon: const Icon(Icons.refresh),
                      label: Text(AppLocalizations.of(context)!.retry),
                    ),
                  ),
              ],
            );
          },
        );
      }),
    );
  }
}
