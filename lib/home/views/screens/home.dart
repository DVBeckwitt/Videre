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
  String? _serverUrl;

  void _openItem(BuildContext context, PhoneNavigationItem item) {
    final router = AutoRouter.of(context);
    switch (item) {
      case PhoneNavigationItem.search:
        router.push(SearchRoute());
      case PhoneNavigationItem.downloads:
        router.push(const DownloadManagerRoute());
      case PhoneNavigationItem.queue:
        router.push(const VideoQueueRoute());
      case PhoneNavigationItem.playlist:
        router.push(const PlaylistLibraryRoute());
      default:
        router.push(NavigationSectionRoute(source: item.source!));
    }
  }

  List<Widget> _topActions(BuildContext context, PhoneNavigation navigation) {
    final locals = AppLocalizations.of(context)!;
    final visible =
        navigation.top.length > 3 ? navigation.top.take(2) : navigation.top;
    return [
      for (final item in visible)
        item == PhoneNavigationItem.downloads
            ? const AppBarDownloadButton()
            : IconButton(
                tooltip: item.label(locals),
                icon: Icon(item.icon),
                onPressed: () => _openItem(context, item)),
      if (navigation.top.length > 3)
        PopupMenuButton<PhoneNavigationItem>(
          tooltip: locals.phoneNavigationMore,
          onSelected: (item) => _openItem(context, item),
          itemBuilder: (_) => [
            for (final item in navigation.top.skip(2))
              PopupMenuItem(
                  value: item,
                  child: Row(children: [
                    Icon(item.icon),
                    const SizedBox(width: 12),
                    Expanded(child: Text(item.label(locals)))
                  ]))
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

  void openSettings(BuildContext context) {
    AutoRouter.of(context).push(const SettingsRoute());
  }

  void openSubscriptionManagement(BuildContext context) {
    AutoRouter.of(context).push(const ManageSubscriptionsRoute());
  }

  void openLayoutEditor(BuildContext context) {
    var app = context.read<AppCubit>();
    AutoRouter.of(context)
        .push(const EditHomeLayoutRoute())
        .then((value) => app.updateLayout());
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
      return previous.server != current.server;
    }, builder: (context, appState) {
      var app = context.read<AppCubit>();
      var settings = context.watch<SettingsCubit>().state;

      final deviceType = getDeviceType();
      if (_serverUrl != appState.server?.url) {
        _serverUrl = appState.server?.url;
        _activePage = null;
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
      final initialPage = deviceType == DeviceType.phone
          ? phoneNavigation.startup.source
          : settings.appLayout.elementAtOrNull(appState.firstIndex);
      final allowedPages = deviceType == DeviceType.phone
          ? phoneNavigation.bottom
              .where((item) => item.isTab)
              .map((item) => item.source!)
              .toList()
          : configuredPages;

      var selectedIndex = allowedPages
          .indexOf(_activePage ?? initialPage ?? HomeDataSource.home);
      if (selectedIndex < 0) {
        selectedIndex = 0;
      }

      return allowedPages.isEmpty
          ? Scaffold(
              body: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Center(
                      child: AppIcon(
                    width: 150,
                    height: 150,
                  )),
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
                appState.server?.url,
                deviceType,
                allowedPages.map((page) => page.name).join(',')
              )),
              homeIndex: selectedIndex,
              routes: allowedPages.map((e) => e.route!).toList(),
              physics: deviceType == DeviceType.phone
                  ? const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics())
                  : const NeverScrollableScrollPhysics(),
              builder: (context, child, controller) {
                final tabsRouter = AutoTabsRouter.of(context);
                _initializeStartupTab(tabsRouter, selectedIndex);
                final selectedPage = allowedPages[tabsRouter.activeIndex];
                _activePage = selectedPage;
                return Scaffold(
                    // so we rebuild the view if the server changes
                    backgroundColor: colorScheme.surface,
                    bottomNavigationBar: deviceType == DeviceType.phone
                        ? NavigationBar(
                            animationDuration: AppMotion.duration(
                                context, const Duration(milliseconds: 500)),
                            onDestinationSelected: (index) {
                              final item = phoneNavigation.bottom[index];
                              if (item.isTab) {
                                tabsRouter.setActiveIndex(
                                    allowedPages.indexOf(item.source!));
                              } else {
                                _openItem(context, item);
                              }
                            },
                            selectedIndex: phoneNavigation.bottom.indexWhere(
                                (item) => item.source == selectedPage),
                            destinations: [
                              for (final item in phoneNavigation.bottom)
                                NavigationDestination(
                                    icon: Icon(item.icon),
                                    label: item.label(locals)),
                            ],
                          )
                        : null,
                    appBar: AppBar(
                      title: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                              child: Text(
                            selectedPage.getLabel(locals),
                            overflow: TextOverflow.ellipsis,
                          )),
                          if (selectedPage == HomeDataSource.home)
                            IconButton(
                                iconSize: 15,
                                onPressed: () => openLayoutEditor(context),
                                icon: Icon(
                                  Icons.edit,
                                  color: colorScheme.secondary,
                                ))
                        ],
                      ),
                      actions: [
                        IconButton(
                          tooltip: locals.profiles,
                          onPressed: () => showProfilePicker(context),
                          icon: const Icon(Icons.account_circle_outlined),
                        ),
                        selectedPage == HomeDataSource.subscription
                            ? IconButton(
                                onPressed: () =>
                                    openSubscriptionManagement(context),
                                icon: const Icon(Icons.checklist))
                            : const SizedBox.shrink(),
                        if (deviceType == DeviceType.phone)
                          ..._topActions(context, phoneNavigation)
                        else ...[
                          const AppBarDownloadButton(),
                          IconButton(
                            onPressed: () {
                              AutoRouter.of(context).push(SearchRoute());
                            },
                            icon: const Icon(Icons.search),
                          ),
                        ],
                        IconButton(
                          onPressed: () => openSettings(context),
                          icon: const Icon(Icons.settings),
                        ),
                      ],
                    ),
                    body: Row(
                      children: [
                        if (deviceType == DeviceType.tablet &&
                            allowedPages.length > 2)
                          OrientationBuilder(
                            builder: (context, orientation) => NavigationRail(
                                extended:
                                    getOrientation() == Orientation.landscape,
                                onDestinationSelected:
                                    tabsRouter.setActiveIndex,
                                destinations: allowedPages
                                    .map((e) =>
                                        e.getNavigationRailWidget(context))
                                    .toList(),
                                selectedIndex: tabsRouter.activeIndex),
                          ),
                        Expanded(
                          child: Container(
                              // home handles its own padding because we don't want to cut horizontal scroll lists on the right
                              padding: EdgeInsets.symmetric(
                                  horizontal:
                                      selectedPage == HomeDataSource.home
                                          ? 0
                                          : innerHorizontalPadding),
                              child: child),
                        ),
                      ],
                    ));
              });
    });
  }
}
