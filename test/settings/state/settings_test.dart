import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/search/models/db/search_history_item.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:clipious/workmanager.dart';
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
  setUp(() async {
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
    await settingsCubit.close();
    await appCubit.close();
    await db.close();
    messenger.setMockMethodCallHandler(pathProvider, null);
    await documents.delete(recursive: true);
    WorkmanagerPlatform.instance = originalWorkmanager;
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
  int registrations = 0;
  Completer<void>? cancelPending;
  final cancellationStarted = Completer<void>();

  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
  }

  @override
  Future<void> cancelByUniqueName(String uniqueName) async {
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
