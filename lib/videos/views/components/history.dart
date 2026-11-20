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
  final bool music;

  const HistoryView({super.key, this.nestedScroll = false, this.music = false});

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  HistorySource selected = HistorySource.video;

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
            ? switch (history.source) {
                HistorySource.music => locals.clearMusicPlaybackHistory,
                HistorySource.video => locals.clearVideoPlaybackHistory,
                HistorySource.device => locals.localHistoryClearDescription,
                HistorySource.server => locals.clearHistoryQuestionExplanation,
              }
            : history.source.cached(videoId)?.title ?? videoId),
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
    final source = widget.music
        ? HistorySource.music
        : !loggedIn && selected == HistorySource.server
            ? HistorySource.video
            : selected;
    final session = context.select((AppCubit app) =>
        (app.state.profileId, app.state.sessionRevision, app.state.server));
    return MultiBlocProvider(
      key: ValueKey((source, session)),
      providers: [
        BlocProvider(
            create: (BuildContext context) => ItemListCubit<String>(
                ItemListState<String>(
                    itemList: PageBasedPaginatedList<String>(
                        getItemsFunc: source.page, maxResults: 20)))),
        BlocProvider(
          create: (context) => HistoryCubit(
              null, context.read<ItemListCubit<String>>(),
              source: source),
        )
      ],
      child: Column(children: [
        if (!widget.music)
          DropdownButton<HistorySource>(
            key: const ValueKey('history-source'),
            isExpanded: true,
            value: source,
            items: [
              for (final item in [
                HistorySource.video,
                HistorySource.device,
                if (loggedIn) HistorySource.server,
              ])
                DropdownMenuItem(
                    value: item,
                    child: Text(item.label(locals),
                        overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (value) {
              if (value != null) setState(() => selected = value);
            },
          ),
        Expanded(child:
            BlocBuilder<ItemListCubit<String>, ItemListState<String>>(
                builder: (context, state) {
          var listCubit = context.read<ItemListCubit<String>>();
          var historyCubit = context.read<HistoryCubit>();
          return Stack(
            children: [
              if (!state.loading &&
                  (state.error != ItemListErrors.none || state.items.isEmpty))
                Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(switch (state.error) {
                    ItemListErrors.none => widget.music
                        ? locals.noMusicPlaybackHistory
                        : locals.noHistory,
                    ItemListErrors.nerdVpnApprovalPending =>
                      locals.nerdVpnAccessPendingShort,
                    ItemListErrors.invalidScope =>
                      locals.itemListErrorInvalidScope,
                    _ => locals.itemlistErrorGeneric
                  }),
                  IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: state.error == ItemListErrors.none
                          ? locals.refresh
                          : locals.retry,
                      onPressed: listCubit.refreshItems),
                ]))
              else
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: RefreshIndicator(
                    onRefresh: () {
                      if (!widget.music) {
                        unawaited(service.syncHistory());
                      }
                      return listCubit.refreshItems();
                    },
                    child: NotificationListener<ScrollUpdateNotification>(
                      onNotification: (notice) {
                        if (widget.nestedScroll && notice.depth == 0) {
                          listCubit.onScrollEvent(notice.metrics);
                        }
                        return false;
                      },
                      child: ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        controller: widget.nestedScroll
                            ? null
                            : listCubit.scrollController,
                        primary: widget.nestedScroll ? true : null,
                        scrollDirection: Axis.vertical,
                        itemCount: state.items.length + (state.loading ? 5 : 0),
                        itemBuilder: (context, index) => Padding(
                          padding: EdgeInsets.only(
                              bottom:
                                  index == state.items.length - 1 ? 70.0 : 0),
                          child: index >= state.items.length
                              ? const CompactVideoPlaceHolder()
                              : HistoryVideoView(
                                  key: ValueKey(state.items[index]),
                                  videoId: state.items[index],
                                  source: source,
                                  onLongPress: () => _confirmRemoval(context,
                                      historyCubit, state.items[index])),
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
                    heroTag: null,
                    tooltip: locals.clearHistoryQuestion,
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
