import 'dart:async';
import 'dart:convert';

import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:bloc/bloc.dart';
import 'package:easy_debounce/easy_debounce.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/workmanager.dart';
import 'package:clipious/l10n/app_languages.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../globals.dart';
import '../../content_filter/community_filter.dart';
import '../../main.dart' show isTv;
import '../../downloads/states/download_manager.dart';
import '../../home/models/db/home_layout.dart';
import '../../home/models/phone_navigation.dart';
import '../../home/models/content_mode.dart';
import '../../home/models/home_tabs_layout.dart';
import '../../music/models/music_layout.dart';
import '../../music/models/song_transition.dart';
import '../../player/models/music_audio_quality.dart';
import '../../player/models/video_display_mode.dart';
import '../../player/states/player.dart';
import '../../recommendations/recommendation_service.dart';
import '../../utils.dart';
import '../../utils/motion.dart';
import '../../utils/backup.dart';
import '../../utils/models/country.dart';
import '../models/db/settings.dart';

part 'settings.freezed.dart';

const String subtitleDefaultSize = '14';
const String searchHistoryDefaultLength = '12';
const skipSteps = [5, 10, 15, 20, 30, 60];
const defaultStep = 10;
const _backgroundRestartDebounce = 'restarting-background-service';

enum EnableBackGroundNotificationResponse {
  ok,
  notificationsNotAllowed,
  needBatteryOptimization;
}

class SettingsCubit extends Cubit<SettingsState> {
  final AppCubit appCubit;
  bool _backupBusy = false;
  final _pendingSettingWrites = <String, Future<void>>{};

  SettingsCubit(super.initialState, this.appCubit) {
    onReady();
  }

  Future<void> reloadForProfile() async {
    if (isClosed) return;
    EasyDebounce.cancel(_backgroundRestartDebounce);
    emit(SettingsState.init().copyWith(packageInfo: state.packageInfo));
    await _getSubscriptionNotification();
    if (isClosed) return;
    // Periodic work follows the selected person's notification preference.
    // Reuse the saved permission decision; switching never prompts for access.
    await configureBackgroundService(this);
    await setupTasks(this);
  }

  onReady() async {
    await getPackageInfo();
    await _getSubscriptionNotification();
  }

  toggleForceLandscapeFullScreen(bool value) async {
    await setForceLandscapeFullScreen(value);
  }

  toggleDynamicTheme(bool value) async {
    await setUseDynamicTheme(value);
    updateApp();
  }

  toggleDash(bool value) async {
    await setUseDash(value);
  }

  toggleAutoplayOnLoad(bool value) async {
    await setAutoplayVideoOnLoad(value);
  }

  toggleReturnYoutubeDislike(bool value) async {
    await setUseReturnYoutubeDislike(value);
  }

  toggleSearchHistory(bool value) async {
    await setUseSearchHistory(value);
    if (!value) {
      await db.clearSearchHistory();
    }
  }

  toggleRememberPlaybackSpeed(bool value) async {
    await setRememberPlayBackSpeed(value);
  }

  selectOnOpen(int index) async {
    await setOnOpen(index);
  }

  Future<void> selectCountry(String selected) async {
    await setCountry(countryCodes.firstWhere(
        (element) => element.name == selected,
        orElse: () => state.country));
  }

  toggleSslVerification(bool value) async {
    await setSkipSslVerification(value);
  }

  getPackageInfo() async {
    emit(state.copyWith(packageInfo: packageInfo!));
  }

  toggleBlackBackground(bool value) async {
    await setBlackBackground(value);
    appCubit.rebuildApp();
  }

  changeSkipStep({required bool increase}) async {
    int index = skipSteps.indexOf(state.skipStep);
    if (increase) {
      if (index < skipSteps.length - 1) {
        await setSkipStep(skipSteps[index + 1]);
      }
    } else {
      if (index > 0) {
        await setSkipStep(skipSteps[index - 1]);
      }
    }
  }

  Future<void> changeSubtitleSize({required bool increase}) =>
      _updateSubtitleSize((current) =>
          increase ? current + 1 : (current - 1).clamp(1.0, double.infinity));

