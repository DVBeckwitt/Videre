import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../downloads/models/music_download_format.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../music/models/device_music_artwork_preferences.dart';
import '../../../music/models/music_background_playback.dart';
import '../../../music/models/music_cover_corners.dart';
import '../../../music/models/music_mini_player_preferences.dart';
import '../../../music/models/music_song_row_swipe_action.dart';
import '../../../music/models/music_song_tap_queue_scope.dart';
import '../../../music/models/music_player_appearance.dart';
import '../../../music/models/song_transition.dart';
import '../../../music/services/music_community_cover_preferences.dart';
import '../../../music/services/music_lyrics_preferences.dart';
import '../../../music/views/components/music_history_privacy.dart';
import '../../../music/views/components/music_screen_privacy.dart';
import '../../../player/models/music_audio_quality.dart';
import '../../../utils.dart' show selectKeys;
import '../../states/settings.dart';
import 'music_artwork_cache_settings.dart';

class MusicProviderSettings extends StatelessWidget {
  const MusicProviderSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final (mode, seconds) = context.select((SettingsCubit settings) => (
          settings.state.songTransitionMode,
          settings.state.songTransitionSeconds
        ));
    final settings = context.read<SettingsCubit>();
    final quality = context.select(
        (SettingsCubit settings) => settings.state.musicStreamingQuality);
    final (songTapScope, retainShuffle) =
        context.select((SettingsCubit settings) => (
              settings.state.musicSongTapQueueScope,
              settings.state.musicRetainShuffleOnSongTap,
            ));
    final (previousTrack, pauseAtRepeat, keepPausedOnSkip) =
        context.select((SettingsCubit settings) => (
              settings.state.musicPreviousTrackPolicy,
              settings.state.musicPauseAtRepeat,
              settings.state.musicKeepPausedOnSkip,
            ));
    final (
      resumeAfterAudioFocusLoss,
      pauseAtZeroVolume,
      autoReconnect,
      skipAfterRetryExhaustion,
    ) = context.select((SettingsCubit settings) => (
          settings.state.musicResumeAfterAudioFocusLoss,
          settings.state.musicPauseAtZeroVolume,
          settings.state.musicAutoReconnect,
          settings.state.musicSkipAfterRetryExhaustion,
        ));
    final (taskRemoval, audioOffload) =
        context.select((SettingsCubit settings) => (
              settings.state.musicTaskRemoval,
              settings.state.musicAudioOffload,
            ));
    final screenPrivacy = context
        .select((SettingsCubit settings) => settings.state.musicScreenPrivacy);
    final (miniLayout, miniShortcut, artworkSwipe, artworkDoubleTapSeek) =
        context.select((SettingsCubit settings) => (
              settings.state.musicMiniPlayerLayout,
              settings.state.musicMiniPlayerShortcut,
              settings.state.musicArtworkSwipe,
              settings.state.musicArtworkDoubleTapSeek,
            ));
    final app = context.watch<AppCubit>().state;
    final (swipeTowardEnd, swipeTowardStart) =
        context.select((SettingsCubit settings) => (
              settings.state.musicSongSwipeTowardEnd,
              settings.state.musicSongSwipeTowardStart,
            ));
    final rtl = Directionality.of(context) == TextDirection.rtl;
    String rowSwipeLabel(MusicSongRowSwipeAction action) => switch (action) {
          MusicSongRowSwipeAction.off => locals.musicSongRowSwipeOff,
          MusicSongRowSwipeAction.playNext => locals.playNext,
          MusicSongRowSwipeAction.addToQueue => locals.addToQueueList,
        };
    bool canChangePreference() {
      final current = context.read<AppCubit>().state;
      return db.profileId == app.profileId &&
          current.profileId == app.profileId &&
          current.sessionRevision == app.sessionRevision &&
          !current.globalLoading &&
          !current.sessionRecoveryRequired;
    }

