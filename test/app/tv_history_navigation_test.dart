import 'package:clipious/app/states/app.dart';
import 'package:clipious/app/views/components/session_focus_guard.dart';
import 'package:clipious/app/views/tv/screens/tv_home.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app;
import 'package:clipious/router.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/tv/screens/history.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _App extends Cubit<AppState> implements AppCubit {
  _App() : super(AppState(0, null, HomeLayout()));

  @override
  bool get isLoggedIn => false;

  void setSessionState(AppState value) => emit(value);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends Cubit<SettingsState> implements SettingsCubit {
  _Settings() : super(SettingsState.init());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Service extends Service {
  @override
  Future<bool> isLoggedIn() async => false;

  @override
  Future<List<Video>> getTrending({String? type}) async => [];

  @override
  Future<List<Video>> getPopular() async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Service originalService;
  late bool originalIsTv;
  late _App appCubit;
  late _Settings settings;

  setUp(() async {
    originalService = service;
    service = _Service();
    originalIsTv = app.isTv;
    app.isTv = true;
    db = await SembastSqfDb.createInMemory();
    appCubit = _App();
    settings = _Settings();
  });

  tearDown(() async {
    await settings.close();
    await appCubit.close();
    await db.close();
    service = originalService;
    app.isTv = originalIsTv;
  });

  Future<void> mount(WidgetTester tester, Size size,
      {AppRouter? router}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Widget guard(BuildContext context, Widget? child) =>
        BlocBuilder<AppCubit, AppState>(
          builder: (context, state) => SessionFocusGuard(
            blocked: state.globalLoading || state.sessionRecoveryRequired,
            restoreFocus: true,
            child: KeyedSubtree(
                key: ValueKey(state.sessionRevision), child: child!),
          ),
        );
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: appCubit),
        BlocProvider<SettingsCubit>.value(value: settings),
      ],
      child: router != null
          ? MaterialApp.router(
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: guard,
              routerConfig: router.config(),
            )
          : MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: guard,
              home: const TvHomeScreen(),
            ),
    ));
    await tester.pumpAndSettle();
    if (router != null) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('TV remote opens History and Back returns to its menu item',
      (tester) async {
    await mount(tester, const Size(1280, 720));
    final historyIcon = find.byIcon(Icons.history);
    Focus.of(tester.element(historyIcon)).requestFocus();
    await tester.pumpAndSettle();
    expect(find.text('History'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(TvHistoryScreen), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TvHistoryScreen), findsNothing);
    expect(Focus.of(tester.element(historyIcon)).hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV sidebar remains navigable at a 720p TV logical size',
      (tester) async {
    await mount(tester, const Size(960, 540));
    Focus.of(tester.element(find.byIcon(Icons.search))).requestFocus();
    await tester.pumpAndSettle();
    for (final icon in [
      Icons.subscriptions,
      Icons.history,
      Icons.playlist_play,
      Icons.local_fire_department,
      Icons.trending_up,
      Icons.account_circle_outlined,
      Icons.phonelink,
      Icons.settings,
    ]) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final item = find.byIcon(icon);
      expect(Focus.of(tester.element(item)).hasFocus, isTrue,
          reason: 'Each sidebar item must be reachable in order');
      expect(tester.getRect(item).bottom, lessThanOrEqualTo(540));
    }
    final settingsIcon = find.byIcon(Icons.settings);
    expect(Focus.of(tester.element(settingsIcon)).hasFocus, isTrue);
    expect(tester.getRect(settingsIcon).bottom, lessThanOrEqualTo(540));
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV profile rebuild restores remote navigation after loading',
      (tester) async {
    final router = AppRouter(hasServer: true);
    addTearDown(router.dispose);
    await tester.runAsync(
        () => db.upsertServer(const Server(url: 'https://focus.example')));
    await mount(tester, const Size(1280, 720), router: router);
    Focus.of(tester.element(find.byIcon(Icons.history))).requestFocus();
    await tester.pumpAndSettle();
    appCubit.setSessionState(appCubit.state.copyWith(globalLoading: true));
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.byIcon(Icons.history))).canRequestFocus,
        isFalse);
    appCubit.setSessionState(appCubit.state.copyWith(sessionRevision: 1));
    await tester.runAsync(() =>
        router.replaceAll([const TvHomeRoute()], updateExistingRoutes: false));
    await tester.pumpAndSettle();
    appCubit.setSessionState(appCubit.state.copyWith(globalLoading: false));
    await tester.pumpAndSettle();
    expect(
        Focus.of(tester.element(find.byIcon(Icons.search))).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.byIcon(Icons.subscriptions))).hasFocus,
        isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(TvHistoryScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV rollback restores previous focus only after recovery clears',
      (tester) async {
    await mount(tester, const Size(1280, 720));
    final history = find.byIcon(Icons.history);
    Focus.of(tester.element(history)).requestFocus();
    await tester.pumpAndSettle();
    appCubit.setSessionState(appCubit.state.copyWith(globalLoading: true));
    await tester.pumpAndSettle();
    appCubit.setSessionState(appCubit.state
        .copyWith(globalLoading: false, sessionRecoveryRequired: true));
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(history)).canRequestFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(TvHistoryScreen), findsNothing);

    appCubit.setSessionState(
        appCubit.state.copyWith(sessionRecoveryRequired: false));
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(history)).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(TvHistoryScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
