import 'package:json_annotation/json_annotation.dart';

part 'settings.g.dart';

const sponsorBlockPrefix = 'sponsor-block-';
const watchNotesSettingPrefix = 'watch-notes-v1:';
const browsingCountry = 'browsing-country';
const dynamicTheme = 'dynamic-theme';
const themePaletteSettingName = 'theme-palette';
const useDashSettingName = 'use-dash';
const playerRepeat = 'player-repeat';
const playerShuffle = 'player-shuffle';
const playerAutoplayOnLoad = 'player-autoplay-on-load';
const playerAutoplayQueue = 'player-autoplay-queue';
const playRecommendedNextSettingName = 'play-recommended-next';
// Retained so backups from versions with a direct playback setting import.
const useProxySettingName = 'use-proxy';
const networkSocksProxySettingName = 'network-socks-proxy';
const useReturnYoutubeDislikeSettingName = 'use-return-youtube-dislike';
const returnYoutubeDislikeUrlSettingName = 'custom-return-youtube-dislike-url';
const blackBackgroundSettingName = 'black-background';
const subtitleSizeSettingName = 'subtitles-size';
const rememberLastSubtitle = 'remember-last-subtitle';
const lastSubtitle = 'last-subtitle';
const skipSslVerificationSettingName = 'skip-ssl-verification';
const themeModeSettingName = 'theme-mode';
const motionPreferenceSettingName = 'motion-preference';
const localeSettingName = 'locale';
const useSearchHistorySettingName = 'use-search-history';
const searchHistoryLimitSettingName = 'search-history-limit';
const remeberPlaybackSpeed = 'remember-playback-speed';
// Older versions stored one speed for every type of playback.
const lastSpeedSettingName = 'last-speed';
const videoSpeedSettingName = 'video-playback-speed';
const musicSpeedSettingName = 'music-playback-speed';
const videoPitchSettingName = 'video-playback-pitch';
const musicPitchSettingName = 'music-playback-pitch';
const musicReplayGainModeSettingName = 'music-replaygain-mode';
// Legacy default for profiles that used one preamp.
const musicPreampSettingName = 'music-preamp-db';
const musicSkipSilenceSettingName = 'music-skip-silence';
const musicTaggedPreampSettingName = 'music-preamp-tagged-db';
const musicUntaggedPreampSettingName = 'music-preamp-untagged-db';
const rememberVideoQualitySettingName = 'remember-video-quality';
const lastVideoQualitySettingName = 'last-video-quality';
const lockOrientationFullScreen = 'lock-orientation-fullscreen';
const skipStepSettingName = 'skip-step';
const skipExponentialSettingName = 'skip-exponentially';
const fillFullScreen = 'fill-fullscreen';
const videoDisplayModeSettingName = 'video-display-mode';
const appLayoutSettingName = 'app-layout';
const tvAppLayoutSettingName = 'tv-app-layout';
const phoneNavigationSettingName = 'phone-navigation';
const homeTabsLayoutSettingName = 'home-tabs-layout';
const musicLayoutSettingName = 'music-layout';
const musicMiniPlayerLayoutSettingName = 'music-mini-player-layout';
const musicMiniPlayerShortcutSettingName = 'music-mini-player-shortcut';
const musicSongTapQueueScopeSettingName = 'music-song-tap-queue-scope';
const musicCollectionDetailSongTapQueueScopeSettingName =
    'music-collection-detail-song-tap-queue-scope';
const musicRetainShuffleOnSongTapSettingName =
    'music-retain-shuffle-on-song-tap';
const musicNowPlayingStyleSettingName = 'music-now-playing-style';
const musicPlayerBackgroundSettingName = 'music-player-background';
const musicScrubberStyleSettingName = 'music-scrubber-style';
const musicMiniPlayerLyricsSettingName = 'music-mini-player-lyrics';
const musicArtworkSwipeSettingName = 'music-artwork-swipe';
const musicArtworkDoubleTapSeekSettingName = 'music-artwork-double-tap-seek';
const musicSongSwipeTowardEndSettingName = 'music-song-swipe-toward-end';
const musicSongSwipeTowardStartSettingName = 'music-song-swipe-toward-start';
const musicPreviousTrackPolicySettingName = 'music-previous-track-policy';
const musicPauseAtRepeatSettingName = 'music-pause-at-repeat';
const musicKeepPausedOnSkipSettingName = 'music-keep-paused-on-skip';
const musicPlaybackVolumeSettingName = 'music-playback-volume';
const musicScreenPrivacySettingName = 'music-screen-privacy';
const musicQueueLockedSettingName = 'music-queue-locked';
const songTransitionModeSettingName = 'music-song-transition';
const songTransitionSecondsSettingName = 'music-song-transition-seconds';
const preserveAlbumTransitionsSettingName = 'music-preserve-album-transitions';
const musicStreamingQualitySettingName = 'music-streaming-quality';
const musicResumeAfterAudioFocusLossSettingName =
    'music-resume-after-audio-focus-loss';
const musicPauseAtZeroVolumeSettingName = 'music-pause-at-zero-volume';
const musicResumeOnVolumeRiseSettingName = 'music-resume-on-volume-rise';
const musicAutoReconnectSettingName = 'music-auto-reconnect';
const musicResumeOnBluetoothReconnectSettingName =
    'music-resume-on-bluetooth-reconnect';
const musicSkipAfterRetryExhaustionSettingName =
    'music-skip-after-retry-exhaustion';
const musicRememberQueueAfterRestartSettingName =
    'music-remember-queue-after-restart';
const musicTaskRemovalSettingName = 'music-task-removal';
const musicAudioOffloadSettingName = 'music-audio-offload';
const musicWiredHeadsetAutoplaySettingName = 'music-wired-headset-autoplay';
const homeContentModeSettingName = 'home-content-mode';
const homeExperienceSettingName = 'home-experience';
const musicCoverCornersSettingName = 'music-cover-corners';
const deviceMusicArtworkLoadingSettingName = 'device-music-artwork-loading';
const deviceMusicArtworkSourceSettingName = 'device-music-artwork-source';
const deviceMusicArtworkQualitySettingName = 'device-music-artwork-quality';
const deviceMusicArtworkCropSettingName = 'device-music-artwork-crop';
const musicCommunityCoverSettingName = 'music-community-cover-art-enabled';
const musicDownloadFormatSettingName = 'music-download-output-format';
const musicDownloadOrderSettingName = 'music-download-order';
const navigationBarLabelBehaviorSettingName = 'navigation-bar-label-behavior';
const distractionFreeModeSettingName = 'distraction-free-mode';
const hideCommentsByDefaultSettingName = 'hide-comments-by-default';
const hideWatchedSubscriptionsSettingName = 'hide-watched-subscriptions';
const subscriptionAccountSetting = 'subscription-source-account-v1';
const backgroundNotificationsSettingName = 'background-notifications';
const backgroundCheckFrequency = "background-check-frequency";
const subtitleBackground = 'subtitle-background';
const dearrowSettingName = 'dearrow';
const dearrowThumbnailsSettingName = "dearrow-thumbnails";
const fullScreenOnLandscapeSettingName = "fullscreen-on-landscape";
const screenControlsSettingName = "screen-controls";
const forceTvUiSettingName = "force-tv-ui";

const onOpenSettingName = "on-open";

@JsonSerializable()
class SettingsValue {
  String name;

  String value;

  SettingsValue(this.name, this.value);

  factory SettingsValue.fromJson(Map<String, dynamic> json) =>
      _$SettingsValueFromJson(json);

  Map<String, dynamic> toJson() => _$SettingsValueToJson(this);
}