    ValueChanged<bool>? onPreferenceChanged(Future<void> Function(bool) save) {
      if (!canChangePreference()) return null;
      return (enabled) async {
        if (!canChangePreference()) return;
        try {
          await save(enabled);
        } catch (_) {
          if (context.mounted && canChangePreference()) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(locals.error)));
          }
        }
      };
    }

    String modeLabel(SongTransitionMode value) => switch (value) {
          SongTransitionMode.seamless => locals.musicTransitionSeamless,
          SongTransitionMode.pause => locals.musicTransitionPause,
          SongTransitionMode.fade => locals.musicTransitionFade,
          SongTransitionMode.crossfade => locals.musicTransitionCrossfade,
        };
    return Column(mainAxisSize: MainAxisSize.min, children: [
      const MusicHistoryPrivacy(),
      _MusicChoice<MusicStreamingQuality>(
        tileKey: const ValueKey('music-streaming-quality-setting'),
        icon: Icons.high_quality_outlined,
        title: locals.musicStreamingQualitySetting,
        values: MusicStreamingQuality.values,
        read: () => quality,
        label: (value) => switch (value) {
          MusicStreamingQuality.auto => locals.musicAudioQualityAuto,
          MusicStreamingQuality.dataSaver => locals.musicAudioQualityDataSaver,
          MusicStreamingQuality.highest => locals.musicAudioQualityHighest,
        },
        optionKey: (value) => ValueKey('music-streaming-quality-${value.name}'),
        save: settings.setMusicStreamingQuality,
      ),
      _MusicChoice<MusicSongTapQueueScope>(
        tileKey: const ValueKey('music-song-tap-queue-setting'),
        icon: Icons.queue_music,
        title: locals.musicSongTapQueueSetting,
        values: MusicSongTapQueueScope.values,
        read: () => songTapScope,
        label: (value) => switch (value) {
          MusicSongTapQueueScope.collection => locals.musicSongTapCollection,
          MusicSongTapQueueScope.songOnly => locals.musicSongTapSongOnly,
        },
        optionKey: (value) => ValueKey('music-song-tap-queue-${value.name}'),
        save: settings.setMusicSongTapQueueScope,
      ),
      Shortcuts(
        shortcuts: {
          for (final key in selectKeys)
            SingleActivator(key): const ActivateIntent()
        },
        child: SwitchListTile(
          key: const ValueKey('music-retain-shuffle-on-song-tap-setting'),
          secondary: const Icon(Icons.shuffle),
          title: Text(locals.musicRetainShuffleOnSongTap),
          subtitle: Text(locals.musicRetainShuffleOnSongTapHelp),
          value: retainShuffle,
          onChanged:
              onPreferenceChanged(settings.setMusicRetainShuffleOnSongTap),
        ),
      ),
      _MusicChoice<bool>(
        tileKey: const ValueKey('music-audio-focus-return-setting'),
        icon: Icons.pause_circle_outline,
        title: locals.musicAudioFocusReturnSetting,
        values: const [true, false],
        read: () => resumeAfterAudioFocusLoss,
        label: (resume) => resume
            ? locals.musicAudioFocusResume
            : locals.musicAudioFocusStayPaused,
        optionKey: (resume) => ValueKey('music-audio-focus-return-$resume'),
        save: settings.setMusicResumeAfterAudioFocusLoss,
      ),
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
        _MusicChoice<bool>(
          tileKey: const ValueKey('music-volume-zero-setting'),
          icon: Icons.volume_off_outlined,
          title: locals.musicVolumeZeroSetting,
          values: const [false, true],
          read: () => pauseAtZeroVolume,
          label: (pause) =>
              pause ? locals.musicVolumeZeroPause : locals.musicVolumeZeroPlay,
          description: (pause) =>
              pause ? locals.musicVolumeZeroPauseHelp : null,
          optionKey: (pause) => ValueKey('music-volume-zero-$pause'),
          save: settings.setMusicPauseAtZeroVolume,
        ),
      _MusicChoice<bool>(
        tileKey: const ValueKey('music-reconnect-setting'),
        icon: Icons.sync_outlined,
        title: locals.musicReconnectSetting,
        values: const [true, false],
        read: () => autoReconnect,
        label: (automatic) =>
            automatic ? locals.musicReconnectAuto : locals.musicReconnectManual,
        optionKey: (automatic) => ValueKey('music-reconnect-$automatic'),
        save: settings.setMusicAutoReconnect,
      ),
      _MusicChoice<bool>(
        tileKey: const ValueKey('music-retry-exhaustion-setting'),
        icon: Icons.skip_next_outlined,
        title: locals.musicRetryExhaustionSetting,
        values: const [false, true],
        read: () => skipAfterRetryExhaustion,
        label: (skip) => skip
            ? locals.musicRetryExhaustionSkip
            : locals.musicRetryExhaustionStay,
        optionKey: (skip) => ValueKey('music-retry-exhaustion-$skip'),
        save: settings.setMusicSkipAfterRetryExhaustion,
      ),
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) ...[
        _MusicChoice<MusicTaskRemoval>(
          tileKey: const ValueKey('music-task-removal-setting'),
          icon: Icons.app_shortcut_outlined,
          title: locals.musicTaskRemovalSetting,
          values: MusicTaskRemoval.values,
          read: () => taskRemoval,
          label: (value) => switch (value) {
            MusicTaskRemoval.stop => locals.musicTaskRemovalStop,
            MusicTaskRemoval.keepPlaying => locals.musicTaskRemovalKeepPlaying,
          },
          description: (value) => value == MusicTaskRemoval.keepPlaying
              ? locals.musicTaskRemovalKeepPlayingHelp
              : null,
          optionKey: (value) => ValueKey('music-task-removal-${value.name}'),
          save: settings.setMusicTaskRemoval,
        ),
        _MusicChoice<MusicAudioOffload>(
          tileKey: const ValueKey('music-audio-offload-setting'),
          icon: Icons.battery_saver_outlined,
          title: locals.musicAudioOffloadSetting,
          values: MusicAudioOffload.values,
          read: () => audioOffload,
          label: (value) => switch (value) {
            MusicAudioOffload.disabled => locals.musicAudioOffloadDisabled,
            MusicAudioOffload.whenSupported =>
              locals.musicAudioOffloadWhenSupported,
          },
          description: (value) => value == MusicAudioOffload.whenSupported
              ? locals.musicAudioOffloadWhenSupportedHelp
              : null,
          optionKey: (value) => ValueKey('music-audio-offload-${value.name}'),
          save: settings.setMusicAudioOffload,
        ),
      ],
      _MusicChoice<MusicNowPlayingStyle>(
        tileKey: const ValueKey('music-now-playing-style-setting'),
        icon: Icons.dashboard_outlined,
        title: locals.musicNowPlayingStyle,
        values: MusicNowPlayingStyle.values,
        read: () => MusicNowPlayingStyle.forDatabase(db),
        label: (value) => switch (value) {
          MusicNowPlayingStyle.classic => locals.musicNowPlayingClassic,
          MusicNowPlayingStyle.largeArtwork =>
            locals.musicNowPlayingLargeArtwork,
          MusicNowPlayingStyle.compact => locals.musicNowPlayingCompact,
        },
        optionKey: (value) => ValueKey('music-now-playing-style-${value.name}'),
        save: (value) => value.save(db),
      ),
      _MusicChoice<MusicPlayerBackground>(
        tileKey: const ValueKey('music-player-background-setting'),
        icon: Icons.wallpaper_outlined,
        title: locals.musicPlayerBackground,
        values: MusicPlayerBackground.values,
        read: () => MusicPlayerBackground.forDatabase(db),
        label: (value) => switch (value) {
          MusicPlayerBackground.artwork => locals.musicPlayerBackgroundArtwork,
          MusicPlayerBackground.solid => locals.musicPlayerBackgroundSolid,
        },
        optionKey: (value) => ValueKey('music-player-background-${value.name}'),
        save: (value) => value.save(db),
      ),
      _MusicChoice<MusicScrubberStyle>(
        tileKey: const ValueKey('music-scrubber-style-setting'),
        icon: Icons.linear_scale_outlined,
        title: locals.musicScrubberStyle,
        values: MusicScrubberStyle.values,
        read: () => MusicScrubberStyle.forDatabase(db),
        label: (value) => switch (value) {
          MusicScrubberStyle.gapped => locals.musicScrubberGapped,
          MusicScrubberStyle.continuous => locals.musicScrubberContinuous,
          MusicScrubberStyle.wave => locals.musicScrubberWave,
        },
        optionKey: (value) => ValueKey('music-scrubber-style-${value.name}'),
        save: (value) => value.save(db),
      ),
      if (!isTv) ...[
        _MusicChoice<MusicMiniPlayerLayout>(
          tileKey: const ValueKey('music-mini-player-layout-setting'),
          icon: Icons.view_compact_outlined,
          title: locals.musicMiniPlayerLayout,
          values: MusicMiniPlayerLayout.values,
          read: () => miniLayout,
          label: (value) => switch (value) {
            MusicMiniPlayerLayout.automatic => locals.downloadAutomatic,
            MusicMiniPlayerLayout.compact => locals.musicMiniPlayerCompact,
            MusicMiniPlayerLayout.transport => locals.musicMiniPlayerTransport,
          },
          optionKey: (value) =>
              ValueKey('music-mini-player-layout-${value.name}'),
          save: settings.setMusicMiniPlayerLayout,
        ),
        _MusicChoice<MusicMiniPlayerShortcut>(
          tileKey: const ValueKey('music-mini-player-shortcut-setting'),
          icon: Icons.touch_app_outlined,
          title: locals.musicMiniPlayerShortcut,
          values: MusicMiniPlayerShortcut.values,
          read: () => miniShortcut,
          label: (value) => switch (value) {
            MusicMiniPlayerShortcut.automatic => locals.downloadAutomatic,
            MusicMiniPlayerShortcut.next => locals.musicMiniPlayerNext,
            MusicMiniPlayerShortcut.repeat => locals.musicMiniPlayerRepeat,
            MusicMiniPlayerShortcut.shuffle => locals.musicShuffle,
          },
          optionKey: (value) =>
              ValueKey('music-mini-player-shortcut-${value.name}'),
          save: settings.setMusicMiniPlayerShortcut,
        ),
        SwitchListTile(
          key: const ValueKey('music-artwork-swipe-setting'),
          secondary: const Icon(Icons.swipe_outlined),
          title: Text(locals.musicArtworkSwipe),
          value: artworkSwipe,
          onChanged: onPreferenceChanged(settings.setMusicArtworkSwipe),
        ),
        SwitchListTile(
          key: const ValueKey('music-artwork-double-tap-seek-setting'),
          secondary: const Icon(Icons.touch_app_outlined),
          title: Text(locals.musicArtworkDoubleTapSeek),
          subtitle: Text(locals.musicArtworkDoubleTapSeekHelp),
          value: artworkDoubleTapSeek,
          onChanged: onPreferenceChanged(settings.setMusicArtworkDoubleTapSeek),
        ),
        _MusicChoice<MusicSongRowSwipeAction>(
          tileKey: const ValueKey('music-song-swipe-end-setting'),
          icon: rtl ? Icons.swipe_left_outlined : Icons.swipe_right_outlined,
          title: rtl
              ? locals.musicSongRowSwipeLeft
              : locals.musicSongRowSwipeRight,
          values: MusicSongRowSwipeAction.values,
          read: () => swipeTowardEnd,
          label: rowSwipeLabel,
          optionKey: (value) => ValueKey('music-song-swipe-end-${value.name}'),
          save: settings.setMusicSongSwipeTowardEnd,
        ),
        _MusicChoice<MusicSongRowSwipeAction>(
          tileKey: const ValueKey('music-song-swipe-start-setting'),
          icon: rtl ? Icons.swipe_right_outlined : Icons.swipe_left_outlined,
          title: rtl
              ? locals.musicSongRowSwipeRight
              : locals.musicSongRowSwipeLeft,
          values: MusicSongRowSwipeAction.values,
          read: () => swipeTowardStart,
          label: rowSwipeLabel,
          optionKey: (value) =>
              ValueKey('music-song-swipe-start-${value.name}'),
          save: settings.setMusicSongSwipeTowardStart,
        ),
      ],
      _MusicChoice<MusicPreviousTrackPolicy>(
        tileKey: const ValueKey('music-previous-track-policy-setting'),
        icon: Icons.skip_previous_outlined,
        title: locals.musicPreviousTrackPolicy,
        values: MusicPreviousTrackPolicy.values,
        read: () => previousTrack,
        label: (value) => switch (value) {
          MusicPreviousTrackPolicy.previousTrack =>
            locals.musicPreviousTrackAlways,
          MusicPreviousTrackPolicy.restartCurrentAfterThreshold =>
            locals.musicPreviousTrackRestart,
        },
        optionKey: (value) => ValueKey('music-previous-track-${value.name}'),
        save: settings.setMusicPreviousTrackPolicy,
      ),
      SwitchListTile(
        key: const ValueKey('music-pause-at-repeat-setting'),
        secondary: const Icon(Icons.repeat_rounded),
        title: Text(locals.musicPauseAtRepeat),
        subtitle: Text(locals.musicPauseAtRepeatHelp),
        value: pauseAtRepeat,
        onChanged: onPreferenceChanged(settings.setMusicPauseAtRepeat),
      ),
      SwitchListTile(
        key: const ValueKey('music-keep-paused-on-skip-setting'),
        secondary: const Icon(Icons.pause_rounded),
        title: Text(locals.musicKeepPausedOnSkip),
        value: keepPausedOnSkip,
        onChanged: onPreferenceChanged(settings.setMusicKeepPausedOnSkip),
      ),
      if (supportsMusicScreenPrivacy)
        SwitchListTile(
          key: const ValueKey('music-screen-privacy-setting'),
          secondary: const Icon(Icons.privacy_tip_outlined),
          title: Text(locals.musicScreenPrivacySetting),
          subtitle: Text(locals.musicScreenPrivacyHelp),
          value: screenPrivacy,
          onChanged: onPreferenceChanged(settings.setMusicScreenPrivacy),
        ),
      _MusicChoice<SongTransitionMode>(
        tileKey: const ValueKey('music-transition-setting'),
        icon: Icons.multitrack_audio_rounded,
        title: locals.musicTransitionSetting,
        subtitle: locals.musicTransitionSummary(modeLabel(mode)),
        values: SongTransitionMode.values,
        read: () => mode,
        label: modeLabel,
        description: (value) => value == SongTransitionMode.crossfade
            ? locals.musicTransitionCrossfadeHelp
            : null,
        optionKey: (value) => ValueKey('music-transition-${value.name}'),
        save: settings.setSongTransitionMode,
      ),
      if (mode != SongTransitionMode.seamless)
        _MusicChoice<int>(
          tileKey: const ValueKey('music-transition-duration-setting'),
          icon: Icons.timer_outlined,
          title: locals.musicTransitionDuration,
          values: [
            for (var value = minSongTransitionSeconds;
                value <= maxSongTransitionSeconds;
                value++)
              value
          ],
          read: () => seconds,
          label: locals.musicTransitionSeconds,
          optionKey: (value) => ValueKey('music-transition-seconds-$value'),
          save: settings.setSongTransitionSeconds,
        ),
      _ProviderSwitch(
        tileKey: const ValueKey('music-lrclib-setting'),
        icon: Icons.lyrics_outlined,
        title: locals.musicLrclibSetting,
        help: locals.musicLrclibSettingHelp,
        revision: lrclibPreferenceRevision,
        read: isLrclibEnabled,
        write: setLrclibEnabled,
      ),
      _ProviderSwitch(
        tileKey: const ValueKey('music-community-cover-setting'),
        icon: Icons.album_outlined,
        title: locals.musicCommunityCoverSetting,
        help: locals.musicCommunityCoverSettingHelp,
        revision: communityCoverArtPreferenceRevision,
        read: isCommunityCoverArtEnabled,
        write: setCommunityCoverArtEnabled,
      ),
      const MusicArtworkCacheSettings(),
      _MusicChoice<MusicCoverCorners>(
        tileKey: const ValueKey('music-cover-corners-setting'),
        icon: Icons.crop_square_outlined,
        title: locals.musicCoverCorners,
        values: MusicCoverCorners.values,
        read: () => MusicCoverCorners.forDatabase(db),
        label: (corners) => switch (corners) {
          MusicCoverCorners.rounded => locals.musicCoverCornersRounded,
          MusicCoverCorners.square => locals.musicCoverCornersSquare,
        },
        optionKey: (corners) => ValueKey('music-cover-corners-${corners.name}'),
        save: (corners) => corners.save(db),
      ),
      _MusicChoice<DeviceMusicArtworkSource>(
        tileKey: const ValueKey('device-music-artwork-source-setting'),
        icon: Icons.folder_outlined,
        title: locals.deviceMusicArtworkSource,
        values: DeviceMusicArtworkSource.values,
        read: () => DeviceMusicArtworkPreferences.forDatabase(db).source,
        label: (value) => switch (value) {
          DeviceMusicArtworkSource.preferAdjacent =>
            locals.deviceMusicArtworkPreferFolder,
          DeviceMusicArtworkSource.embeddedOnly =>
            locals.deviceMusicArtworkEmbeddedOnly,
        },
        description: (value) => value == DeviceMusicArtworkSource.preferAdjacent
            ? locals.deviceMusicArtworkPreferFolderHelp
            : null,
        optionKey: (value) =>
            ValueKey('device-music-artwork-source-${value.name}'),
        save: (value) => DeviceMusicArtworkPreferences.setSource(db, value),
      ),
      _MusicChoice<DeviceMusicArtworkQuality>(
        tileKey: const ValueKey('device-music-artwork-quality-setting'),
        icon: Icons.high_quality_outlined,
        title: locals.deviceMusicArtworkQuality,
        values: DeviceMusicArtworkQuality.values,
        read: () => DeviceMusicArtworkPreferences.forDatabase(db).quality,
        label: (value) => switch (value) {
          DeviceMusicArtworkQuality.balanced =>
            locals.deviceMusicArtworkQualityBalanced,
          DeviceMusicArtworkQuality.high =>
            locals.deviceMusicArtworkQualityHigh,
        },
        optionKey: (value) =>
            ValueKey('device-music-artwork-quality-${value.name}'),
        save: (value) => DeviceMusicArtworkPreferences.setQuality(db, value),
      ),
      _MusicChoice<DeviceMusicArtworkCrop>(
        tileKey: const ValueKey('device-music-artwork-crop-setting'),
        icon: Icons.crop_outlined,
        title: locals.deviceMusicArtworkFit,
        values: DeviceMusicArtworkCrop.values,
        read: () => DeviceMusicArtworkPreferences.forDatabase(db).crop,
        label: (value) => switch (value) {
          DeviceMusicArtworkCrop.crop => locals.deviceMusicArtworkFill,
          DeviceMusicArtworkCrop.fit => locals.deviceMusicArtworkFitWhole,
        },
        optionKey: (value) =>
            ValueKey('device-music-artwork-crop-${value.name}'),
        save: (value) => DeviceMusicArtworkPreferences.setCrop(db, value),
      ),
      _MusicChoice<MusicDownloadFormat>(
        tileKey: const ValueKey('music-download-format-setting'),
        icon: Icons.audio_file_outlined,
        title: locals.musicDownloadFormatSetting,
        values: MusicDownloadFormat.values,
        read: () => MusicDownloadFormat.forDatabase(db),
        label: (format) => format == MusicDownloadFormat.opus
            ? locals.musicDownloadOpusBestQuality
            : format.label,
        description: (format) => format == MusicDownloadFormat.opus
            ? locals.musicDownloadOpusHelp
            : null,
        optionKey: (format) => ValueKey('music-download-format-${format.name}'),
        save: (format) => format.save(db),
      ),
    ]);
  }
}

