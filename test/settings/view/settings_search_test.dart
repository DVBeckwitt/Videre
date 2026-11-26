import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/models/replay_gain.dart';
import 'package:clipious/music/views/components/music_replay_gain_controls.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_app_cubit.dart';
import '../../test_player_cubit.dart';
import '../../test_settings_cubit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const query = 'volume normalization';
  const artworkSwipe = 'Swipe artwork to change songs';
  final entry = find.byKey(const ValueKey('open-settings-search'));
  final input = find.byKey(const ValueKey('settings-search-input'));
  final result = find
      .byKey(const ValueKey('settings-search-result-music-replaygain-setting'));
  final artworkSwipeResult = find.byKey(
      const ValueKey('settings-search-result-music-artwork-swipe-setting'));
  final offChip = find.byKey(const ValueKey('music-replaygain-off'));
  final trackChip = find.byKey(const ValueKey('music-replaygain-track'));

  late bool previousTv;
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;

  setUp(() async {
    previousTv = app_globals.isTv;
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = TestPlayerCubit(PlayerState.init(null), settings);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    app_globals.isTv = previousTv;
  });

  Future<void> mountSettings(WidgetTester tester,
      {bool television = false, Locale locale = const Locale('en')}) async {
    app_globals.isTv = television;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize =
        television ? const Size(1280, 720) : const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = RootStackRouter.build(routes: [
      AutoRoute(
        page: television ? TVSettingsRoute.page : SettingsRoute.page,
        path: '/',
      ),
      AutoRoute(page: TvTextFieldRoute.page),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
        BlocProvider<PlayerCubit>.value(value: player),
      ],
      child: MaterialApp.router(
        routerConfig: router.config(),
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ));
    await tester.pumpAndSettle();
  }

  bool hasPrimaryFocus(WidgetTester tester, Finder target) {
    final element = tester.element(target);
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == element) return true;
    var inside = false;
    context?.visitAncestorElements((ancestor) {
      inside = ancestor == element;
      return !inside;
    });
    return inside;
  }

  Future<void> submitTvQuery(WidgetTester tester, String text) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), text);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
  }

  testWidgets('phone finds and opens the actual ReplayGain preference',
      (tester) async {
    await mountSettings(tester);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    await tester.enterText(input, artworkSwipe);
    await tester.pumpAndSettle();
    expect(artworkSwipeResult, findsOneWidget);

    await tester.enterText(input, query);
    await tester.pumpAndSettle();
    await tester.tap(result);
    await tester.pumpAndSettle();
    expect(offChip.hitTestable(), findsOneWidget);
    expect(tester.widget<ChoiceChip>(offChip).selected, isTrue);
    expect(hasPrimaryFocus(tester, offChip), isTrue);

    final controls = tester
        .widget<MusicReplayGainControls>(find.byType(MusicReplayGainControls));
    expect(controls.isCurrent(), isTrue);
    expect(trackChip.hitTestable(), findsOneWidget);
    final sound = player.musicSound;
    await tester.runAsync(() async {
      await tester.tap(trackChip);
      final timeout = Stopwatch()..start();
      while (sound.replayGainMode != ReplayGainMode.track &&
          timeout.elapsed < const Duration(seconds: 2)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pumpAndSettle();
    expect(sound.replayGainMode, ReplayGainMode.track);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        query);
    expect(result, findsOneWidget);

    await tester.tap(result);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(trackChip).selected, isTrue);
    expect(hasPrimaryFocus(tester, trackChip), isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('TV selects ReplayGain and Back restores result focus',
      (tester) async {
    await mountSettings(tester, television: true);
    expect(hasPrimaryFocus(tester, entry), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(hasPrimaryFocus(tester, input), isTrue);

    await submitTvQuery(tester, artworkSwipe);
    expect(artworkSwipeResult, findsNothing);
    await submitTvQuery(tester, query);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(hasPrimaryFocus(tester, result), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(offChip.hitTestable(), findsOneWidget);
    expect(hasPrimaryFocus(tester, offChip), isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text(query), findsOneWidget);
    expect(hasPrimaryFocus(tester, result), isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('ReplayGain is excluded on unsupported platforms',
      (tester) async {
    await mountSettings(tester);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    await tester.enterText(input, query);
    await tester.pumpAndSettle();
    expect(result, findsNothing);
    expect(find.text('No matching settings'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a Spanish behavior query matches without its accent',
      (tester) async {
    await mountSettings(tester, locale: const Locale('es'));
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.text('Buscar ajustes'), findsWidgets);
    await tester.enterText(input, 'normalizacion de volumen');
    await tester.pumpAndSettle();
    expect(result, findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
