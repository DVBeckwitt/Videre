import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/home/models/home_tabs_layout.dart';
import 'package:clipious/home/views/screens/home_tabs_editor.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _App extends Cubit<AppState> implements AppCubit {
  _App() : super(AppState(0, null, HomeLayout()));

  void changeSession() =>
      emit(state.copyWith(sessionRevision: state.sessionRevision + 1));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends SettingsCubit {
  _Settings(AppCubit app) : super(SettingsState.init(), app);
  bool failSave = false;

  @override
  void onReady() {}

  @override
  Future<void> setHomeTabsLayout(HomeTabsLayout layout) {
    if (failSave) throw StateError('Storage unavailable');
    return super.setHomeTabsLayout(layout);
  }
}

void main() {
  late _App app;
  late _Settings settings;
  final interests = const RecommendationResult<Video>(
    items: [],
    available: true,
    summary: {
      'interestChips': [
        {
          'id': 'animation',
          'label': 'Animation',
          'queries': ['animation']
        },
      ],
    },
  ).interests;
  final topic = HomeTabsLayout.topicId('animation');

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = _App();
    settings = _Settings(app);
  });
  tearDown(() async {
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HomeTabsEditorScreen(interests: interests),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('Continue watching is opt-in and every Home tab can stay hidden',
      (tester) async {
    await mount(tester);
    final resume = find.byKey(const ValueKey('home-continue-watching-toggle'));
    expect(tester.widget<SwitchListTile>(resume).value, isFalse);
    await tester.tap(resume);
    await settle(tester);
    expect(settings.state.homeTabsLayout.continueWatching, isTrue);

    final hide = find.byKey(const ValueKey('home-tabs-hide-all'));
    await tester.ensureVisible(hide);
    await tester.tap(hide);
    await settle(tester);
    expect(settings.state.homeTabsLayout.enabledOrder, isEmpty);
    expect(settings.state.homeTabsLayout.continueWatching, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await settings.close();
    settings = _Settings(app);
    await mount(tester);
    expect(settings.state.homeTabsLayout.enabledOrder, isEmpty);
    expect(tester.widget<SwitchListTile>(resume).value, isTrue);
    final showTopic = find.byKey(ValueKey('home-tabs-toggle-$topic'));
    await tester.ensureVisible(showTopic);
    await tester.tap(showTopic);
    await settle(tester);
    expect(settings.state.homeTabsLayout.enabledOrder, [topic]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Hide all clears enabled topics that are temporarily unavailable',
      (tester) async {
    final missing = HomeTabsLayout.topicId('temporarily-unavailable');
    await tester.runAsync(() => settings.setHomeTabsLayout(
        HomeTabsLayout(enabledOrder: [missing], continueWatching: true)));
    await mount(tester);
    expect(find.byKey(ValueKey('home-tab-row-$missing')), findsNothing);
    final hide = find.byKey(const ValueKey('home-tabs-hide-all'));
    await tester.ensureVisible(hide);
    expect(tester.widget<TextButton>(hide).onPressed, isNotNull);
    await tester.tap(hide);
    await settle(tester);
    expect(settings.state.homeTabsLayout.enabledOrder, isEmpty);
    expect(settings.state.homeTabsLayout.continueWatching, isTrue);
    final restored =
        HomeTabsLayout.decode(db.getSettings(homeTabsLayoutSettingName)!.value);
    expect(restored.orderedIds([missing, ...HomeTabsLayout.fixedIds]), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'topic and fixed tabs reorder together without losing missing topics',
      (tester) async {
    final missing = HomeTabsLayout.topicId('temporarily-unavailable');
    await tester.runAsync(
        () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [
              HomeTabsLayout.forYou,
              missing,
              HomeTabsLayout.yourFeeds,
              HomeTabsLayout.discover,
              topic,
            ])));
    await mount(tester);
    for (var i = 0; i < 3; i++) {
      final menu = find.byKey(ValueKey('home-tabs-move-$topic'));
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move earlier'));
      await settle(tester);
    }
    expect(
        settings.state.homeTabsLayout.orderedIds([
          ...HomeTabsLayout.fixedIds,
          topic,
        ]),
        [topic, ...HomeTabsLayout.fixedIds]);
    expect(settings.state.homeTabsLayout.enabledOrder, contains(missing));
    expect(tester.getTopLeft(find.text('Animation')).dy,
        lessThan(tester.getTopLeft(find.text('For you')).dy));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'failed save is recoverable and an old session cannot change layout',
      (tester) async {
    await mount(tester);
    final resume = find.byKey(const ValueKey('home-continue-watching-toggle'));
    settings.failSave = true;
    await tester.tap(resume);
    await settle(tester);
    expect(settings.state.homeTabsLayout.continueWatching, isFalse);
    expect(find.text('Could not save Home tabs. Please try again.'),
        findsOneWidget);
    settings.failSave = false;
    await tester.tap(resume);
    await settle(tester);
    expect(settings.state.homeTabsLayout.continueWatching, isTrue);
    final saved = db.getSettings(homeTabsLayoutSettingName)!.value;
    app.changeSession();
    await settle(tester);
    expect(tester.widget<SwitchListTile>(resume).onChanged, isNull);
    expect(db.getSettings(homeTabsLayoutSettingName)!.value, saved);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
