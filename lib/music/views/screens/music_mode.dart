import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../router.dart';
import '../../../settings/states/settings.dart';
import '../../../utils.dart';
import '../../../utils/motion.dart';
import '../../models/music_layout.dart';
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

class MusicModeScreen extends StatefulWidget {
  static void openSearch(BuildContext context) =>
      context.findAncestorStateOfType<_MusicModeScreenState>()?._openSearch();

  final PreferredSizeWidget? appBar;
  final Widget? mainNavigationBar;
  final Widget? mainNavigationRail;
  final bool inMainPager;

  const MusicModeScreen({
    super.key,
    required this.appBar,
    this.mainNavigationBar,
    this.mainNavigationRail,
    this.inMainPager = false,
  });

  @override
  State<MusicModeScreen> createState() => _MusicModeScreenState();
}

class _MusicModeScreenState extends State<MusicModeScreen> {
  late List<MusicDestination> _order;
  late final PageController _pages;
  final _storage = PageStorageBucket();
  final _search = GlobalKey<MusicScreenState>();
  MusicDestination _page = MusicDestination.home;
  Object? _pendingSearchFocus;

  @override
  void initState() {
    super.initState();
    _order = context.read<SettingsCubit>().state.musicLayout.destinations;
    _pages =
        PageController(initialPage: _order.indexOf(_page), keepPage: false);
  }

  void _applyOrder(List<MusicDestination> order) {
    _pendingSearchFocus = null;
    setState(() => _order = order);
    _pages.jumpToPage(order.indexOf(_page));
  }

  void _openSearch() => _show(MusicDestination.search, focusSearch: true);

  void _select(MusicDestination page) {
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

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final phone = getDeviceType() == DeviceType.phone;
    final embedded = widget.inMainPager ||
        widget.mainNavigationBar != null ||
        widget.mainNavigationRail != null;
    final colors = Theme.of(context).colorScheme;
    return BlocListener<SettingsCubit, SettingsState>(
      listenWhen: (before, after) => !listEquals(
          before.musicLayout.destinations, after.musicLayout.destinations),
      listener: (_, state) => _applyOrder(state.musicLayout.destinations),
      child: Scaffold(
        appBar: widget.appBar,
        bottomNavigationBar: widget.mainNavigationBar ??
            (phone && !widget.inMainPager
                ? NavigationBar(
                    height: MediaQuery.textScalerOf(context).scale(12) <= 16
                        ? 60
                        : 76,
                    backgroundColor: colors.surfaceContainer,
                    surfaceTintColor: Colors.transparent,
                    indicatorColor: colors.surfaceContainerHighest,
                    selectedIndex: _order.indexOf(_page),
                    onDestinationSelected: (index) => _select(_order[index]),
                    destinations: [
                      for (final destination in _order)
                        NavigationDestination(
                            icon: Icon(destination.icon),
                            label: destination.label(locals)),
                    ],
                  )
                : null),
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
              if (embedded)
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
                child: PageStorage(
                    bucket: _storage,
                    child: PageView(
                      key: const PageStorageKey('music-mode-pages'),
                      controller: _pages,
                      // In the primary phone pager, horizontal page gestures
                      // follow the configured bottom tabs. Chips still select
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
                            key: ValueKey(destination),
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
                    )),
              ),
            ]),
          ),
        ]),
      ),
    );
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
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return TickerMode(
      enabled: widget.active,
      child: ExcludeFocus(excluding: !widget.active, child: widget.child),
    );
  }
}