  Future<void> setSubtitleSize(int value) =>
      _updateSubtitleSize((_) => value < 1 ? 1 : value.toDouble());

  toggleRememberSubtitles(bool value) async {
    await setRememberSubtitles(value);
  }

  changeSearchHistoryLimit({required bool increase}) async {
    if (increase) {
      if (state.searchHistoryLimit < 30) {
        await setSearchHistoryLimit(state.searchHistoryLimit + 1);
      }
    } else {
      if (state.searchHistoryLimit > 1) {
        await setSearchHistoryLimit(state.searchHistoryLimit - 1);
      }
    }
    if (!increase) {
      await db.clearExcessSearchHistory();
    }
  }

  setHistoryLimit(int value) async {
    if (value > 30) return;
    final limit = value < 1 ? 1 : value;
    final previousLimit = state.searchHistoryLimit;
    await setSearchHistoryLimit(limit);

    if (limit < previousLimit) {
      await db.clearExcessSearchHistory();
    }
  }

  String getThemeLabel(AppLocalizations locals, ThemeMode theme) {
    switch (theme) {
      case ThemeMode.dark:
        return locals.themeDark;
      case ThemeMode.light:
        return locals.themeLight;
      case ThemeMode.system:
        return locals.followSystem;
    }
  }

  setThemeMode(ThemeMode? theme) async {
    if (theme != null) {
      await _setThemeMode(theme);
    }
    updateApp();
  }

  Future<void> setLocale(Locale? locale) async {
    final key = locale?.toString();
    await _set(localeSettingName, key);
    await fileDb.setLocale(key);
    updateApp();
  }

  updateApp() {
    appCubit.rebuildApp();
  }

  Future<void> setShuffle(bool value) => _set(playerShuffle, value);

  Future<void> setRepeatMode(PlayerRepeat repeat) =>
      _saveSettingInOrder(playerRepeat, () => repeat.index.toString());

  toggleShuffle() {
    setShuffle(!state.playerShuffleMode);
  }

  Future<void> setNextRepeatMode() => _saveSettingInOrder(playerRepeat, () {
        final next =
            (state.playerRepeatMode.index + 1) % PlayerRepeat.values.length;
        return next.toString();
      });

  Future<void> setLastSubtitle(String value) => _set(lastSubtitle, value);

  String? getLocaleDisplayName() {
    final locale = parseSavedLocale(state.locale);
    return locale == null
        ? null
        : lookupAppLocalizations(locale).nativeLanguageName;
  }

  Future<EnableBackGroundNotificationResponse> setBackgroundNotifications(
      bool b) async {
    if (!b) {
      EasyDebounce.cancel(_backgroundRestartDebounce);
      await _setBackgroundNotifications(b);
      await stopTasks();
    } else {
      var isAllowed = await AwesomeNotifications().isNotificationAllowed();
      if (!isAllowed) {
        var allowed =
            await AwesomeNotifications().requestPermissionToSendNotifications();
        if (!allowed) {
          return EnableBackGroundNotificationResponse.notificationsNotAllowed;
        }
      }

      await _setBackgroundNotifications(b);
      await configureBackgroundService(this);
      await setupTasks(this);
      return EnableBackGroundNotificationResponse.ok;
    }

    return EnableBackGroundNotificationResponse.ok;
  }

  setBackgroundCheckFrequency(int i) async {
    if (i > 0 && i <= 24) {
      await setBackgroundNotificationFrequency(i);
      if (isClosed || !state.backgroundNotifications) return;
      EasyDebounce.debounce(
          _backgroundRestartDebounce, const Duration(seconds: 2), () {
        if (!isClosed && state.backgroundNotifications) setupTasks(this);
      });
    }
  }

  copySettingsAsJson(BuildContext context) {
    var encoder = const JsonEncoder.withIndent('    ');
    String json = encoder.convert(state.settings);
    Clipboard.setData(ClipboardData(text: json));
  }

