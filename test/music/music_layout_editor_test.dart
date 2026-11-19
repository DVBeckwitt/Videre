import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_layout.dart';
import 'package:clipious/music/views/screens/music_layout_editor.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _App extends Cubit<AppState> implements AppCubit {
  _App() : super(AppState(0, null, HomeLayout(), profileId: db.profileId));

  void switchSession() => emit(state.copyWith(
      profileId: db.profileId, sessionRevision: state.sessionRevision + 1));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends SettingsCubit {
  _Settings(AppCubit app) : super(SettingsState.init(), app);

  @override
  void onReady() {}
}

void main() {
  late _App app;
  late _Settings settings;

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

  Future<void> mount(WidgetTester tester, {bool tv = false}) async {
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MusicLayoutEditor(includeSearchShortcut: tv),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Finder control(String key) => find.byKey(ValueKey(key));

  Future<void> tap(WidgetTester tester, Finder control) async {
    await tester.ensureVisible(control);
    await tester.tap(control);
    await tester.pumpAndSettle();
  }

  Future<void> settleSave(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
  }

  testWidgets(
      'move Search, change shortcut order and visibility, reopen and reset',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(450, 1400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester);
    expect(control('music-shortcut-search-toggle'), findsNothing);
    await tap(tester, control('music-destination-search-move'));
    await tap(tester, find.text('Move later'));
    await settleSave(tester);
    expect(settings.state.musicLayout.destinations, [
      MusicDestination.home,
      MusicDestination.library,
      MusicDestination.search,
    ]);

    await tap(tester, control('music-shortcut-charts-move'));
    await tap(tester, find.text('Move earlier'));
    await settleSave(tester);
    final updated = settings.state.musicLayout.shortcuts;
    expect(updated.indexOf(MusicShortcut.charts),
        lessThan(updated.indexOf(MusicShortcut.library)));
    await tap(tester, control('music-shortcut-library-toggle'));
    await settleSave(tester);
    expect(settings.state.musicLayout.shortcuts,
        isNot(contains(MusicShortcut.library)));
    expect(
        settings.state.musicLayout.shortcuts, contains(MusicShortcut.search));

    final saved = settings.state.musicLayout.encode();
    await tester.pumpWidget(const SizedBox.shrink());
    await settings.close();
    settings = _Settings(app);
    await mount(tester, tv: true);
    expect(settings.state.musicLayout.encode(), saved);
    expect(control('music-shortcut-search-toggle'), findsOneWidget);
    final toggle = control('music-shortcut-library-toggle');
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tap(tester, toggle);
    await settleSave(tester);
    expect(
        settings.state.musicLayout.shortcuts, contains(MusicShortcut.library));
    await tap(tester, control('music-layout-reset'));
    await settleSave(tester);
    expect(settings.state.musicLayout.encode(),
        const MusicLayout.defaults().encode());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a Music editor opened for another session cannot change this profile',
      (tester) async {
    await mount(tester);
    final original = db.forProfile(db.profileId);
    await tester.runAsync(() async {
      final other = await db.createProfile('Other');
      await db.useProfile(other.id);
      app.switchSession();
    });
    await tester.pumpAndSettle();
    final toggle = control('music-shortcut-library-toggle');
    await tester.ensureVisible(toggle);
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
    expect(db.getSettings(musicLayoutSettingName), isNull);
    expect(original.getSettings(musicLayoutSettingName), isNull);
  });
}
