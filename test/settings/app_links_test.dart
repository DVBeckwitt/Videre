import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app;
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/views/screens/browsing.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _Settings extends Cubit<SettingsState> implements SettingsCubit {
  _Settings() : super(SettingsState.init());

  @override
  String? getLocaleDisplayName() => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Settings settings;
  late bool previousIsTv;

  setUp(() async {
    previousIsTv = app.isTv;
    app.isTv = false;
    db = await SembastSqfDb.createInMemory();
    settings = _Settings();
  });

  tearDown(() async {
    await settings.close();
    await db.close();
    app.isTv = previousIsTv;
  });

  for (final size in [const Size(390, 844), const Size(1280, 900)]) {
    testWidgets('Browsing leaves link defaults to Android at $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(BlocProvider<SettingsCubit>.value(
        value: settings,
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BrowsingSettingsScreen(),
        ),
      ));
      await tester.pumpAndSettle();
      final locals = AppLocalizations.of(
          tester.element(find.byType(BrowsingSettingsScreen)))!;
      expect(find.text('Open YouTube links'), findsNothing);
      expect(find.text(locals.localRecommendations), findsOneWidget);
      expect(find.text(locals.customizeAppLayout), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({TargetPlatform.android}));
  }
}