  Future<void> backupLibrary(BuildContext context,
      {bool restore = false}) async {
    if (_backupBusy) return;
    _backupBusy = true;
    final locals = AppLocalizations.of(context)!;
    const files = MethodChannel('videre/files');
    try {
      if (!restore) {
        final backup = await db.exportBackup();
        final saved = await files.invokeMethod<bool>('save', {
          'name':
              'videre-${DateTime.now().toIso8601String().split('T').first}.json',
          'text': backup.encode(),
        });
        if (saved == true && context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(locals.backupSaved)));
        }
        return;
      }
      final text = await files.invokeMethod<String>('open');
      if (text == null || !context.mounted) return;
      final backup = UserBackup.parse(text);
      final replace = await showDialog<bool>(
          animationStyle: AppMotion.dialogStyle(context),
          context: context,
          builder: (context) => AlertDialog(
                title: Text(locals.importBackup),
                content: Text(locals.backupPreview(backup.itemCount)),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(locals.cancel)),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(locals.replaceBackup)),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(locals.mergeBackup)),
                ],
              ));
      if (replace == null || !context.mounted) return;
      if (context.read<PlayerCubit>().state.hasVideo) {
        showAlertDialog(
            context, locals.importBackup, [Text(locals.backupStopPlayback)]);
        return;
      }
      final downloads = backup.subscriptionsOnly
          ? null
          : context.read<DownloadManagerCubit>();
      final database = db.forProfile(db.profileId);
      if (backup.subscriptionsOnly) {
        await database.restoreBackup(backup, replace: replace);
      } else {
        await RecommendationService.forCurrentProfile().restoreBackup(
            () => database.restoreBackup(backup, replace: replace));
      }
      if (!backup.subscriptionsOnly) {
        unawaited(communityFilters.reloadForProfile());
      }
      if (downloads != null) {
        await downloads.setWifiOnly(
            db.getSettings('downloads-wifi-only')?.value == 'true');
      }
      await fileDb.syncWithDb();
      if (isClosed) return;
      emit(state.copyWith(settings: {
        for (final setting in db.getAllSettings()) setting.name: setting
      }));
      await appCubit.initState();
      playbackHistoryRevision.value++;
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(locals.backupRestored)));
      }
    } catch (error) {
      if (context.mounted) {
        final message = error is PlatformException
            ? error.message ?? error.code
            : error.toString();
        showAlertDialog(context, locals.error, [Text(message)]);
      }
    } finally {
      _backupBusy = false;
    }
  }

  Future<void> saveSetting(SettingsValue settings) async {
    await db.saveSetting(settings);
    if (isClosed) return;
    var newSettings = Map<String, SettingsValue>.from(state.settings);
    newSettings[settings.name] = settings;
    emit(state.copyWith(settings: newSettings));
  }

  setOnOpen(int i) async => await _set(onOpenSettingName, i);

  setBlackBackground(bool b) async => await _set(blackBackgroundSettingName, b);

  setRememberSubtitles(bool b) async => await _set(rememberLastSubtitle, b);

  setRememberPlayBackSpeed(bool b) async => await _set(remeberPlaybackSpeed, b);

  Future<void> setRememberVideoQuality(bool value) =>
      _set(rememberVideoQualitySettingName, value);

  Future<void> setLastVideoQuality(int height) async {
    if (height < 0 || height > 16384) return;
    await _set(lastVideoQualitySettingName, height);
  }

  Future<void> setVideoDisplayMode(VideoDisplayMode mode) async {
    final owner = db.forProfile(db.profileId);
    final session = appCubit.state.sessionRevision;
    final setting = SettingsValue(videoDisplayModeSettingName, mode.name);
    await owner.saveSetting(setting);
    if (isClosed ||
        db.profileId != owner.profileId ||
        appCubit.state.sessionRevision != session) {
      return;
    }
    emit(state.copyWith(settings: {
      ...state.settings,
      videoDisplayModeSettingName: setting,
    }));
  }

  setForceTvUi(bool b) async => await _set(forceTvUiSettingName, b);

  setSearchHistoryLimit(int b) async =>
      await _set(searchHistoryLimitSettingName, b);

  setLastSpeed(double d) async => await _set(lastSpeedSettingName, d);

  setPlayRecommendedNext(bool b) async =>
      await _set(playRecommendedNextSettingName, b);

  Future<void> setCountry(Country c) async {
    String code = countryCodes
        .firstWhere((element) => element.name == c.name,
            orElse: () => state.country)
        .code;
    await _set(browsingCountry, code);
  }

  setUseDynamicTheme(bool b) async => await _set(dynamicTheme, b);

  setUseDash(bool b) async => await _set(useDashSettingName, b);

  setAutoplayVideoOnLoad(bool b) async => await _set(playerAutoplayOnLoad, b);

  Future<void> setAutoplayQueue(bool value) => _set(playerAutoplayQueue, value);

  setUseReturnYoutubeDislike(bool b) async =>
      await _set(useReturnYoutubeDislikeSettingName, b);

  Future<void> _updateSubtitleSize(double Function(double) update) =>
      _saveSettingInOrder(
          subtitleSizeSettingName, () => update(state.subtitleSize).toString());

  Future<void> _saveSettingInOrder(String name, String Function() nextValue) {
    final owner = db.forProfile(db.profileId);
    final profile = owner.profileId;
    final session = appCubit.state.sessionRevision;
    bool isCurrentSession() =>
        !isClosed &&
        db.profileId == profile &&
        appCubit.state.sessionRevision == session;

    Future<void> save() async {
      if (!isCurrentSession()) return;
      final setting = SettingsValue(name, nextValue());
      await owner.saveSetting(setting);
      if (isCurrentSession()) {
        emit(state
            .copyWith(settings: {...state.settings, setting.name: setting}));
      }
    }

    // Each adjustment sees the result of the previous write to this setting.
    final previous = _pendingSettingWrites[name] ?? Future<void>.value();
    final saving = previous.then((_) => save());
    _pendingSettingWrites[name] = saving.catchError((Object _) {});
    return saving;
  }

  setSkipSslVerification(bool b) async =>
      await _set(skipSslVerificationSettingName, b);

  setForceLandscapeFullScreen(bool b) async =>
      await _set(lockOrientationFullScreen, b);

  _setThemeMode(ThemeMode t) async => await _set(themeModeSettingName, t.name);

  Future<void> setMotionPreference(MotionPreference value) async =>
      _set(motionPreferenceSettingName, value.name);

  setUseSearchHistory(bool b) async =>
      await _set(useSearchHistorySettingName, b);

  setAppLayout(List<HomeDataSource> layout) async {
    var layoutToString = layout.map((e) => e.name).join(",");
    await _set(
        isTv ? tvAppLayoutSettingName : appLayoutSettingName, layoutToString);
  }

  Future<void> setAppLayoutAndStartup(
      List<HomeDataSource> layout, int startupIndex) async {
    if (isClosed) return;
    final owner = db.forProfile(db.profileId);
    final session = appCubit.state.sessionRevision;
    final layoutSetting = SettingsValue(
        isTv ? tvAppLayoutSettingName : appLayoutSettingName,
        layout.map((source) => source.name).join(','));
    final startupSetting =
        SettingsValue(onOpenSettingName, startupIndex.toString());
    // Both values belong to the original editor, even if it closes or the
    // active profile/interface changes while the first write is pending.
    await owner.saveSetting(layoutSetting);
    await owner.saveSetting(startupSetting);
    if (isClosed ||
        db.profileId != owner.profileId ||
        appCubit.state.sessionRevision != session) {
      return;
    }
    emit(state.copyWith(settings: {
      ...state.settings,
      layoutSetting.name: layoutSetting,
      startupSetting.name: startupSetting,
    }));
  }

  Future<void> setPhoneNavigation(PhoneNavigation layout) =>
      _set(phoneNavigationSettingName, layout.encode());

  Future<void> setSongTransitionMode(SongTransitionMode mode) =>
      _saveSettingInOrder(songTransitionModeSettingName, () => mode.name);

  Future<void> setMusicStreamingQuality(MusicStreamingQuality quality) =>
      _saveSettingInOrder(musicStreamingQualitySettingName, () => quality.name);

  Future<void> setSongTransitionSeconds(int seconds) {
    RangeError.checkValueInInterval(
        seconds, minSongTransitionSeconds, maxSongTransitionSeconds, 'seconds');
    return _saveSettingInOrder(
        songTransitionSecondsSettingName, seconds.toString);
  }

  Future<void> setMusicLayout(MusicLayout layout) =>
      _saveSettingInOrder(musicLayoutSettingName, layout.encode);

  Future<void> setHomeTabsLayout(HomeTabsLayout layout) async {
    final owner = db.forProfile(db.profileId);
    final session = appCubit.state.sessionRevision;
    final setting = SettingsValue(homeTabsLayoutSettingName, layout.encode());
    await owner.saveSetting(setting);
    if (isClosed ||
        db.profileId != owner.profileId ||
        appCubit.state.sessionRevision != session) {
      return;
    }
    emit(state.copyWith(settings: {
      ...state.settings,
      homeTabsLayoutSettingName: setting,
    }));
  }

  Future<void> setHomeContentMode(HomeContentMode mode) async {
    final owner = db.forProfile(db.profileId);
    final session = appCubit.state.sessionRevision;
    await owner
        .saveSetting(SettingsValue(homeContentModeSettingName, mode.name));
    if (isClosed ||
        db.profileId != owner.profileId ||
        appCubit.state.sessionRevision != session) {
      return;
    }
    emit(state.copyWith(settings: {
      ...state.settings,
      homeContentModeSettingName:
          SettingsValue(homeContentModeSettingName, mode.name),
    }));
  }

  setNavigationBarLabelBehavior(
          NavigationDestinationLabelBehavior behavior) async =>
      await _set(navigationBarLabelBehaviorSettingName, behavior.name);

  setDistractionFreeMode(bool b) async =>
      await _set(distractionFreeModeSettingName, b);

  Future<void> setHideCommentsByDefault(bool value) =>
      _saveSettingInOrder(hideCommentsByDefaultSettingName, value.toString);

  Future<void> setHideWatchedSubscriptions(bool value) async {
    await _set(hideWatchedSubscriptionsSettingName, value);
    playbackHistoryRevision.value++;
  }

  _setBackgroundNotifications(bool b) async =>
      await _set(backgroundNotificationsSettingName, b);

  setBackgroundNotificationFrequency(int i) async =>
      await _set(backgroundCheckFrequency, i);

  setSubtitlesBackground(bool b) async => await _set(subtitleBackground, b);

  setDearrow(bool b) async => await _set(dearrowSettingName, b);

  setDearrowThumbnails(bool b) async =>
      await _set(dearrowThumbnailsSettingName, b);

  setSkipStep(int s) async => await _set(skipStepSettingName, s);

  setSkipExponentially(bool b) async =>
      await _set(skipExponentialSettingName, b);

  setFullscreenOnRotate(bool b) async =>
      await _set(fullScreenOnLandscapeSettingName, b);

  setScreenControls(bool b) async => await _set(screenControlsSettingName, b);

  setReturnYoutubeDislikeUrl(String url) async =>
      await _set(returnYoutubeDislikeUrlSettingName, url);

  Future<void> _set<T>(String name, T value) async {
    if (value == null) {
      await db.deleteSetting(name);
      if (isClosed) return;
      final settings = Map<String, SettingsValue>.from(state.settings)
        ..remove(name);
      emit(state.copyWith(settings: settings));
    } else {
      await saveSetting(SettingsValue(name, value.toString()));
    }
  }

  setSubscriptionsNotifications(bool value) async {
    await fileDb.setSubscriptionNotifications(value);
    await _getSubscriptionNotification();
  }

  _getSubscriptionNotification() async {
    final enabled = await fileDb.getSubscriptionNotifications();
    if (!isClosed) emit(state.copyWith(subscriptionNotifications: enabled));
  }
}

