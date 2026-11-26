import 'package:clipious/utils/motion.dart';
import 'package:clipious/app/views/components/session_focus_guard.dart';
import 'package:clipious/utils/motion_binding.dart';
import 'dart:async';
import 'dart:io';
import 'music/services/local_music_library.dart';
import 'music/views/screens/music.dart';
import 'content_filter/community_filter.dart';
import 'network/network_proxy.dart';
import 'package:videre_recommendations/videre_recommendations.dart';
import 'package:clipious/utils/upstream_licenses.dart';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:clipious/l10n/app_languages.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/http_overrides.dart';
import 'package:clipious/media_handler.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/notifications/notifications.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/podcasts/services/podcast_downloads.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/workmanager.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'settings/models/db/app_logs.dart';
import 'settings/models/db/server.dart';
import 'settings/models/theme_palette.dart';
import 'feedback/views/feedback_screenshot.dart';
import 'music/views/components/music_screen_privacy.dart';

final scaffoldKey = GlobalKey<ScaffoldMessengerState>();
bool isTv = false;

late MediaHandler mediaHandler;

final Logger log = Logger('main');

Future<void> main() async {
  Logger.root.level =
      kDebugMode ? Level.FINEST : Level.INFO; // defaults to Level.INFO
  Logger.root.onRecord.listen((record) async {
    debugPrint(
        '[${record.level.name}] [${record.loggerName}] ${record.message}');
    // we don't want debug
    if (record.level == Level.INFO || record.level == Level.SEVERE) {
      await db.insertLogs(AppLog(
          logger: record.loggerName,
          level: record.level.name,
          time: record.time,
          message: record.message,
          stacktrace: record.stackTrace?.toString()));
    }
  });

  HttpOverrides.global = MyHttpOverrides();

  VidereWidgetsBinding();
  VidereRecommendations.registerLicenses();
  registerUpstreamUiLicenses();

  packageInfo = await PackageInfo.fromPlatform();

  // FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);
  db = await SembastSqfDb.create();
  await fileDb.syncWithDb();
  await NetworkProxy.instance.initialize();
  unawaited(communityFilters.reloadForProfile());

  Server? selectedServer;
  try {
    selectedServer = await db.getCurrentlySelectedServer();
  } catch (_) {
    // The ordinary welcome flow also handles profiles with no server.
  }
  final hasServer = selectedServer != null;
  final hasActivity = await MediaHandler.hasMediaActivity();
  if (hasServer && hasActivity) {
    await service.validateCurrentSessionSafely();
    selectedServer = await db.getCurrentlySelectedServer();
  }
  // Resolve the interface before constructing its route table.
  isTv = await isDeviceTv();
  appRouter = AppRouter(hasServer: hasServer);
  initializeNotifications();

  // Start the shared controller with the engine. Android can ask the media
  // session to play while there is no Activity to build the provider tree.
  final app = AppCubit(
      AppState(0, selectedServer, db.getHomeLayout(), profileId: db.profileId),
      onResume: () => unawaited(communityFilters.refreshIfStale()));
  final settings = SettingsCubit(SettingsState.init(), app);
  final player = PlayerCubit(PlayerState.init(null), settings,
      ownAudioDecoder:
          !kIsWeb && defaultTargetPlatform == TargetPlatform.android && !isTv);
  final downloads = DownloadManagerCubit(const DownloadManagerState(), player);

  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(configureBackgroundService(settings));
    if (!hasActivity && hasServer) {
      unawaited(service.validateCurrentSessionSafely());
    }
    unawaited(_setHighRefreshRate());
  });
  runApp(VidereFeedbackHost(
    child: MultiBlocProvider(providers: [
      BlocProvider.value(value: app),
      BlocProvider.value(value: settings),
      BlocProvider.value(value: player),
      BlocProvider.value(value: downloads),
    ], child: const MyApp()),
  ));
}

Future<void> _setHighRefreshRate() async {
  try {
    await FlutterDisplayMode.setHighRefreshRate();
  } catch (error) {
    log.severe('Failed to set high refresh mode', error);
  }
}

