import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../router.dart';
import '../../../utils.dart';
import '../../../utils/motion.dart';
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
  final _pages = PageController();
  final _storage = PageStorageBucket();
  final _search = GlobalKey<MusicScreenState>();
  int _page = 0;
  Object? _pendingSearchFocus;

  void _openSearch() => _show(1, focusSearch: true);

  Future<void> _show(int page, {bool focusSearch = false}) async {
    if (focusSearch && _pendingSearchFocus != null) return;
    final request = focusSearch ? Object() : null;
    _pendingSearchFocus = request;
    final from = _page;
    if (page != from || _pages.position.isScrollingNotifier.value) {
      if (AppMotion.allowsMovement(context)) {
        await _pages.animateToPage(page,
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      } else {
        _pages.jumpToPage(page);
      }
    }
    if (request == null) return;
    // The retained search field can take focus after the page has been laid out.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _pendingSearchFocus != request) return;
    _pendingSearchFocus = null;
    if (_page == 1 && TickerMode.of(context)) {
      _search.currentState
          ?.focusSearch(onBack: from == 1 ? null : () => _show(from));
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
    final labels = [locals.home, locals.search, locals.musicLibrary];
    const icons = [
      Icons.home_outlined,
      Icons.search,
      Icons.library_music_outlined
    ];
    return Scaffold(
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
                  selectedIndex: _page,
                  onDestinationSelected: (page) =>
                      page == 1 ? _openSearch() : _show(page),
                  destinations: [
                    for (var i = 0; i < labels.length; i++)
                      NavigationDestination(
                          icon: Icon(icons[i]), label: labels[i]),
                  ],
                )
              : null),
      body: Row(children: [
        if (widget.mainNavigationRail != null)
          widget.mainNavigationRail!
        else if (!phone && !widget.inMainPager)
          NavigationRail(
            selectedIndex: _page,
            onDestinationSelected: _show,
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (var i = 0; i < labels.length; i++)
                NavigationRailDestination(
                    icon: Icon(icons[i]), label: Text(labels[i])),
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
                    for (var i = 0; i < labels.length; i++)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 8),
                        child: ChoiceChip(
                          key: ValueKey('music-section-$i'),
                          label: Text(labels[i]),
                          selected: i == _page,
                          onSelected: (_) => _show(i),
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
                    onPageChanged: (page) {
                      if (page != 1) _search.currentState?.leaveSearch();
                      setState(() => _page = page);
                    },
                    children: [
                      _RetainedMusicPage(
                        active: _page == 0,
                        child: MusicHomePage(
                            showSearchShortcut: false,
                            onSearch: () => _show(1),
                            onLibrary: () => _show(2)),
                      ),
                      _RetainedMusicPage(
                          active: _page == 1,
                          child: MusicScreen(key: _search, embedded: true)),
                      _RetainedMusicPage(
                          active: _page == 2, child: const MusicLibraryPage()),
                    ],
                  )),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _RetainedMusicPage extends StatefulWidget {
  final bool active;
  final Widget child;

  const _RetainedMusicPage({required this.active, required this.child});

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