@freezed
sealed class SettingsState with _$SettingsState {
  const factory SettingsState(
      {required Map<String, SettingsValue> settings,
      required PackageInfo packageInfo,
      @Default(false) subscriptionNotifications}) = _SettingsState;

  static SettingsState init() {
    PackageInfo packageInfo =
        PackageInfo(appName: '', packageName: '', version: '', buildNumber: '');
    var allSettings = db.getAllSettings();
    var settings = {for (var s in allSettings) s.name: s};

    return SettingsState(settings: settings, packageInfo: packageInfo);
  }

  int get onOpen => int.parse(_get(onOpenSettingName)?.value ?? '0');

  bool get blackBackground => _get(blackBackgroundSettingName)?.value == 'true';

  bool get rememberSubtitles => _get(rememberLastSubtitle)?.value == 'true';

  bool get rememberPlayBackSpeed => _get(remeberPlaybackSpeed)?.value == 'true';

  bool get rememberVideoQuality =>
      _get(rememberVideoQualitySettingName)?.value != 'false';

  // Zero represents automatic adaptive quality; null means no saved choice.
  int? get lastVideoQuality {
    final height = int.tryParse(_get(lastVideoQualitySettingName)?.value ?? '');
    return height != null && height >= 0 && height <= 16384 ? height : null;
  }

