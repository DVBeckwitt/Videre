import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../downloads/models/music_download_format.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../music/models/music_cover_corners.dart';
import '../../../music/models/music_mini_player_preferences.dart';
import '../../../music/models/song_transition.dart';
import '../../../music/services/music_community_cover_preferences.dart';
import '../../../music/services/music_lyrics_preferences.dart';
import '../../../music/views/components/music_history_privacy.dart';
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
    final (miniLayout, miniShortcut, artworkSwipe, artworkDoubleTapSeek) =
        context.select((SettingsCubit settings) => (
              settings.state.musicMiniPlayerLayout,
              settings.state.musicMiniPlayerShortcut,
              settings.state.musicArtworkSwipe,
              settings.state.musicArtworkDoubleTapSeek,
            ));
    final app = context.watch<AppCubit>().state;
    bool canChangeArtworkGesture() {
      final current = context.read<AppCubit>().state;
      return db.profileId == app.profileId &&
          current.profileId == app.profileId &&
          current.sessionRevision == app.sessionRevision &&
          !current.globalLoading &&
          !current.sessionRecoveryRequired;
    }

    ValueChanged<bool>? onArtworkGestureChanged(
        Future<void> Function(bool) save) {
      if (!canChangeArtworkGesture()) return null;
      return (enabled) async {
        if (!canChangeArtworkGesture()) return;
        try {
          await save(enabled);
        } catch (_) {
          if (context.mounted && canChangeArtworkGesture()) {
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
          onChanged: onArtworkGestureChanged(settings.setMusicArtworkSwipe),
        ),
        SwitchListTile(
          key: const ValueKey('music-artwork-double-tap-seek-setting'),
          secondary: const Icon(Icons.touch_app_outlined),
          title: Text(locals.musicArtworkDoubleTapSeek),
          subtitle: Text(locals.musicArtworkDoubleTapSeekHelp),
          value: artworkDoubleTapSeek,
          onChanged:
              onArtworkGestureChanged(settings.setMusicArtworkDoubleTapSeek),
        ),
      ],
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
