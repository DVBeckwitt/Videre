import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/content_mode.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/home/models/phone_navigation.dart';
import 'package:clipious/home/views/screens/edit_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app;
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/views/components/app_customizer.dart';
import 'package:clipious/settings/views/components/phone_navigation_editor.dart';
import 'package:clipious/settings/views/screens/browsing.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _App extends Cubit<AppState> implements AppCubit {
  _App() : super(AppState(0, null, HomeLayout()));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends Cubit<SettingsState> implements SettingsCubit {
  _Settings(this.appCubit) : super(SettingsState.init());

  @override
  final AppCubit appCubit;

  @override
  String? getLocaleDisplayName() => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _App appCubit;
  late _Settings settings;
  late bool previousIsTv;

  setUp(() async {
    previousIsTv = app.isTv;
    app.isTv = false;
    db = await SembastSqfDb.createInMemory();
    await db.saveSetting(
        SettingsValue(homeContentModeSettingName, HomeContentMode.music.name));
    appCubit = _App();
    settings = _Settings(appCubit);
  });

  tearDown(() async {
    await settings.close();
    await appCubit.close();
    await db.close();
    app.isTv = previousIsTv;
  });

  Future<void> mount(WidgetTester tester, Widget child,
      {Size size = const Size(390, 844)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(BlocProvider<SettingsCubit>.value(
      value: settings,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'Browsing separates Navigation and Home tabs without experience modes',
      (tester) async {
    await mount(tester, const BrowsingSettingsScreen());
    expect(find.text('Home experience'), findsNothing);
    expect(find.text('Videos only'), findsNothing);
    expect(find.text('Music only'), findsNothing);
    expect(find.text('Home tabs'), findsOneWidget);
    expect(find.text('Customize app sections'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final editor in <String, Widget>{
    'phone navigation editor': const PhoneNavigationEditor(),
    'tablet Settings customizer': const AppCustomizer(),
    'tablet Home editor': const EditHomeLayoutScreen(),
  }.entries) {
    testWidgets('${editor.key} only edits navigation', (tester) async {
      final phone = editor.value is PhoneNavigationEditor;
      final original = settings.state.phoneNavigation.encode();
      await mount(tester, editor.value,
          size: phone ? const Size(390, 844) : const Size(1024, 1366));
      expect(find.text('Home experience'), findsNothing);
      expect(find.text('Home content'), findsNothing);
      expect(find.byType(TabBar), findsNothing);
      expect(settings.state.phoneNavigation.encode(), original);
      expect(settings.state.phoneNavigation.encode(),
          PhoneNavigation.defaults().encode());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('tablet Settings dialog fits a short landscape display',
      (tester) async {
    await mount(
        tester,
        const AlertDialog(
            content: SizedBox(width: 300, child: AppCustomizer())),
        size: const Size(960, 600));
    expect(find.text('Home experience'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