  VideoDisplayMode get videoDisplayMode =>
      VideoDisplayMode.fromStorage(_get(videoDisplayModeSettingName)?.value) ??
      (_get(fillFullScreen)?.value == 'true'
          ? VideoDisplayMode.crop
          : VideoDisplayMode.fit);

  String? get locale => _get(localeSettingName)?.value;

  int get searchHistoryLimit => int.parse(
      _get(searchHistoryLimitSettingName)?.value ?? searchHistoryDefaultLength);

  double get lastSpeed =>
      double.parse(_get(lastSpeedSettingName)?.value ?? "1.0");

  bool get playerShuffleMode => _get(playerShuffle)?.value == "true";

  PlayerRepeat get playerRepeatMode =>
      PlayerRepeat.values[int.parse(_get(playerRepeat)?.value ?? '0')];

  String get lastSubtitles => _get(lastSubtitle)?.value ?? '';

  bool get playRecommendedNext =>
      _get(playRecommendedNextSettingName)?.value == "true";

  Country get country =>
      getCountryFromCode(_get(browsingCountry)?.value ?? 'US');

  bool get useDynamicTheme => _get(dynamicTheme)?.value == 'true';

  bool get useDash => (_get(useDashSettingName)?.value ?? 'true') == 'true';

  bool get hasDashPreference => _get(useDashSettingName) != null;