late ColorScheme darkColorScheme;

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  Route<void>? _openedAudioPage;
  VoidCallback? _retireOpenedAudio;

  Future<void> _openAudio(
      PlayerCubit player, Uri uri, bool Function() isCurrent) async {
    final file = await LocalMusicLibrary.instance
        .resolveOpenedAudio(uri, isCurrent: isCurrent);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !isCurrent() || player.isClosed) return;
    final navigator = appRouter.navigatorKey.currentState;
    if (navigator == null) return;
    if (file == null) {
      final context = navigator.context;
      if (!context.mounted) return;
      scaffoldKey.currentState?.showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context)!.musicSourceUnavailable)));
      return;
    }
    final hasPlayerSurface = !isTv &&
        appRouter.hasEntries &&
        appRouter.current.name == MainRoute.name;
    if (!hasPlayerSurface && _openedAudioPage?.isActive != true) {
      final page = MaterialPageRoute<void>(
          builder: (_) => OpenedAudioPlaybackPage(television: isTv));
      _openedAudioPage = page;
      unawaited(navigator.push(page).then((_) {
        if (!identical(_openedAudioPage, page)) return;
        _openedAudioPage = null;
        final retire = _retireOpenedAudio;
        _retireOpenedAudio = null;
        retire?.call();
      }));
    }
    final page = _openedAudioPage;
    if (page?.isActive != true) {
      await player.playOpenedAudio(file, isCurrent: isCurrent);
      return;
    }
    bool ownsPage() => identical(_openedAudioPage, page) && page!.isActive;
    final retire = await player.playOpenedAudio(file,
        isCurrent: () => isCurrent() && ownsPage());
    if (retire == null) return;
    if (ownsPage()) {
      _retireOpenedAudio = retire;
    } else {
      retire();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppCubit>();
    final player = context.read<PlayerCubit>();
    final downloads = context.read<DownloadManagerCubit>();
    final settings = context.read<SettingsCubit>();
    player.saveMusicHomeWidgetSong = (entry, isCurrent) {
      // The widget's Activity can be resuming a retained playback engine.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final context = appRouter.navigatorKey.currentState?.overlay?.context;
        if (context != null && context.mounted && isCurrent()) {
          unawaited(MusicLibraryActions.savePlayingSong(context, entry,
              isCurrent: isCurrent));
        }
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    };
    MusicPlaylistSaveNotification.onOpen = player.musicMediaSave.open;
    MusicPlaylistSaveNotification.onDismiss = player.musicMediaSave.dismiss;
    app.bindOpenedAudio((uri, current) => _openAudio(player, uri, current));
    NotificationController.canHandleActions = () =>
        !app.isClosed &&
        !app.state.globalLoading &&
        !app.state.sessionRecoveryRequired;
    app.clearSessionNotifications = () async {
      await AwesomeNotifications().dismissAllNotifications();
    };
    app.beforeAccountSwitch = () async {
      await PodcastDownloads.forProfile(db, db.profileId).cancelAll();
      await downloads.pauseForProfileSwitch();
      await player.prepareForProfileSwitch();
      await AwesomeNotifications().dismissAllNotifications();
    };
    app.afterAccountSwitch = () async {
      unawaited(communityFilters.reloadForProfile());
      await settings.reloadForProfile();
      await player.reloadForProfile();
      await downloads.reloadForProfile();
    };
    app.resetNavigation = (hasServer) async {
      await appRouter.replaceAll(
          isTv
              ? (hasServer
                  ? [const TvHomeRoute()]
                  : [const TvWelcomeWizardRoute()])
              : (hasServer
                  ? [const MainRoute()]
                  : [const WelcomeWizardRoute()]),
          updateExistingRoutes: false);
    };
    return BlocBuilder<AppCubit, AppState>(
        buildWhen: (previous, current) =>
            previous.server != current.server ||
            previous.profileId != current.profileId ||
            previous.sessionRevision != current.sessionRevision ||
            previous.globalLoading != current.globalLoading ||
            previous.sessionRecoveryRequired != current.sessionRecoveryRequired,
        // we want to rebuild only when anything other than the navigation index is changed
        builder: (context, state) {
          final palette =
              context.select((SettingsCubit value) => value.state.themePalette);
          bool useBlackBackground = context
              .select((SettingsCubit value) => value.state.blackBackground);
          String? locale =
              context.select((SettingsCubit value) => value.state.locale);
          final motionPreference = context
              .select((SettingsCubit value) => value.state.motionPreference);
          final musicScreenPrivacy = context
              .select((SettingsCubit value) => value.state.musicScreenPrivacy);
          ThemeMode themeMode =
              context.select((SettingsCubit value) => value.state.themeMode);

          var navigationBarBehavior = context
              .select((SettingsCubit s) => s.state.navigationBarLabelBehavior);

          return DynamicColorBuilder(
              builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
            ColorScheme lightColorScheme;

            if (palette == ThemePalette.dynamicColors &&
                lightDynamic != null &&
                darkDynamic != null) {
              lightColorScheme = lightDynamic.harmonized();
              darkColorScheme = darkDynamic.harmonized();
            } else {
              lightColorScheme = palette.seededScheme(Brightness.light);
              darkColorScheme = palette.seededScheme(Brightness.dark);
            }

            if (useBlackBackground) {
              darkColorScheme = darkColorScheme.copyWith(surface: Colors.black);
            }

            final savedLocale = parseSavedLocale(locale);
            log.fine('Saved locale: $savedLocale');

            var colors = getColorSchemeOutsideOfMaterial(context,
                dark: darkColorScheme, light: lightColorScheme);

            var navigationBarTheme = NavigationBarThemeData(
              elevation: 0,
              backgroundColor: colors.surface,
              labelBehavior: navigationBarBehavior,
            );

            var navigationRailTheme = NavigationRailThemeData(
              elevation: 0,
              backgroundColor: colors.surface,
            );

            var appBarTheme = AppBarTheme(
                backgroundColor: colors.surface,
                elevation: 0,
                scrolledUnderElevation: 0,
                systemOverlayStyle: getUiOverlayStyle(context,
                    dark: darkColorScheme, light: lightColorScheme));

            var sliderTheme =
                const SliderThemeData(inactiveTrackColor: Colors.blue);

            return MaterialApp.router(
              builder: (context, child) => MotionScope(
                  preference: motionPreference,
                  child: Stack(children: [
                    SessionFocusGuard(
                        blocked: state.globalLoading ||
                            state.sessionRecoveryRequired,
                        restoreFocus: isTv,
                        child: MusicScreenPrivacyScope(
                            enabled: musicScreenPrivacy,
                            child: KeyedSubtree(
                                key: ValueKey(state.sessionRevision),
                                child: child!))),
                    if (state.sessionRecoveryRequired)
                      Positioned.fill(
                        child: Material(
                            color: Theme.of(context).colorScheme.surface,
                            child: SafeArea(
                                child: Center(
                                    child: Padding(
                                        padding: const EdgeInsets.all(24),
                                        child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                  AppLocalizations.of(context)!
                                                      .profileRecoveryRequired,
                                                  textAlign: TextAlign.center),
                                              const SizedBox(height: 16),
                                              Shortcuts(
                                                  shortcuts: {
                                                    LogicalKeySet(
                                                            LogicalKeyboardKey
                                                                .select):
                                                        const ActivateIntent(),
                                                  },
                                                  child: FilledButton(
                                                      autofocus: true,
                                                      onPressed:
                                                          state.globalLoading
                                                              ? null
                                                              : () async {
                                                                  try {
                                                                    await app
                                                                        .retrySessionRecovery();
                                                                  } on SessionRecoveryRequired {
                                                                    // The recovery notice remains visible for another retry.
                                                                  }
                                                                },
                                                      child: Text(
                                                          AppLocalizations.of(
                                                                  context)!
                                                              .retry))),
                                            ]))))),
                      ),
                    if (state.globalLoading)
                      const Positioned.fill(
                          child: AbsorbPointer(
                              child: ColoredBox(
                                  color: Color(0x33000000),
                                  child: Center(
                                      child: CircularProgressIndicator())))),
                  ])),
              routerConfig: appRouter.config(
                  navigatorObservers: () => [MyRouteObserver()],
                  includePrefixMatches: true),
              locale: savedLocale,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              localeListResolutionCallback: (locales, supportedLocales) {
                log.info(
                    'device locales=$locales supported locales=$supportedLocales, saved: $savedLocale');
                if (savedLocale != null) {
                  log.info("using saved locale, $savedLocale");
                  return savedLocale;
                }
                if (locales != null) {
                  for (Locale locale in locales) {
                    // if device language is supported by the app,
                    // just return it to set it as current app language
                    if (supportedLocales.contains(locale)) {
                      log.info("Locale match found, $locale");
                      return locale;
                    } else {
                      Locale? match = supportedLocales
                          .where((element) =>
                              element.languageCode == locale.languageCode)
                          .firstOrNull;
                      if (match != null) {
                        log.info("found partial match $locale with $match");
                        return match;
                      }
                    }
                  }
                }
                // if device language is not supported by the app,
                // the app will set it to english but return this to set to Bahasa instead
                log.info("locale not supported, returning english");
                return const Locale('en', 'US');
              },
              supportedLocales: AppLocalizations.supportedLocales,
              scaffoldMessengerKey: scaffoldKey,
              debugShowCheckedModeBanner: false,
              themeMode: ThemeMode.values.firstWhere(
                  (element) => element.name == themeMode.name,
                  orElse: () => ThemeMode.system),
              title: 'Videre',
              theme: ThemeData(
                  useMaterial3: true,
                  colorScheme: lightColorScheme,
                  navigationBarTheme: navigationBarTheme,
                  navigationRailTheme: navigationRailTheme,
                  appBarTheme: appBarTheme,
                  sliderTheme: sliderTheme.copyWith(
                      inactiveTrackColor: lightColorScheme.secondaryContainer),
                  progressIndicatorTheme: ProgressIndicatorThemeData(
                      circularTrackColor: lightColorScheme.secondaryContainer
                          .withValues(alpha: 0.8))),
              darkTheme: ThemeData(
                  useMaterial3: true,
                  colorScheme: darkColorScheme,
                  appBarTheme: appBarTheme,
                  navigationBarTheme: navigationBarTheme,
                  navigationRailTheme: navigationRailTheme,
                  sliderTheme: sliderTheme.copyWith(
                      inactiveTrackColor: darkColorScheme.secondaryContainer),
                  progressIndicatorTheme: ProgressIndicatorThemeData(
                      circularTrackColor: darkColorScheme.secondaryContainer
                          .withValues(alpha: 0.8))),
            );
          });
        });
  }
}
