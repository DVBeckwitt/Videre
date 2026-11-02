import 'package:clipious/app/states/app.dart';
import 'package:clipious/app/views/tv/screens/tv_home.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app;
import 'package:clipious/service.dart';
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

  Future<void> mount(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: appCubit),
        BlocProvider<SettingsCubit>.value(value: settings),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const TvHomeScreen(),
      ),
    ));
    await tester.pumpAndSettle();
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
    for (var i = 0; i < 7; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    final settingsIcon = find.byIcon(Icons.settings);
    expect(Focus.of(tester.element(settingsIcon)).hasFocus, isTrue);
    expect(tester.getRect(settingsIcon).bottom, lessThanOrEqualTo(540));
    expect(tester.takeException(), isNull);
  });
}
