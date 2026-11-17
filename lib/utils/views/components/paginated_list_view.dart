import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/videos/views/components/community_browse.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/utils/views/components/top_loading.dart';

import '../../models/paginated_list.dart';
import '../../states/paginated_list_view.dart';

class PaginatedListView<T> extends StatelessWidget {
  final PaginatedList<T> paginatedList;
  final List<T>? startItems;
  final List<CommunityMatch> Function(T item)? communityMatch;
  final Widget Function(T item) itemBuilder;

  const PaginatedListView(
      {super.key,
      required this.paginatedList,
      required this.itemBuilder,
      this.communityMatch,
      this.startItems});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => PaginatedListCubit<T>(
          PaginatedListViewController.init<T>(
              paginatedList: paginatedList, startItems: startItems)),
      child: BlocBuilder<PaginatedListCubit<T>, PaginatedListViewController<T>>(
          builder: (context, state) {
        var cubit = context.read<PaginatedListCubit<T>>();
        return CommunityBrowse<T>(
          items: state.items,
          match: communityMatch,
          builder: (context, items, hiddenNotice) {
            final noticeCount = hiddenNotice == null ? 0 : 1;
            final canLoadMore = hiddenNotice != null &&
                !state.loading &&
                !state.hasError &&
                state.paginatedList.getHasMore();
            return Stack(
              children: [
                if (state.loading) const TopListLoading(),
                ListView.builder(
                  controller: cubit.scrollController,
                  itemCount: noticeCount + items.length + (canLoadMore ? 1 : 0),
                  itemBuilder: (BuildContext context, int index) {
                    if (noticeCount != 0 && index == 0) return hiddenNotice!;
                    index -= noticeCount;
                    if (index == items.length) {
                      return Center(
                        child: TextButton(
                          onPressed: cubit.getMoreItems,
                          child: Text(AppLocalizations.of(context)!.loadMore),
                        ),
                      );
                    }
                    return itemBuilder(items[index]);
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
