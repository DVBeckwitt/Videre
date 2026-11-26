import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/models/music_settings_search_entries.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/views/screens/music_settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_settings_cubit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('videre/music_android_settings');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final notifications =
      find.widgetWithText(ListTile, 'Android notification settings');
  final battery = find.widgetWithText(ListTile, 'Android battery settings');
  late AppCubit app;
  late SettingsCubit settings;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    await app.initState();
    settings = TestSettingsCubit(SettingsState.init(), app);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> showMusicSettings(
    WidgetTester tester, {
    bool television = false,
    String focusedSetting = '',
  }) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider.value(value: app),
        BlocProvider.value(value: settings),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MusicSettingsScreen(
          television: television,
          focusedSetting: focusedSetting,
          settingFocusNode: focusNode,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> tapTile(WidgetTester tester, Finder tile) async {
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  Iterable<String> androidSearchEntries(WidgetTester tester) {
    final context = tester.element(find.byType(MusicSettingsScreen));
    return musicSettingsSearchEntries(
      AppLocalizations.of(context)!,
      television: false,
      direction: TextDirection.ltr,
      showTransitionDuration: false,
    ).map((entry) => entry.id).where((id) => id.startsWith('music-android-'));
  }

  testWidgets('Android Music shortcuts open only their selected destinations',
      (tester) async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });
    await showMusicSettings(tester);
    expect(calls, isEmpty);
    expect(androidSearchEntries(tester), [
      'music-android-notifications-setting',
      'music-android-battery-setting',
    ]);

    await tapTile(tester, notifications);
    await tapTile(tester, battery);

    expect(calls, ['openNotifications', 'openBattery']);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(MusicSettingsScreen), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('unavailable notification settings offer Videre App info',
      (tester) async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'openNotifications') {
        throw PlatformException(code: 'unavailable');
      }
      return true;
    });
    await showMusicSettings(tester);
    await tapTile(tester, notifications);
    expect(find.textContaining('look for Notifications'), findsOneWidget);
    expect(calls, ['openNotifications']);

    await tester.tap(find.text('Open App info'));
    await tester.pumpAndSettle();
    expect(calls, ['openNotifications', 'openAppDetails']);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(MusicSettingsScreen), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
      'TV select and Back work when Android battery settings are absent',
      (tester) async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return false;
    });
    await showMusicSettings(
      tester,
      television: true,
      focusedSetting: 'music-android-battery-setting',
    );
    await tester.ensureVisible(battery);
    final focus = tester.widget<ListTile>(battery).focusNode!;
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(find.textContaining('look for Battery or Background usage'),
        findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(focus.hasPrimaryFocus, isTrue);
    expect(calls, ['openBattery']);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open App info'));
    await tester.pumpAndSettle();
    expect(calls, ['openBattery', 'openBattery', 'openAppDetails']);
    expect(
        find.textContaining('In Android Settings, open Apps and select Videre'),
        findsOneWidget);
    expect(find.byType(MusicSettingsScreen), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Music settings and search hide the Android shortcuts on iOS',
      (tester) async {
    await showMusicSettings(tester);
    expect(notifications, findsNothing);
    expect(battery, findsNothing);
    expect(androidSearchEntries(tester), isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
