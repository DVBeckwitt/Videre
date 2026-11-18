import 'package:clipious/utils/motion.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/home/states/home.dart';
import 'package:clipious/router.dart';

import '../../../utils/views/components/app_icon.dart';
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

class _ConfiguredHomeView extends StatelessWidget {
  final Widget? continueWatching;

  const _ConfiguredHomeView({required this.continueWatching});

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

    final shelf = continueWatching;
    final smallSources = Padding(
      padding: const EdgeInsets.only(left: innerHorizontalPadding),
      child: Column(children: summaries),
    );
    final header = [
      if (shelf != null) SliverToBoxAdapter(child: shelf),
      if (summaries.isNotEmpty) SliverToBoxAdapter(child: smallSources),
    ];

    if (!layout.showBigSource) {
      return CustomScrollView(
        slivers: [
          ...header,
          if (layout.smallSources.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                  child: Opacity(opacity: 0.2, child: AppIcon(height: 200))),
            ),
        ],
      );
    }

    final mainSource = Padding(
      padding: const EdgeInsets.symmetric(horizontal: innerHorizontalPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(layout.bigSource.getLabel(locals),
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: theme.colorScheme.secondary)),
          Expanded(
            key: ValueKey(layout.bigSource),
            child: layout.bigSource
                .build(context, false, nestedScroll: shelf != null),
          ),
        ],
      ),
    );
    if (shelf != null) {
      return NestedScrollView(
        headerSliverBuilder: (context, innerScrolled) => header,
        body: mainSource,
      );
    }

    // The standard layout lets people swipe tabs from the main feed heading
    // and independently scroll compact sources on short screens.
    return BlocProvider(
      create: (_) => HomeCubit(false),
      child: BlocBuilder<HomeCubit, bool>(builder: (context, scrolled) {
        return NotificationListener<ScrollUpdateNotification>(
          onNotification: (notice) {
            if (notice.metrics.axis == Axis.vertical) {
              context.read<HomeCubit>().setScroll(notice.metrics.pixels > 100);
            }
            return false;
          },
          child: LayoutBuilder(builder: (context, constraints) {
            return Column(children: [
              AnimatedCrossFade(
                crossFadeState: scrolled
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                firstCurve: Curves.easeInOutQuad,
                secondCurve: Curves.easeInOutQuad,
                sizeCurve: Curves.easeInOutQuad,
                duration: AppMotion.duration(context),
                firstChild: ConstrainedBox(
                  constraints:
                      BoxConstraints(maxHeight: constraints.maxHeight * 0.6),
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (_) => true,
                    child: SingleChildScrollView(child: smallSources),
                  ),
                ),
                secondChild: const SizedBox(width: double.infinity),
              ),
              Expanded(child: mainSource),
            ]);
          }),
        );
      }),
    );
  }
}
