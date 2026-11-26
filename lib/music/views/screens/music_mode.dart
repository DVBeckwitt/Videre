import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../player/states/player.dart';
import '../../../player/views/components/mini_player_aware.dart';
import '../../../router.dart';
import '../../../settings/states/settings.dart';
import '../../../utils.dart';
import '../../../utils/motion.dart';
import '../../models/music_layout.dart';
import '../components/music_screen_privacy.dart';
import '../../services/local_music_library.dart';
import '../components/local_music_locations.dart';
import 'music.dart';
import 'music_discovery.dart';
import 'music_library.dart';

@RoutePage()
class MainMusicTab extends StatelessWidget {
  const MainMusicTab({super.key});

  static Future<void> openSearch(TabsRouter tabs) async {
    final key = GlobalObjectKey<_MusicModeScreenState>(tabs);
    // A second tap can arrive before the newly selected tab has mounted.
    if (key.currentState == null) await WidgetsBinding.instance.endOfFrame;
    if (tabs.current.name == MainMusicRoute.name) {
      key.currentState?._openSearch();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabs = AutoTabsRouter.of(context, watch: true);
    final active = tabs.current.name == MainMusicRoute.name;
    // Retained tab pages remain mounted. Only the visible Music page may
    // handle Back, request focus, or refresh discovery recommendations.
    return TickerMode(
      enabled: active,
      child: ExcludeFocus(
        excluding: !active,
        child: MusicModeScreen(
            key: GlobalObjectKey<_MusicModeScreenState>(tabs),
            appBar: null,
            inMainPager: true),
      ),
    );
  }
}

@RoutePage()
class MusicShortcutScreen extends StatefulWidget {
  const MusicShortcutScreen(
      {super.key, required this.destination, this.canStartShuffle});

  final MusicDestination destination;
  final bool Function()? canStartShuffle;

  @override
  State<MusicShortcutScreen> createState() => _MusicShortcutScreenState();
}

class _MusicShortcutScreenState extends State<MusicShortcutScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.canStartShuffle != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => unawaited(_shuffleLocalMusic()));
    }
  }

  Future<void> _shuffleLocalMusic() async {
    if (!mounted) return;
    final canStartShuffle = widget.canStartShuffle;
    if (canStartShuffle == null || !canStartShuffle()) return;
    final route = ModalRoute.of(context);
    final library = LocalMusicLibrary.instance;
    await library.loadForShuffle();
    if (!mounted || !canStartShuffle() || route?.isCurrent == false) return;
    final locals = AppLocalizations.of(context)!;
    final tracks = library.visibleTracks;
    if (tracks.isEmpty) {
      final message = localMusicSourceStatus(library, locals) ??
          (library.enabled
              ? locals.localMusicNoVisibleFiles
              : locals.localMusicChooseFolder);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      return;
    }
    final selection = library.selectionId;
    await context.read<PlayerCubit>().shuffleLocalMusic(tracks,
        queueTitle: locals.onDevice,
        isCurrent: () =>
            mounted &&
            canStartShuffle() &&
            route?.isCurrent != false &&
            library.acceptsSessionSelection(selection));
  }

  @override
  Widget build(BuildContext context) => MusicModeScreen(
        appBar: AppBar(title: Text(AppLocalizations.of(context)!.music)),
        initialDestination: widget.destination,
      );
}

class MusicModeScreen extends StatefulWidget {
  static void openSearch(BuildContext context) =>
      context.findAncestorStateOfType<_MusicModeScreenState>()?._openSearch();

  final PreferredSizeWidget? appBar;
  final Widget? mainNavigationBar;
  final Widget? mainNavigationRail;
  final bool inMainPager;
  final MusicDestination initialDestination;

  const MusicModeScreen({
    super.key,
    required this.appBar,
    this.mainNavigationBar,
    this.mainNavigationRail,
    this.inMainPager = false,
    this.initialDestination = MusicDestination.home,
  });

  @override
  State<MusicModeScreen> createState() => _MusicModeScreenState();
}

class _MusicModeScreenState extends State<MusicModeScreen> {
  late List<MusicDestination> _order;
  late final PageController _pages;
  final _storage = PageStorageBucket();
  final _search = GlobalKey<MusicScreenState>();
  final _retained = {
    for (final destination in MusicDestination.values)
      destination: GlobalKey<_RetainedMusicPageState>(),
  };
  late MusicDestination _page;
  Object? _pendingSearchFocus;

