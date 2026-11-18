import 'dart:async';

import 'package:flutter/material.dart';
import 'package:clipious/app/states/app.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/utils/states/item_list.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/utils/views/components/top_loading.dart';
import 'package:clipious/videos/views/components/history_video.dart';

import '../../../utils/models/paginated_list.dart';
import '../../../utils/views/components/placeholders.dart';
import '../../states/history.dart';

class HistoryView extends StatefulWidget {
  final bool nestedScroll;

  const HistoryView({super.key, this.nestedScroll = false});

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  bool local = true;

  Future<void> _confirmRemoval(
      BuildContext context, HistoryCubit history, String? videoId) async {
    final locals = AppLocalizations.of(context)!;
    final profile = db.profileId;
    final app = context.read<AppCubit>();
    final session = app.state.sessionRevision;
    final server = app.state.server;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (context) => AlertDialog(
        title:
            Text(videoId == null ? locals.clearHistoryQuestion : locals.delete),
        content: Text(videoId == null
            ? history.local
                ? locals.localHistoryClearDescription
                : locals.clearHistoryQuestionExplanation
            : db.getHistoryVideoByVideoId(videoId)?.title ?? videoId),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(locals.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(videoId == null ? locals.ok : locals.delete)),
        ],
      ),
    );
    // Both row and bulk deletion belong to the original source and person,
    // even if that list or session changes while its confirmation is open.
    if (confirmed == true &&
        context.mounted &&
        !history.isClosed &&
        !app.isClosed &&
        db.profileId == profile &&
        app.state.sessionRevision == session &&
        app.state.server == server &&
        !app.state.globalLoading &&
        !app.state.sessionRecoveryRequired) {
      if (videoId == null) {
        await history.clearHistory();
      } else {
        await history.removeFromHistory(videoId);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    final loggedIn = context.select((AppCubit app) => app.isLoggedIn);
    final showLocal = local || !loggedIn;
    return MultiBlocProvider(
      key: ValueKey(showLocal),
      providers: [
        BlocProvider(
            create: (BuildContext context) => ItemListCubit<String>(
                ItemListState<String>(
                    itemList: PageBasedPaginatedList<String>(
                        getItemsFunc: showLocal
                            ? service.getLocalHistoryPage
                            : service.getUserHistory,
                        maxResults: 20)))),
        BlocProvider(
          create: (context) => HistoryCubit(
              null, context.read<ItemListCubit<String>>(),
              local: showLocal),
        )
      ],
      child: Column(children: [
        DropdownButton<bool>(
          value: showLocal,
          items: [
            DropdownMenuItem(value: true, child: Text(locals.onDevice)),
            if (loggedIn)
              DropdownMenuItem(value: false, child: Text(locals.onServer)),
          ],
          onChanged: (value) => setState(() => local = value ?? true),
        ),
        Expanded(child:
            BlocBuilder<ItemListCubit<String>, ItemListState<String>>(
                builder: (context, state) {
          var listCubit = context.read<ItemListCubit<String>>();
          var historyCubit = context.read<HistoryCubit>();
          return Stack(
            children: [
              state.error != ItemListErrors.none
                  ? Center(
                      child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(switch (state.error) {
                        ItemListErrors.nerdVpnApprovalPending =>
                          locals.nerdVpnAccessPendingShort,
                        ItemListErrors.invalidScope =>
                          locals.itemListErrorInvalidScope,
                        _ => locals.itemlistErrorGeneric
                      }),
                    ))
                  : !state.loading && state.items.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Text(locals.noHistory),
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: RefreshIndicator(
                            onRefresh: () {
                              unawaited(service.syncHistory());
                              return listCubit.refreshItems();
                            },
                            child:
                                NotificationListener<ScrollUpdateNotification>(
                              onNotification: (notice) {
                                if (widget.nestedScroll && notice.depth == 0) {
                                  listCubit.onScrollEvent(notice.metrics);
                                }
                                return false;
                              },
                              child: ListView.builder(
                                controller: widget.nestedScroll
                                    ? null
                                    : listCubit.scrollController,
                                primary: widget.nestedScroll ? true : null,
                                scrollDirection: Axis.vertical,
                                itemCount: state.items.length +
                                    (state.loading ? 5 : 0),
                                itemBuilder: (context, index) => Padding(
                                  padding: EdgeInsets.only(
                                      bottom: index == state.items.length - 1
                                          ? 70.0
                                          : 0),
                                  child: index >= state.items.length
                                      ? const CompactVideoPlaceHolder()
                                      : HistoryVideoView(
                                          key: ValueKey(state.items[index]),
                                          videoId: state.items[index],
                                          onLongPress: () => _confirmRemoval(
                                              context,
                                              historyCubit,
                                              state.items[index])),
                                ),
                              ),
                            ),
                          ),
                        ),
              if (state.loading) const TopListLoading(),
              Positioned(
                  bottom: 15,
                  right: 15,
                  child: FloatingActionButton(
                    onPressed: () =>
                        _confirmRemoval(context, historyCubit, null),
                    child: const Icon(Icons.delete),
                  ))
            ],
          );
        })),
      ]),
    );
  }
}