class _MusicChoice<T extends Object> extends StatefulWidget {
  final Key tileKey;
  final IconData icon;
  final String title;
  final String? subtitle;
  final List<T> values;
  final T Function() read;
  final String Function(T) label;
  final String? Function(T)? description;
  final Key Function(T) optionKey;
  final Future<void> Function(T) save;

  const _MusicChoice(
      {required this.tileKey,
      required this.icon,
      required this.title,
      this.subtitle,
      required this.values,
      required this.read,
      required this.label,
      this.description,
      required this.optionKey,
      required this.save});

  @override
  State<_MusicChoice<T>> createState() => _MusicChoiceState<T>();
}

class _MusicChoiceState<T extends Object> extends State<_MusicChoice<T>> {
  Future<void> _select() async {
    final app = context.read<AppCubit>();
    final database = db;
    final profile = database.profileId;
    final session = app.state.sessionRevision;
    bool isCurrent() =>
        mounted &&
        !app.isClosed &&
        identical(db, database) &&
        db.profileId == profile &&
        app.state.profileId == profile &&
        app.state.sessionRevision == session &&
        !app.state.globalLoading &&
        !app.state.sessionRecoveryRequired;
    if (!isCurrent()) return;
    final current = widget.read();
    final options = widget;
    final locals = AppLocalizations.of(context)!;
    final selected = await showDialog<T>(
      context: context,
      builder: (context) => Shortcuts(
        shortcuts: {
          for (final key in selectKeys)
            SingleActivator(key): const ActivateIntent()
        },
        child: SimpleDialog(
          title: Text(options.title),
          children: [
            for (final value in options.values)
              ListTile(
                key: options.optionKey(value),
                autofocus: value == current,
                selected: value == current,
                title: Text(options.label(value)),
                subtitle: switch (options.description?.call(value)) {
                  final String text => Text(text),
                  null => null,
                },
                trailing: value == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, value),
              ),
            Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(locals.cancel))),
          ],
        ),
      ),
    );
    if (selected == null || selected == current || !isCurrent()) return;
    try {
      await options.save(selected);
      if (isCurrent()) setState(() {});
    } catch (_) {
      if (mounted && isCurrent()) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(locals.error)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppCubit>().state;
    return Semantics(
        container: true,
        child: Shortcuts(
          shortcuts: {
            for (final key in selectKeys)
              SingleActivator(key): const ActivateIntent()
          },
          child: ListTile(
            key: widget.tileKey,
            leading: Icon(widget.icon),
            title: Text(widget.title),
            subtitle: Text(widget.subtitle ?? widget.label(widget.read())),
            onTap: db.profileId == app.profileId &&
                    !app.globalLoading &&
                    !app.sessionRecoveryRequired
                ? _select
                : null,
          ),
        ));
  }
}

