import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../utils.dart';
import '../../../utils/motion.dart';
import 'music_discovery.dart';
import 'music_library.dart';

class MusicModeScreen extends StatefulWidget {
  final PreferredSizeWidget appBar;

  const MusicModeScreen({super.key, required this.appBar});

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
    final labels = [locals.home, locals.musicExplore, locals.musicLibrary];
    const icons = [
      Icons.home_outlined,
      Icons.explore_outlined,
      Icons.library_music_outlined
    ];
    return Scaffold(
      appBar: widget.appBar,
      bottomNavigationBar: phone
          ? NavigationBar(
              selectedIndex: _page,
              onDestinationSelected: _show,
              destinations: [
                for (var i = 0; i < labels.length; i++)
                  NavigationDestination(icon: Icon(icons[i]), label: labels[i]),
              ],
            )
          : null,
      body: Row(children: [
        if (!phone)
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
          child: PageStorage(
              bucket: _storage,
              child: PageView(
                key: const PageStorageKey('music-mode-pages'),
                controller: _pages,
                onPageChanged: (page) => setState(() => _page = page),
                children: [
                  _RetainedMusicPage(
                    active: _page == 0,
                    child: MusicHomePage(
                        onExplore: () => _show(1), onLibrary: () => _show(2)),
                  ),
                  _RetainedMusicPage(
                      active: _page == 1, child: const MusicExplorePage()),
                  _RetainedMusicPage(
                      active: _page == 2, child: const MusicLibraryPage()),
                ],
              )),
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
