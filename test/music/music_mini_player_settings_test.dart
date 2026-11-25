import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app;
import 'package:clipious/music/models/music_mini_player_preferences.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/views/components/music_provider_settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_settings_cubit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppCubit appCubit;
  late SettingsCubit settings;
  late bool previousTv;

  setUp(() async {
    previousTv = app.isTv;
    app.isTv = false;
    db = await SembastSqfDb.createInMemory();
    appCubit = TestAppCubit(AppState(0, null, HomeLayout()));
    appCubit.intentDataStreamSubscription = const Stream.empty().listen((_) {});
    await appCubit.initState();
    settings = TestSettingsCubit(SettingsState.init(), appCubit);
  });
  tearDown(() async {
    app.isTv = previousTv;
    await settings.close();
    await appCubit.close();
    await db.close();
  });

  Future<void> showSettings(WidgetTester tester) async {
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider.value(value: appCubit),
        BlocProvider.value(value: settings),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
            body: SingleChildScrollView(child: MusicProviderSettings())),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('selects the mini-player layout and shortcut independently',
      (tester) async {
    await showSettings(tester);
    Future<void> choose(
        String setting, List<String> labels, String target) async {
      final tile = find.byKey(ValueKey('music-mini-player-$setting-setting'));
      expect(find.descendant(of: tile, matching: find.text('Automatic')),
          findsOneWidget);
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      final dialog = find.byType(SimpleDialog);
      for (final label in labels) {
        expect(find.descendant(of: dialog, matching: find.text(label)),
            findsOneWidget);
      }
      await tester
          .tap(find.descendant(of: dialog, matching: find.text(target)));
      await tester.pumpAndSettle();
      expect(find.descendant(of: tile, matching: find.text(target)),
          findsOneWidget);
    }

    await choose('layout', ['Automatic', 'Compact', 'Transport'], 'Transport');
    await choose(
        'shortcut', ['Automatic', 'Next', 'Repeat', 'Shuffle'], 'Repeat');
    expect(
        settings.state.musicMiniPlayerLayout, MusicMiniPlayerLayout.transport);
    expect(
        settings.state.musicMiniPlayerShortcut, MusicMiniPlayerShortcut.repeat);
  });

  testWidgets('artwork swiping starts enabled and can be turned off',
      (tester) async {
    await showSettings(tester);
    final tile =
        find.widgetWithText(SwitchListTile, 'Swipe artwork to change songs');
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    expect(settings.state.musicArtworkSwipe, isFalse);
  });

  testWidgets('double-tap seeking is opt-in and independent of artwork swiping',
      (tester) async {
    await showSettings(tester);
    final swipe =
        find.widgetWithText(SwitchListTile, 'Swipe artwork to change songs');
    await tester.ensureVisible(swipe);
    await tester.tap(swipe);
    await tester.pumpAndSettle();
    final tile =
        find.widgetWithText(SwitchListTile, 'Double-tap artwork to seek');
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    expect(settings.state.musicArtworkDoubleTapSeek, isTrue);
    expect(settings.state.musicArtworkSwipe, isFalse);
  });

  testWidgets('TV omits touch gestures and mini-player choices',
      (tester) async {
    app.isTv = true;
    await showSettings(tester);
    expect(find.text('Streaming audio quality'), findsOneWidget);
    expect(find.text('Mini-player layout'), findsNothing);
    expect(find.text('Mini-player shortcut'), findsNothing);
    expect(find.text('Swipe artwork to change songs'), findsNothing);
    expect(find.text('Double-tap artwork to seek'), findsNothing);
  });
}