  bool get autoplayVideoOnLoad => _get(playerAutoplayOnLoad)?.value == 'true';

  bool get autoplayQueue => _get(playerAutoplayQueue)?.value != 'false';

  bool get useReturnYoutubeDislike =>
      (_get(useReturnYoutubeDislikeSettingName)?.value ?? 'true') == 'true';

  String get returnYoutubeDislikeUrl =>
      _get(returnYoutubeDislikeUrlSettingName)?.value ?? '';

  double get subtitleSize =>
      double.parse(_get(subtitleSizeSettingName)?.value ?? subtitleDefaultSize);

  bool get skipSslVerification =>
      _get(skipSslVerificationSettingName)?.value == 'true';

  bool get forceLandscapeFullScreen =>
      _get(lockOrientationFullScreen)?.value == 'true';

  int get skipStep =>
      int.parse(_get(skipStepSettingName)?.value ?? defaultStep.toString());

  bool get skipExponentially =>
      (_get(skipExponentialSettingName)?.value ?? 'true') == 'true';

  MotionPreference get motionPreference => MotionPreference.values.firstWhere(
      (value) => value.name == _get(motionPreferenceSettingName)?.value,
      orElse: () => MotionPreference.system);

  ThemeMode get themeMode => ThemeMode.values.firstWhere(
      (element) => element.name == _get(themeModeSettingName)?.value,
      orElse: () => ThemeMode.system);

  bool get useSearchHistory =>
      (_get(useSearchHistorySettingName)?.value ?? 'true') == 'true';

  bool get screenControls =>
      (_get(screenControlsSettingName)?.value ?? 'true') == 'true';

