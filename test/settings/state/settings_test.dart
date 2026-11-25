import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/content_mode.dart';
import 'package:clipious/home/models/home_tabs_layout.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/home/models/phone_navigation.dart';
import 'package:clipious/l10n/app_languages.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app;
import 'package:clipious/music/models/device_music_artwork_preferences.dart';
import 'package:clipious/music/models/music_background_playback.dart';
import 'package:clipious/music/models/music_cover_corners.dart';
import 'package:clipious/music/models/music_download_order.dart';
import 'package:clipious/music/models/music_mini_player_preferences.dart';
import 'package:clipious/music/models/music_song_row_swipe_action.dart';
import 'package:clipious/music/models/song_transition.dart';
import 'package:clipious/music/services/music_community_cover_preferences.dart';
import 'package:clipious/music/services/music_lyrics_preferences.dart';
import 'package:clipious/player/models/music_audio_quality.dart';
import 'package:clipious/player/models/video_display_mode.dart';
import 'package:clipious/player/states/player.dart' show PlayerRepeat;
import 'package:clipious/search/models/db/search_history_item.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/app_customizer.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/models/theme_palette.dart';
import 'package:clipious/settings/views/screens/settings.dart';
import 'package:clipious/settings/views/screens/appearance.dart';
import 'package:clipious/settings/views/screens/video_player.dart';
import 'package:clipious/settings/views/tv/screens/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/backup.dart';
import 'package:clipious/utils/interfaces/db.dart';
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
  late _SessionAppCubit appCubit;
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
    appCubit = _SessionAppCubit(AppState(0, null, HomeLayout()));
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

  test('song transitions persist per profile and reject unusable durations',
      () async {
    final other = await db.createProfile('Other listener');
    expect(settingsCubit.state.songTransitionMode, SongTransitionMode.seamless);
    expect(settingsCubit.state.songTransitionSeconds, 3);
    for (final mode in SongTransitionMode.values) {
      await settingsCubit.setSongTransitionMode(mode);
      expect(settingsCubit.state.songTransitionMode, mode);
      expect(SettingsState.init().songTransitionMode, mode);
    }
    await Future.wait([
      settingsCubit.setSongTransitionSeconds(1),
      settingsCubit.setSongTransitionSeconds(10)
    ]);
    expect(SettingsState.init().songTransitionSeconds, 10);
    expect(() => settingsCubit.setSongTransitionSeconds(11), throwsRangeError);
    expect(() => settingsCubit.setSongTransitionSeconds(0), throwsRangeError);
    final backup = UserBackup.parse((await db.exportBackup()).encode());
    await db.useProfile(other.id);
    expect(
        SettingsState.init().songTransitionMode, SongTransitionMode.seamless);
    expect(SettingsState.init().songTransitionSeconds, 3);
    await db.restoreBackup(backup, replace: true);
    expect(
        SettingsState.init().songTransitionMode, SongTransitionMode.crossfade);
    expect(SettingsState.init().songTransitionSeconds, 10);
    for (final invalid in [
      SettingsValue(songTransitionModeSettingName, 'unsupported'),
      SettingsValue(songTransitionSecondsSettingName, '11'),
      SettingsValue(songTransitionSecondsSettingName, '-1'),
      SettingsValue(songTransitionSecondsSettingName, 'NaN'),
    ]) {
      expect(UserBackup.validSetting(invalid), isFalse);
      await db.saveSetting(invalid);
    }
    expect(
        SettingsState.init().songTransitionMode, SongTransitionMode.seamless);
    expect(SettingsState.init().songTransitionSeconds, 3);
  });

  test('Music interruption choices persist per profile and in backups',
      () async {
    final other = await db.createProfile('Other listener');
    (bool, bool, bool, bool) choices(SettingsState state) => (
          state.musicResumeAfterAudioFocusLoss,
          state.musicPauseAtZeroVolume,
          state.musicAutoReconnect,
          state.musicSkipAfterRetryExhaustion,
        );
    const defaults = (true, false, true, false);
    const changed = (false, true, false, true);
    expect(choices(settingsCubit.state), defaults);

    await settingsCubit.setMusicResumeAfterAudioFocusLoss(false);
    await settingsCubit.setMusicPauseAtZeroVolume(true);
    await settingsCubit.setMusicAutoReconnect(false);
    await settingsCubit.setMusicSkipAfterRetryExhaustion(true);
    expect(choices(settingsCubit.state), changed);
    expect(choices(SettingsState.init()), changed);

    final backup = UserBackup.parse((await db.exportBackup()).encode());
    await db.useProfile(other.id);
    expect(choices(SettingsState.init()), defaults);
    await db.restoreBackup(backup, replace: true);
    expect(choices(SettingsState.init()), changed);

    for (final key in [
      musicResumeAfterAudioFocusLossSettingName,
      musicPauseAtZeroVolumeSettingName,
      musicAutoReconnectSettingName,
      musicSkipAfterRetryExhaustionSettingName,
    ]) {
      final oldValue = SettingsValue(key, 'unsupported');
      expect(UserBackup.validSetting(oldValue), isFalse);
      await db.saveSetting(oldValue);
    }
    expect(choices(SettingsState.init()), defaults);
  });

  test('Music background playback choices persist per profile and in backups',
      () async {
    void expectDefaults(SettingsState state) {
      expect(state.musicTaskRemoval, MusicTaskRemoval.stop);
      expect(state.musicAudioOffload, MusicAudioOffload.disabled);
    }

    void expectSelected(SettingsState state) {
      expect(state.musicTaskRemoval, MusicTaskRemoval.keepPlaying);
      expect(state.musicAudioOffload, MusicAudioOffload.whenSupported);
    }

    expectDefaults(settingsCubit.state);
    final other = await db.createProfile('Other listener');
    await settingsCubit.setMusicTaskRemoval(MusicTaskRemoval.keepPlaying);
    await settingsCubit.setMusicAudioOffload(MusicAudioOffload.whenSupported);
    expectSelected(settingsCubit.state);
    expectSelected(SettingsState.init());

    final backup = UserBackup.parse((await db.exportBackup()).encode());
    await db.useProfile(other.id);
    expectDefaults(SettingsState.init());
    await db.restoreBackup(backup, replace: true);
    expectSelected(SettingsState.init());

    for (final name in [
      musicTaskRemovalSettingName,
      musicAudioOffloadSettingName,
    ]) {
      final invalid = SettingsValue(name, 'unknown');
      expect(UserBackup.validSetting(invalid), isFalse);
      await db.saveSetting(invalid);
    }
    expectDefaults(SettingsState.init());
  });

  test('the palette preserves legacy dynamic colors and saves each choice',
      () async {
    expect(settingsCubit.state.themePalette, ThemePalette.neutral);
    await settingsCubit.saveSetting(SettingsValue(dynamicTheme, 'true'));
    expect(settingsCubit.state.themePalette, ThemePalette.dynamicColors);
    for (final palette in ThemePalette.values) {
      await settingsCubit.setThemePalette(palette);
      expect(SettingsState.init().themePalette, palette);
      expect(UserBackup.validSetting(db.getSettings(themePaletteSettingName)!),
          isTrue);
    }
    expect(
        UserBackup.validSetting(
            SettingsValue(themePaletteSettingName, 'unknown')),
        isFalse);
    for (final brightness in Brightness.values) {
      expect(
          ThemePalette.classicPurple.seededScheme(brightness),
          ColorScheme.fromSeed(
              seedColor: const Color(0xff4f0096), brightness: brightness));
      expect(ThemePalette.dynamicColors.seededScheme(brightness),
          ThemePalette.neutral.seededScheme(brightness));
    }
  });

  testWidgets('Appearance selects Classic purple and preserves brightness',
      (tester) async {
    await tester.pumpWidget(BlocProvider<SettingsCubit>.value(
      value: settingsCubit,
      child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AppearanceSettingsScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Color palette'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Classic purple'));
    await tester.pumpAndSettle();
    expect(settingsCubit.state.themePalette, ThemePalette.classicPurple);
    expect(settingsCubit.state.themeMode, ThemeMode.system);
    expect(find.text('Classic purple'), findsOneWidget);
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

  test('legacy home experience values do not force the selected TV destination',
      () async {
    expect(settingsCubit.state.homeContentMode, HomeContentMode.videos);
    for (final value in [
      'videosOnly',
      'musicOnly',
      'videosAndMusic',
      'unknown'
    ]) {
      await settingsCubit
          .saveSetting(SettingsValue(homeExperienceSettingName, value));
      await settingsCubit.setHomeContentMode(HomeContentMode.music);
      expect(SettingsState.init().homeContentMode, HomeContentMode.music);
      await settingsCubit.setHomeContentMode(HomeContentMode.videos);
      expect(SettingsState.init().homeContentMode, HomeContentMode.videos);
    }
  });

  test('Home tabs preserve an explicit empty selection and navigation',
      () async {
    final navigation = PhoneNavigation.defaults()
        .move(PhoneNavigationItem.music, NavigationArea.top)!
        .startAt(PhoneNavigationItem.history);
    await settingsCubit.setPhoneNavigation(navigation);
    final layout = HomeTabsLayout(enabledOrder: [], continueWatching: true);
    await settingsCubit.setHomeTabsLayout(layout);
    final restored = SettingsState.init();
    expect(restored.homeTabsLayout.enabledOrder, isEmpty);
    expect(restored.homeTabsLayout.continueWatching, isTrue);
    expect(restored.phoneNavigation.encode(), navigation.encode());
  });

  test('removing app sections preserves the actual startup destination',
      () async {
    await settingsCubit.setAppLayout([
      HomeDataSource.home,
      HomeDataSource.history,
      HomeDataSource.playlist,
    ]);
    await settingsCubit.selectOnOpen(1);
    final customizer =
        AppCustomizerCubit(settingsCubit.state.appLayout, settingsCubit);
    addTearDown(customizer.close);

    await customizer.updateSource(HomeDataSource.home, false);
    expect(settingsCubit.state.appLayout,
        [HomeDataSource.history, HomeDataSource.playlist]);
    expect(settingsCubit.state.onOpen, 0);
    expect(SettingsState.init().onOpen, 0);

    await customizer.updateSource(HomeDataSource.home, true);
    expect(settingsCubit.state.appLayout[settingsCubit.state.onOpen],
        HomeDataSource.history);

    await customizer.updateSource(HomeDataSource.history, false);
    expect(settingsCubit.state.onOpen, 0);
    expect(settingsCubit.state.appLayout[settingsCubit.state.onOpen],
        HomeDataSource.playlist);
  });

  test('retired experiences preserve video layouts and the music library',
      () async {
    final navigation = PhoneNavigation.defaults()
        .move(PhoneNavigationItem.music, NavigationArea.top)!
        .startAt(PhoneNavigationItem.history);
    await settingsCubit.setPhoneNavigation(navigation);
    await settingsCubit
        .setAppLayout([HomeDataSource.history, HomeDataSource.home]);
    await settingsCubit.setHomeContentMode(HomeContentMode.music);
    const library = '{"likedSongs":[{"videoId":"abcdefghijk"}]}';
    await settingsCubit.saveSetting(SettingsValue('music-library-v1', library));
    final original = SettingsState.init();
    for (final value in ['videosOnly', 'musicOnly', 'videosAndMusic']) {
      await settingsCubit
          .saveSetting(SettingsValue(homeExperienceSettingName, value));
      final restored = SettingsState.init();
      expect(restored.phoneNavigation.encode(), navigation.encode());
      expect(restored.appLayout, original.appLayout);
      expect(restored.homeContentMode, HomeContentMode.music);
      expect(db.getSettings('music-library-v1')?.value, library);
    }
  });

  for (final reorder in [false, true]) {
    test('pending navigation save survives editor close (reorder=$reorder)',
        () async {
      await settingsCubit.setAppLayout([
        HomeDataSource.home,
        HomeDataSource.history,
        HomeDataSource.playlist,
      ]);
      await settingsCubit.selectOnOpen(1);
      final customizer =
          AppCustomizerCubit(settingsCubit.state.appLayout, settingsCubit);
      final database = db;
      final pending = Completer<void>();
      final started = Completer<void>();
      db = _DelayedSettingsDb(database, pending, started);
      final saving = reorder
          ? customizer.reorder(0, 2)
          : customizer.updateSource(HomeDataSource.home, false);
      await started.future;
      await customizer.close();
      db = database;
      pending.complete();
      await saving;
      final restored = SettingsState.init();
      expect(restored.appLayout, [
        HomeDataSource.history,
        HomeDataSource.playlist,
        if (reorder) HomeDataSource.home,
      ]);
      expect(restored.onOpen, 0);
      expect(settingsCubit.state.onOpen, 0);
    });

    test(
        'pending navigation save retains its profile and TV key (reorder=$reorder)',
        () async {
      app.isTv = true;
      final initial = [
        HomeDataSource.home,
        HomeDataSource.history,
        HomeDataSource.playlist,
      ];
      await settingsCubit.setAppLayout(initial);
      await settingsCubit.selectOnOpen(1);
      final customizer = AppCustomizerCubit(initial, settingsCubit);
      addTearDown(customizer.close);
      final database = db;
      final other = await database.createProfile('Other');
      final otherDb = database.forProfile(other.id);
      await otherDb
          .saveSetting(SettingsValue(appLayoutSettingName, 'popular,trending'));
      await otherDb.saveSetting(SettingsValue(onOpenSettingName, '1'));
      final pending = Completer<void>();
      final started = Completer<void>();
      db = _DelayedSettingsDb(database, pending, started);
      final saving = reorder
          ? customizer.reorder(0, 2)
          : customizer.updateSource(HomeDataSource.home, false);
      await started.future;
      db = database;
      await db.useProfile(other.id);
      await fileDb.useProfile(other.id);
      app.isTv = false;
      appCubit.advanceSession();
      await settingsCubit.reloadForProfile();
      pending.complete();
      await saving;
      expect(customizer.state, initial);
      expect(settingsCubit.state.appLayout,
          [HomeDataSource.popular, HomeDataSource.trending]);
      expect(settingsCubit.state.onOpen, 1);
      expect(otherDb.getSettings(tvAppLayoutSettingName), isNull);
      final original = database.forProfile('default');
      expect(original.getSettings(tvAppLayoutSettingName)?.value,
          reorder ? 'history,playlist,home' : 'history,playlist');
      expect(original.getSettings(appLayoutSettingName), isNull);
      expect(original.getSettings(onOpenSettingName)?.value, '0');
    });
  }

  test('pending navigation save cannot emit into a later owner session',
      () async {
    await settingsCubit
        .setAppLayout([HomeDataSource.home, HomeDataSource.history]);
    await settingsCubit.selectOnOpen(1);
    final customizer =
        AppCustomizerCubit(settingsCubit.state.appLayout, settingsCubit);
    addTearDown(customizer.close);
    final database = db;
    final pending = Completer<void>();
    final started = Completer<void>();
    db = _DelayedSettingsDb(database, pending, started);
    final saving = customizer.updateSource(HomeDataSource.home, false);
    await started.future;
    db = database;
    appCubit.advanceSession();
    await settingsCubit.reloadForProfile();
    pending.complete();
    await saving;
    expect(customizer.state, [HomeDataSource.home, HomeDataSource.history]);
    expect(settingsCubit.state.onOpen, 1);
    expect(SettingsState.init().onOpen, 0);
  });

  test('each profile restores its own Home tabs and last selected TV mode',
      () async {
    final first = HomeTabsLayout(
        enabledOrder: [HomeTabsLayout.yourFeeds], continueWatching: true);
    final second = HomeTabsLayout(enabledOrder: []);
    await settingsCubit.setHomeContentMode(HomeContentMode.music);
    await settingsCubit.setHomeTabsLayout(first);
    final other = await db.createProfile('Other');
    await db.useProfile(other.id);
    await fileDb.useProfile(other.id);
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.homeTabsLayout.continueWatching, isFalse);
    expect(settingsCubit.state.homeContentMode, HomeContentMode.videos);
    await settingsCubit.setHomeTabsLayout(second);
    await db.useProfile('default');
    await fileDb.useProfile('default');
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.homeTabsLayout.encode(), first.encode());
    expect(settingsCubit.state.homeContentMode, HomeContentMode.music);
    await db.useProfile(other.id);
    await fileDb.useProfile(other.id);
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.homeTabsLayout.encode(), second.encode());
    expect(settingsCubit.state.homeContentMode, HomeContentMode.videos);
  });

  test('pending Home tab saves remain with their owner after profile switch',
      () async {
    final database = db;
    final other = await database.createProfile('Other');
    final pending = Completer<void>();
    final started = Completer<void>();
    db = _DelayedSettingsDb(database, pending, started);
    final layout = HomeTabsLayout(enabledOrder: [], continueWatching: true);
    final saving = settingsCubit.setHomeTabsLayout(layout);
    await started.future;
    db = database;
    await db.useProfile(other.id);
    await fileDb.useProfile(other.id);
    await settingsCubit.reloadForProfile();
    pending.complete();
    await saving;
    expect(settingsCubit.state.homeTabsLayout.continueWatching, isFalse);
    expect(db.getSettings(homeTabsLayoutSettingName), isNull);
    expect(
        database
            .forProfile('default')
            .getSettings(homeTabsLayoutSettingName)
            ?.value,
        layout.encode());
  });

  test(
      'pending Home tab saves cannot emit into a later session for the same profile',
      () async {
    final database = db;
    final pending = Completer<void>();
    final started = Completer<void>();
    db = _DelayedSettingsDb(database, pending, started);
    final layout = HomeTabsLayout(enabledOrder: [], continueWatching: true);
    final saving = settingsCubit.setHomeTabsLayout(layout);
    await started.future;
    db = database;
    appCubit.advanceSession();
    await settingsCubit.reloadForProfile();
    pending.complete();
    await saving;
    expect(settingsCubit.state.homeTabsLayout.continueWatching, isFalse);
    expect(SettingsState.init().homeTabsLayout.encode(), layout.encode());
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
    await settingsCubit.setRememberVideoQuality(false);
    final other = await db.createProfile('Other');
    await db.useProfile(other.id);
    await fileDb.useProfile(other.id);

    await settingsCubit.reloadForProfile();

    expect(settingsCubit.state.rememberVideoQuality, isTrue);
    expect(settingsCubit.state.packageInfo.appName, info.appName);
    expect(settingsCubit.state.packageInfo.packageName, info.packageName);
    expect(settingsCubit.state.packageInfo.version, info.version);
    expect(settingsCubit.state.packageInfo.buildNumber, info.buildNumber);
  });

  test('legacy speed is inherited until each mode saves its own adjustments',
      () async {
    await settingsCubit.saveSetting(SettingsValue(lastSpeedSettingName, '1.5'));
    expect(settingsCubit.state.playbackSpeed(music: false), 1.5);
    expect(settingsCubit.state.playbackSpeed(music: true), 1.5);
    expect(settingsCubit.state.playbackPitch(music: true), 0);
    final database = db;
    final pending = Completer<void>();
    db = _DelayedSettingsDb(database, pending, Completer<void>());
    try {
      final writes = [
        settingsCubit.setLastSpeed(1.75),
        settingsCubit.setLastPitch(2, music: false),
      ];
      expect(settingsCubit.state.playbackSpeed(music: true), 1.5);
      expect(settingsCubit.state.playbackSpeed(music: false), 1.75);
      expect(settingsCubit.state.playbackPitch(music: false), 2);
      writes.addAll([
        settingsCubit.setLastSpeed(0.8, music: true),
        settingsCubit.setLastSpeed(0.9, music: true),
        settingsCubit.setLastPitch(-3, music: true),
      ]);
      expect(settingsCubit.state.playbackSpeed(music: true), 0.9);
      expect(settingsCubit.state.playbackPitch(music: true), -3);
      pending.complete();
      await Future.wait(writes);
    } finally {
      if (!pending.isCompleted) pending.complete();
      db = database;
    }
    final reloaded = SettingsState.init();
    expect(reloaded.playbackSpeed(music: false), 1.75);
    expect(reloaded.playbackPitch(music: false), 2);
    expect(reloaded.playbackSpeed(music: true), 0.9);
    expect(reloaded.playbackPitch(music: true), -3);
    expect(db.getSettings(lastSpeedSettingName)?.value, '1.5');
  });

  test('an unusable native speed falls back without rejecting old backups',
      () async {
    final legacy = SettingsValue(lastSpeedSettingName, '1e-300');
    expect(UserBackup.validSetting(legacy), isTrue);
    await settingsCubit.saveSetting(legacy);
    expect(SettingsState.init().playbackSpeed(music: false), 1.0);
    expect(SettingsState.init().playbackSpeed(music: true), 1.0);

    await settingsCubit.saveSetting(SettingsValue(lastSpeedSettingName, '9.0'));
    await settingsCubit
        .saveSetting(SettingsValue(musicSpeedSettingName, '1e-300'));
    expect(SettingsState.init().playbackSpeed(music: true), 9.0);
  });

  test('pending playback preferences stay pinned to their original profile',
      () async {
    final database = db;
    final original = database.forProfile(database.profileId);
    final other = await database.createProfile('Other');
    final pending = Completer<void>();
    db = _DelayedSettingsDb(original, pending, Completer<void>());
    final saved = settingsCubit.setLastPitch(-4, music: true);
    db = database;
    await database.useProfile(other.id);
    appCubit.advanceSession();
    await settingsCubit.reloadForProfile();
    pending.complete();
    await saved;
    expect(settingsCubit.state.playbackPitch(music: true), 0);
    expect(database.getSettings(musicPitchSettingName), isNull);
    expect(original.getSettings(musicPitchSettingName)?.value, '-4');
  });

  test('a failed playback preference save restores the previous choice',
      () async {
    await settingsCubit.setLastPitch(1, music: true);
    final database = db;
    final pending = Completer<void>(), started = Completer<void>();
    db = _DelayedSettingsDb(database, pending, started);
    final failed = expectLater(
        settingsCubit.setLastPitch(-4, music: true), throwsStateError);
    await started.future;
    expect(settingsCubit.state.playbackPitch(music: true), -4);
    pending.completeError(StateError('write failed'));
    await failed;
    db = database;
    expect(settingsCubit.state.playbackPitch(music: true), 1);
    expect(SettingsState.init().playbackPitch(music: true), 1);
  });

  test('Music download formats default to MP3 and belong to each profile',
      () async {
    final first = db.forProfile(db.profileId);
    final otherProfile = await db.createProfile('Other');
    expect(MusicDownloadFormat.forDatabase(first), MusicDownloadFormat.mp3);
    await first
        .saveSetting(SettingsValue(musicDownloadFormatSettingName, 'flac'));
    expect(MusicDownloadFormat.forDatabase(first), MusicDownloadFormat.mp3);
    await setLrclibEnabled(true);
    for (final format in MusicDownloadFormat.values) {
      await format.save(first);
      expect(MusicDownloadFormat.forDatabase(first), format);
      expect(first.getSettings(musicDownloadFormatSettingName)?.value,
          format.name);
    }
    expect(isLrclibEnabled(), isTrue);
    expect(isCommunityCoverArtEnabled(), isFalse);
    await MusicDownloadFormat.m4a.save(first);
    await db.useProfile(otherProfile.id);
    expect(MusicDownloadFormat.forDatabase(db), MusicDownloadFormat.mp3);
    await MusicDownloadFormat.opus.save(db);
    expect(MusicDownloadFormat.forDatabase(db), MusicDownloadFormat.opus);
    expect(MusicDownloadFormat.forDatabase(first), MusicDownloadFormat.m4a);
    expect(isLrclibEnabled(), isFalse);
    expect(isCommunityCoverArtEnabled(), isFalse);
  });

  test('artwork swipes default on and restore only an explicit boolean',
      () async {
    final original = db.forProfile(db.profileId);
    expect(settingsCubit.state.musicArtworkSwipe, isTrue);
    await settingsCubit.setMusicArtworkSwipe(false);
    expect(settingsCubit.state.musicArtworkSwipe, isFalse);
    final backup = UserBackup.parse((await db.exportBackup()).encode());

    final other = await db.createProfile('Other');
    await db.useProfile(other.id);
    appCubit.advanceSession();
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.musicArtworkSwipe, isTrue);
    await db.restoreBackup(backup, replace: false);
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.musicArtworkSwipe, isFalse);
    final bad = SettingsValue(musicArtworkSwipeSettingName, 'off');
    expect(UserBackup.validSetting(bad), isFalse);
    await db.saveSetting(bad);
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.musicArtworkSwipe, isTrue);
    await settingsCubit.setMusicArtworkSwipe(true);
    expect(db.getSettings(musicArtworkSwipeSettingName)?.value, 'true');
    expect(original.getSettings(musicArtworkSwipeSettingName)?.value, 'false');
  });

  test('artwork double-tap seeking is opt-in and follows its profile',
      () async {
    final original = db.forProfile(db.profileId);
    expect(settingsCubit.state.musicArtworkDoubleTapSeek, isFalse);
    await settingsCubit.setMusicArtworkDoubleTapSeek(true);
    expect(settingsCubit.state.musicArtworkDoubleTapSeek, isTrue);
    final backup = UserBackup.parse((await db.exportBackup()).encode());

    final other = await db.createProfile('Other');
    await db.useProfile(other.id);
    appCubit.advanceSession();
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.musicArtworkDoubleTapSeek, isFalse);
    await db.restoreBackup(backup, replace: false);
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.musicArtworkDoubleTapSeek, isTrue);

    final malformed =
        SettingsValue(musicArtworkDoubleTapSeekSettingName, 'yes');
    expect(UserBackup.validSetting(malformed), isFalse);
    await db.saveSetting(malformed);
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.musicArtworkDoubleTapSeek, isFalse);
    await settingsCubit.setMusicArtworkDoubleTapSeek(false);
    expect(
        db.getSettings(musicArtworkDoubleTapSeekSettingName)?.value, 'false');
    expect(original.getSettings(musicArtworkDoubleTapSeekSettingName)?.value,
        'true');
  });

  test('song-row swipe choices default off and round-trip by profile',
      () async {
    const next = MusicSongRowSwipeAction.playNext;
    const append = MusicSongRowSwipeAction.addToQueue;
    const off = MusicSongRowSwipeAction.off;
    expect(settingsCubit.state.musicSongSwipeTowardEnd, off);
    expect(settingsCubit.state.musicSongSwipeTowardStart, off);
    await settingsCubit.setMusicSongSwipeTowardEnd(next);
    await settingsCubit.setMusicSongSwipeTowardStart(append);
    final backup = UserBackup.parse((await db.exportBackup()).encode());

    final other = await db.createProfile('Other');
    await db.useProfile(other.id);
    appCubit.advanceSession();
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.musicSongSwipeTowardEnd, off);
    expect(settingsCubit.state.musicSongSwipeTowardStart, off);
    await db.restoreBackup(backup, replace: false);
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.musicSongSwipeTowardEnd, next);
    expect(settingsCubit.state.musicSongSwipeTowardStart, append);

    final malformed = SettingsValue(musicSongSwipeTowardEndSettingName, 'true');
    expect(UserBackup.validSetting(malformed), isFalse);
    await db.saveSetting(malformed);
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.musicSongSwipeTowardEnd, off);
    expect(settingsCubit.state.musicSongSwipeTowardStart, append);
  });

  test('mini-player settings follow the profile and round-trip through backup',
      () async {
    final original = db.forProfile(db.profileId);
    await settingsCubit
        .setMusicMiniPlayerLayout(MusicMiniPlayerLayout.transport);
    await Future.wait([
      settingsCubit.setMusicMiniPlayerShortcut(MusicMiniPlayerShortcut.repeat),
      settingsCubit.setMusicMiniPlayerShortcut(MusicMiniPlayerShortcut.shuffle),
    ]);
    expect(settingsCubit.state.musicMiniPlayerLayout,
        MusicMiniPlayerLayout.transport);
    expect(settingsCubit.state.musicMiniPlayerShortcut,
        MusicMiniPlayerShortcut.shuffle);
    final backup = UserBackup.parse((await db.exportBackup()).encode());

    final other = await db.createProfile('Other');
    await db.useProfile(other.id);
    appCubit.advanceSession();
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.musicMiniPlayerLayout,
        MusicMiniPlayerLayout.automatic);
    expect(settingsCubit.state.musicMiniPlayerShortcut,
        MusicMiniPlayerShortcut.automatic);
    await db.restoreBackup(backup, replace: false);
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.musicMiniPlayerLayout,
        MusicMiniPlayerLayout.transport);
    expect(settingsCubit.state.musicMiniPlayerShortcut,
        MusicMiniPlayerShortcut.shuffle);

    for (final key in [
      musicMiniPlayerLayoutSettingName,
      musicMiniPlayerShortcutSettingName
    ]) {
      final bad = SettingsValue(key, 'unknown');
      expect(UserBackup.validSetting(bad), isFalse);
      await db.saveSetting(bad);
    }
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.musicMiniPlayerLayout,
        MusicMiniPlayerLayout.automatic);
    expect(settingsCubit.state.musicMiniPlayerShortcut,
        MusicMiniPlayerShortcut.automatic);
    expect(original.getSettings(musicMiniPlayerShortcutSettingName)?.value,
        'shuffle');
  });

  test('queued mini-player writes cannot update a replacement profile',
      () async {
    final database = db;
    final original = database.forProfile(database.profileId);
    final other = await database.createProfile('Other');
    final pending = Completer<void>();
    final started = Completer<void>();
    db = _DelayedSettingsDb(original, pending, started);
    final first =
        settingsCubit.setMusicMiniPlayerLayout(MusicMiniPlayerLayout.compact);
    await started.future;
    final second =
        settingsCubit.setMusicMiniPlayerLayout(MusicMiniPlayerLayout.transport);
    db = database;
    await database.useProfile(other.id);
    appCubit.advanceSession();
    pending.complete();
    await Future.wait([first, second]);
    expect(settingsCubit.state.musicMiniPlayerLayout,
        MusicMiniPlayerLayout.automatic);
    expect(database.getSettings(musicMiniPlayerLayoutSettingName), isNull);
    expect(original.getSettings(musicMiniPlayerLayoutSettingName)?.value,
        'compact');
  });

  test('Music Downloads order follows the profile and survives backup',
      () async {
    const initial = MusicDownloadOrder();
    const byArtist = MusicDownloadOrder(
        field: MusicDownloadSortField.artist, descending: true);
    final original = db.forProfile(db.profileId);
    expect(settingsCubit.state.musicDownloadOrder, initial);
    expect(original.getSettings(musicDownloadOrderSettingName), isNull);
    await Future.wait([
      settingsCubit.updateMusicDownloadOrder(
          field: MusicDownloadSortField.artist),
      settingsCubit.updateMusicDownloadOrder(descending: true),
    ]);
    expect(settingsCubit.state.musicDownloadOrder, byArtist);
    final backup = UserBackup.parse((await db.exportBackup()).encode());
    final other = await db.createProfile('Other');
    await db.useProfile(other.id);
    appCubit.advanceSession();
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.musicDownloadOrder, initial);
    await db.restoreBackup(backup, replace: false);
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.musicDownloadOrder, byArtist);

    final malformed =
        SettingsValue(musicDownloadOrderSettingName, 'artist:sideways');
    final invalid = jsonDecode(backup.encode()) as Map<String, dynamic>;
    invalid['settings'] = [malformed.toJson()];
    expect(() => UserBackup.parse(jsonEncode(invalid)), throwsFormatException);
    await db.saveSetting(malformed);
    await settingsCubit.reloadForProfile();
    expect(settingsCubit.state.musicDownloadOrder, initial);
    expect(original.getSettings(musicDownloadOrderSettingName)?.value,
        byArtist.encode());
  });

  test('queued Music Downloads order writes stay with their original profile',
      () async {
    const byAlbum = MusicDownloadOrder(field: MusicDownloadSortField.album);
    const byDuration = MusicDownloadOrder(
        field: MusicDownloadSortField.duration, descending: true);
    final database = db;
    final original = database.forProfile(database.profileId);
    final other = await database.createProfile('Other');
    final pending = Completer<void>();
    final started = Completer<void>();
    db = _DelayedSettingsDb(original, pending, started);
    final first = settingsCubit.setMusicDownloadOrder(byAlbum);
    await started.future;
    final second = settingsCubit.setMusicDownloadOrder(byDuration);
    db = database;
    await database.useProfile(other.id);
    appCubit.advanceSession();
    pending.complete();
    await Future.wait([first, second]);
    expect(settingsCubit.state.musicDownloadOrder, const MusicDownloadOrder());
    expect(database.getSettings(musicDownloadOrderSettingName), isNull);
    expect(original.getSettings(musicDownloadOrderSettingName)?.value,
        byAlbum.encode());
  });

  test('Music streaming quality belongs to the profile and survives backup',
      () async {
    final first = db.forProfile(db.profileId);
    expect(
        settingsCubit.state.musicStreamingQuality, MusicStreamingQuality.auto);
    await settingsCubit
        .setMusicStreamingQuality(MusicStreamingQuality.dataSaver);
    expect(settingsCubit.state.musicStreamingQuality,
        MusicStreamingQuality.dataSaver);

    final backup = UserBackup.parse((await db.exportBackup()).encode());
    final other = await db.createProfile('Other');
    await db.useProfile(other.id);
    expect(MusicStreamingQuality.forDatabase(db), MusicStreamingQuality.auto);
    await db.restoreBackup(backup, replace: false);
    expect(
        MusicStreamingQuality.forDatabase(db), MusicStreamingQuality.dataSaver);

    await db.saveSetting(SettingsValue(
        musicStreamingQualitySettingName, MusicStreamingQuality.highest.name));
    expect(
        MusicStreamingQuality.forDatabase(db), MusicStreamingQuality.highest);
    expect(MusicStreamingQuality.forDatabase(first),
        MusicStreamingQuality.dataSaver);
    expect(
        UserBackup.validSetting(
            SettingsValue(musicStreamingQualitySettingName, 'invalid')),
        isFalse);
  });

  test('portable backups restore the format and reject unknown values',
      () async {
    await MusicDownloadFormat.opus.save(db);
    await setLrclibEnabled(true);
    final exported = await db.exportBackup();
    final backup = UserBackup.parse(exported.encode());
    final format = backup.sections['settings']!
        .singleWhere((row) => row['name'] == musicDownloadFormatSettingName);
    expect(format['value'], 'opus');
    final target = await db.createProfile('Target');
    await db.useProfile(target.id);
    await MusicDownloadFormat.m4a.save(db);
    await setCommunityCoverArtEnabled(true);
    await db.restoreBackup(backup, replace: true);
    expect(MusicDownloadFormat.forDatabase(db), MusicDownloadFormat.opus);
    expect(isLrclibEnabled(), isFalse);
    expect(isCommunityCoverArtEnabled(), isTrue);

    final malformed = jsonDecode(exported.encode()) as Map<String, dynamic>;
    malformed['settings'] = [
      SettingsValue(musicDownloadFormatSettingName, 'flac').toJson(),
    ];
    expect(
        () => UserBackup.parse(jsonEncode(malformed)), throwsFormatException);
  });

  test('LRCLIB consent defaults off and is stored only for its profile',
      () async {
    final first = db.profileId;
    final other = await db.createProfile('Other');
    expect(isLrclibEnabled(), isFalse);
    final write = setLrclibEnabled(true, expectedProfileId: first);
    await db.useProfile(other.id);
    await write;
    expect(isLrclibEnabled(), isFalse);
    await setLrclibEnabled(true, expectedProfileId: first);
    expect(isLrclibEnabled(), isFalse);
    await db.useProfile(first);
    expect(isLrclibEnabled(), isTrue);
    final backup = await db.exportBackup();
    expect(backup.sections['settings']!.map((row) => row['name']),
        isNot(contains('music-lrclib-enabled')));
    await setLrclibEnabled(false);
    expect(isLrclibEnabled(), isFalse);
  });

  test('cover consent stays in its profile and cannot be transferred by backup',
      () async {
    final first = db.profileId;
    final other = await db.createProfile('Other');
    expect(isCommunityCoverArtEnabled(), isFalse);
    final revision = communityCoverArtPreferenceRevision.value;
    await setLrclibEnabled(true);
    expect(communityCoverArtPreferenceRevision.value, revision);
    await setCommunityCoverArtEnabled(true);
    expect(communityCoverArtPreferenceRevision.value, revision + 1);
    await setCommunityCoverArtEnabled(false);
    final writing = setCommunityCoverArtEnabled(true, expectedProfileId: first);
    await db.useProfile(other.id);
    await writing;
    expect(isCommunityCoverArtEnabled(), isFalse);
    final otherRevision = communityCoverArtPreferenceRevision.value;
    await setCommunityCoverArtEnabled(true, expectedProfileId: first);
    expect(isCommunityCoverArtEnabled(), isFalse);
    expect(communityCoverArtPreferenceRevision.value, otherRevision);
    await db.useProfile(first);
    expect(isCommunityCoverArtEnabled(), isTrue);
    final backup = jsonDecode((await db.exportBackup()).encode()) as Map;
    expect((backup['settings'] as List).map((row) => row['name']),
        isNot(contains(musicCommunityCoverSettingName)));
    backup['settings'] = [
      SettingsValue(musicCommunityCoverSettingName, 'true').toJson()
    ];
    expect(() => UserBackup.parse(jsonEncode(backup)), throwsFormatException);
    await setCommunityCoverArtEnabled(false);
    expect(isLrclibEnabled(), isTrue);
  });

  for (final (provider, read, write, revision) in [
    ('lyrics', isLrclibEnabled, setLrclibEnabled, lrclibPreferenceRevision),
    (
      'covers',
      isCommunityCoverArtEnabled,
      setCommunityCoverArtEnabled,
      communityCoverArtPreferenceRevision
    ),
  ]) {
    test('$provider opt-out blocks requests before its write completes',
        () async {
      final database = db;
      await write(true);
      final pending = Completer<void>();
      final started = Completer<void>();
      db = _DelayedSettingsDb(database, pending, started);
      try {
        expect(read(), isTrue);
        final before = revision.value;
        final disabling = write(false);
        await started.future;
        expect(read(), isFalse);
        expect(revision.value, greaterThan(before));
        pending.complete();
        await disabling;
        expect(read(), isFalse);
      } finally {
        if (!pending.isCompleted) pending.complete();
        db = database;
      }
    });

    test('$provider finishing a write cannot invalidate another profile',
        () async {
      final database = db;
      final other = await database.createProfile('Other');
      final pending = Completer<void>();
      final started = Completer<void>();
      db = _DelayedSettingsDb(database, pending, started);
      try {
        final saving = write(true);
        await started.future;
        await database.useProfile(other.id);
        final before = revision.value;
        pending.complete();
        await saving;
        expect(revision.value, before);
        expect(read(), isFalse);
      } finally {
        if (!pending.isCompleted) pending.complete();
        db = database;
      }
    });
  }

  for (final (name, screen) in const [
    ('phone', SettingsScreen()),
    ('TV', TVSettingsScreen()),
  ]) {
    Future<void> showSettings(WidgetTester tester, String settingKey,
        {double? width}) async {
      tester.view.physicalSize =
          Size(width ?? (name == 'TV' ? 1280 : 360), 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MultiBlocProvider(
          providers: [
            BlocProvider<AppCubit>.value(value: appCubit),
            BlocProvider.value(value: settingsCubit),
          ],
          child: MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: screen)));
      await tester.pumpAndSettle();
      // The section heading and its controls mount as separate TV list items.
      await tester.scrollUntilVisible(find.byKey(ValueKey(settingKey)), 400,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
    }

    testWidgets(
        '$name YT Music settings keep cover and lyrics opt-ins independent',
        (tester) async {
      await showSettings(tester, 'music-community-cover-setting');
      final lyrics = find.byKey(const ValueKey('music-lrclib-setting'));
      final cover = find.byKey(const ValueKey('music-community-cover-setting'));
      await tester.ensureVisible(cover);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(lyrics).value, isFalse);
      expect(tester.widget<SwitchListTile>(cover).value, isFalse);
      await tester.runAsync(() => setLrclibEnabled(true));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(lyrics).value, isTrue);
      expect(tester.widget<SwitchListTile>(cover).value, isFalse);
      if (name == 'TV') {
        Focus.of(tester.element(find.text('Use LRCLIB for lyrics')))
            .requestFocus();
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        expect(isCommunityCoverArtEnabled(), isTrue);
        // Simulate alternate remote OK keys using a Flutter key map which
        // defines both names. The widget and focus traversal still use TV UI.
        for (final (key, expected) in [
          (LogicalKeyboardKey.accept, false),
          (LogicalKeyboardKey.open, true),
        ]) {
          await tester.sendKeyEvent(key,
              platform: 'web', physicalKey: PhysicalKeyboardKey.select);
          await tester.pumpAndSettle();
          expect(isCommunityCoverArtEnabled(), expected);
        }
      } else {
        await tester.tap(cover);
      }
      await tester.pumpAndSettle();
      expect(isCommunityCoverArtEnabled(), isTrue);
      expect(tester.widget<SwitchListTile>(cover).value, isTrue);
      await tester.ensureVisible(lyrics);
      await tester.pumpAndSettle();
      await tester.tap(lyrics);
      await tester.pumpAndSettle();
      expect(isLrclibEnabled(), isFalse);
      expect(isCommunityCoverArtEnabled(), isTrue);
    });

    for (final width in name == 'TV' ? [1280.0] : [360.0, 800.0]) {
      final surface = width == 800 ? 'tablet' : name;
      testWidgets('$surface edits automatic song transitions in YT Music',
          (tester) async {
        final tv = name == 'TV';
        app.isTv = tv;
        await showSettings(tester, 'music-transition-setting', width: width);
        Finder keyed(String key) => find.byKey(ValueKey(key));
        final setting = keyed('music-transition-setting');
        final duration = keyed('music-transition-duration-setting');
        Future<void> open(Finder tile) async {
          await tester.ensureVisible(tile);
          await tester.pumpAndSettle();
          if (tv) {
            final label =
                find.descendant(of: tile, matching: find.byType(Text)).first;
            Focus.of(tester.element(label)).requestFocus();
            await tester.pumpAndSettle();
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
          } else {
            await tester.tap(tile);
          }
          await tester.pumpAndSettle();
        }

        Future<void> choose(String key, int steps) async {
          if (tv) {
            final direction = steps > 0
                ? LogicalKeyboardKey.arrowDown
                : LogicalKeyboardKey.arrowUp;
            for (var i = 0; i < steps.abs(); i++) {
              await tester.sendKeyEvent(direction);
              await tester.pumpAndSettle();
            }
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
          } else {
            await tester.ensureVisible(keyed(key));
            await tester.tap(keyed(key));
          }
          await tester.pumpAndSettle();
        }

        expect(settingsCubit.state.songTransitionMode,
            SongTransitionMode.seamless);
        expect(duration, findsNothing);
        await tester.ensureVisible(setting);
        await tester.pumpAndSettle();
        expect(tester.getSemantics(find.text('Song transition options')).label,
            allOf(contains('Seamless'), contains('automatically')));
        await open(setting);
        for (final mode in SongTransitionMode.values) {
          expect(keyed('music-transition-${mode.name}'), findsOneWidget);
        }
        await choose('music-transition-pause', 1);
        expect(
            settingsCubit.state.songTransitionMode, SongTransitionMode.pause);
        expect(find.descendant(of: duration, matching: find.text('3 seconds')),
            findsOneWidget);
        await open(duration);
        for (var seconds = 1; seconds <= 10; seconds++) {
          expect(keyed('music-transition-seconds-$seconds'), findsOneWidget);
        }
        expect(keyed('music-transition-seconds-0'), findsNothing);
        expect(keyed('music-transition-seconds-11'), findsNothing);
        final seconds = tv ? 1 : 10;
        await choose('music-transition-seconds-$seconds', seconds - 3);
        expect(SettingsState.init().songTransitionSeconds, seconds);

        for (final mode in [
          SongTransitionMode.fade,
          SongTransitionMode.crossfade
        ]) {
          await open(setting);
          await choose('music-transition-${mode.name}', 1);
          expect(SettingsState.init().songTransitionMode, mode);
          expect(settingsCubit.state.songTransitionSeconds, seconds);
        }
        await open(setting);
        if (tv) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        } else {
          await tester.tap(find.text('Cancel'));
        }
        await tester.pumpAndSettle();
        expect(keyed('music-transition-fade'), findsNothing);
        expect(SettingsState.init().songTransitionMode,
            SongTransitionMode.crossfade);
        await open(setting);
        await choose('music-transition-seamless', -3);
        expect(settingsCubit.state.songTransitionMode,
            SongTransitionMode.seamless);
        expect(duration, findsNothing);
      });
    }

    testWidgets('$name chooses a Music streaming quality default',
        (tester) async {
      await showSettings(tester, 'music-streaming-quality-setting');
      final setting =
          find.byKey(const ValueKey('music-streaming-quality-setting'));
      await tester.ensureVisible(setting);
      await tester.pumpAndSettle();
      final dataSaver =
          find.byKey(const ValueKey('music-streaming-quality-dataSaver'));
      if (name == 'TV') {
        Focus.of(tester.element(find.text('Streaming audio quality')))
            .requestFocus();
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        expect(dataSaver, findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
      } else {
        await tester.tap(setting);
        await tester.pumpAndSettle();
        await tester.tap(dataSaver);
      }
      await tester.pumpAndSettle();
      expect(MusicStreamingQuality.forDatabase(db),
          MusicStreamingQuality.dataSaver);
      expect(find.descendant(of: setting, matching: find.text('Data saver')),
          findsOneWidget);
    });

    testWidgets('$name chooses square Music cover corners', (tester) async {
      await showSettings(tester, 'music-cover-corners-setting');
      final setting = find.byKey(const ValueKey('music-cover-corners-setting'));
      await tester.ensureVisible(setting);
      await tester.pumpAndSettle();
      expect(find.descendant(of: setting, matching: find.text('Rounded')),
          findsOneWidget);

      if (name == 'TV') {
        Focus.of(tester.element(find.text('Cover corners'))).requestFocus();
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
      } else {
        await tester.tap(setting);
        await tester.pumpAndSettle();
        await tester
            .tap(find.byKey(const ValueKey('music-cover-corners-square')));
      }
      await tester.pumpAndSettle();
      expect(MusicCoverCorners.forDatabase(db), MusicCoverCorners.square);
      expect(find.descendant(of: setting, matching: find.text('Square')),
          findsOneWidget);
    });

    testWidgets('$name chooses device artwork source, quality and fit',
        (tester) async {
      app.isTv = name == 'TV';
      await showSettings(tester, 'device-music-artwork-source-setting');
      for (final (choice, title, initial, option, selected) in const [
        (
          'source',
          'Device artwork source',
          'Prefer folder artwork',
          'embeddedOnly',
          'Embedded artwork only',
        ),
        (
          'quality',
          'Folder artwork quality',
          'Balanced',
          'high',
          'High',
        ),
        (
          'crop',
          'Device artwork fit',
          'Fill and crop',
          'fit',
          'Fit whole image',
        ),
      ]) {
        final key = 'device-music-artwork-$choice';
        final tile = find.byKey(ValueKey('$key-setting'));
        final target = find.byKey(ValueKey('$key-$option'));
        await tester.ensureVisible(tile);
        await tester.pumpAndSettle();
        expect(find.descendant(of: tile, matching: find.text(initial)),
            findsOneWidget);
        if (name == 'TV') {
          Focus.of(tester.element(find.text(title))).requestFocus();
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
          await tester.pumpAndSettle();
          expect(target, findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
        } else {
          await tester.tap(tile);
          await tester.pumpAndSettle();
          await tester.tap(target);
        }
        await tester.pumpAndSettle();
        expect(find.descendant(of: tile, matching: find.text(selected)),
            findsOneWidget);
      }
      final result = DeviceMusicArtworkPreferences.forDatabase(db);
      expect(result.source, DeviceMusicArtworkSource.embeddedOnly);
      expect(result.quality, DeviceMusicArtworkQuality.high);
      expect(result.crop, DeviceMusicArtworkCrop.fit);
    });

    testWidgets('$name selects and cancels the YT Music download format',
        (tester) async {
      await showSettings(tester, 'music-download-format-setting');
      final setting =
          find.byKey(const ValueKey('music-download-format-setting'));
      await tester.pumpAndSettle();
      final formatNode =
          tester.getSemantics(find.text('Music download format'));
      expect(formatNode.rect.size, tester.getSize(setting));
      expect(formatNode.label, contains('MP3'));
      await tester.ensureVisible(setting);
      await tester.pumpAndSettle();
      Future<void> openFormatChoice() async {
        if (name == 'TV') {
          Focus.of(tester.element(find.descendant(
                  of: setting, matching: find.text('Music download format'))))
              .requestFocus();
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
        } else {
          await tester.tap(setting);
        }
        await tester.pumpAndSettle();
      }

      expect(find.descendant(of: setting, matching: find.text('MP3')),
          findsOneWidget);
      await openFormatChoice();
      for (final (format, label) in const [
        (MusicDownloadFormat.mp3, 'MP3'),
        (MusicDownloadFormat.opus, 'Opus (Best quality)'),
        (MusicDownloadFormat.m4a, 'M4A (AAC)'),
      ]) {
        final row =
            find.byKey(ValueKey('music-download-format-${format.name}'));
        expect(find.descendant(of: row, matching: find.text(label)),
            findsOneWidget);
      }
      final opus = find.byKey(const ValueKey('music-download-format-opus'));
      if (name == 'TV') {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
      } else {
        await tester.tap(opus);
      }
      await tester.pumpAndSettle();
      expect(MusicDownloadFormat.forDatabase(db), MusicDownloadFormat.opus);
      expect(
          find.descendant(
              of: setting, matching: find.text('Opus (Best quality)')),
          findsOneWidget);
      await openFormatChoice();
      if (name == 'TV') {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        await tester.tap(find.text('Cancel'));
      }
      await tester.pumpAndSettle();
      expect(opus, findsNothing);
      expect(MusicDownloadFormat.forDatabase(db), MusicDownloadFormat.opus);
      expect(isLrclibEnabled(), isFalse);
      expect(isCommunityCoverArtEnabled(), isFalse);
    });
  }

  for (final (name, screen) in const [
    ('phone', VideoPlayerSettingsScreen()),
    ('TV', TVSettingsScreen()),
  ]) {
    testWidgets('$name playback settings offer no direct playback opt-out',
        (tester) async {
      await tester.runAsync(() => settingsCubit
          .saveSetting(SettingsValue(useProxySettingName, 'false')));
      tester.view.physicalSize = const Size(1280, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<AppCubit>.value(value: appCubit),
          BlocProvider.value(value: settingsCubit),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: screen,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Use DASH'), findsOneWidget);
      expect(find.text('Skip forward/backward step'), findsOneWidget);
      expect(find.text('Proxy videos'), findsNothing);
    });
  }

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
      PhoneNavigationItem.music,
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
    var layout = PhoneNavigation.defaults()
        .move(PhoneNavigationItem.music, NavigationArea.hidden)!
        .startAt(PhoneNavigationItem.history);
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

  test('older navigation gains Music without disturbing explicit places', () {
    final legacyDefault = PhoneNavigation.decode(
        '{"bottom":["home","subscription","history","search"],'
        '"top":["downloads","queue","playlist"],"startup":"home"}')!;
    expect(legacyDefault.bottom, PhoneNavigation.defaults().bottom);
    expect(legacyDefault.top, PhoneNavigation.defaults().top);

    final full = PhoneNavigation.decode(
        '{"bottom":["history","home","trending","popular","search"],'
        '"top":["downloads","queue"],"startup":"history"}')!;
    expect(full.bottom, [
      PhoneNavigationItem.history,
      PhoneNavigationItem.home,
      PhoneNavigationItem.trending,
      PhoneNavigationItem.popular,
      PhoneNavigationItem.search,
    ]);
    expect(full.top.last, PhoneNavigationItem.music);
    expect(full.startup, PhoneNavigationItem.history);

    final explicitTop =
        PhoneNavigation.decode('{"bottom":["home","history","search"],'
            '"top":["downloads","music","queue"],"startup":"history"}')!;
    expect(explicitTop.top[1], PhoneNavigationItem.music);
    expect(explicitTop.bottom, isNot(contains(PhoneNavigationItem.music)));

    final explicitBottom =
        PhoneNavigation.decode('{"bottom":["music","history","search"],'
            '"top":[],"startup":"history"}')!;
    expect(explicitBottom.bottom.first, PhoneNavigationItem.music);
    expect(explicitBottom.top, isEmpty);
  });

  test('Music can start, move and remain intentionally hidden after a reload',
      () async {
    final layout = PhoneNavigation.defaults()
        .move(PhoneNavigationItem.music, NavigationArea.bottom,
            before: PhoneNavigationItem.home)!
        .startAt(PhoneNavigationItem.music);
    await settingsCubit.setPhoneNavigation(layout);
    final reloaded = SettingsState.init().phoneNavigation;
    expect(reloaded.bottom.first, PhoneNavigationItem.music);
    expect(reloaded.startup, PhoneNavigationItem.music);

    final hidden =
        reloaded.move(PhoneNavigationItem.music, NavigationArea.hidden)!;
    await settingsCubit.setPhoneNavigation(hidden);
    final afterHide = SettingsState.init().phoneNavigation;
    expect(afterHide.hidden, contains(PhoneNavigationItem.music));
    expect(afterHide.startup, PhoneNavigationItem.home);
    expect(afterHide.encode(), hidden.encode());
  });

  test('Videos only falls back safely from Music and Search', () {
    final layout = PhoneNavigation(
        [PhoneNavigationItem.music, PhoneNavigationItem.search], []);
    final available = layout.available(searchHistory: true, music: false);
    expect(available.bottom,
        [PhoneNavigationItem.home, PhoneNavigationItem.search]);
    expect(available.startup, PhoneNavigationItem.home);
    expect(layout.startup, PhoneNavigationItem.music);
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

  test(
      'the language picker has a distinct native name for every supported locale',
      () {
    final names = nativeLanguageNames.values;
    expect(names, everyElement(isNotEmpty));
    expect(names.toSet().length, AppLocalizations.supportedLocales.length);
    expect(parseSavedLocale('null'), isNull);
    expect(parseSavedLocale(''), isNull);
  });

  test('locale changes finish saving to both foreground and background storage',
      () async {
    await settingsCubit.setLocale(const Locale('fr'));

    expect(settingsCubit.state.locale, 'fr');
    expect(SettingsState.init().locale, 'fr');
    expect(await fileDb.getLocale(), 'fr');

    const traditionalChinese =
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
    await settingsCubit.setLocale(traditionalChinese);
    expect(SettingsState.init().locale, 'zh_Hant');
    expect(parseSavedLocale(await fileDb.getLocale()), traditionalChinese);
    expect(settingsCubit.getLocaleDisplayName(), '中文（繁體）');

    await settingsCubit.setLocale(null);

    expect(settingsCubit.state.locale, isNull);
    expect(SettingsState.init().locale, isNull);
    expect(await fileDb.getLocale(), isNull);
  });

  test('legacy or imported locale variants display their effective language',
      () async {
    for (final (key, expected, name) in [
      ('nb_NO', const Locale('nb', 'NO'), 'norsk bokmål'),
      ('fr-CA', const Locale('fr', 'CA'), 'français'),
      (
        'zh_Hans',
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
        '中文'
      ),
      (
        'zh-Hant-TW',
        const Locale.fromSubtags(
            languageCode: 'zh', scriptCode: 'Hant', countryCode: 'TW'),
        '中文（繁體）'
      ),
    ]) {
      await db.saveSetting(SettingsValue(localeSettingName, key));
      final restored = TestSettingsCubit(SettingsState.init(), appCubit);
      try {
        expect(restored.state.locale, key);
        expect(parseSavedLocale(key), expected);
        expect(restored.getLocaleDisplayName(), name);
      } finally {
        await restored.close();
      }
    }
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

  test('display mode honors the legacy toggle and persists each new choice',
      () async {
    expect(settingsCubit.state.videoDisplayMode, VideoDisplayMode.fit);
    await settingsCubit.saveSetting(SettingsValue(fillFullScreen, 'false'));
    expect(SettingsState.init().videoDisplayMode, VideoDisplayMode.fit);
    await settingsCubit.saveSetting(SettingsValue(fillFullScreen, 'true'));
    expect(SettingsState.init().videoDisplayMode, VideoDisplayMode.crop);
    await settingsCubit
        .saveSetting(SettingsValue(videoDisplayModeSettingName, 'unknown'));
    expect(SettingsState.init().videoDisplayMode, VideoDisplayMode.crop);

    for (final mode in VideoDisplayMode.values) {
      await settingsCubit.setVideoDisplayMode(mode);
      expect(settingsCubit.state.videoDisplayMode, mode);
      expect(SettingsState.init().videoDisplayMode, mode);
    }
  });

  test('pending display mode changes stay with the original profile', () async {
    final database = db;
    final other = await database.createProfile('Other');
    final pending = Completer<void>();
    final started = Completer<void>();
    db = _DelayedSettingsDb(database, pending, started);
    final saving = settingsCubit.setVideoDisplayMode(VideoDisplayMode.crop);
    await started.future;
    db = database;
    await db.useProfile(other.id);
    await fileDb.useProfile(other.id);
    await settingsCubit.reloadForProfile();
    pending.complete();
    await saving;

    expect(settingsCubit.state.videoDisplayMode, VideoDisplayMode.fit);
    expect(db.getSettings(videoDisplayModeSettingName), isNull);
    expect(
        database
            .forProfile('default')
            .getSettings(videoDisplayModeSettingName)
            ?.value,
        VideoDisplayMode.crop.name);
  });

  test('hiding comments defaults off and persists each choice', () async {
    expect(settingsCubit.state.hideCommentsByDefault, isFalse);
    for (final value in [true, false]) {
      await settingsCubit.setHideCommentsByDefault(value);
      expect(settingsCubit.state.hideCommentsByDefault, value);
      expect(SettingsState.init().hideCommentsByDefault, value);
    }
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

  test('sponsor and non-music skipping default on alongside dislike counts',
      () {
    expect(settingsCubit.state.useReturnYoutubeDislike, isTrue);
    final enabled = SponsorSegmentType.values.where((type) => type
        .isEnabled(settingsCubit.state.settings[type.settingsName()]?.value));
    expect(enabled,
        [SponsorSegmentType.sponsor, SponsorSegmentType.musicOffTopic]);
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

  test('SponsorBlock defaults and explicit opt-outs stay with each profile',
      () async {
    List<SponsorSegmentType> enabled() => SponsorSegmentType.values
        .where((type) => type.isEnabled(
            settingsCubit.state.settings[type.settingsName()]?.value))
        .toList();

    await settingsCubit.saveSetting(SettingsValue(
        SponsorSegmentType.musicOffTopic.settingsName(), 'false'));
    await settingsCubit.reloadForProfile();
    expect(enabled(), [SponsorSegmentType.sponsor]);

    final other = await db.createProfile('Other');
    await db.useProfile(other.id);
    await fileDb.useProfile(other.id);
    await settingsCubit.reloadForProfile();
    expect(enabled(),
        [SponsorSegmentType.sponsor, SponsorSegmentType.musicOffTopic]);

    await settingsCubit.saveSetting(
        SettingsValue(SponsorSegmentType.sponsor.settingsName(), 'false'));
    await settingsCubit.reloadForProfile();
    expect(enabled(), [SponsorSegmentType.musicOffTopic]);

    await db.useProfile('default');
    await fileDb.useProfile('default');
    await settingsCubit.reloadForProfile();
    expect(enabled(), [SponsorSegmentType.sponsor]);
    expect(
        db.getSettings(SponsorSegmentType.musicOffTopic.settingsName())?.value,
        'false');
    expect(db.getSettings(SponsorSegmentType.sponsor.settingsName()), isNull);
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

  test('rapid Repeat taps advance once per input while persistence is busy',
      () async {
    final database = db;
    final pending = Completer<void>();
    final started = Completer<void>();
    db = _DelayedSettingsDb(database, pending, started);
    final first = settingsCubit.setNextRepeatMode();
    await started.future;
    final second = settingsCubit.setNextRepeatMode();
    pending.complete();
    await Future.wait([first, second]);
    db = database;
    expect(settingsCubit.state.playerRepeatMode, PlayerRepeat.repeatOne);
    expect(database.getSettings(playerRepeat)?.value,
        PlayerRepeat.repeatOne.index.toString());
  });

  test('pending Repeat changes cannot change another profile’s playback mode',
      () async {
    final database = db;
    final original = database.profileId;
    final other = await database.createProfile('Other');
    final pending = Completer<void>();
    final started = Completer<void>();
    db = _DelayedSettingsDb(database.forProfile(original), pending, started);
    final first = settingsCubit.setNextRepeatMode();
    await started.future;
    final second = settingsCubit.setNextRepeatMode();
    db = database;
    await database.useProfile(other.id);
    appCubit.advanceSession();
    pending.complete();
    await Future.wait([first, second]);
    expect(settingsCubit.state.playerRepeatMode, PlayerRepeat.noRepeat);
    expect(database.getSettings(playerRepeat), isNull);
    expect(database.forProfile(original).getSettings(playerRepeat)?.value,
        PlayerRepeat.repeatAll.index.toString());
  });

  test('subtitle size changes from separate controls save in order', () async {
    final database = db;
    final pending = Completer<void>();
    final started = Completer<void>();
    db = _DelayedSettingsDb(database, pending, started);
    final first = settingsCubit.changeSubtitleSize(increase: true);
    await started.future;
    final second = settingsCubit.changeSubtitleSize(increase: true);
    pending.complete();
    await Future.wait([first, second]);
    db = database;
    expect(settingsCubit.state.subtitleSize, 16);
    expect(db.getSettings(subtitleSizeSettingName)?.value, '16.0');
  });

  test('absolute subtitle size writes keep their order with queued steps',
      () async {
    final database = db;
    final pending = Completer<void>();
    final started = Completer<void>();
    db = _DelayedSettingsDb(database, pending, started);
    final first = settingsCubit.changeSubtitleSize(increase: true);
    await started.future;
    final Future<void> absolute = settingsCubit.setSubtitleSize(24);
    final decrement = settingsCubit.changeSubtitleSize(increase: false);
    pending.complete();
    await Future.wait([first, absolute, decrement]);
    db = database;
    expect(settingsCubit.state.subtitleSize, 23);
    expect(db.getSettings(subtitleSizeSettingName)?.value, '23.0');
  });

  test('a failed subtitle save leaves later changes usable', () async {
    final database = db;
    final pending = Completer<void>();
    final started = Completer<void>();
    db = _DelayedSettingsDb(database, pending, started);
    final first = settingsCubit.changeSubtitleSize(increase: true);
    final failure = expectLater(first, throwsStateError);
    await started.future;
    db = database;
    final retry = settingsCubit.changeSubtitleSize(increase: true);
    pending.completeError(StateError('Save failed'));
    await failure;
    await retry;
    expect(settingsCubit.state.subtitleSize, 15);
    expect(db.getSettings(subtitleSizeSettingName)?.value, '15.0');
  });

  for (final changeProfile in [false, true]) {
    test(
        'queued subtitle changes stop at session replacement (profile=$changeProfile)',
        () async {
      final database = db;
      final other = await database.createProfile('Other');
      final pending = Completer<void>();
      final started = Completer<void>();
      db = _DelayedSettingsDb(database, pending, started);
      final first = settingsCubit.changeSubtitleSize(increase: true);
      await started.future;
      final queued = settingsCubit.changeSubtitleSize(increase: true);
      db = database;
      if (changeProfile) {
        await db.useProfile(other.id);
        await fileDb.useProfile(other.id);
      }
      appCubit.advanceSession();
      await settingsCubit.reloadForProfile();
      final Future<void> replacement = settingsCubit.setSubtitleSize(20);
      pending.complete();
      await Future.wait([first, queued, replacement]);
      expect(settingsCubit.state.subtitleSize, 20);
      expect(db.getSettings(subtitleSizeSettingName)?.value, '20.0');
      if (changeProfile) {
        expect(
            database
                .forProfile('default')
                .getSettings(subtitleSizeSettingName)
                ?.value,
            '15.0');
      }
    });
  }

  test('Generic set settings method', () async {
    var setting = db.getSettings('test');
    expect(setting, null);

    SettingsValue s = SettingsValue('test', 'yo');
    await settingsCubit.saveSetting(s);
    expect(db.getSettings('test')?.value, 'yo');
  });
}

class _SessionAppCubit extends TestAppCubit {
  _SessionAppCubit(super.initialState);

  void advanceSession() =>
      emit(state.copyWith(sessionRevision: state.sessionRevision + 1));
}

class _DelayedSettingsDb implements IDbClient {
  final IDbClient delegate;
  final Completer<void> pending;
  final Completer<void> started;

  _DelayedSettingsDb(this.delegate, this.pending, this.started);

  @override
  String get profileId => delegate.profileId;

  @override
  IDbClient forProfile(String id) =>
      _DelayedSettingsDb(delegate.forProfile(id), pending, started);

  @override
  SettingsValue? getSettings(String name) => delegate.getSettings(name);

  @override
  Future<void> saveSetting(SettingsValue setting) async {
    if (!started.isCompleted) started.complete();
    await pending.future;
    await delegate.saveSetting(setting);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