  @override
  void initState() {
    super.initState();
    _page = widget.initialDestination;
    _order = context.read<SettingsCubit>().state.musicLayout.destinations;
    _pages =
        PageController(initialPage: _order.indexOf(_page), keepPage: false);
    if (_page == MusicDestination.search) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pages.positions.length == 1) _openSearch();
      });
    }
  }

  void _applyOrder(List<MusicDestination> order) {
    _pendingSearchFocus = null;
    setState(() => _order = order);
    _pages.jumpToPage(order.indexOf(_page));
  }

  void _openSearch() => _show(MusicDestination.search, focusSearch: true);

  void _select(MusicDestination page) {
    if (_pages.positions.length != 1) return;
    if (page == _page && !_pages.position.isScrollingNotifier.value) {
      final player = context.read<PlayerCubit?>()?.state;
      final covered = player != null &&
          (player.isPip || !player.isHidden && !player.isMini);
      if (!covered &&
          TickerMode.of(context) &&
          ModalRoute.isCurrentOf(context) != false) {
        _retained[page]?.currentState?.scrollToTop();
      }
      return;
    }
    if (page == MusicDestination.search) {
      _openSearch();
    } else {
      _show(page);
    }
  }

  Future<void> _show(MusicDestination page, {bool focusSearch = false}) async {
    if (focusSearch && _pendingSearchFocus != null) return;
    final request = focusSearch ? Object() : null;
    _pendingSearchFocus = request;
    final from = _page;
    if (page != from || _pages.position.isScrollingNotifier.value) {
      final index = _order.indexOf(page);
      if (AppMotion.allowsMovement(context)) {
        await _pages.animateToPage(index,
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      } else {
        _pages.jumpToPage(index);
      }
    }
    if (request == null) return;
    // The retained search field can take focus after the page has been laid out.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _pendingSearchFocus != request) return;
    _pendingSearchFocus = null;
    // The pager can finish animating while Settings is opening over Music.
    if (_page == MusicDestination.search &&
        TickerMode.of(context) &&
        ModalRoute.isCurrentOf(context) != false) {
      _search.currentState?.focusSearch(
          onBack: from == MusicDestination.search ? null : () => _show(from));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // An offstage page's animation may finish only after returning to Music.
    if (!TickerMode.of(context)) _pendingSearchFocus = null;
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Widget _navigationBar(BuildContext context,
      {required bool embedded, required bool compact}) {
    final locals = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    return NavigationBar(
      key: embedded ? const ValueKey('music-destination-bar') : null,
      height: phoneNavigationHeight(context, compact: compact),
      backgroundColor: colors.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      indicatorColor:
          embedded ? colors.secondaryContainer : colors.surfaceContainerHighest,
      labelBehavior:
          compact ? NavigationDestinationLabelBehavior.alwaysHide : null,
      selectedIndex: _order.indexOf(_page),
      onDestinationSelected: (index) => _select(_order[index]),
      destinations: [
        for (final destination in _order)
          NavigationDestination(
              key: embedded
                  ? ValueKey('music-section-${destination.name}')
                  : null,
              icon: Icon(destination.icon),
              label: destination.label(locals)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) =>
      MusicScreenPrivacySurface(child: _buildMusicMode(context));

  Widget _buildMusicMode(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final phone = getDeviceType() == DeviceType.phone;
    final embedded = widget.inMainPager ||
        widget.mainNavigationBar != null ||
        widget.mainNavigationRail != null;
    final embeddedPhone =
        phone && (widget.inMainPager || widget.mainNavigationBar != null);
    final dock = embeddedPhone ? MiniPlayerDock.maybeOf(context) : null;
    final keyboardVisible =
        dock?.keyboardVisible ?? MediaQuery.viewInsetsOf(context).bottom > 0;
    final slimNavigation = context.select(
        (SettingsCubit cubit) => cubit.state.musicLayout.slimNavigation);
    final phoneBar = phone && !(embeddedPhone && keyboardVisible)
        ? _navigationBar(context,
            embedded: embeddedPhone,
            compact: slimNavigation ||
                embeddedPhone && usesCompactMusicNavigation(context))
        : null;
    final mainBar = widget.mainNavigationBar;
    final bottomBar = mainBar == null
        ? phoneBar
        : embeddedPhone
            ? keyboardVisible
                ? null
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [phoneBar!, mainBar])
            : mainBar;
    return BlocListener<SettingsCubit, SettingsState>(
      listenWhen: (before, after) => !listEquals(
          before.musicLayout.destinations, after.musicLayout.destinations),
      listener: (_, state) => _applyOrder(state.musicLayout.destinations),
      child: Scaffold(
        appBar: widget.appBar,
        bottomNavigationBar: bottomBar,
        body: Row(children: [
          if (widget.mainNavigationRail != null)
            widget.mainNavigationRail!
          else if (!phone && !widget.inMainPager)
            NavigationRail(
              selectedIndex: _order.indexOf(_page),
              onDestinationSelected: (index) => _select(_order[index]),
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final destination in _order)
                  NavigationRailDestination(
                      icon: Icon(destination.icon),
                      label: Text(destination.label(locals))),
              ],
            ),
          Expanded(
            child: Column(children: [
              if (embedded && !embeddedPhone)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(children: [
                      for (final destination in _order)
                        Padding(
                          key: ValueKey(destination),
                          padding: const EdgeInsetsDirectional.only(end: 8),
                          child: ChoiceChip(
                            key: ValueKey('music-section-${destination.name}'),
                            label: Text(destination.label(locals)),
                            selected: destination == _page,
                            onSelected: (_) => _select(destination),
                          ),
                        ),
                    ]),
                  ),
                ),
              Expanded(
                child: _musicBody(
                    dock: dock,
                    child: PageStorage(
                        bucket: _storage,
                        child: PageView(
                          key: const PageStorageKey('music-mode-pages'),
                          controller: _pages,
                          // In the primary phone pager, horizontal page gestures
                          // follow the configured app tabs. The Music row selects
                          // Music sections, and their own horizontal lists scroll.
                          physics: widget.inMainPager
                              ? const NeverScrollableScrollPhysics()
                              : null,
                          onPageChanged: (index) {
                            final page = _order[index];
                            if (page != MusicDestination.search) {
                              _search.currentState?.leaveSearch();
                            }
                            setState(() => _page = page);
                          },
                          children: [
                            for (final destination in _order)
                              _RetainedMusicPage(
                                key: _retained[destination],
                                active: destination == _page,
                                child: switch (destination) {
                                  MusicDestination.home => MusicHomePage(
                                      showSearchShortcut: false,
                                      onSearch: () =>
                                          _show(MusicDestination.search),
                                      onLibrary: () =>
                                          _show(MusicDestination.library)),
                                  MusicDestination.search =>
                                    MusicScreen(key: _search, embedded: true),
                                  MusicDestination.library =>
                                    const MusicLibraryPage(),
                                },
                              ),
                          ],
                        ))),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _musicBody({required MiniPlayerDock? dock, required Widget child}) {
    if (dock == null) return child;
    return MiniPlayerInset(
        enabled: dock.active && !dock.miniSuppressed, child: child);
  }
}

class _RetainedMusicPage extends StatefulWidget {
  final bool active;
  final Widget child;

  const _RetainedMusicPage(
      {super.key, required this.active, required this.child});

  @override
  State<_RetainedMusicPage> createState() => _RetainedMusicPageState();
}

class _RetainedMusicPageState extends State<_RetainedMusicPage>
    with AutomaticKeepAliveClientMixin {
  final _verticalPanes = <ScrollableState>{};

  @override
  bool get wantKeepAlive => true;

  bool _rememberScroll(ScrollMetrics metrics, int depth, BuildContext? source) {
    if (depth == 0 &&
        metrics.axis == Axis.vertical &&
        source?.mounted == true) {
      _verticalPanes.removeWhere((pane) => !pane.mounted);
      final pane = Scrollable.maybeOf(source!, axis: Axis.vertical);
      if (pane != null) _verticalPanes.add(pane);
    }
    return false;
  }

  void scrollToTop() {
    if (!widget.active) return;
    _verticalPanes.removeWhere((pane) => !pane.mounted);
    final duration = AppMotion.duration(context);
    // Compact Search can have independent scrollable controls and results.
    // Each page records its own top-level panes, apart from nested shelves.
    for (final pane in _verticalPanes.toList()) {
      final position = pane.position;
      if (position.context.notificationContext?.mounted != true ||
          !TickerMode.of(pane.context) ||
          !position.hasPixels ||
          !position.hasContentDimensions ||
          !position.hasViewportDimension ||
          position.viewportDimension <= 0 ||
          position.pixels <= position.minScrollExtent) {
        continue;
      }
      if (duration == Duration.zero) {
        position.jumpTo(position.minScrollExtent);
      } else {
        unawaited(position.animateTo(position.minScrollExtent,
            duration: duration, curve: Curves.easeInOutQuad));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return TickerMode(
      enabled: widget.active,
      child: ExcludeFocus(
        excluding: !widget.active,
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: (notification) => _rememberScroll(
              notification.metrics, notification.depth, notification.context),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) => _rememberScroll(
                notification.metrics, notification.depth, notification.context),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