  bool get forceTvUi =>
      (_get(forceTvUiSettingName)?.value ?? 'false') == 'true';

  List<HomeDataSource> get appLayout {
    var savedLayout = _get(appLayoutSettingName)?.value;
    var defaultLayout = HomeDataSource.defaultSettings();
    if (isTv) {
      final tvLayout = _get(tvAppLayoutSettingName)?.value;
      final names = (tvLayout ??
              savedLayout ??
              defaultLayout.map((e) => e.name).join(','))
          .split(',');
      final layout = [
        for (final name in names)
          for (final source in HomeDataSource.values)
            if (source.name == name &&
                source.showOn != HomeDataSourceAppearance.phone)
              source
      ].toSet().toList();
      // Older TV layouts predate History. A TV-specific save makes later
      // opt-outs explicit without changing the phone/tablet layout.
      if (tvLayout == null && !layout.contains(HomeDataSource.history)) {
        layout.add(HomeDataSource.history);
      }
      return layout;
    }
    return (savedLayout ?? defaultLayout.map((e) => e.name).join(","))
        .split(',')
        .where((element) => element.isNotEmpty)
        .map((e) =>
            HomeDataSource.values.firstWhere((element) => element.name == e))
        .toList();
  }

  PhoneNavigation? get savedPhoneNavigation =>
      PhoneNavigation.decode(_get(phoneNavigationSettingName)?.value);

  PhoneNavigation get phoneNavigation =>
      savedPhoneNavigation ?? PhoneNavigation.fromLegacy(appLayout, onOpen);

  HomeTabsLayout get homeTabsLayout =>
      HomeTabsLayout.decode(_get(homeTabsLayoutSettingName)?.value);

  SongTransitionMode get songTransitionMode =>
      SongTransitionMode.fromStorage(
          _get(songTransitionModeSettingName)?.value) ??
      SongTransitionMode.seamless;

  MusicStreamingQuality get musicStreamingQuality =>
      MusicStreamingQuality.fromStorage(
          _get(musicStreamingQualitySettingName)?.value) ??
      MusicStreamingQuality.auto;

  int get songTransitionSeconds {
    final saved =
        int.tryParse(_get(songTransitionSecondsSettingName)?.value ?? '');
    return saved != null &&
            saved >= minSongTransitionSeconds &&
            saved <= maxSongTransitionSeconds
        ? saved
        : defaultSongTransitionSeconds;
  }

  MusicLayout get musicLayout =>
      MusicLayout.decode(_get(musicLayoutSettingName)?.value);

  HomeContentMode get homeContentMode =>
      _get(homeContentModeSettingName)?.value == HomeContentMode.music.name
          ? HomeContentMode.music
          : HomeContentMode.videos;

  NavigationDestinationLabelBehavior get navigationBarLabelBehavior =>
      NavigationDestinationLabelBehavior.values.firstWhere((e) =>
          e.name ==
          (_get(navigationBarLabelBehaviorSettingName)?.value ??
              NavigationDestinationLabelBehavior.onlyShowSelected.name));

  bool get distractionFreeMode =>
      _get(distractionFreeModeSettingName)?.value == "true";

  bool get hideCommentsByDefault =>
      _get(hideCommentsByDefaultSettingName)?.value == 'true';

  bool get hideWatchedSubscriptions =>
      _get(hideWatchedSubscriptionsSettingName)?.value == 'true';

  bool get backgroundNotifications =>
      _get(backgroundNotificationsSettingName)?.value == 'true';

  int get backgroundNotificationFrequency =>
      int.parse(_get(backgroundCheckFrequency)?.value ?? "1");

  bool get subtitlesBackground => _get(subtitleBackground)?.value == 'true';

  bool get dearrow => _get(dearrowSettingName)?.value == 'true';

  bool get dearrowThumbnails =>
      _get(dearrowThumbnailsSettingName)?.value == 'true';

  bool get fullscreenOnRotate =>
      (_get(fullScreenOnLandscapeSettingName)?.value ?? "true") == "true";

  SettingsValue? _get(String settingName) => settings[settingName];

  const SettingsState._();
}
