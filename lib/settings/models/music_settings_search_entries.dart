import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../l10n/generated/app_localizations.dart';
import '../views/screens/music_settings.dart';
import 'settings_search_entry.dart';

List<SettingsSearchEntry> musicSettingsSearchEntries(
  AppLocalizations locals, {
  required bool television,
  required TextDirection direction,
  required bool showTransitionDuration,
}) {
  final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  final rtl = direction == TextDirection.rtl;

  SettingsSearchEntry setting(
    String id,
    String title, {
    String? description,
    List<String> keywords = const [],
  }) =>
      SettingsSearchEntry(
        id: id,
        title: title,
        category: locals.ytMusicSettings,
        description: description,
        keywords: keywords,
        destination: (context, focusNode) => MusicSettingsScreen(
          television: television,
          focusedSetting: id,
          settingFocusNode: focusNode,
        ),
      );

  return [
    if (android) ...[
      setting('music-replaygain-setting', locals.musicReplayGain,
          description: locals.musicReplayGainHelp,
          keywords: [locals.settingsSearchReplayGainKeywords]),
      setting('music-preamp-setting', locals.musicTaggedPreamp,
          keywords: [locals.settingsSearchPreampKeywords]),
      setting('music-untagged-preamp-setting', locals.musicUntaggedPreamp,
          keywords: [locals.settingsSearchPreampKeywords]),
    ],
    setting('music-history-privacy-setting', locals.musicHistoryPrivacy,
        keywords: [locals.settingsSearchHistoryPrivacyKeywords]),
    setting(
        'music-streaming-quality-setting', locals.musicStreamingQualitySetting,
        keywords: [
          locals.musicAudioQualityDataSaver,
          locals.musicAudioQualityHighest
        ]),
    setting('music-song-tap-queue-setting', locals.musicSongTapQueueSetting,
        keywords: [locals.musicSongTapCollection, locals.musicSongTapSongOnly]),
    setting('music-retain-shuffle-on-song-tap-setting',
        locals.musicRetainShuffleOnSongTap,
        description: locals.musicRetainShuffleOnSongTapHelp),
    setting(
        'music-audio-focus-return-setting', locals.musicAudioFocusReturnSetting,
        keywords: [
          locals.settingsSearchAudioFocusKeywords,
          locals.musicAudioFocusStayPaused
        ]),
    if (android)
      setting('music-volume-zero-setting', locals.musicVolumeZeroSetting,
          description: locals.musicVolumeZeroPauseHelp,
          keywords: [locals.settingsSearchZeroVolumeKeywords]),
    setting('music-reconnect-setting', locals.musicReconnectSetting, keywords: [
      locals.settingsSearchReconnectKeywords,
      locals.musicReconnectAuto,
      locals.musicReconnectManual
    ]),
    setting(
        'music-retry-exhaustion-setting', locals.musicRetryExhaustionSetting,
        keywords: [
          locals.musicRetryExhaustionSkip,
          locals.musicRetryExhaustionStay
        ]),
    setting('music-remember-queue-after-restart-setting',
        locals.musicRememberQueueAfterRestartSetting,
        description: locals.musicRememberQueueAfterRestartHelp,
        keywords: [locals.settingsSearchRememberQueueKeywords]),
    if (android) ...[
      setting('music-task-removal-setting', locals.musicTaskRemovalSetting,
          description: locals.musicTaskRemovalKeepPlayingHelp,
          keywords: [locals.settingsSearchTaskRemovalKeywords]),
      setting('music-audio-offload-setting', locals.musicAudioOffloadSetting,
          description: locals.musicAudioOffloadWhenSupportedHelp),
      setting('music-android-notifications-setting',
          locals.musicAndroidNotificationSettings,
          description: locals.musicAndroidNotificationSettingsHelp,
          keywords: [locals.notifications]),
      setting(
          'music-android-battery-setting', locals.musicAndroidBatterySettings,
          description: locals.musicAndroidBatterySettingsHelp),
    ],
    setting('music-now-playing-style-setting', locals.musicNowPlayingStyle,
        keywords: [
          locals.musicNowPlayingClassic,
          locals.musicNowPlayingLargeArtwork,
          locals.musicNowPlayingCompact
        ]),
    setting('music-player-background-setting', locals.musicPlayerBackground,
        keywords: [
          locals.musicPlayerBackgroundArtwork,
          locals.musicPlayerBackgroundSolid
        ]),
    setting('music-scrubber-style-setting', locals.musicScrubberStyle,
        keywords: [
          locals.settingsSearchScrubberKeywords,
          locals.musicScrubberWave
        ]),
    if (!television) ...[
      setting('music-mini-player-layout-setting', locals.musicMiniPlayerLayout,
          keywords: [
            locals.musicMiniPlayerCompact,
            locals.musicMiniPlayerTransport
          ]),
      setting(
          'music-mini-player-shortcut-setting', locals.musicMiniPlayerShortcut,
          keywords: [
            locals.musicMiniPlayerNext,
            locals.musicMiniPlayerRepeat,
            locals.musicShuffle
          ]),
      setting('music-artwork-swipe-setting', locals.musicArtworkSwipe),
      setting('music-artwork-double-tap-seek-setting',
          locals.musicArtworkDoubleTapSeek,
          description: locals.musicArtworkDoubleTapSeekHelp),
      setting('music-song-swipe-end-setting',
          rtl ? locals.musicSongRowSwipeLeft : locals.musicSongRowSwipeRight,
          keywords: [locals.playNext, locals.addToQueueList]),
      setting('music-song-swipe-start-setting',
          rtl ? locals.musicSongRowSwipeRight : locals.musicSongRowSwipeLeft,
          keywords: [locals.playNext, locals.addToQueueList]),
    ],
    setting(
        'music-previous-track-policy-setting', locals.musicPreviousTrackPolicy,
        keywords: [
          locals.musicPreviousTrackAlways,
          locals.musicPreviousTrackRestart
        ]),
    setting('music-pause-at-repeat-setting', locals.musicPauseAtRepeat,
        description: locals.musicPauseAtRepeatHelp),
    setting('music-keep-paused-on-skip-setting', locals.musicKeepPausedOnSkip),
    if (android)
      setting('music-screen-privacy-setting', locals.musicScreenPrivacySetting,
          description: locals.musicScreenPrivacyHelp),
    setting('music-transition-setting', locals.musicTransitionSetting,
        description: locals.musicTransitionCrossfadeHelp,
        keywords: [
          locals.musicTransitionCrossfade,
          locals.musicTransitionFade,
          locals.musicTransitionPause,
          locals.musicTransitionSeamless
        ]),
    if (showTransitionDuration)
      setting(
          'music-transition-duration-setting', locals.musicTransitionDuration,
          keywords: [
            locals.musicTransitionCrossfade,
            locals.musicTransitionFade,
            locals.musicTransitionPause
          ]),
    setting('music-lrclib-setting', locals.musicLrclibSetting,
        description: locals.musicLrclibSettingHelp),
    setting('music-community-cover-setting', locals.musicCommunityCoverSetting,
        description: locals.musicCommunityCoverSettingHelp),
    setting('music-artwork-cache-setting', locals.musicArtworkCache,
        description: locals.musicArtworkCacheHint,
        keywords: [
          locals.musicArtworkCacheLimit,
          locals.musicArtworkCacheClear
        ]),
    setting('music-cover-corners-setting', locals.musicCoverCorners, keywords: [
      locals.musicCoverCornersRounded,
      locals.musicCoverCornersSquare
    ]),
    setting(
        'device-music-artwork-source-setting', locals.deviceMusicArtworkSource,
        description: locals.deviceMusicArtworkPreferFolderHelp,
        keywords: [locals.deviceMusicArtworkEmbeddedOnly]),
    setting('device-music-artwork-quality-setting',
        locals.deviceMusicArtworkQuality),
    setting('device-music-artwork-crop-setting', locals.deviceMusicArtworkFit,
        keywords: [
          locals.deviceMusicArtworkFill,
          locals.deviceMusicArtworkFitWhole
        ]),
    setting('music-download-format-setting', locals.musicDownloadFormatSetting,
        description: locals.musicDownloadOpusHelp,
        keywords: [locals.musicDownloadOpusBestQuality]),
  ];
}