class _ProviderSwitch extends StatelessWidget {
  final Key tileKey;
  final IconData icon;
  final String title, help;
  final ValueListenable<int> revision;
  final bool Function() read;
  final Future<void> Function(bool, {String? expectedProfileId}) write;

  const _ProviderSwitch({
    required this.tileKey,
    required this.icon,
    required this.title,
    required this.help,
    required this.revision,
    required this.read,
    required this.write,
  });

  @override
  Widget build(BuildContext context) {
    final profile = context.select((AppCubit app) => app.state.profileId);
    return ValueListenableBuilder<int>(
      valueListenable: revision,
      builder: (context, _, child) {
        final active = db.profileId == profile;
        return Shortcuts(
          shortcuts: {
            for (final key in selectKeys)
              SingleActivator(key): const ActivateIntent(),
          },
          child: SwitchListTile(
            key: tileKey,
            secondary: Icon(icon),
            title: Text(title),
            subtitle: Text(help),
            value: active && read(),
            onChanged: active
                ? (value) async {
                    try {
                      await write(value, expectedProfileId: profile);
                    } catch (_) {
                      if (context.mounted && db.profileId == profile) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content:
                                Text(AppLocalizations.of(context)!.error)));
                      }
                    }
                  }
                : null,
          ),
        );
      },
    );
  }
}
