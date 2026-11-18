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
        child: const MusicModeScreen(appBar: null, inMainPager: true),
      ),
    );
  }
}

class MusicModeScreen extends StatefulWidget {
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
  int _page = 0;

  void _show(int page) {
    if (page == _page) return;
    if (AppMotion.allowsMovement(context)) {
      _pages.animateToPage(page,
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    } else {
      _pages.jumpToPage(page);
    }
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
                  onDestinationSelected: _show,
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
                    onPageChanged: (page) => setState(() => _page = page),
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
                          child: const MusicScreen(embedded: true)),
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
