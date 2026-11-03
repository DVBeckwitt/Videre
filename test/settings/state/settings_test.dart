import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/home/models/phone_navigation.dart';
import 'package:clipious/main.dart' as app;
import 'package:clipious/search/models/db/search_history_item.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/workmanager.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:workmanager/workmanager.dart';

import '../../test_app_cubit.dart';
import '../../test_settings_cubit.dart';

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory documents;
  late TestAppCubit appCubit;
  late SettingsCubit settingsCubit;
  late WorkmanagerPlatform originalWorkmanager;
  late _Workmanager workmanager;
  late bool originalIsTv;
  setUp(() async {
    originalIsTv = app.isTv;
    app.isTv = false;
    originalWorkmanager = WorkmanagerPlatform.instance;
    workmanager = _Workmanager();
    WorkmanagerPlatform.instance = workmanager;
    documents = await Directory.systemTemp.createTemp('videre-settings-test-');
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documents.path);
    db = await SembastSqfDb.createInMemory();
    appCubit = TestAppCubit(AppState(0, null, HomeLayout()));
    appCubit.intentDataStreamSubscription = const Stream.empty().listen((_) {});
    await appCubit.initState();
    settingsCubit = TestSettingsCubit(SettingsState.init(), appCubit);
  });
  tearDown(() async {
    app.isTv = originalIsTv;
    await settingsCubit.close();
    await appCubit.close();
    await db.close();
    messenger.setMockMethodCallHandler(pathProvider, null);
    await documents.delete(recursive: true);
    WorkmanagerPlatform.instance = originalWorkmanager;
  });

  test('motion follows Android by default and persists each choice', () async {
    expect(settingsCubit.state.motionPreference, MotionPreference.system);
    for (final preference in MotionPreference.values) {
      await settingsCubit.setMotionPreference(preference);
      expect(settingsCubit.state.motionPreference, preference);
      expect(
          db.getSettings(motionPreferenceSettingName)?.value, preference.name);
    }
    await settingsCubit
        .saveSetting(SettingsValue(motionPreferenceSettingName, 'invalid'));
    expect(settingsCubit.state.motionPreference, MotionPreference.system);
  });

  test('disabling notifications cancels a pending frequency restart', () async {
    await settingsCubit
        .saveSetting(SettingsValue(backgroundNotificationsSettingName, 'true'));
    await settingsCubit.setBackgroundCheckFrequency(3);

    await settingsCubit.setBackgroundNotifications(false);
    await Future<void>.delayed(const Duration(milliseconds: 2100));

    expect(workmanager.cancelAllCalls, 1);
    expect(workmanager.registrations, 0);
    expect(settingsCubit.state.backgroundNotifications, isFalse);
  });

  test('profile reload replaces notification work with the selected preference',
      () async {
    await settingsCubit
        .saveSetting(SettingsValue(backgroundNotificationsSettingName, 'true'));
    await settingsCubit.setBackgroundCheckFrequency(3);
    final other = await db.createProfile('Other');
    await db.useProfile(other.id);
    await fileDb.useProfile(other.id);
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.backgroundNotifications, isFalse);
    expect(workmanager.registrations, 0);
    expect(workmanager.cancelUniqueCalls, 1);

    await db.useProfile('default');
    await fileDb.useProfile('default');
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.backgroundNotifications, isTrue);
    expect(workmanager.registrations, 1);
    expect(workmanager.cancelUniqueCalls, 2);
    expect(workmanager.initializeCalls, 1);
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    expect(workmanager.registrations, 1);
  });

  test(
      'profile reload keeps device package metadata while replacing preferences',
      () async {
    final info = PackageInfo(
        appName: 'Videre',
        packageName: 'com.github.dvbeckwitt.videre',
        version: '1.22.34',
        buildNumber: '60896');
    await settingsCubit.close();
    settingsCubit = TestSettingsCubit(
        SettingsState.init().copyWith(packageInfo: info), appCubit);
    await settingsCubit.setUseProxy(true);
    final other = await db.createProfile('Other');
    await db.useProfile(other.id);
    await fileDb.useProfile(other.id);

    await settingsCubit.reloadForProfile();

    expect(settingsCubit.state.useProxy, isFalse);
    expect(settingsCubit.state.packageInfo.appName, info.appName);
    expect(settingsCubit.state.packageInfo.packageName, info.packageName);
    expect(settingsCubit.state.packageInfo.version, info.version);
    expect(settingsCubit.state.packageInfo.buildNumber, info.buildNumber);
  });

  test('disabling during a restart prevents late task registration', () async {
    await settingsCubit
        .saveSetting(SettingsValue(backgroundNotificationsSettingName, 'true'));
    final cancelled = Completer<void>();
    workmanager.cancelPending = cancelled;
    final restarting = setupTasks(settingsCubit);
    await workmanager.cancellationStarted.future;

    await settingsCubit.setBackgroundNotifications(false);
    cancelled.complete();
    await restarting;

    expect(workmanager.cancelAllCalls, 1);
    expect(workmanager.registrations, 0);
  });

  test('country selection finishes saving before it completes', () async {
    await settingsCubit.selectCountry('France');

    expect(settingsCubit.state.country.code, 'FR');
    expect(SettingsState.init().country.code, 'FR');
  });

  test('TV defaults include History without changing phone sections', () {
    final phoneLayout = settingsCubit.state.appLayout;
    app.isTv = true;
    expect(settingsCubit.state.appLayout, [
      HomeDataSource.search,
      HomeDataSource.subscription,
      HomeDataSource.history,
      HomeDataSource.playlist,
      HomeDataSource.popular,
      HomeDataSource.trending,
    ]);
    app.isTv = false;
    expect(settingsCubit.state.appLayout, phoneLayout);
  });

  test('legacy TV sections gain History and preserve later opt-outs', () async {
    const legacy = 'search,playlist,trending';
    await settingsCubit
        .saveSetting(SettingsValue(appLayoutSettingName, legacy));
    app.isTv = true;
    expect(settingsCubit.state.appLayout, [
      HomeDataSource.search,
      HomeDataSource.playlist,
      HomeDataSource.trending,
      HomeDataSource.history,
    ]);
    final withoutHistory = settingsCubit.state.appLayout
      ..remove(HomeDataSource.history);
    await settingsCubit.setAppLayout(withoutHistory);
    expect(SettingsState.init().appLayout, withoutHistory);
    expect(db.getSettings(appLayoutSettingName)?.value, legacy);
    expect(db.getSettings(tvAppLayoutSettingName)?.value, legacy);

    await settingsCubit.setAppLayout([]);
    expect(SettingsState.init().appLayout, isEmpty);
    app.isTv = false;
    expect(settingsCubit.state.appLayout, withoutHistory);
  });

  test('TV layout ignores phone-only sections without editing their settings',
      () async {
    await settingsCubit.setAppLayout([
      HomeDataSource.home,
      HomeDataSource.history,
      HomeDataSource.downloads,
      HomeDataSource.playlist,
    ]);
    final phoneLayout = settingsCubit.state.appLayout;
    app.isTv = true;
    expect(settingsCubit.state.appLayout,
        [HomeDataSource.history, HomeDataSource.playlist]);
    await settingsCubit.setAppLayout([HomeDataSource.search]);
    app.isTv = false;
    expect(settingsCubit.state.appLayout, phoneLayout);
    expect(HomeDataSource.history.showOn, HomeDataSourceAppearance.both);
  });

  test(
      'phone navigation preserves defaults and legacy startup without changing tablet sections',
      () async {
    expect(settingsCubit.state.phoneNavigation.encode(),
        PhoneNavigation.defaults().encode());
    await settingsCubit.setAppLayout(
        [HomeDataSource.history, HomeDataSource.home, HomeDataSource.playlist]);
    final original = settingsCubit.state.appLayout;
    var layout = settingsCubit.state.phoneNavigation;
    expect(layout.bottom, [
      PhoneNavigationItem.history,
      PhoneNavigationItem.home,
      PhoneNavigationItem.search
    ]);
    expect(layout.startup, PhoneNavigationItem.history);
    layout = layout.move(PhoneNavigationItem.playlist, NavigationArea.bottom,
        before: PhoneNavigationItem.search)!;
    layout = layout.move(PhoneNavigationItem.history, NavigationArea.top)!;
    await settingsCubit.setPhoneNavigation(layout);
    expect(SettingsState.init().phoneNavigation.encode(), layout.encode());
    expect(SettingsState.init().appLayout, original);
    expect(layout.startup, PhoneNavigationItem.home);
  });

  test(
      'navigation moves preserve startup identity and reject unusable bottom bars',
      () {
    var layout =
        PhoneNavigation.defaults().startAt(PhoneNavigationItem.history);
    layout = layout.move(PhoneNavigationItem.history, NavigationArea.bottom,
        before: PhoneNavigationItem.home)!;
    expect(layout.startup, PhoneNavigationItem.history);
    expect(layout.bottom.first, PhoneNavigationItem.history);
    layout = layout.move(PhoneNavigationItem.playlist, NavigationArea.bottom)!;
    expect(
        layout.move(PhoneNavigationItem.queue, NavigationArea.bottom), isNull);
    layout = layout.move(PhoneNavigationItem.home, NavigationArea.hidden)!;
    layout = layout.move(PhoneNavigationItem.subscription, NavigationArea.top)!;
    layout = layout.move(PhoneNavigationItem.playlist, NavigationArea.top)!;
    expect(layout.bottom,
        [PhoneNavigationItem.history, PhoneNavigationItem.search]);
    expect(layout.move(PhoneNavigationItem.history, NavigationArea.hidden),
        isNull);
    expect(
        layout
            .move(PhoneNavigationItem.queue, NavigationArea.bottom)!
            .move(PhoneNavigationItem.history, NavigationArea.top),
        isNull);
    expect(
        layout
            .move(PhoneNavigationItem.search, NavigationArea.bottom,
                before: PhoneNavigationItem.search)!
            .encode(),
        layout.encode());
  });

  test(
      'disabled search history has a usable fallback without changing the saved layout',
      () {
    final layout = PhoneNavigation(
        [PhoneNavigationItem.searchHistory, PhoneNavigationItem.search],
        [PhoneNavigationItem.home]);
    final available = layout.available(searchHistory: false);
    expect(available.bottom,
        [PhoneNavigationItem.home, PhoneNavigationItem.search]);
    expect(available.top, isEmpty);
    expect(layout.bottom.first, PhoneNavigationItem.searchHistory);
  });

  test('malformed navigation preferences fall back safely', () async {
    for (final value in [
      'null',
      '{',
      '{}',
      '{"bottom":["unknown"],"top":[],"startup":"unknown"}',
      '{"bottom":["home","home"],"top":[],"startup":"home"}',
      '{"bottom":["home","search"],"top":["home"],"startup":"home"}',
      '{"bottom":["search","queue"],"top":[],"startup":"search"}'
    ]) {
      expect(PhoneNavigation.decode(value), isNull);
      await settingsCubit
          .saveSetting(SettingsValue(phoneNavigationSettingName, value));
      expect(settingsCubit.state.phoneNavigation.encode(),
          PhoneNavigation.defaults().encode());
    }
  });

  test('queue autoplay defaults on and its opt-out persists independently',
      () async {
    expect(settingsCubit.state.autoplayQueue, isTrue);
    final onLoad = settingsCubit.state.autoplayVideoOnLoad;
    await settingsCubit.setAutoplayQueue(false);
    expect(SettingsState.init().autoplayQueue, isFalse);
    expect(settingsCubit.state.autoplayVideoOnLoad, onLoad);
    await settingsCubit.setAutoplayQueue(true);
    expect(SettingsState.init().autoplayQueue, isTrue);
  });

  test('locale changes finish saving to both foreground and background storage',
      () async {
    await settingsCubit.setLocale([const Locale('fr')], ['French'], 'French');

    expect(settingsCubit.state.locale, 'fr');
    expect(SettingsState.init().locale, 'fr');
    expect(await fileDb.getLocale(), 'fr');

    await settingsCubit.setLocale([const Locale('fr')], ['French'], null);

    expect(settingsCubit.state.locale, isNull);
    expect(SettingsState.init().locale, isNull);
    expect(await fileDb.getLocale(), isNull);
  });

  test('search history defaults on and respects saved choices after reload',
      () async {
    expect(settingsCubit.state.useSearchHistory, isTrue);
    expect(SettingsState.init().useSearchHistory, isTrue);

    await settingsCubit.setUseSearchHistory(false);
    expect(settingsCubit.state.useSearchHistory, isFalse);
    expect(SettingsState.init().useSearchHistory, isFalse);

    await settingsCubit.setUseSearchHistory(true);
    expect(SettingsState.init().useSearchHistory, isTrue);
  });

  test('overlapping setting writes retain both values in the current state',
      () async {
    await Future.wait<void>([
      settingsCubit.setUseSearchHistory(true),
      settingsCubit.setSkipStep(30),
    ]);

    expect(settingsCubit.state.useSearchHistory, isTrue);
    expect(settingsCubit.state.skipStep, 30);
    expect(SettingsState.init().useSearchHistory, isTrue);
    expect(SettingsState.init().skipStep, 30);
  });

  test('video quality defaults on and survives settings reload', () async {
    expect(settingsCubit.state.rememberVideoQuality, isTrue);
    expect(settingsCubit.state.lastVideoQuality, isNull);
    await settingsCubit.setLastVideoQuality(720);
    expect(SettingsState.init().lastVideoQuality, 720);
    await settingsCubit.setRememberVideoQuality(false);
    expect(SettingsState.init().rememberVideoQuality, isFalse);
    expect(SettingsState.init().lastVideoQuality, 720);
    await settingsCubit.setLastVideoQuality(0);
    expect(SettingsState.init().lastVideoQuality, 0);
    await settingsCubit.setLastVideoQuality(-1);
    await settingsCubit.setLastVideoQuality(20000);
    expect(SettingsState.init().lastVideoQuality, 0);
    await settingsCubit
        .saveSetting(SettingsValue(lastVideoQualitySettingName, 'invalid'));
    expect(SettingsState.init().lastVideoQuality, isNull);
  });

  test('hiding watched subscriptions defaults off and persists', () async {
    expect(settingsCubit.state.hideWatchedSubscriptions, isFalse);
    await settingsCubit.setHideWatchedSubscriptions(true);
    expect(settingsCubit.state.hideWatchedSubscriptions, isTrue);
    expect(SettingsState.init().hideWatchedSubscriptions, isTrue);
    await settingsCubit.setHideWatchedSubscriptions(false);
    expect(SettingsState.init().hideWatchedSubscriptions, isFalse);
  });

  test('reducing the history limit immediately trims existing history',
      () async {
    for (var index = 0; index < 5; index++) {
      await db.addToSearchHistory(SearchHistoryItem('query $index', index));
    }
    await settingsCubit.setHistoryLimit(2);

    expect(settingsCubit.state.searchHistoryLimit, 2);
    expect(db.getSearchHistory(), hasLength(2));
  });

  test('closing settings during a save still persists the setting', () async {
    final saving = settingsCubit.setSkipStep(30);
    await settingsCubit.close();
    await saving;

    expect(SettingsState.init().skipStep, 30);
  });

  test('sponsor skipping and dislike counts are on without saved settings', () {
    expect(settingsCubit.state.useReturnYoutubeDislike, isTrue);
    final enabled = SponsorSegmentType.values.where((type) => type
        .isEnabled(settingsCubit.state.settings[type.settingsName()]?.value));
    expect(enabled, [SponsorSegmentType.sponsor]);
  });

  test('saved choices override defaults after settings reload', () async {
    await settingsCubit.setUseReturnYoutubeDislike(false);
    for (final type in SponsorSegmentType.values) {
      await settingsCubit
          .saveSetting(SettingsValue(type.settingsName(), 'false'));
    }
    var restored = SettingsState.init();
    expect(restored.useReturnYoutubeDislike, isFalse);
    for (final type in SponsorSegmentType.values) {
      expect(type.isEnabled(restored.settings[type.settingsName()]?.value),
          isFalse);
    }

    await settingsCubit.setUseReturnYoutubeDislike(true);
    await settingsCubit.saveSetting(
        SettingsValue(SponsorSegmentType.intro.settingsName(), 'true'));
    restored = SettingsState.init();
    expect(restored.useReturnYoutubeDislike, isTrue);
    expect(
        SponsorSegmentType.intro.isEnabled(
            restored.settings[SponsorSegmentType.intro.settingsName()]?.value),
        isTrue);
  });

  test('setting and reading settings', () async {
    // testing boolean setting
    await settingsCubit.setUseSearchHistory(true);
    expect(settingsCubit.state.useSearchHistory, true);

    // testing numbers
    await settingsCubit.setSubtitleSize(10);
    expect(settingsCubit.state.subtitleSize, 10);

    //testing strings
    await settingsCubit.setLastSubtitle("en_US");
    expect(settingsCubit.state.lastSubtitles, "en_US");

    // testing skip steps
    await settingsCubit.setSkipStep(skipSteps.first);
    expect(settingsCubit.state.skipStep, skipSteps.first);

    for (int i = 1; i < skipSteps.length; i++) {
      await settingsCubit.changeSkipStep(increase: true);
      expect(settingsCubit.state.skipStep, skipSteps[i]);
    }

    await settingsCubit.changeSkipStep(increase: true);
    // should remain to the max
    expect(settingsCubit.state.skipStep, skipSteps.last);

    await settingsCubit.setSkipStep(skipSteps.last);
    expect(settingsCubit.state.skipStep, skipSteps.last);
    for (int i = skipSteps.length - 2; i > 0; i--) {
      await settingsCubit.changeSkipStep(increase: false);
      expect(settingsCubit.state.skipStep, skipSteps[i]);
    }
  });

  test('Generic set settings method', () async {
    var setting = db.getSettings('test');
    expect(setting, null);

    SettingsValue s = SettingsValue('test', 'yo');
    await settingsCubit.saveSetting(s);
    expect(db.getSettings('test')?.value, 'yo');
  });
}

class _Workmanager extends WorkmanagerPlatform {
  int cancelAllCalls = 0;
  int cancelUniqueCalls = 0;
  int initializeCalls = 0;
  int registrations = 0;
  Completer<void>? cancelPending;
  final cancellationStarted = Completer<void>();

  @override
  Future<void> initialize(Function callbackDispatcher,
      {bool isInDebugMode = false}) async {
    initializeCalls++;
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
  }

  @override
  Future<void> cancelByUniqueName(String uniqueName) async {
    cancelUniqueCalls++;
    if (!cancellationStarted.isCompleted) cancellationStarted.complete();
    await cancelPending?.future;
  }

  @override
  Future<void> registerPeriodicTask(String uniqueName, String taskName,
      {Duration? frequency,
      Duration? flexInterval,
      Map<String, dynamic>? inputData,
      Duration? initialDelay,
      Constraints? constraints,
      ExistingPeriodicWorkPolicy? existingWorkPolicy,
      BackoffPolicy? backoffPolicy,
      Duration? backoffPolicyDelay,
      String? tag}) async {
    registrations++;
  }
}
