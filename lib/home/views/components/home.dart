import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/router.dart';

import '../../../utils/views/components/app_icon.dart';
import '../../../utils/motion.dart';
import '../../../recommendations/recommendation_service.dart';
import '../screens/home_tabs_editor.dart';
import 'flow_video_home.dart';

class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();

  static void openSearch(BuildContext context, String search) {
    AutoRouter.of(context)
        .push(SearchRoute(
      query: search,
      searchNow: true,
    ))
        .then((value) {
      if (context.mounted) context.read<AppCubit>().updateLayout();
    });
  }
}

class _HomeViewState extends State<HomeView> {
  Future<void> _editLayout(
      BuildContext context, List<RecommendationInterest> interests) async {
    final app = context.read<AppCubit>();
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => HomeTabsEditorScreen(interests: interests)));
    if (mounted) app.updateLayout();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppCubit>().state;
    final tabs = TabsRouterScope.of(context, watch: true)?.controller;
    final visible = TickerMode.of(context) &&
        (tabs == null || tabs.current.name == HomeRoute.name);
    return FlowVideoHome(
      key: ValueKey((session.profileId, session.sessionRevision)),
      active: visible,
      configuredFeed: (shelf) => _ConfiguredHomeView(continueWatching: shelf),
      onEdit: (interests) => _editLayout(context, interests),
    );
  }
}

class _ConfiguredHomeView extends StatefulWidget {
  final Widget? continueWatching;

  const _ConfiguredHomeView({required this.continueWatching});

  @override
  State<_ConfiguredHomeView> createState() => _ConfiguredHomeViewState();
}

class _ConfiguredHomeViewState extends State<_ConfiguredHomeView> {
  final _nested = GlobalKey<NestedScrollViewState>();
  bool _scrolled = false;

  @override
  void didUpdateWidget(_ConfiguredHomeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.continueWatching != null || widget.continueWatching == null) {
      return;
    }
    final position =
        _nested.currentState?.innerController.positions.singleOrNull;
    if (position == null || position.pixels <= position.minScrollExtent) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          widget.continueWatching == null ||
          _nested.currentState?.innerController.positions.singleOrNull !=
              position) {
        return;
      }
      // The nested coordinator maps this inner offset past the newly laid-out
      // shelf. Keep the row being read at the same position in the viewport.
      if (position.pixels > position.minScrollExtent) {
        position.jumpTo(position.pixels);
      }
    });
  }

  List<Widget> getSmallSources(
      BuildContext context, HomeLayout layout, bool isLoggedIn) {
    var textTheme = Theme.of(context).textTheme;
    var colors = Theme.of(context).colorScheme;
    var locals = AppLocalizations.of(context)!;
    return layout.smallSources
        .where((element) => element.isPermitted(context, isLoggedIn))
        .map((e) => Padding(
              key: ValueKey(e),
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2.0),
                    child: Text(
                      e.getLabel(locals),
                      style: textTheme.titleSmall
                          ?.copyWith(color: colors.secondary),
                    ),
                  ),
                  e.build(context, true)
                ],
              ),
            ))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final layout = context.select((AppCubit app) => app.state.homeLayout);
    final isLoggedIn = context.select((AppCubit app) => app.isLoggedIn);
    final summaries = getSmallSources(context, layout, isLoggedIn);
    final theme = Theme.of(context);
    final locals = AppLocalizations.of(context)!;

    final shelf = widget.continueWatching;
    final smallSources = Padding(
      padding: const EdgeInsets.only(left: innerHorizontalPadding),
      child: Column(children: summaries),
    );
    if (!layout.showBigSource) {
      return CustomScrollView(
        slivers: [
          if (shelf != null) SliverToBoxAdapter(child: shelf),
          if (summaries.isNotEmpty)
            SliverToBoxAdapter(
                key: const ValueKey('configured-summaries'),
                child: smallSources),
          if (layout.smallSources.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                  child: Opacity(opacity: 0.2, child: AppIcon(height: 200))),
            ),
        ],
      );
    }

    final heading = Padding(
      padding: const EdgeInsets.symmetric(horizontal: innerHorizontalPadding),
      child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(layout.bigSource.getLabel(locals),
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: theme.colorScheme.secondary))),
    );
    // History can add or remove the resume shelf while another feed is on a
    // later page. Keep the paginated body and its scroll position mounted.
    return LayoutBuilder(builder: (context, constraints) {
      return Column(children: [
        if (shelf == null) ...[
          if (summaries.isNotEmpty)
            AnimatedCrossFade(
              crossFadeState: _scrolled
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: AppMotion.duration(context),
              firstChild: ConstrainedBox(
                constraints:
                    BoxConstraints(maxHeight: constraints.maxHeight * 0.6),
                child:
                    SingleChildScrollView(primary: false, child: smallSources),
              ),
              secondChild: const SizedBox(width: double.infinity),
            ),
          // Keep the phone pager's horizontal drag target outside vertical scrollables.
          heading,
        ],
        Expanded(
            child: NestedScrollView(
          key: _nested,
          headerSliverBuilder: (context, innerScrolled) => [
            if (shelf != null) SliverToBoxAdapter(child: shelf),
            if (shelf != null && summaries.isNotEmpty)
              SliverToBoxAdapter(child: smallSources),
          ],
          body: Column(children: [
            if (shelf != null) heading,
            Expanded(
                key: ValueKey(layout.bigSource),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: innerHorizontalPadding),
                  child: NotificationListener<ScrollUpdateNotification>(
                    onNotification: (notice) {
                      if (summaries.isNotEmpty &&
                          notice.depth == 0 &&
                          notice.metrics.axis == Axis.vertical) {
                        final scrolled = notice.metrics.pixels > 100;
                        if (scrolled != _scrolled) {
                          setState(() => _scrolled = scrolled);
                        }
                      }
                      return false;
                    },
                    child: layout.bigSource
                        .build(context, false, nestedScroll: true),
                  ),
                )),
          ]),
        )),
      ]);
    });
  }
}
