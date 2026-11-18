import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../router.dart';
import '../../../utils.dart';
import '../../../utils/motion.dart';
import '../../../utils/views/components/placeholders.dart';
import '../../states/channel.dart';
import '../components/channel_load_error.dart';
import '../components/channel_search.dart';
import '../components/info.dart';

@RoutePage()
class ChannelScreen extends StatelessWidget {
  final String channelId;

  const ChannelScreen({super.key, @pathParam required this.channelId});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => ChannelCubit(ChannelController(channelId: channelId)),
      child: BlocBuilder<ChannelCubit, ChannelController>(
        buildWhen: (previous, current) =>
            previous.channel != current.channel ||
            previous.loading != current.loading ||
            previous.hasError != current.hasError,
        builder: (context, state) {
          final channel = state.channel;
          if (state.hasError) {
            return Scaffold(
              appBar: AppBar(),
              body: ChannelLoadError(
                  onRetry: context.read<ChannelCubit>().onReady),
            );
          }
          if (channel == null) {
            return Scaffold(appBar: AppBar(), body: const ChannelPlaceHolder());
          }

          final locals = AppLocalizations.of(context)!;
          final colors = Theme.of(context).colorScheme;
          // Flow ChannelContent.kt and ChannelTabRow.kt at 565d1f7a keep
          // one collapsing header and pin the secondary tabs above the list.
          return AutoTabsRouter.tabBar(
            key: ValueKey(channel.authorId),
            animatePageTransition: AppMotion.allowsMovement(context),
            routes: [
              ChannelInfoRoute(channel: channel),
              ChannelVideoRoute(channel: channel),
              ChannelShortsRoute(channel: channel),
              ChannelStreamRoute(channel: channel),
              ChannelPlaylistsRoute(channelId: channel.authorId),
            ],
            builder: (context, page, controller) => ChannelSearchShell(
              channelId: channel.authorId,
              builder: (context, openSearch) => Scaffold(
                body: NestedScrollView(
                  headerSliverBuilder: (context, innerScrolled) => [
                    SliverAppBar(
                      pinned: true,
                      title: innerScrolled
                          ? Text(channel.author,
                              overflow: TextOverflow.ellipsis)
                          : null,
                      actions: [
                        if (openSearch != null)
                          IconButton(
                            tooltip: locals.channelSearch,
                            onPressed: openSearch,
                            icon: const Icon(Icons.search_rounded),
                          ),
                        IconButton(
                          tooltip: locals.share,
                          onPressed: () => showSharingSheet(context, channel),
                          icon: const Icon(Icons.share_outlined),
                        ),
                      ],
                    ),
                    SliverToBoxAdapter(child: ChannelHeader(channel: channel)),
                    PinnedHeaderSliver(
                      child: Material(
                        color: colors.surface,
                        child: TabBar(
                          controller: controller,
                          isScrollable: true,
                          tabAlignment: TabAlignment.start,
                          indicatorSize: TabBarIndicatorSize.tab,
                          indicatorWeight: 2,
                          labelColor: colors.onSurface,
                          unselectedLabelColor: colors.onSurfaceVariant,
                          indicatorColor: colors.onSurface,
                          dividerColor: colors.outlineVariant,
                          tabs: [
                            Tab(text: locals.home),
                            Tab(text: locals.videos),
                            Tab(text: locals.shorts),
                            Tab(text: locals.streams),
                            Tab(text: locals.playlists),
                          ],
                        ),
                      ),
                    ),
                  ],
                  body: MediaQuery.removePadding(
                      context: context, removeTop: true, child: page),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
