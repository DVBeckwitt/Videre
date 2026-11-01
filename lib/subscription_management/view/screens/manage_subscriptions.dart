import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/router.dart';
import 'package:clipious/subscription_management/models/subscription.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/views/components/simple_list_item.dart';
import 'package:clipious/utils/views/components/top_loading.dart';

import '../../states/manage_subscriptions.dart';

@RoutePage()
class ManageSubscriptionsScreen extends StatelessWidget {
  const ManageSubscriptionsScreen({super.key});

  Future<void> _changeSubscription(Future<void> change) async {
    try {
      await change;
    } catch (_) {
      // The cubit exposes failures in the screen's error and retry controls.
    }
  }

  @override
  Widget build(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(locals.manageSubscriptions),
      ),
      body: SafeArea(
        bottom: true,
        child: Center(
          child: Container(
            alignment: Alignment.topCenter,
            constraints: BoxConstraints(maxWidth: tabletMaxVideoWidth),
            child: BlocProvider(
              create: (context) =>
                  ManageSubscriptionCubit(const ManageSubscriptionsState()),
              child: BlocBuilder<ManageSubscriptionCubit,
                  ManageSubscriptionsState>(
                builder: (context, state) {
                  var cubit = context.read<ManageSubscriptionCubit>();

                  return DefaultTabController(
                    length: state.isLoggedIn ? 2 : 1,
                    child: Column(
                      children: [
                        TabBar(tabs: [
                          if (state.isLoggedIn)
                            Tab(
                              text: locals.invidiousAccount,
                            ),
                          Tab(text: locals.onDeviceSubscriptions),
                        ]),
                        if (state.hasError)
                          Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Row(
                              children: [
                                Expanded(
                                    child: Text(locals.itemlistErrorGeneric)),
                                TextButton.icon(
                                  onPressed: cubit.refreshSubs,
                                  icon: const Icon(Icons.refresh),
                                  label: Text(locals.retry),
                                ),
                              ],
                            ),
                          ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: TabBarView(
                              children: [
                                if (state.isLoggedIn)
                                  !state.loading && state.subs.isEmpty
                                      ? Center(
                                          child: state.hasError
                                              ? null
                                              : Text(locals.noChannels))
                                      : Stack(
                                          children: [
                                            RefreshIndicator(
                                              onRefresh: () =>
                                                  cubit.refreshSubs(),
                                              child: ListView.builder(
                                                itemCount: state.subs.length,
                                                itemBuilder: (context, index) {
                                                  Subscription sub =
                                                      state.subs[index];

                                                  return GestureDetector(
                                                    onTap: () => AutoRouter.of(
                                                            context)
                                                        .push(ChannelRoute(
                                                            channelId:
                                                                sub.authorId))
                                                        .then((value) => cubit
                                                            .refreshSubs()),
                                                    child: SimpleListItem(
                                                      key: ValueKey(
                                                          sub.authorId),
                                                      index: index,
                                                      child: Row(
                                                        mainAxisAlignment:
                                                            MainAxisAlignment
                                                                .spaceBetween,
                                                        children: [
                                                          Text(sub.author),
                                                          IconButton
                                                              .filledTonal(
                                                            visualDensity:
                                                                VisualDensity
                                                                    .compact,
                                                            onPressed: () {
                                                              okCancelDialog(
                                                                  context,
                                                                  locals
                                                                      .unSubscribeQuestion,
                                                                  locals
                                                                      .youCanSubscribeAgainLater,
                                                                  () => _changeSubscription(
                                                                      cubit.unsubscribe(
                                                                          sub.authorId)));
                                                            },
                                                            icon: const Icon(
                                                              Icons.clear,
                                                              size: 15,
                                                            ),
                                                          )
                                                        ],
                                                      ),
                                                    ),
                                                  );
                                                },
                                              ),
                                            ),
                                            if (state.loading)
                                              const TopListLoading()
                                          ],
                                        ),
                                !state.loading && state.offlineSubs.isEmpty
                                    ? Center(child: Text(locals.noChannels))
                                    : Stack(
                                        children: [
                                          RefreshIndicator(
                                            onRefresh: () =>
                                                cubit.refreshSubs(),
                                            child: ListView.builder(
                                              itemCount:
                                                  state.offlineSubs.length,
                                              itemBuilder: (context, index) {
                                                OfflineSubscription sub =
                                                    state.offlineSubs[index];

                                                return GestureDetector(
                                                  onTap: () => AutoRouter.of(
                                                          context)
                                                      .push(ChannelRoute(
                                                          channelId:
                                                              sub.channelId))
                                                      .then((value) =>
                                                          cubit.refreshSubs()),
                                                  child: SimpleListItem(
                                                    key:
                                                        ValueKey(sub.channelId),
                                                    index: index,
                                                    child: Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .spaceBetween,
                                                      children: [
                                                        Text(sub.channelName),
                                                        IconButton.filledTonal(
                                                          visualDensity:
                                                              VisualDensity
                                                                  .compact,
                                                          onPressed: () {
                                                            okCancelDialog(
                                                                context,
                                                                locals
                                                                    .unSubscribeQuestion,
                                                                locals
                                                                    .youCanSubscribeAgainLater,
                                                                () => _changeSubscription(
                                                                    cubit.unsubscribeOffline(
                                                                        sub.channelId)));
                                                          },
                                                          icon: const Icon(
                                                            Icons.clear,
                                                            size: 15,
                                                          ),
                                                        )
                                                      ],
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                          if (state.loading)
                                            const TopListLoading()
                                        ],
                                      ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
