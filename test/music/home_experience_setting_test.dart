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
import 'package:clipious/settings/views/components/home_experience_setting.dart';
import 'package:clipious/settings/views/components/phone_navigation_editor.dart';
import 'package:clipious/settings/views/screens/browsing.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _App extends Cubit<AppState> implements AppCubit {
  _App() : super(AppState(0, null, HomeLayout()));

  void advanceSession() =>
      emit(state.copyWith(sessionRevision: state.sessionRevision + 1));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends Cubit<SettingsState> implements SettingsCubit {
  _Settings(this.appCubit) : super(SettingsState.init());

  @override
  final AppCubit appCubit;

  final choices = <HomeExperience>[];

  @override
  Future<void> setHomeExperience(HomeExperience experience) async {
    choices.add(experience);
    emit(state.copyWith(settings: {
      ...state.settings,
      homeExperienceSettingName:
          SettingsValue(homeExperienceSettingName, experience.name),
    }));
  }

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

  Future<void> choose(WidgetTester tester, HomeExperience experience) async {
    await tester.tap(find.text('Home experience').first);
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(ValueKey('home-experience-${experience.name}')));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'chooser shows every option and can recover from either single mode',
      (tester) async {
    await mount(tester, const HomeExperienceSetting());
    expect(find.text('Videos and Music'), findsOneWidget);
    await tester.tap(find.text('Home experience'));
    await tester.pumpAndSettle();
    expect(find.text('Videos only'), findsOneWidget);
    expect(find.text('Music only'), findsOneWidget);
    expect(
        tester
            .widget<ListTile>(
                find.byKey(const ValueKey('home-experience-videosAndMusic')))
            .selected,
        isTrue);
    await tester.tap(find.byKey(const ValueKey('home-experience-musicOnly')));
    await tester.pumpAndSettle();
    expect(find.text('Music only'), findsOneWidget);
    expect(settings.state.showContentModeSelector, isFalse);
    expect(settings.state.effectiveHomeContentMode, HomeContentMode.music);

    await choose(tester, HomeExperience.videosOnly);
    expect(find.text('Videos only'), findsOneWidget);
    expect(settings.state.effectiveHomeContentMode, HomeContentMode.videos);
    await choose(tester, HomeExperience.videosAndMusic);
    expect(find.text('Videos and Music'), findsOneWidget);
    expect(settings.state.showContentModeSelector, isTrue);
    expect(settings.state.effectiveHomeContentMode, HomeContentMode.music);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dismissing the chooser leaves the saved experience alone',
      (tester) async {
    await mount(tester, const HomeExperienceSetting());
    await tester.tap(find.text('Home experience'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsNothing);
    expect(settings.choices, isEmpty);
    expect(settings.state.homeExperience, HomeExperience.videosAndMusic);
  });

  testWidgets('Browsing exposes the current choice and restores both modes',
      (tester) async {
    await settings.setHomeExperience(HomeExperience.musicOnly);
    await mount(tester, const BrowsingSettingsScreen());
    expect(find.text('Home experience'), findsOneWidget);
    expect(find.text('Music only'), findsOneWidget);
    await choose(tester, HomeExperience.videosAndMusic);
    expect(find.text('Videos and Music'), findsOneWidget);
    expect(settings.state.showContentModeSelector, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a picker opened for another profile cannot change this profile',
      (tester) async {
    final other = (await tester.runAsync(() => db.createProfile('Other')))!;
    await mount(tester, const HomeExperienceSetting());
    await tester.tap(find.text('Home experience'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => db.useProfile(other.id));
    await tester.tap(find.byKey(const ValueKey('home-experience-musicOnly')));
    await tester.pumpAndSettle();
    expect(settings.choices, isEmpty);
    expect(settings.state.homeExperience, HomeExperience.videosAndMusic);
  });

  testWidgets('a stale picker cannot apply after returning to the same profile',
      (tester) async {
    final other = (await tester.runAsync(() => db.createProfile('Other')))!;
    await mount(tester, const HomeExperienceSetting());
    await tester.tap(find.text('Home experience'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await db.useProfile(other.id);
      await db.useProfile('default');
    });
    appCubit.advanceSession();
    await tester.tap(find.byKey(const ValueKey('home-experience-musicOnly')));
    await tester.pumpAndSettle();
    expect(settings.choices, isEmpty);
    expect(settings.state.homeExperience, HomeExperience.videosAndMusic);
  });

  for (final editor in <String, Widget>{
    'phone navigation editor': const PhoneNavigationEditor(),
    'tablet Settings customizer': const AppCustomizer(),
    'tablet Home editor': const EditHomeLayoutScreen(),
  }.entries) {
    testWidgets('${editor.key} keeps the experience recoverable',
        (tester) async {
      final phone = editor.value is PhoneNavigationEditor;
      await settings.setHomeExperience(HomeExperience.musicOnly);
      final original = settings.state.phoneNavigation.encode();
      await mount(tester, editor.value,
          size: phone ? const Size(390, 844) : const Size(1024, 1366));
      expect(find.text('Home experience'), findsOneWidget);
      await choose(tester, HomeExperience.videosAndMusic);
      expect(settings.state.homeExperience, HomeExperience.videosAndMusic);
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
    expect(tester.takeException(), isNull);
    await choose(tester, HomeExperience.musicOnly);
    expect(settings.state.homeExperience, HomeExperience.musicOnly);
  });
}
