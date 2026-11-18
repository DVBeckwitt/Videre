import 'package:clipious/utils/motion.dart';
import 'package:auto_route/auto_route.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:back_button_interceptor/back_button_interceptor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/views/components/download_app_bar_button.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/views/components/profile_picker.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/views/components/app_icon.dart';
import 'package:logging/logging.dart';

import '../../../notifications/notifications.dart';
import '../../models/phone_navigation.dart';
import '../../../music/views/screens/music_mode.dart';

enum _HomeUtility { profiles, subscriptions }

var log = Logger('Home Screen');

@RoutePage()
class MainContentScreen extends StatefulWidget {
  const MainContentScreen({super.key});

  @override
  State<MainContentScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainContentScreen> {
  TabsRouter? _initializedTabsRouter;
  HomeDataSource? _activePage;
  bool? _musicSelected;
  Object? _sessionKey;
  bool _musicVisited = false;
  bool _videoVisited = false;
  PageStorageBucket _videoStorage = PageStorageBucket();

  void _openItem(BuildContext context, PhoneNavigationItem item) {
    final router = AutoRouter.of(context);
    switch (item) {
      case PhoneNavigationItem.search:
        router.push(SearchRoute());
      case PhoneNavigationItem.downloads:
        router.push(const DownloadManagerRoute());
      case PhoneNavigationItem.queue:
        router.push(const VideoQueueRoute());
      case PhoneNavigationItem.music:
        Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (context) => MusicModeScreen(appBar: _musicAppBar(context)),
        ));
      case PhoneNavigationItem.playlist:
        router.push(const PlaylistLibraryRoute());
      default:
        router.push(NavigationSectionRoute(source: item.source!));
    }
  }

  List<Widget> _topActions(BuildContext context, PhoneNavigation navigation,
      {bool compact = false, HomeDataSource? selectedPage}) {
    final locals = AppLocalizations.of(context)!;
    final maxVisible = compact
        ? (MediaQuery.textScalerOf(context).scale(14) > 23 ? 0 : 1)
        : (navigation.top.length > 3 ? 2 : navigation.top.length);
    final visible = navigation.top.take(maxVisible);
    final hidden = navigation.top.skip(maxVisible);
    return [
      for (final item in visible)
        item == PhoneNavigationItem.downloads
            ? const AppBarDownloadButton()
            : IconButton(
                tooltip: item.label(locals),
                icon: Icon(item.icon),
                onPressed: () => _openItem(context, item)),
      if (hidden.isNotEmpty || compact)
        PopupMenuButton<Object>(
          tooltip: locals.phoneNavigationMore,
          onSelected: (item) {
            if (item is PhoneNavigationItem) {
              _openItem(context, item);
            } else if (item == _HomeUtility.profiles) {
              showProfilePicker(context);
            } else if (item == _HomeUtility.subscriptions) {
              openSubscriptionManagement(context);
            }
          },
          itemBuilder: (_) => [
            for (final item in hidden)
              PopupMenuItem(
                  value: item,
                  child: Row(children: [
                    Icon(item.icon),
                    const SizedBox(width: 12),
                    Expanded(child: Text(item.label(locals)))
                  ])),
            if (compact) ...[
              if (hidden.isNotEmpty) const PopupMenuDivider(),
              PopupMenuItem(
                  value: _HomeUtility.profiles, child: Text(locals.profiles)),
              if (selectedPage == HomeDataSource.subscription)
                PopupMenuItem(
                    value: _HomeUtility.subscriptions,
                    child: Text(locals.manageSubscriptions)),
            ],
          ],
        ),
    ];
  }

  void _initializeStartupTab(TabsRouter router, int index) {
    if (identical(_initializedTabsRouter, router)) return;
    _initializedTabsRouter = router;
    // homeIndex controls Back navigation, not the initially selected tab.
    // Keep an explicit incoming tab route ahead of the saved startup choice.
    if (index == 0 || router.activeIndex != 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          identical(_initializedTabsRouter, router) &&
          router.activeIndex == 0 &&
          index < router.pageCount) {
        router.setActiveIndex(index);
      }
    });
  }

  void _setVideoRouterActive(TabsRouter router, bool active) {
    final parent = router.parent<RoutingController>();
    if (parent == null) return;
    final attached = parent.childControllers.contains(router);
    // TabsRouter handles Back by selecting homeIndex before consulting the
    // enclosing route's PopScopes. Let Music's detail pages handle Back first,
    // while retaining the pager and all tab controllers for swiping back out.
    if (active && !attached) {
      parent.attachChildController(router);
    } else if (!active && attached) {
      parent.removeChildController(router);
    }
  }

  void openSettings(BuildContext context) {
    AutoRouter.of(context).push(const SettingsRoute());
  }

  void openSubscriptionManagement(BuildContext context) {
    AutoRouter.of(context).push(const ManageSubscriptionsRoute());
  }

  AppBar _musicAppBar(BuildContext context,
      {bool showSearch = true, VoidCallback? onSearch}) {
    final locals = AppLocalizations.of(context)!;
    return AppBar(
      titleSpacing: 16,
      title: Text(locals.music),
      actions: [
        if (showSearch)
          Builder(
              builder: (context) => IconButton(
                  tooltip: locals.search,
                  onPressed:
                      onSearch ?? () => MusicModeScreen.openSearch(context),
                  icon: const Icon(Icons.search))),
        IconButton(
            tooltip: locals.settings,
            onPressed: () => openSettings(context),
            icon: const Icon(Icons.settings)),
      ],
    );
  }

  PhoneNavigationItem _itemFor(HomeDataSource page) =>
      PhoneNavigationItem.values.firstWhere((item) => item.source == page);

  Widget _phoneBar(
      BuildContext context,
      PhoneNavigation navigation,
      PhoneNavigationItem selected,
      ValueChanged<PhoneNavigationItem> onSelect) {
    final locals = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    return NavigationBar(
      height: MediaQuery.textScalerOf(context).scale(12) <= 16 ? 60 : 76,
      indicatorColor: colors.surfaceContainerHighest,
      surfaceTintColor: Colors.transparent,
      animationDuration:
          AppMotion.duration(context, const Duration(milliseconds: 500)),
      onDestinationSelected: (index) => onSelect(navigation.bottom[index]),
      selectedIndex: navigation.bottom.indexOf(selected),
      destinations: [
        for (final item in navigation.bottom)
          NavigationDestination(
              key: ValueKey('main-navigation-${item.name}'),
              icon: Icon(item.icon),
              label: item.label(locals)),
      ],
    );
  }

  Widget _tabletRail(
      BuildContext context,
      List<PhoneNavigationItem> items,
      PhoneNavigationItem selected,
      ValueChanged<PhoneNavigationItem> onSelect) {
    final locals = AppLocalizations.of(context)!;
    return OrientationBuilder(
      builder: (context, orientation) => NavigationRail(
        extended: orientation == Orientation.landscape,
        selectedIndex: items.indexOf(selected),
        onDestinationSelected: (index) => onSelect(items[index]),
        destinations: [
          for (final item in items)
            NavigationRailDestination(
                icon: Icon(item.icon), label: Text(item.label(locals))),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();

    // Only after at least the action method is set, the notification events are delivered
    AwesomeNotifications()
        .setListeners(
            onActionReceivedMethod:
                NotificationController.onActionReceivedMethod,
            onNotificationCreatedMethod:
                NotificationController.onNotificationCreatedMethod,
            onNotificationDisplayedMethod:
                NotificationController.onNotificationDisplayedMethod,
            onDismissActionReceivedMethod:
                NotificationController.onDismissActionReceivedMethod)
        .then(
      (value) {
        AwesomeNotifications()
            .getInitialNotificationAction()
            .then((initialNotification) {
          log.fine('Initial notification ${initialNotification?.payload}');

          if (initialNotification != null) {
            NotificationController.onActionReceivedMethod(initialNotification);
          }
        });
      },
    );
  }

  @override
  void dispose() {
    BackButtonInterceptor.removeByName('mainNavigator');
    super.dispose();
  }

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    var locals = AppLocalizations.of(context)!;

    return BlocBuilder<AppCubit, AppState>(buildWhen: (previous, current) {
      return previous.server != current.server ||
          previous.profileId != current.profileId ||
          previous.sessionRevision != current.sessionRevision;
    }, builder: (context, appState) {
      var app = context.read<AppCubit>();
      var settings = context.watch<SettingsCubit>().state;

      final deviceType = getDeviceType();
      final phone = deviceType == DeviceType.phone;
      final tablet = deviceType == DeviceType.tablet;
      final sessionKey =
          (appState.profileId, appState.sessionRevision, appState.server?.url);
      if (_sessionKey != sessionKey) {
        _sessionKey = sessionKey;
        _activePage = null;
        _initializedTabsRouter = null;
        _musicSelected = null;
        _musicVisited = false;
        _videoVisited = false;
        _videoStorage = PageStorageBucket();
      }
      final phoneNavigation = (settings.savedPhoneNavigation ??
              PhoneNavigation.fromLegacy(
                  settings.appLayout, appState.firstIndex))
          .available(searchHistory: settings.useSearchHistory);
      final configuredPages = settings.appLayout
          .where((element) =>
              element.isPermitted(context, app.isLoggedIn) &&
              element.route != null)
          .toList();
      final initialPage = phone
          ? phoneNavigation.startup.source
          : settings.appLayout.elementAtOrNull(appState.firstIndex);
      final allowedPages = phone
          ? phoneNavigation.bottom
              .where((item) => item.isTab && item.source != null)
              .map((item) => item.source!)
              .toList()
          : configuredPages;
      final tabletItems = [
        for (final page in allowedPages) _itemFor(page),
        if (tablet) PhoneNavigationItem.music,
      ];
      final tabItems = phone
          ? phoneNavigation.bottom.where((item) => item.isTab).toList()
          : allowedPages.map(_itemFor).toList();

      final hasMusicTab = phone
          ? phoneNavigation.bottom.contains(PhoneNavigationItem.music)
          : tablet && tabletItems.length > 1;
      if (!hasMusicTab) _musicSelected = false;
      _musicSelected ??=
          phone && phoneNavigation.startup == PhoneNavigationItem.music;
      final phoneMusicTab = phone && hasMusicTab;
      final musicTabSelected =
          hasMusicTab && !phoneMusicTab && _musicSelected == true;
      final music = musicTabSelected;
      if (music) {
        _musicVisited = true;
      } else {
        _videoVisited = true;
      }

      final selectedItem = phoneMusicTab && _musicSelected == true
          ? PhoneNavigationItem.music
          : _itemFor(_activePage ?? initialPage ?? HomeDataSource.home);
      var selectedIndex = tabItems.indexOf(selectedItem);
      if (selectedIndex < 0) {
        selectedIndex = 0;
      }

      void select(BuildContext context, PhoneNavigationItem item) {
        if (phone) {
          final tabs = _initializedTabsRouter;
          if (item == PhoneNavigationItem.search &&
              tabs != null &&
              tabs.current.name == MainMusicRoute.name) {
            MainMusicTab.openSearch(tabs);
            return;
          }
          final index = tabItems.indexOf(item);
          if (index < 0) {
            _openItem(context, item);
          } else {
            _initializedTabsRouter?.setActiveIndex(index);
          }
          return;
        }
        if (item == PhoneNavigationItem.music) {
          if (!musicTabSelected) setState(() => _musicSelected = true);
          return;
        }
        final source = item.source;
        final index = source == null ? -1 : allowedPages.indexOf(source);
        if (index < 0 || (phone && !item.isTab)) {
          _openItem(context, item);
          return;
        }
        if (musicTabSelected) {
          setState(() {
            _activePage = allowedPages[index];
            _musicSelected = false;
          });
        }
        final router = _initializedTabsRouter;
        if (router != null && index < router.pageCount) {
          router.setActiveIndex(index);
        }
      }

      final video = !_videoVisited
          ? const SizedBox.shrink()
          : tabItems.isEmpty
              ? Scaffold(
                  appBar: AppBar(
                    title: Text(locals.videos),
                    actions: [
                      if (tablet)
                        IconButton(
                          tooltip: locals.music,
                          onPressed: () =>
                              _openItem(context, PhoneNavigationItem.music),
                          icon: const Icon(Icons.music_note),
                        ),
                      IconButton(
                        tooltip: locals.settings,
                        onPressed: () => openSettings(context),
                        icon: const Icon(Icons.settings),
                      ),
                    ],
                  ),
                  body: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Center(child: AppIcon(width: 150, height: 150)),
                      FilledButton.tonalIcon(
                          onPressed: () => openSettings(context),
                          icon: const Icon(Icons.settings),
                          label: Text(locals.settings))
                    ],
                  ),
                )
              : AutoTabsRouter.tabBar(
                  animatePageTransition: AppMotion.allowsMovement(context),
                  key: ValueKey((
                    sessionKey,
                    deviceType,
                    tabItems.map((item) => item.name).join(',')
                  )),
                  homeIndex: selectedIndex,
                  routes: tabItems
                      .map((item) => item == PhoneNavigationItem.music
                          ? const MainMusicRoute()
                          : item.source!.route!)
                      .toList(),
                  physics: phone
                      ? const BouncingScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics())
                      : const NeverScrollableScrollPhysics(),
                  builder: (context, child, controller) {
                    final tabsRouter = AutoTabsRouter.of(context);
                    _initializeStartupTab(tabsRouter, selectedIndex);
                    final selectedItem = tabItems[tabsRouter.activeIndex];
                    _setVideoRouterActive(tabsRouter,
                        !music && selectedItem != PhoneNavigationItem.music);
                    final selectedPage = selectedItem.source;
                    if (selectedPage != null) _activePage = selectedPage;
                    if (phone) {
                      _musicSelected =
                          selectedItem == PhoneNavigationItem.music;
                    }
                    return Scaffold(
                      backgroundColor: colorScheme.surface,
                      bottomNavigationBar: phone
                          ? _phoneBar(context, phoneNavigation, selectedItem,
                              (item) => select(context, item))
                          : null,
                      appBar: selectedItem == PhoneNavigationItem.music
                          ? _musicAppBar(context,
                              showSearch: phoneNavigation.top
                                  .contains(PhoneNavigationItem.search),
                              onSearch: () =>
                                  MainMusicTab.openSearch(tabsRouter))
                          : AppBar(
                              title: Text(selectedPage!.getLabel(locals),
                                  overflow: TextOverflow.ellipsis),
                              actions: [
                                if (!phone)
                                  IconButton(
                                    tooltip: locals.profiles,
                                    onPressed: () => showProfilePicker(context),
                                    icon: const Icon(
                                        Icons.account_circle_outlined),
                                  ),
                                if (selectedPage ==
                                        HomeDataSource.subscription &&
                                    !phone)
                                  IconButton(
                                    tooltip: locals.manageSubscriptions,
                                    onPressed: () =>
                                        openSubscriptionManagement(context),
                                    icon: const Icon(Icons.checklist),
                                  ),
                                if (phone)
                                  ..._topActions(context, phoneNavigation,
                                      compact: true, selectedPage: selectedPage)
                                else ...[
                                  const AppBarDownloadButton(),
                                  IconButton(
                                    tooltip: locals.search,
                                    onPressed: () => _openItem(
                                        context, PhoneNavigationItem.search),
                                    icon: const Icon(Icons.search),
                                  ),
                                ],
                                IconButton(
                                  tooltip: locals.settings,
                                  onPressed: () => openSettings(context),
                                  icon: const Icon(Icons.settings),
                                ),
                              ],
                            ),
                      body: Row(
                        children: [
                          if (tablet && tabletItems.length >= 2)
                            _tabletRail(context, tabletItems, selectedItem,
                                (item) => select(context, item)),
                          Expanded(
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                  horizontal:
                                      selectedPage == HomeDataSource.home ||
                                              selectedItem ==
                                                  PhoneNavigationItem.music
                                          ? 0
                                          : innerHorizontalPadding),
                              child: child,
                            ),
                          ),
                        ],
                      ),
                    );
                  });

      return IndexedStack(index: music ? 1 : 0, children: [
        TickerMode(
            enabled: !music,
            child: ExcludeFocus(
                excluding: music,
                child: PageStorage(bucket: _videoStorage, child: video))),
        TickerMode(
            enabled: music,
            child: ExcludeFocus(
                excluding: !music,
                child: _musicVisited && !phoneMusicTab
                    ? MusicModeScreen(
                        key: ValueKey(sessionKey),
                        appBar: _musicAppBar(context, showSearch: !hasMusicTab),
                        mainNavigationBar: hasMusicTab && phone
                            ? _phoneBar(
                                context,
                                phoneNavigation,
                                PhoneNavigationItem.music,
                                (item) => select(context, item))
                            : null,
                        mainNavigationRail: hasMusicTab && tablet
                            ? _tabletRail(
                                context,
                                tabletItems,
                                PhoneNavigationItem.music,
                                (item) => select(context, item))
                            : null,
                      )
                    : const SizedBox.shrink())),
      ]);
    });
  }
}
