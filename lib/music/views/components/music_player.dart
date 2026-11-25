import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart' show db;
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/local_music_artist.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/music_content_advisory.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_lyrics_service.dart';
import 'package:clipious/music/views/components/music_playback_toggles.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/backend_recovery_notice.dart';
import 'package:clipious/player/views/components/player_backend_picker.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/player/models/sleep_timer.dart';
import 'package:clipious/player/views/components/playlist_loading_notice.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/models/theme_palette.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'local_music_folder.dart' show renameLocalMusicTrack;
import 'music_audio_quality_button.dart';
import 'music_duration_label.dart';
import 'music_library_actions.dart';
import 'music_player_artwork.dart';
import 'music_playback_artwork.dart';
import 'music_playing_device_artists.dart';
import 'music_playing_source.dart';
import 'music_sound_sheet.dart';
import 'music_sponsor_notice.dart';
import 'music_wide_player_layout.dart';

/// Presentation only: commands still reach the existing mounted audio decoder.
class MusicPlayer extends StatefulWidget {
  final bool television;
  final MusicLyricsLoader lyricsLoader;
  final MusicVideoSurfaceBuilder? videoSurfaceBuilder;

  const MusicPlayer(
      {super.key,
      this.television = false,
      this.lyricsLoader = loadMusicLyrics,
      this.videoSurfaceBuilder});

  @override
  State<MusicPlayer> createState() => _MusicPlayerState();
}

const _canvas = Color(0xff121212);

/// Resolves saved titles for the visible player without changing its queue.
class MusicPlaybackTitles extends StatelessWidget {
  const MusicPlaybackTitles({super.key, required this.builder});

  final Widget Function(BuildContext, String? Function(IdedVideo?)) builder;

  @override
  Widget build(BuildContext context) {
    final profileId = context.select((AppCubit? app) {
      final session = app?.state;
      if (session == null ||
          session.globalLoading ||
          session.sessionRecoveryRequired) {
        return null;
      }
      return session.profileId;
    });
    final library = profileId != null && profileId == db.profileId
        ? MusicLibraryService.forProfile(db, profileId)
        : null;

    String? savedTitle(IdedVideo? entry) {
      if (library == null ||
          entry == null ||
          isLocalMusicPlaybackId(entry.videoId)) {
        return null;
      }
      final ownedSong = switch (entry) {
        Video(
          :final musicMetadata,
          :final playbackConnection,
          :final backendPlayback
        ) =>
          musicMetadata != null &&
              ((playbackConnection ?? backendPlayback)?.server.profileId ??
                      library.profileId) ==
                  library.profileId,
        DownloadedVideo(:final musicMetadata, :final profileId) =>
          musicMetadata != null && profileId == library.profileId,
        _ => false,
      };
      return ownedSong ? library.savedSong(entry.videoId)?.savedTitle : null;
    }

    return ListenableBuilder(
      listenable: library?.changes ?? const AlwaysStoppedAnimation(0),
      builder: (context, _) => builder(context, savedTitle),
    );
  }
}

/// Keeps the song launcher and the active player on the same surface.
class _MusicPlayerSurface extends StatelessWidget {
  final Widget child;

  const _MusicPlayerSurface({required this.child});

  static const _playerColors = ColorScheme.dark(
    surface: _canvas,
    surfaceContainer: Color(0xff232323),
    surfaceContainerHigh: Color(0xff303030),
    surfaceContainerHighest: Color(0xff3d3d3d),
    onSurface: Color(0xfff0f0f0),
    onSurfaceVariant: Color(0xffc7c7c7),
    primary: Color(0xfff0f0f0),
    onPrimary: _canvas,
    primaryContainer: Color(0xff444444),
    onPrimaryContainer: Color(0xfff0f0f0),
    secondaryContainer: Color(0xff595959),
    onSecondaryContainer: Color(0xfff0f0f0),
  );

  @override
  Widget build(BuildContext context) {
    final appTheme = Theme.of(context);
    final palette =
        context.select((SettingsCubit cubit) => cubit.state.themePalette);
    final colors = palette == ThemePalette.classicPurple
        ? ThemePalette.classicDark
        : _playerColors;
    return Theme(
      data: appTheme.copyWith(
        brightness: Brightness.dark,
        colorScheme: colors,
        iconTheme: IconThemeData(color: colors.onSurface),
        textTheme: appTheme.textTheme.apply(
          bodyColor: colors.onSurface,
          displayColor: colors.onSurface,
        ),
      ),
      child: Material(color: colors.surface, child: child),
    );
  }
}

class MusicPlayerOpening extends StatelessWidget {
  final Widget child;
  final VoidCallback? onBack;
  final FocusNode? backFocus;

  const MusicPlayerOpening(
      {super.key, required this.child, this.onBack, this.backFocus});

  @override
  Widget build(BuildContext context) {
    return _MusicPlayerSurface(
      child: SafeArea(
        child: Column(children: [
          AppBar(
              automaticallyImplyLeading: false,
              leading: onBack == null
                  ? null
                  : IconButton(
                      focusNode: backFocus,
                      onPressed: onBack,
                      tooltip:
                          MaterialLocalizations.of(context).backButtonTooltip,
                      icon: const BackButtonIcon()),
              title: Text(AppLocalizations.of(context)!.musicNowPlaying),
              centerTitle: true,
              backgroundColor: Colors.transparent),
          Expanded(
              child: Center(
                  child: Padding(
                      padding: const EdgeInsets.all(24), child: child))),
        ]),
      ),
    );
  }
}

class _MusicPlayerState extends State<MusicPlayer>
    with SingleTickerProviderStateMixin {
  bool? _queueVisibility;
  late final AnimationController _queueMotion;
  bool _draggingQueue = false;
  // The cover and its active inline video move between columns as the queue
  // opens and the viewport rotates. Keep the same surface for the same song.
  final _artwork = GlobalKey();
  (Object, double)? _portraitReserve;
  final _queueButtonFocus = FocusNode(debugLabel: 'Music queue');
  final _closeQueueFocus = FocusNode(debugLabel: 'Close music queue');
  final _queueScope = FocusScopeNode(debugLabel: 'Music queue overlay');
  double? _seekPosition;
  String? _queueId;
  int? _layoutMode;
  int _layoutRevision = 0;

  @override
  void initState() {
    super.initState();
    _queueMotion = AnimationController(vsync: this);
  }

  void _setQueueVisible(bool visible) {
    setState(() {
      _queueVisibility = visible;
      _draggingQueue = false;
    });
    _settleQueue(visible);
    // Phone keyboards and remotes need the same entry point as TV. Wait for
    // the overlay to mount, or for ExcludeFocus to release the player controls.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _queueVisibility != visible) return;
      (visible ? _closeQueueFocus : _queueButtonFocus).requestFocus();
    });
  }

  void _settleQueue(bool open) {
    final target = open ? 1.0 : 0.0;
    final duration = AppMotion.duration(context);
    if (duration == Duration.zero) {
      _queueMotion.value = target;
    } else {
      _queueMotion.animateTo(target,
          duration: duration, curve: Curves.easeOutCubic);
    }
  }

  void _startQueueDrag(DragStartDetails details) {
    _queueMotion.stop();
    setState(() => _draggingQueue = true);
  }

  void _updateQueueDrag(DragUpdateDetails details, double travel) {
    if (!_draggingQueue) return;
    _queueMotion.value =
        (_queueMotion.value - details.delta.dy / travel).clamp(0.0, 1.0);
  }

  void _releaseQueueDrag(DragEndDetails details) {
    if (!_draggingQueue) return;
    final velocity = details.primaryVelocity ?? 0;
    final open =
        velocity.abs() >= 550 ? velocity < 0 : _queueMotion.value >= 0.5;
    _setQueueVisible(open);
  }

  void _cancelQueueDrag() {
    if (!_draggingQueue) return;
    setState(() => _draggingQueue = false);
    _settleQueue(_queueVisibility == true);
  }

  @override
  void dispose() {
    // An old pointer can still send its final event after this surface closes.
    _draggingQueue = false;
    _queueMotion.dispose();
    _queueButtonFocus.dispose();
    _closeQueueFocus.dispose();
    _queueScope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _MusicPlayerSurface(
        child: MusicPlaybackTitles(builder: _buildPlayer));
  }

  Widget _buildPlayer(
      BuildContext context, String? Function(IdedVideo?) savedTitle) {
    final app = context.watch<AppCubit>();
    final session = app.state;
    final player = context.read<PlayerCubit>();
    final state = context.watch<PlayerCubit>().state;
    final pending = player.openingMusicEntry;
    final entry =
        pending ?? state.currentlyPlaying ?? state.offlineCurrentlyPlaying;
    final video = entry is Video ? entry : null;
    final offline = entry is DownloadedVideo ? entry : null;
    final onDevice = isLocalMusicPlaybackId(video?.videoId ?? offline?.videoId);
    final recovery = onDevice || pending != null ? null : state.backendRecovery;
    final queueId = entry == null ? null : playbackQueueId(entry);
    final advisoryQueueId = pending == null &&
            state.isAudio &&
            !state.isHidden &&
            !state.isMini &&
            !state.isClosing &&
            !session.globalLoading &&
            !session.sessionRecoveryRequired &&
            session.profileId == db.profileId &&
            queueId == state.currentQueueId
        ? queueId
        : null;
    final metadataOccurrence = (
      session.profileId,
      session.sessionRevision,
      player.playlistGeneration,
      queueId,
    );
    if (queueId != _queueId) {
      _queueId = queueId;
      _seekPosition = null;
    }
    final music = video?.musicMetadata ?? offline?.musicMetadata;
    if (music == null) return const SizedBox.shrink();
    final displayTitle = savedTitle(entry) ?? music.title;
    final locals = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final titleStyle = theme.textTheme.titleLarge
        ?.copyWith(fontWeight: FontWeight.w700, height: 1.14);
    final seekStep = _seekStep(context, player, state);
    final metadataButtonStyle = IconButton.styleFrom(
      foregroundColor: colors.onPrimary,
      backgroundColor: colors.primary,
      disabledForegroundColor: colors.onSurfaceVariant,
      disabledBackgroundColor: colors.surfaceContainerHighest,
      shape: const CircleBorder(),
      visualDensity: VisualDensity.compact,
      minimumSize: const Size.square(40),
      padding: const EdgeInsets.all(9),
    );
    final view = LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 640 && constraints.maxHeight >= 480;
      final fixedQueue = wide && !widget.television;
      final showQueue = fixedQueue || _queueVisibility == true;
      final sideQueue = wide && showQueue;
      final interactiveArtwork = sideQueue || (!showQueue && !_draggingQueue);
      final allowOnlineArtwork = pending == null &&
          video != null &&
          !onDevice &&
          !video.downloadPlaybackOnly &&
          video.explicitMusicDownload == null &&
          state.isAudio &&
          !state.isMini &&
          !state.isHidden &&
          !state.isClosing &&
          (!showQueue || sideQueue);
      final shortLandscape = !sideQueue &&
          constraints.maxWidth >= 480 &&
          constraints.maxWidth > constraints.maxHeight;
      final portraitPhone = !wide && !shortLandscape && !widget.television;
      final mode = shortLandscape
          ? 1
          : wide
              ? 2
              : 0;
      if (_layoutMode != mode) {
        _layoutMode = mode;
        _layoutRevision++;
        _seekPosition = null;
        // The previous layout's drag recognizer can disappear before pointer-up.
        if (_draggingQueue) {
          _draggingQueue = false;
          _queueMotion.value = _queueVisibility == true ? 1 : 0;
        }
      }
      final nowPlaying = LayoutBuilder(
          builder: (context, viewport) => SingleChildScrollView(
                key: const ValueKey('music-now-playing-scroll'),
                padding: shortLandscape
                    ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
                    : EdgeInsets.fromLTRB(18, 10, 18, portraitPhone ? 6 : 16),
                child: Center(
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 510),
                        child: LayoutBuilder(builder: (context, panel) {
                          final textScale =
                              MediaQuery.textScalerOf(context).scale(20);
                          final metadataHeight =
                              (textScale - 20).clamp(0.0, 45.0);
                          final failed = pending == null &&
                              player.playbackStatus == MediaState.error;
                          final noticeBudget = failed || recovery != null
                              ? 112 + metadataHeight
                              : 0.0;
                          final mountedVideo = state.currentlyPlaying;
                          final mountedOffline = state.offlineCurrentlyPlaying;
                          final mountedMusic = mountedVideo?.musicMetadata ??
                              mountedOffline?.musicMetadata;
                          // Keep the artwork in place while the header previews
                          // an incoming song whose source is still opening.
                          final source = player.playlistReference;
                          final mountedDeviceTrack =
                              localMusicTrackForPlayback(state.currentQueueId);
                          final hasSourceAction = source != null ||
                              mountedMusic?.albumPlaylistId != null ||
                              mountedDeviceTrack?.albumKey != null;
                          final albumTitle = mountedMusic?.album?.trim();
                          final hasSeparateAlbumLabel =
                              musicQueueAlbumId(source) != null &&
                                  mountedMusic?.albumPlaylistId == null &&
                                  albumTitle?.isNotEmpty == true &&
                                  albumTitle !=
                                      (player.musicQueueTitle ??
                                          source?.displayTitle ??
                                          locals.musicOpenAlbum);
                          final sourceBudget =
                              (hasSourceAction ? 48 + metadataHeight : 0.0) +
                                  (hasSeparateAlbumLabel
                                      ? 22 + metadataHeight
                                      : 0.0);
                          final metadataReserve = portraitPhone &&
                                  mountedMusic != null
                              ? _portraitMetadataReserve(
                                  context,
                                  mountedMusic,
                                  savedTitle(mountedVideo ?? mountedOffline) ??
                                      mountedMusic.title,
                                  titleStyle,
                                  width: panel.maxWidth,
                                  hasBookmark: mountedVideo != null,
                                  deviceArtist: mountedDeviceTrack == null
                                      ? null
                                      : localMusicArtistCredits(
                                              mountedDeviceTrack)
                                          .firstOrNull
                                          ?.name,
                                  onDevice: isLocalMusicPlaybackId(
                                      mountedVideo?.videoId ??
                                          mountedOffline?.videoId))
                              : 0.0;
                          final controlBudget = 318 +
                              metadataHeight * 2 +
                              metadataReserve +
                              noticeBudget +
                              sourceBudget;
                          // The portrait viewport excludes the queue's persistent footer.
                          // Reserve space for scaled text and controls before sizing the cover.
                          const artworkSpacing = 12.0;
                          final heightBudget = (portraitPhone
                                  ? viewport.maxHeight
                                  : constraints.maxHeight) -
                              (portraitPhone || wide
                                  ? controlBudget
                                  : 356 + metadataHeight * 2 + sourceBudget) -
                              artworkSpacing;
                          final artworkSize = math.min(
                              panel.maxWidth, heightBudget.clamp(116.0, 480.0));
                          final artwork = !shortLandscape
                              ? SizedBox(
                                  height: artworkSize + artworkSpacing,
                                  child: _artworkFrame(
                                      music, video, offline, artworkSize,
                                      allowOnlineArtwork: allowOnlineArtwork,
                                      interactive: interactiveArtwork,
                                      onSeekStep:
                                          widget.television ? null : seekStep))
                              : null;
                          final controls = Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _MusicMetadataTransition(
                                  occurrence: metadataOccurrence,
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        OverflowBar(
                                          alignment:
                                              MainAxisAlignment.spaceBetween,
                                          spacing: 8,
                                          overflowSpacing: 4,
                                          children: [
                                            Column(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Semantics(
                                                  header: true,
                                                  child: Text(displayTitle,
                                                      key: const ValueKey(
                                                          'music-player-title'),
                                                      style: titleStyle),
                                                ),
                                                const SizedBox(height: 2),
                                                _artistAndAdvisory(
                                                  player,
                                                  advisoryQueueId,
                                                  _artistByline(
                                                      context,
                                                      music,
                                                      onDevice,
                                                      metadataOccurrence),
                                                ),
                                              ],
                                            ),
                                            Wrap(
                                              alignment: WrapAlignment.end,
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              spacing: 4,
                                              children: [
                                                if (!portraitPhone &&
                                                    !onDevice &&
                                                    pending == null)
                                                  MusicAudioQualityButton(
                                                    showLabel:
                                                        panel.maxWidth >= 380 &&
                                                            textScale <= 24,
                                                  ),
                                                if (video != null && !onDevice)
                                                  MusicBookmarkButton(
                                                    key: ValueKey((
                                                      'music-player-bookmark',
                                                      video.videoId
                                                    )),
                                                    entry:
                                                        MusicLibraryEntry.song(
                                                            video),
                                                    iconStyle:
                                                        metadataButtonStyle,
                                                  ),
                                                _songActionsButton(
                                                    pending == null
                                                        ? entry
                                                        : null,
                                                    maxWidth:
                                                        panel.maxWidth * 0.45),
                                              ],
                                            ),
                                          ],
                                        ),
                                        MusicPlayingSource(
                                            music: music,
                                            occurrence: queueId,
                                            television: widget.television),
                                      ]),
                                ),
                                SizedBox(
                                    height: shortLandscape
                                        ? 4
                                        : portraitPhone
                                            ? 6
                                            : 16),
                                if (pending != null ||
                                    player.playbackStatus ==
                                        MediaState.loading ||
                                    player.playbackStatus ==
                                        MediaState.buffering)
                                  const LinearProgressIndicator(),
                                if (recovery != null)
                                  BackendRecoveryNotice(recovery: recovery),
                                if (failed) ...[
                                  Text(
                                      playbackFailureText(
                                          locals, player.playbackFailureReason,
                                          music: true),
                                      textAlign: TextAlign.center),
                                  TextButton.icon(
                                    onPressed: state.hasVideo
                                        ? player.retryCurrentVideo
                                        : null,
                                    icon: const Icon(Icons.refresh),
                                    label: Text(locals.retry),
                                  ),
                                ],
                                _progress(context, player, state,
                                    length: video?.lengthSeconds ??
                                        offline?.lengthSeconds,
                                    live: video?.liveNow == true),
                                SizedBox(
                                    height: shortLandscape
                                        ? 4
                                        : portraitPhone
                                            ? 12
                                            : 16),
                                IconButtonTheme(
                                    data: portraitPhone
                                        ? IconButtonThemeData(
                                            style: IconButton.styleFrom(
                                            minimumSize: const Size.square(48),
                                            shape: const CircleBorder(),
                                            foregroundColor:
                                                colors.onSurfaceVariant,
                                            backgroundColor:
                                                colors.surfaceContainerHighest,
                                          ))
                                        : IconButtonTheme.of(context),
                                    child: Wrap(
                                      alignment: WrapAlignment.spaceBetween,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      spacing: 0,
                                      runSpacing: 8,
                                      children: [
                                        const MusicShuffleButton(
                                            controlKey: ValueKey(
                                                'music-player-shuffle')),
                                        _trackTransport(context, player, state,
                                            previous: true, seekStep: seekStep),
                                        IconButton.filledTonal(
                                            key: const ValueKey(
                                                'music-player-play'),
                                            autofocus: widget.television,
                                            iconSize: 36,
                                            style: IconButton.styleFrom(
                                                fixedSize: Size.square(
                                                    shortLandscape ? 64 : 72),
                                                backgroundColor:
                                                    colors.primaryContainer,
                                                foregroundColor:
                                                    colors.onPrimaryContainer,
                                                shape: portraitPhone
                                                    ? const CircleBorder()
                                                    : RoundedRectangleBorder(
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(25))),
                                            tooltip: state.isPlaying
                                                ? locals.musicPause
                                                : locals.musicPlay,
                                            onPressed: pending == null
                                                ? player.togglePlaying
                                                : null,
                                            icon: Icon(state.isPlaying
                                                ? Icons.pause_rounded
                                                : player.playbackStatus ==
                                                        MediaState.completed
                                                    ? Icons.replay_rounded
                                                    : Icons
                                                        .play_arrow_rounded)),
                                        _trackTransport(context, player, state,
                                            previous: false,
                                            seekStep: seekStep),
                                        const MusicRepeatButton(
                                            controlKey: ValueKey(
                                                'music-player-repeat')),
                                      ],
                                    )),
                                SizedBox(
                                    height: shortLandscape
                                        ? 8
                                        : portraitPhone
                                            ? 12
                                            : 20),
                                _options(context, player, state,
                                    showQueue: showQueue,
                                    onDevice: onDevice,
                                    hideQueueButton: !widget.television &&
                                        (wide || !shortLandscape),
                                    portraitPhone: portraitPhone),
                              ]);
                          if (!portraitPhone) {
                            return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (artwork != null) artwork,
                                  controls
                                ]);
                          }
                          // Muzza centers the cover in the space above a bottom-aligned
                          // control group. Keep that composition scrollable on short
                          // screens and when large text or a retry notice needs room.
                          final artworkTop = math.max(
                              0.0,
                              (viewport.maxHeight -
                                      16 -
                                      controlBudget -
                                      artworkSize -
                                      artworkSpacing) /
                                  2);
                          return ConstrainedBox(
                              constraints: BoxConstraints(
                                  minHeight:
                                      math.max(0.0, viewport.maxHeight - 16)),
                              child: Column(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Padding(
                                      padding: EdgeInsets.only(top: artworkTop),
                                      child: artwork!,
                                    ),
                                    controls
                                  ]));
                        }))),
              ));
      if (fixedQueue) {
        return MusicWidePlayerLayout(
          nowPlaying: nowPlaying,
          queue: const MusicQueue(),
        );
      }
      final swipeQueue = !widget.television && !shortLandscape;
      const footerHeight = 52.0;
      final queueHeight =
          constraints.maxHeight * (shortLandscape ? 0.94 : 0.87);
      final queueTravel = math.max(1.0, queueHeight - footerHeight);
      final queueHeader = Column(mainAxisSize: MainAxisSize.min, children: [
        if (!sideQueue)
          Container(
            margin: const EdgeInsets.only(top: 10),
            width: 30,
            height: 4,
            decoration: BoxDecoration(
              color: colors.onSurfaceVariant.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 8, 4),
          child: Row(children: [
            Expanded(
                child: Text(locals.musicQueue,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700))),
            IconButton(
                key: const ValueKey('music-player-close-queue'),
                focusNode: _closeQueueFocus,
                tooltip: locals.musicNowPlaying,
                onPressed: () => _setQueueVisible(false),
                icon: const Icon(Icons.album_outlined)),
          ]),
        ),
      ]);
      final queue = Column(children: [
        if (swipeQueue)
          GestureDetector(
            key: const ValueKey('music-queue-drag-header'),
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: _startQueueDrag,
            onVerticalDragUpdate: (details) =>
                _updateQueueDrag(details, queueTravel),
            onVerticalDragEnd: _releaseQueueDrag,
            onVerticalDragCancel: _cancelQueueDrag,
            child: queueHeader,
          )
        else
          queueHeader,
        Expanded(child: MusicQueue(television: widget.television)),
      ]);
      Widget interceptBack(Widget child, {bool active = true}) =>
          PlayerModalBackHandler(
            onBack: () => _setQueueVisible(false),
            active: active,
            child: child,
          );
      if (sideQueue) {
        return Row(children: [
          Expanded(child: nowPlaying),
          Expanded(
            child: Material(
              color: colors.surface.withValues(alpha: 0.65),
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: interceptBack(queue),
              ),
            ),
          ),
        ]);
      }
      final playerPanel = shortLandscape
          ? Row(children: [
              Expanded(
                  flex: 3,
                  child: _artworkFrame(
                      music,
                      video,
                      offline,
                      math.min(constraints.maxWidth * 0.34,
                          math.max(1, constraints.maxHeight - 32)),
                      allowOnlineArtwork: allowOnlineArtwork,
                      interactive: interactiveArtwork,
                      onSeekStep: widget.television ? null : seekStep)),
              Expanded(flex: 5, child: nowPlaying),
            ])
          : nowPlaying;
      if (swipeQueue) {
        return AnimatedBuilder(
          animation: _queueMotion,
          builder: (context, _) {
            final progress = _queueMotion.value;
            final coverPlayer = showQueue || progress > 0;
            return interceptBack(
                Listener(
                  onPointerCancel: (_) => _cancelQueueDrag(),
                  child: Stack(fit: StackFit.expand, children: [
                    ExcludeFocus(
                      excluding: coverPlayer,
                      child: ExcludeSemantics(
                        excluding: coverPlayer,
                        child: IgnorePointer(
                          ignoring: coverPlayer,
                          child: Padding(
                            padding:
                                const EdgeInsets.only(bottom: footerHeight),
                            child: playerPanel,
                          ),
                        ),
                      ),
                    ),
                    if (progress > 0)
                      GestureDetector(
                        excludeFromSemantics: true,
                        onTap: () => _setQueueVisible(false),
                        child: ColoredBox(
                          color:
                              Colors.black.withValues(alpha: progress * 0.54),
                        ),
                      ),
                    if (!coverPlayer || _draggingQueue)
                      Positioned(
                        key: const ValueKey('music-queue-footer'),
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: footerHeight,
                        child: Material(
                          color: colors.surfaceContainer,
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(16)),
                          clipBehavior: Clip.antiAlias,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onVerticalDragStart: _startQueueDrag,
                            onVerticalDragUpdate: (details) =>
                                _updateQueueDrag(details, queueTravel),
                            onVerticalDragEnd: _releaseQueueDrag,
                            onVerticalDragCancel: _cancelQueueDrag,
                            child: TextButton.icon(
                              key: const ValueKey('music-player-queue'),
                              focusNode: _queueButtonFocus,
                              onPressed: () => _setQueueVisible(true),
                              icon: const Icon(Icons.keyboard_arrow_up_rounded),
                              label: const _MusicQueueFooterLabel(),
                              style: TextButton.styleFrom(
                                foregroundColor: colors.onSurface,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                shape: const RoundedRectangleBorder(),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (coverPlayer || _draggingQueue)
                      Positioned(
                        key: const ValueKey('music-queue-sheet'),
                        left: 0,
                        right: 0,
                        bottom: -(1 - progress) * queueTravel,
                        height: queueHeight,
                        child: IgnorePointer(
                          ignoring: !showQueue || progress < 1,
                          child: ExcludeSemantics(
                            excluding: !showQueue,
                            child: Material(
                              color: colors.surfaceContainer,
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(16)),
                              clipBehavior: Clip.antiAlias,
                              child: showQueue
                                  ? FocusScope(
                                      node: _queueScope,
                                      child: Semantics(
                                        container: true,
                                        explicitChildNodes: true,
                                        scopesRoute: true,
                                        namesRoute: true,
                                        label: locals.musicQueue,
                                        child: queue,
                                      ),
                                    )
                                  : ExcludeFocus(child: queue),
                            ),
                          ),
                        ),
                      ),
                  ]),
                ),
                active: showQueue || _draggingQueue);
          },
        );
      }
      return Stack(fit: StackFit.expand, children: [
        ExcludeFocus(
          excluding: showQueue,
          child: ExcludeSemantics(
            excluding: showQueue,
            child: IgnorePointer(ignoring: showQueue, child: playerPanel),
          ),
        ),
        if (showQueue) ...[
          GestureDetector(
            excludeFromSemantics: true,
            onTap: () => _setQueueVisible(false),
            child: const ColoredBox(color: Colors.black54),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: shortLandscape ? 0.94 : 0.82,
              widthFactor: 1,
              child: Material(
                color: colors.surfaceContainer,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(26)),
                clipBehavior: Clip.antiAlias,
                // This queue covers the player and browsing page. Keep Tab
                // and directional traversal inside it until it is dismissed.
                // The wide side queue stays in the normal pane traversal.
                child:
                    interceptBack(FocusScope(node: _queueScope, child: queue)),
              ),
            ),
          ),
        ],
      ]);
    });
    return Stack(fit: StackFit.expand, children: [
      // The same guarded artwork loader supplies Muzza's blurred backdrop.
      ExcludeSemantics(
        child: RepaintBoundary(
          child: ClipRect(
            child: Stack(fit: StackFit.expand, children: [
              ColoredBox(color: colors.surface),
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 52, sigmaY: 52),
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox.square(
                    dimension: 180,
                    child: MusicPlaybackArtwork(
                        music: music,
                        video: video,
                        offline: offline,
                        showPlaceholder: false),
                  ),
                ),
              ),
              DecoratedBox(
                  decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    colors.surface,
                    colors.surface.withAlpha(0x6b),
                    colors.surface.withAlpha(0x99),
                    colors.surface
                  ],
                  stops: const [0, 0.27, 0.76, 1],
                ),
              )),
            ]),
          ),
        ),
      ),
      Column(children: [
        if (!onDevice && pending == null) const MusicSponsorNotice(),
        Expanded(child: view),
      ]),
    ]);
  }

  double _songActionsLabelWidth(BuildContext context) =>
      TextPainter.computeWidth(
          text: TextSpan(
              text: AppLocalizations.of(context)!.musicSongActions,
              style: Theme.of(context).textTheme.labelMedium),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context));

  double _portraitMetadataReserve(BuildContext context, MusicMetadata music,
      String displayTitle, TextStyle? titleStyle,
      {required double width,
      required bool hasBookmark,
      required String? deviceArtist,
      required bool onDevice}) {
    final titleDirection = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final artistStyle = Theme.of(context).textTheme.titleMedium;
    final linked = deviceArtist != null ||
        !onDevice && music.artistCredits.any((credit) => credit.id != null);
    final artist = deviceArtist ??
        (onDevice && music.artist.isEmpty
            ? AppLocalizations.of(context)!.onDevice
            : music.artist);
    final measurement = (
      width,
      displayTitle,
      artist,
      deviceArtist != null,
      linked,
      hasBookmark,
      onDevice,
      titleStyle,
      artistStyle,
      AppLocalizations.of(context)!.musicSongActions,
      Theme.of(context).textTheme.labelMedium,
      titleDirection,
      textScaler,
    );
    if (_portraitReserve case (final previous, final height)
        when previous == measurement) {
      return height;
    }

    Size measure(String text, TextStyle? style, double maxWidth,
        {int? maxLines}) {
      final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: titleDirection,
          textScaler: textScaler,
          maxLines: maxLines)
        ..layout(maxWidth: maxWidth);
      final size = painter.size;
      painter.dispose();
      return size;
    }

    final actionLabelWidth = _songActionsLabelWidth(context) + 50;
    final actionWidth =
        (actionLabelWidth <= width * 0.45 ? actionLabelWidth : 48.0) +
            (hasBookmark && !onDevice ? 52.0 : 0.0);
    final inlineWidth = math.max(1.0, width - actionWidth - 8);
    final title = measure(displayTitle, titleStyle, width);
    final byline = measure(artist, artistStyle, width);
    final textHeight =
        title.height + 2 + math.max(byline.height, linked ? 48.0 : 0.0);
    final wrapsActions =
        math.max(title.width, byline.width + (deviceArtist == null ? 0 : 26)) >
            inlineWidth;
    final fit = wrapsActions ? textHeight + 52 : math.max(48.0, textHeight);

    // Reserve only the height beyond the original two-line inline layout.
    // The caller measures the mounted track so the cover cannot jump as a
    // swipe selects the next title before its decoder opens.
    final priorTitle =
        measure(displayTitle, titleStyle, inlineWidth, maxLines: 2);
    final priorByline = measure(artist, artistStyle, inlineWidth, maxLines: 1);
    final prior = math.max(
        48.0,
        priorTitle.height +
            2 +
            math.max(priorByline.height, linked ? 48.0 : 0.0));
    final extra = math.max(0.0, fit - prior);
    _portraitReserve = (measurement, extra);
    return extra;
  }

  Widget _songActionsButton(IdedVideo? entry, {required double maxWidth}) {
    return Builder(builder: (context) {
      final label = AppLocalizations.of(context)!.musicSongActions;
      final textStyle = Theme.of(context).textTheme.labelMedium;
      final labelWidth = _songActionsLabelWidth(context);
      const key = ValueKey('music-player-song-actions');
      const icon = Icon(Icons.more_horiz);
      final onPressed = entry == null
          ? null
          : () => MusicLibraryActions.showPlayingSongMenu(context, entry,
              television: widget.television);
      // Leave room for the icon, its gap, button padding and tap target.
      if (labelWidth + 50 > maxWidth) {
        return IconButton(
            key: key, tooltip: label, icon: icon, onPressed: onPressed);
      }
      return Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: TextButton.icon(
          key: key,
          style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle: textStyle,
              iconSize: 18),
          onPressed: onPressed,
          icon: icon,
          label: Text(label, maxLines: 1),
        ),
      );
    });
  }

  Widget _artistAndAdvisory(
      PlayerCubit player, String? queueId, Widget artist) {
    final generation = player.backendPlaybackGeneration;
    return ValueListenableBuilder<PlayingMusicContentAdvisory?>(
      valueListenable: player.musicContentAdvisory,
      child: artist,
      builder: (context, reported, artist) {
        final advisory = reported != null &&
                queueId != null &&
                reported.queueId == queueId &&
                reported.generation == generation &&
                generation == player.backendPlaybackGeneration &&
                player.openingMusicEntry == null &&
                player.state.currentQueueId == queueId
            ? reported.advisory
            : null;
        return Wrap(
          spacing: 6,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            artist!,
            if (advisory != null) _MusicAdvisoryBadge(advisory: advisory),
          ],
        );
      },
    );
  }

  Widget _artistByline(BuildContext context, MusicMetadata music, bool onDevice,
      (String, int, int, String?) occurrence) {
    if (onDevice) {
      return MusicPlayingDeviceArtists(
        byline: music.artist,
        occurrence: occurrence,
        television: widget.television,
      );
    }
    final theme = Theme.of(context);
    final style = theme.textTheme.titleMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    if (!music.artistCredits.any((credit) => credit.id != null)) {
      return Text(music.artist, style: style);
    }
    void openArtist(String id) {
      if (!context.mounted || !mounted || !TickerMode.of(context)) return;
      final app = context.read<AppCubit>();
      final player = context.read<PlayerCubit>();
      if (app.isClosed || player.isClosed) return;
      final session = app.state;
      final state = player.state;
      final entry = player.openingMusicEntry ??
          state.currentlyPlaying ??
          state.offlineCurrentlyPlaying;
      if (session.globalLoading ||
          session.sessionRecoveryRequired ||
          session.profileId != db.profileId ||
          state.isHidden ||
          state.isMini ||
          state.isClosing ||
          entry == null ||
          occurrence !=
              (
                session.profileId,
                session.sessionRevision,
                player.playlistGeneration,
                playbackQueueId(entry)
              )) {
        return;
      }
      final current = switch (entry) {
        Video() => entry.musicMetadata,
        DownloadedVideo() => entry.musicMetadata,
        _ => null,
      };
      if (current?.artistCredits.any((credit) => credit.id == id) == true) {
        MusicScreen.openPlayingArtist(context, id,
            television: widget.television);
      }
    }

    return Wrap(
      spacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final (index, credit) in music.artistCredits.indexed)
          if (credit.id case final id?)
            TextButton(
                key: ValueKey(('music-player-artist', id, index)),
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    alignment: AlignmentDirectional.centerStart),
                onPressed: () => openArtist(id),
                child: Text(credit.name,
                    style:
                        style?.copyWith(decoration: TextDecoration.underline)))
          else
            Text(credit.name, style: style),
      ],
    );
  }

  Widget _artworkFrame(MusicMetadata music, Video? video,
          DownloadedVideo? offline, double size,
          {required bool allowOnlineArtwork,
          required bool interactive,
          required ValueChanged<bool>? onSeekStep}) =>
      MusicPlayerArtwork(
          key: _artwork,
          music: music,
          video: video,
          offline: offline,
          size: size,
          active: allowOnlineArtwork,
          interactive: interactive,
          scaleWithPlayback: !widget.television,
          onSeekStep: onSeekStep,
          lyricsLoader: widget.lyricsLoader,
          videoSurfaceBuilder: widget.videoSurfaceBuilder);

  Widget _progress(BuildContext context, PlayerCubit player, PlayerState state,
      {required int? length, required bool live}) {
    final locals = AppLocalizations.of(context)!;
    final duration = math.max(0, length ?? 0) * 1000;
    final opening = player.openingMusicEntry != null;
    final canSeek = !opening && duration > 0 && !live;
    final queueId = _queueId;
    final layoutRevision = _layoutRevision;
    bool isCurrent() =>
        mounted &&
        player.openingMusicEntry == null &&
        queueId == player.state.currentQueueId &&
        layoutRevision == _layoutRevision;
    final maxPosition = math.max(1, duration).toDouble();
    final elapsed = opening ? 0 : state.position.inMilliseconds;
    final position =
        (_seekPosition ?? elapsed.toDouble()).clamp(0.0, maxPosition);
    return Column(children: [
      Semantics(
        // Retire the slider's gesture state with its owner. Flutter replaces
        // callbacks on a mounted Slider, so callback guards alone cannot stop
        // a held drag from ending on the next song after a rebuild.
        key: ValueKey((queueId, layoutRevision)),
        label: locals.musicPosition,
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
              trackHeight: 12,
              trackShape: const GappedSliderTrackShape(),
              thumbShape: const HandleThumbShape(),
              thumbSize: const WidgetStatePropertyAll(Size(4, 32)),
              trackGap: 6,
              activeTrackColor: Theme.of(context).colorScheme.onSurface,
              inactiveTrackColor: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.16),
              thumbColor: Theme.of(context).colorScheme.onSurface),
          child: Slider(
            key: const ValueKey('music-player-progress'),
            min: 0,
            max: maxPosition,
            value: position,
            semanticFormatterCallback: (value) =>
                prettyDurationCustom(Duration(milliseconds: value.round())),
            onChanged: !canSeek
                ? null
                : (value) {
                    if (isCurrent()) setState(() => _seekPosition = value);
                  },
            onChangeEnd: !canSeek
                ? null
                : (value) {
                    if (!isCurrent()) return;
                    player.seek(Duration(milliseconds: value.round()));
                    setState(() => _seekPosition = null);
                  },
          ),
        ),
      ),
      SizedBox(
          width: double.infinity,
          child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 16,
              children: [
                Text(prettyDurationCustom(Duration(
                    milliseconds: duration > 0
                        ? position.round()
                        : math.max(0, elapsed)))),
                Text(duration > 0
                    ? prettyDurationCustom(Duration(milliseconds: duration))
                    : '--:--'),
              ])),
    ]);
  }

  ValueChanged<bool>? _seekStep(
      BuildContext context, PlayerCubit player, PlayerState state) {
    final app = context.read<AppCubit>();
    final session = app.state;
    final occurrence = state.currentQueueId;
    final generation = player.playlistGeneration;
    final seconds =
        context.select((SettingsCubit settings) => settings.state.skipStep);
    final length = state.currentlyPlaying?.lengthSeconds ??
        state.offlineCurrentlyPlaying?.lengthSeconds ??
        0;
    if (player.openingMusicEntry != null ||
        length <= 0 ||
        state.currentlyPlaying?.liveNow == true) {
      return null;
    }
    return (previous) {
      if (player.isClosed ||
          app.isClosed ||
          app.state.globalLoading ||
          app.state.sessionRecoveryRequired ||
          app.state.sessionRevision != session.sessionRevision ||
          app.state.profileId != session.profileId ||
          player.openingMusicEntry != null ||
          player.playlistGeneration != generation ||
          player.state.currentQueueId != occurrence ||
          player.state.isClosing) {
        return;
      }
      HapticFeedback.lightImpact();
      final offset = Duration(seconds: previous ? -seconds : seconds);
      final target = (player.state.position + offset)
          .inMilliseconds
          .clamp(0, length * 1000)
          .toInt();
      player.seek(Duration(milliseconds: target));
    };
  }

  // Port of Muzza Player.kt's combined click/long-click transport.
  Widget _trackTransport(
      BuildContext context, PlayerCubit player, PlayerState state,
      {required bool previous, required ValueChanged<bool>? seekStep}) {
    final locals = AppLocalizations.of(context)!;
    final name = previous ? 'previous' : 'next';
    final label = previous ? locals.musicPrevious : locals.musicNext;
    final seekLabel = previous ? locals.musicRewind : locals.musicForward;
    final session = context.read<AppCubit>().state;
    final seek = seekStep == null ? null : () => seekStep(previous);
    return Semantics(
      key: ValueKey((
        name,
        state.currentQueueId,
        player.playlistGeneration,
        session.sessionRevision,
        session.profileId
      )),
      customSemanticsActions:
          seek == null ? null : {CustomSemanticsAction(label: seekLabel): seek},
      child: GestureDetector(
        excludeFromSemantics: true,
        onLongPress: seek,
        child: Tooltip(
          message: label,
          triggerMode: TooltipTriggerMode.manual,
          child: IconButton(
            key: ValueKey('music-player-$name'),
            iconSize: 26,
            onPressed: state.hasQueue
                ? (previous ? player.playPrevious : player.playNext)
                : null,
            icon: Icon(previous
                ? Icons.skip_previous_rounded
                : Icons.skip_next_rounded),
          ),
        ),
      ),
    );
  }

  Widget _options(BuildContext context, PlayerCubit player, PlayerState state,
      {required bool showQueue,
      required bool onDevice,
      required bool hideQueueButton,
      required bool portraitPhone}) {
    final opening = player.openingMusicEntry != null;
    final locals = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final actionStyle = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      textStyle: theme.textTheme.labelMedium,
      iconSize: 18,
    );
    return LayoutBuilder(builder: (context, constraints) {
      final fitMainActions = constraints.maxWidth >= 280 &&
          MediaQuery.textScalerOf(context).scale(12) <= 14;
      final mainActionWidth = fitMainActions ? constraints.maxWidth / 3 : null;
      Widget action(
          String name, String label, IconData icon, VoidCallback? onPressed,
          {bool active = false, Widget? labelWidget, FocusNode? focusNode}) {
        return SizedBox(
          width: mainActionWidth,
          child: Tooltip(
            message: label,
            excludeFromSemantics: true,
            child: TextButton.icon(
              key: ValueKey('music-player-$name'),
              focusNode: focusNode,
              style: active
                  ? actionStyle.copyWith(
                      backgroundColor: WidgetStatePropertyAll(
                          theme.colorScheme.secondaryContainer))
                  : actionStyle,
              onPressed: onPressed,
              icon: Icon(icon),
              label: labelWidget ??
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        );
      }

      return SingleChildScrollView(
        key: const ValueKey('music-player-actions'),
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          if (!hideQueueButton)
            action('queue', locals.musicQueue, Icons.queue_music,
                () => _setQueueVisible(!showQueue),
                active: showQueue, focusNode: _queueButtonFocus),
          action(
              'sleep',
              state.hasTimer ? locals.cancelSleepTimer : locals.sleepTimer,
              Icons.bedtime_outlined,
              opening && !state.hasTimer
                  ? null
                  : () async {
                      if (player.state.hasTimer) {
                        player.cancelSleep();
                        return;
                      }
                      await _showMusicSleepTimer(context, player);
                    },
              active: state.hasTimer,
              labelWidget: state.hasTimer
                  ? _MusicSleepCountdown(
                      player: player, cancelLabel: locals.cancelSleepTimer)
                  : null),
          action('sound', locals.musicSound, Icons.tune,
              () => showMusicSoundSheet(context, player)),
          if (portraitPhone && !onDevice && !opening)
            const MusicAudioQualityButton(),
          IconButton(
              tooltip: locals.musicRewind,
              onPressed: opening ? null : player.rewind,
              icon: const Icon(Icons.fast_rewind)),
          IconButton(
              tooltip: locals.musicForward,
              onPressed: opening ? null : player.fastForward,
              icon: const Icon(Icons.fast_forward)),
          if (!onDevice && canChoosePlayerBackend(state))
            IconButton(
                tooltip: locals.backendChoose,
                onPressed: opening
                    ? null
                    : () => showPlayerBackendPicker(context, player: player),
                icon: const Icon(Icons.dns_outlined)),
        ]),
      );
    });
  }
}

// Dart port of Muzza Queue.kt / PlayerMenu.kt sleep dialog. The engine receives
// an explicit end-of-item mode or a wall-clock duration in five-minute steps.
Future<void> _showMusicSleepTimer(
    BuildContext context, PlayerCubit player) async {
  final app = context.read<AppCubit>();
  final session = app.state;
  final occurrence = player.state.currentQueueId;
  final generation = player.playlistGeneration;
  final video = player.state.currentlyPlaying;
  final duration = video?.lengthSeconds ??
      player.state.offlineCurrentlyPlaying?.lengthSeconds ??
      0;
  final canEnd = duration > 0 &&
      video?.liveNow != true &&
      player.playbackStatus != MediaState.completed;
  var minutes = 30.0;
  final selected = await showDialog<int>(
    context: context,
    useRootNavigator: false,
    builder: (context) {
      final locals = AppLocalizations.of(context)!;
      return PlayerModalBackHandler(
          child: StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          scrollable: true,
          icon: const Icon(Icons.bedtime_outlined),
          title: Text(locals.sleepTimer),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(locals.musicSleepMinutes(minutes.round())),
            Slider(
              key: const ValueKey('music-sleep-duration'),
              min: 5,
              max: 120,
              divisions: 23,
              value: minutes,
              label: locals.musicSleepMinutes(minutes.round()),
              onChanged: (value) => setState(() => minutes = value),
            ),
            if (canEnd)
              OutlinedButton(
                key: const ValueKey('music-sleep-end-of-song'),
                onPressed: () => Navigator.of(context).pop(-1),
                child: Text(locals.musicSleepEndOfSong),
              ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(locals.cancel)),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(minutes.round()),
              child: Text(locals.setTimer),
            ),
          ],
        ),
      ));
    },
  );
  if (selected == null ||
      !context.mounted ||
      player.isClosed ||
      app.isClosed ||
      app.state.globalLoading ||
      app.state.sessionRecoveryRequired ||
      app.state.profileId != session.profileId ||
      app.state.sessionRevision != session.sessionRevision ||
      player.playlistGeneration != generation ||
      player.state.currentQueueId != occurrence ||
      player.state.isClosing) {
    return;
  }
  if (selected < 0) {
    player.sleepAtEndOfTrack();
  } else {
    player.sleep(
        SleepTimer(duration: Duration(minutes: selected), stopVideo: false));
  }
}

class _MusicAdvisoryBadge extends StatelessWidget {
  const _MusicAdvisoryBadge({required this.advisory});

  final MusicContentAdvisory advisory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locals = AppLocalizations.of(context)!;
    final label = switch (advisory) {
      MusicContentAdvisory.explicit => locals.musicContentExplicit,
      MusicContentAdvisory.clean => locals.musicContentClean,
    };
    return Semantics(
      key: const ValueKey('music-player-content-advisory'),
      container: true,
      liveRegion: TickerMode.of(context),
      label: label,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(label,
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}

class _MusicMetadataTransition extends StatefulWidget {
  const _MusicMetadataTransition(
      {required this.occurrence, required this.child});

  final Object occurrence;
  final Widget child;

  @override
  State<_MusicMetadataTransition> createState() =>
      _MusicMetadataTransitionState();
}

class _MusicMetadataTransitionState extends State<_MusicMetadataTransition>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, value: 1);
  late final _opacity = _controller
      .drive(CurveTween(curve: Curves.easeOut))
      .drive(Tween<double>(begin: 0.78, end: 1));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration =
        AppMotion.duration(context, const Duration(milliseconds: 130));
    if (_controller.duration == Duration.zero) _controller.value = 1;
  }

  @override
  void didUpdateWidget(covariant _MusicMetadataTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.occurrence != oldWidget.occurrence &&
        _controller.duration != Duration.zero) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
      key: const ValueKey('music-player-metadata'),
      opacity: _opacity,
      alwaysIncludeSemantics: true,
      child: widget.child);
}

class _MusicQueueFooterLabel extends StatelessWidget {
  const _MusicQueueFooterLabel();

  @override
  Widget build(BuildContext context) =>
      MusicPlaybackTitles(builder: _buildPreview);

  Widget _buildPreview(
      BuildContext context, String? Function(IdedVideo?) savedTitle) {
    // Position updates and sheet animation frames do not change this target.
    context.select((PlayerCubit player) {
      final state = player.state;
      return (
        state.currentQueueId,
        player.openingMusicEntry,
        state.isAudio,
        state.isHidden,
        state.isClosing,
        state.playQueue.firstOrNull,
        state.videos,
        state.offlineVideos,
      );
    });
    context
        .select((SettingsCubit? settings) => settings?.state.playerRepeatMode);
    final player = context.read<PlayerCubit>();
    return ValueListenableBuilder<int>(
      valueListenable: player.playlistLoadingRevision,
      builder: (context, _, __) {
        final locals = AppLocalizations.of(context)!;
        final next = player.adjacentMusicEntry(previous: false);
        final (catalogTitle, artist) = switch (next) {
          Video(:final musicMetadata, :final title, :final author) => (
              musicMetadata?.title ?? title ?? '',
              musicMetadata?.artist ?? author ?? '',
            ),
          DownloadedVideo(:final musicMetadata, :final title, :final author) =>
            (
              musicMetadata?.title ?? title,
              musicMetadata?.artist ?? author ?? '',
            ),
          _ => ('', ''),
        };
        final title = savedTitle(next) ?? catalogTitle;
        const overflow = TextOverflow.ellipsis;
        final queue = Text(locals.musicQueue, maxLines: 1, overflow: overflow);
        if (title.isEmpty) return queue;

        final song = artist.isEmpty ? title : '$title · $artist';
        final preview = Text(
          locals.musicQueueNextPreview(song),
          key: const ValueKey('music-queue-next-preview'),
          maxLines: 1,
          overflow: overflow,
        );
        final largeText = MediaQuery.textScalerOf(context).scale(14) > 19;
        return Semantics(
          label: locals.musicQueueNextSemantics(song),
          excludeSemantics: true,
          child: largeText
              ? preview
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [queue, preview],
                ),
        );
      },
    );
  }
}

class _MusicSleepCountdown extends StatefulWidget {
  final PlayerCubit player;
  final String cancelLabel;

  const _MusicSleepCountdown({required this.player, required this.cancelLabel});

  @override
  State<_MusicSleepCountdown> createState() => _MusicSleepCountdownState();
}

class _MusicSleepCountdownState extends State<_MusicSleepCountdown> {
  late final Timer _updates;

  @override
  void initState() {
    super.initState();
    _updates =
        Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _updates.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.player.sleepRemaining;
    return Text(
      remaining == null ? widget.cancelLabel : prettyDurationCustom(remaining),
      semanticsLabel: widget.cancelLabel,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// The tape follows Muzza's timeline-window traversal, with Videre's decoder
/// and occurrence IDs still owning each playback command.
class MusicQueue extends StatefulWidget {
  final bool television;

  const MusicQueue({super.key, this.television = false});

  @override
  State<MusicQueue> createState() => _MusicQueueState();
}

enum _QueueSelectionAction {
  play,
  shuffle,
  next,
  append,
  save,
  download,
  remove
}

enum _QueueRowAction {
  play,
  pause,
  next,
  append,
  saveSong,
  removeSavedSong,
  save,
  download,
  rename,
  moveUp,
  moveDown,
  remove
}

typedef _QueueMenuCommand = Future<void> Function();

enum _QueueFollow { reveal, center, jump }

class _MusicQueueState extends State<MusicQueue> {
  final _scroll = ScrollController();
  final _scrollPointers = <int>{};
  ({(String, int, int) owner, String id, int index, double extent})? _activeRow;
  _QueueFollow? _pendingFollow;
  bool _followScheduled = false;
  ({
    (String, int, int) owner,
    List<String> order,
    List<String> upcoming,
    String? active,
    int from,
  })? _drag;
  Set<String>? _selection;
  (String, int, int)? _selectionOwner;

  List<IdedVideo> _sources(PlayerState state) =>
      state.videos.isNotEmpty ? state.videos : state.offlineVideos;

  String? _activeId(PlayerCubit player) {
    final opening = player.openingMusicEntry;
    return opening == null
        ? player.state.currentQueueId
        : playbackQueueId(opening);
  }

  bool _isProtectedOccurrence(PlayerCubit player, String id) =>
      id == player.state.currentQueueId || id == _activeId(player);

  List<IdedVideo> _entries(PlayerCubit player) {
    final state = player.state;
    return playbackQueueTraversal(_sources(state),
        played: state.playedVideos,
        current: _activeId(player),
        upcoming: state.playQueue);
  }

  Video? _catalogSong(IdedVideo item) {
    if (isLocalMusicPlaybackId(item.videoId)) return null;
    return switch (item) {
      Video() => item,
      DownloadedVideo(:final musicMetadata, :final lengthSeconds)
          when musicMetadata != null =>
        Video(
            videoId: item.videoId,
            title: musicMetadata.title,
            author: musicMetadata.artist,
            lengthSeconds: lengthSeconds,
            musicMetadata: musicMetadata,
            videoThumbnails: musicMetadata.thumbnails),
      _ => null,
    };
  }

  bool _canDownload(PlayerCubit player, Video song) {
    final playing = player.state.currentlyPlaying;
    final playingSavedCopy = playing?.videoId == song.videoId &&
        playing?.downloadPlaybackOnly == true;
    return !isTv &&
        !widget.television &&
        !song.downloadPlaybackOnly &&
        song.explicitMusicDownload == null &&
        !playingSavedCopy &&
        db.getDownloadByVideoId(song.videoId) == null;
  }

  List<LocalMusicTrack>? _localTracks(List<IdedVideo> entries) {
    final tracks = entries
        .map((entry) => localMusicTrackForPlayback(entry.videoId))
        .nonNulls
        .toList();
    return tracks.length == entries.length ? tracks : null;
  }

  bool _canEnqueueCopies(PlayerCubit player, List<IdedVideo> entries) {
    if (entries.isEmpty) return false;
    if (player.state.videos.isEmpty) {
      return player.canCopyOfflineMusicEntries(entries.cast<DownloadedVideo>());
    }
    return player.canEnqueueMusicSongs(entries.cast<Video>());
  }

  Future<void> _enqueueCopies(PlayerCubit player, List<IdedVideo> entries,
      {required bool next}) async {
    final bool added;
    if (player.state.videos.isEmpty) {
      added = await player.enqueueOfflineMusicCopies(
          entries.cast<DownloadedVideo>(),
          next: next);
    } else {
      added = await player.enqueueMusicSongs(entries.cast<Video>(), next: next);
    }
    if (!added) throw StateError('The selected songs are unavailable.');
  }

  List<PopupMenuEntry<_QueueMenuCommand>> _menuItems<T extends Enum>(
          Map<T, String> labels, Future<void> Function(T) invoke) =>
      [
        for (final (index, entry) in labels.entries.indexed)
          PopupMenuItem<_QueueMenuCommand>(
            value: () => invoke(entry.key),
            child: index == 0
                ? PlayerModalBackHandler(priority: 5, child: Text(entry.value))
                : Text(entry.value),
          ),
      ];

  void _followActiveRow(
      (String, int, int) owner, String? id, int index, double extent) {
    final previous = _activeRow;
    if (id == null || index < 0) {
      _activeRow = null;
      _pendingFollow = null;
      return;
    }
    _activeRow = (owner: owner, id: id, index: index, extent: extent);
    if (previous?.owner != owner) {
      _pendingFollow = _QueueFollow.center;
    } else if (previous?.id != id || previous?.extent != extent) {
      _pendingFollow ??= _QueueFollow.reveal;
    }
    _scheduleFollow();
  }

  void _scheduleFollow() {
    if (_followScheduled || _pendingFollow == null) return;
    if (_pendingFollow != _QueueFollow.jump && _scrollPointers.isNotEmpty) {
      return;
    }
    _followScheduled = true;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      _followScheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      final follow = _pendingFollow;
      final row = _activeRow;
      if (follow == null || row == null) return;
      final position = _scroll.position;
      // A pointer can be holding a row without moving the ScrollPosition.
      if (follow != _QueueFollow.jump &&
          (_scrollPointers.isNotEmpty || position.isScrollingNotifier.value)) {
        return;
      }
      _pendingFollow = null;
      final rowTop = row.index * row.extent;
      if (follow == _QueueFollow.reveal &&
          rowTop >= position.pixels &&
          rowTop + row.extent <= position.pixels + position.viewportDimension) {
        return;
      }
      final centered = rowTop - (position.viewportDimension - row.extent) / 2;
      final offset = centered
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if (offset != position.pixels) _scroll.jumpTo(offset);
    });
    binding.ensureVisualUpdate();
  }

  void _endScrollPointer(PointerEvent event) {
    _scrollPointers.remove(event.pointer);
    _scheduleFollow();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _closeSelection() => setState(() => _selection = null);

  String _durationLabel(AppLocalizations locals, List<IdedVideo> entries,
      {required bool complete}) {
    final lengths = entries.map((entry) => switch (entry) {
          Video(:final lengthSeconds, :final liveNow, :final isUpcoming)
              when liveNow != true && isUpcoming != true =>
            lengthSeconds,
          DownloadedVideo(:final lengthSeconds) => lengthSeconds,
          _ => null,
        });
    return musicDurationLabel(locals, lengths, complete: complete) ??
        (complete
            ? locals.playlistTotalDuration('00:00')
            : locals.playlistDurationUnknown);
  }

  @override
  Widget build(BuildContext context) =>
      MusicPlaybackTitles(builder: _buildQueue);

  Widget _buildQueue(
      BuildContext context, String? Function(IdedVideo?) savedTitle) {
    final player = context.read<PlayerCubit>();
    final state = context.watch<PlayerCubit>().state;
    final videos = _entries(player);
    final hasDevice = state.offlineVideos
        .any((entry) => isLocalMusicPlaybackId(entry.videoId));
    final hasSaved = state.offlineVideos
        .any((entry) => !isLocalMusicPlaybackId(entry.videoId));
    final currentId = _activeId(player);
    final app = context.watch<AppCubit>();
    final session = app.state;
    final playlistGeneration = player.playlistGeneration;
    final owner =
        (session.profileId, session.sessionRevision, playlistGeneration);
    if (_selectionOwner != owner) {
      _selectionOwner = owner;
      _selection = null;
    }
    final settings = context.watch<SettingsCubit>();
    final locked = settings.state.musicQueueLocked;
    final locals = AppLocalizations.of(context)!;
    final order = videos.map(playbackQueueId).toList();
    final ids = order.toSet();
    final upcoming = state.playQueue.where(ids.contains).toList();
    final active = order.indexOf(currentId ?? '');
    final text = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    final extent = math.max(
        68.0,
        scaler.scale(text.titleMedium?.fontSize ?? 16) * 1.45 +
            scaler.scale(text.bodyMedium?.fontSize ?? 14) * 1.45 +
            24);
    _followActiveRow(owner, currentId, active, extent);
    final selection = _selection?..retainAll(ids);
    final allSelected = ids.isNotEmpty && selection?.length == ids.length;
    final editing = !locked && selection == null;
    bool current() =>
        mounted &&
        !player.isClosed &&
        !app.isClosed &&
        !app.state.globalLoading &&
        !app.state.sessionRecoveryRequired &&
        app.state.profileId == session.profileId &&
        app.state.sessionRevision == session.sessionRevision &&
        app.state.server == session.server &&
        player.playlistGeneration == playlistGeneration &&
        !player.state.isClosing;
    // Muzza Queue.kt binds selection to Timeline.Window UIDs. Local occurrence
    // IDs have the same role and make repeat uploads independently selectable.
    void toggle(String id) {
      if (!current()) return;
      setState(() {
        final selected = _selection ??= <String>{};
        if (!selected.add(id)) selected.remove(id);
      });
    }

    Future<void> perform(Future<void> Function() action) async {
      if (!current()) return;
      try {
        await action();
      } catch (_) {
        if (!context.mounted || !current()) return;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(locals.musicLibraryActionError)));
      }
    }

    Future<void> selectedAction(
        _QueueSelectionAction action, Set<String> selectedIds) async {
      if (_selection == null) return;
      final selected = _entries(player)
          .where((entry) => selectedIds.contains(playbackQueueId(entry)))
          .toList();
      if (selected.isEmpty || selected.length != selectedIds.length) return;
      _closeSelection();
      switch (action) {
        case _QueueSelectionAction.play:
        case _QueueSelectionAction.shuffle:
          final source = player.musicQueueTitle;
          if (action == _QueueSelectionAction.shuffle) selected.shuffle();
          if (player.state.videos.isNotEmpty) {
            await player.playVideo(selected.cast<Video>(),
                audio: true, fromMusic: true, queueTitle: source);
          } else if (player.state.offlineVideos
              .every((entry) => isLocalMusicPlaybackId(entry.videoId))) {
            final tracks = _localTracks(selected);
            if (tracks == null) throw StateError('Device file is unavailable.');
            await player.playLocalMusic(tracks, queueTitle: source);
          } else {
            await player
                .playOfflineMusicSelection(selected.cast<DownloadedVideo>());
          }
        case _QueueSelectionAction.next:
        case _QueueSelectionAction.append:
          await _enqueueCopies(player, selected,
              next: action == _QueueSelectionAction.next);
        case _QueueSelectionAction.save:
          final songs = selected.map(_catalogSong).nonNulls.toList();
          if (songs.length == selected.length) {
            await MusicLibraryActions.save(context, songs, inPlayer: true);
          }
        case _QueueSelectionAction.download:
          await MusicLibraryActions.download(
              context,
              selected
                  .whereType<Video>()
                  .where((v) => _canDownload(player, v))
                  .toList(),
              inPlayer: true);
        case _QueueSelectionAction.remove:
          if (settings.state.musicQueueLocked) return;
          player.removeInactiveQueueOccurrences(selectedIds
              .where((id) => !_isProtectedOccurrence(player, id))
              .toSet());
      }
    }

    Future<void> rowAction(
        _QueueRowAction action, String id, MusicLibrarySession? library) async {
      final latest = _entries(player);
      final index = latest.indexWhere((entry) => playbackQueueId(entry) == id);
      if (index < 0 || library?.isCurrent == false) return;
      final item = latest[index];
      final isActive = _activeId(player) == id;
      final canEdit = !_isProtectedOccurrence(player, id) &&
          _selection == null &&
          !settings.state.musicQueueLocked;
      final song = _catalogSong(item);
      switch (action) {
        case _QueueRowAction.play:
          if (!isActive) {
            await player.selectQueueOccurrence(id);
          } else if (player.openingMusicEntry == null &&
              !player.state.isPlaying) {
            player.play();
          }
        case _QueueRowAction.pause:
          if (isActive &&
              player.openingMusicEntry == null &&
              player.state.isPlaying) {
            player.pause();
          }
        case _QueueRowAction.next:
        case _QueueRowAction.append:
          await _enqueueCopies(player, [item],
              next: action == _QueueRowAction.next);
        case _QueueRowAction.saveSong:
        case _QueueRowAction.removeSavedSong:
          if (song == null || song.musicMetadata == null || library == null) {
            return;
          }
          await library.setBookmark(MusicLibraryEntry.song(song),
              saved: action == _QueueRowAction.saveSong);
        case _QueueRowAction.save:
          if (song != null) {
            await MusicLibraryActions.save(context, [song], inPlayer: true);
          }
        case _QueueRowAction.download:
          if (item is Video && song != null && _canDownload(player, song)) {
            await MusicLibraryActions.download(context, [song], inPlayer: true);
          }
        case _QueueRowAction.rename:
          final track = localMusicTrackForPlayback(item.videoId);
          if (track != null) {
            await renameLocalMusicTrack(
                context, LocalMusicLibrary.instance, track,
                inPlayer: true, isCurrent: current);
          }
        case _QueueRowAction.moveUp:
          if (canEdit && index > 0) {
            player.moveMusicQueueOccurrence(id,
                beforeId: playbackQueueId(latest[index - 1]));
          }
        case _QueueRowAction.moveDown:
          if (canEdit && index < latest.length - 1) {
            player.moveMusicQueueOccurrence(id,
                beforeId: index + 2 < latest.length
                    ? playbackQueueId(latest[index + 2])
                    : null);
          }
        case _QueueRowAction.remove:
          if (canEdit) player.removeInactiveQueueOccurrences({id});
      }
    }

    final list = ReorderableListView.builder(
      buildDefaultDragHandles: false,
      scrollController: _scroll,
      itemExtent: extent,
      footer: hasDevice ? null : const PlaylistLoadingNotice(),
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      itemCount: videos.length,
      onReorderStart: (index) {
        _drag = (
          owner: owner,
          order: order,
          upcoming: upcoming,
          active: currentId,
          from: index,
        );
      },
      onReorderEnd: (index) {
        if (_drag?.from == index) _drag = null;
      },
      onReorder: (from, to) {
        final drag = _drag;
        _drag = null;
        if (!current() ||
            _selection != null ||
            settings.state.musicQueueLocked) {
          return;
        }
        // Touch drops use the timeline at pickup. Flutter's accessibility
        // move actions call onReorder directly and use this rendered timeline.
        if ((drag != null && (drag.owner != owner || drag.from != from)) ||
            (drag == null ? currentId : drag.active) != _activeId(player)) {
          return;
        }
        final expectedOrder = drag?.order ?? order;
        final expectedUpcoming = drag?.upcoming ?? upcoming;
        final latest = _entries(player).map(playbackQueueId).toList();
        if (!listEquals(latest, expectedOrder) ||
            !listEquals(player.state.playQueue.where(ids.contains).toList(),
                expectedUpcoming) ||
            from < 0 ||
            from >= expectedOrder.length ||
            to < 0 ||
            to > expectedOrder.length) {
          return;
        }
        final moving = expectedOrder[from];
        if (_isProtectedOccurrence(player, moving)) return;
        final before = to == expectedOrder.length ? null : expectedOrder[to];
        player.moveMusicQueueOccurrence(moving, beforeId: before);
      },
      itemBuilder: (context, index) {
        final item = videos[index];
        final id = playbackQueueId(item);
        final video = item is Video ? item : null;
        final offline = item is DownloadedVideo ? item : null;
        final music = video?.musicMetadata ?? offline?.musicMetadata;
        final (title: catalogTitle, :artist) = musicQueueLabels(item);
        final title = savedTitle(item) ?? catalogTitle;
        final isActive = id == currentId;
        final canEdit = editing && !_isProtectedOccurrence(player, id);
        final isEarlier = active >= 0 && index < active;
        final mountedVideo = state.currentlyPlaying;
        final artworkVideo = isActive &&
                mountedVideo != null &&
                playbackQueueId(mountedVideo) == id &&
                mountedVideo.explicitMusicDownload ==
                    video?.explicitMusicDownload
            ? mountedVideo
            : video;
        final isPlaying = player.openingMusicEntry == null &&
            state.isPlaying &&
            player.playbackStatus == MediaState.playing;
        final canMoveUp = index > 0;
        final canMoveDown = index < order.length - 1;
        final colors = Theme.of(context).colorScheme;
        return Builder(
          key: ValueKey(('music-queue-row', id)),
          builder: (rowContext) {
            final tile = ListTile(
              key: ValueKey('music-queue-$id'),
              selected: isActive,
              minVerticalPadding: 8,
              contentPadding: const EdgeInsetsDirectional.fromSTEB(12, 0, 4, 0),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              selectedTileColor: colors.surfaceContainerHighest,
              textColor: isEarlier ? colors.onSurfaceVariant : null,
              leading: SizedBox.square(
                dimension: 46,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: Stack(fit: StackFit.expand, children: [
                    Opacity(
                      opacity: isEarlier ? 0.6 : 1,
                      child: MusicPlaybackArtwork(
                          music: artworkVideo?.musicMetadata ?? music,
                          video: artworkVideo,
                          offline: offline,
                          placeholderSize: 22),
                    ),
                    if (isActive)
                      ColoredBox(
                        color: Colors.black54,
                        child: Icon(
                            key: const ValueKey('music-queue-active'),
                            isPlaying
                                ? Icons.equalizer
                                : Icons.play_arrow_rounded,
                            semanticLabel: locals.musicQueueNowPlaying,
                            color: Colors.white),
                      ),
                  ]),
                ),
              ),
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                  isLocalMusicPlaybackId(item.videoId) && artist.isEmpty
                      ? locals.onDevice
                      : artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              onFocusChange: (focused) {
                // The list builder's context belongs to the entire sliver. Reveal
                // this row so remote focus cannot scroll the selected song away.
                if (focused) {
                  Scrollable.ensureVisible(rowContext, alignment: 0.5);
                }
              },
              onTap: () {
                if (!current()) return;
                if (_selection != null) {
                  toggle(id);
                } else if (_activeId(player) == id) {
                  if (player.openingMusicEntry == null) player.togglePlaying();
                } else {
                  unawaited(player.selectQueueOccurrence(id));
                }
              },
              onLongPress: selection == null
                  ? () {
                      HapticFeedback.lightImpact();
                      toggle(id);
                    }
                  : null,
              trailing: selection != null
                  ? Checkbox(
                      key: ValueKey('music-queue-select-$id'),
                      value: selection.contains(id),
                      onChanged: (_) => toggle(id),
                      semanticLabel: title,
                    )
                  : Row(mainAxisSize: MainAxisSize.min, children: [
                      if (canEdit && (canMoveUp || canMoveDown))
                        ReorderableDragStartListener(
                          key: ValueKey(
                              'music-queue-drag-${playbackQueueId(item)}'),
                          index: index,
                          child: Tooltip(
                            message: locals.musicQueueReorder,
                            child: const ColoredBox(
                              color: Colors.transparent,
                              child: SizedBox.square(
                                dimension: 48,
                                child: Icon(Icons.drag_handle_rounded),
                              ),
                            ),
                          ),
                        ),
                      PopupMenuButton<_QueueMenuCommand>(
                        key: ValueKey(
                            'music-queue-menu-${playbackQueueId(item)}'),
                        tooltip: locals.musicQueueRowActions(title),
                        onSelected: (command) => unawaited(command()),
                        itemBuilder: (_) {
                          final song = _catalogSong(item);
                          final library =
                              song == null ? null : MusicLibrarySession(app);
                          final bookmark =
                              song != null && song.musicMetadata != null
                                  ? MusicLibraryEntry.song(song)
                                  : null;
                          final saved = bookmark != null &&
                              library?.library
                                      .contains(bookmark.kind, bookmark.id) ==
                                  true;
                          final track =
                              localMusicTrackForPlayback(item.videoId);
                          final canEnqueue = _canEnqueueCopies(player, [item]);
                          final pause = isActive &&
                              player.openingMusicEntry == null &&
                              state.isPlaying;
                          return _menuItems(
                              {
                                if (pause)
                                  _QueueRowAction.pause: locals.musicPause
                                else
                                  _QueueRowAction.play: locals.musicPlay,
                                if (canEnqueue) ...{
                                  _QueueRowAction.next: locals.playNext,
                                  _QueueRowAction.append: locals.addToQueueList,
                                },
                                if (bookmark != null)
                                  if (saved)
                                    _QueueRowAction.removeSavedSong:
                                        locals.musicRemoveSong
                                  else
                                    _QueueRowAction.saveSong:
                                        locals.musicSaveSong,
                                if (song != null)
                                  _QueueRowAction.save:
                                      locals.musicSaveToPlaylist,
                                if (video != null &&
                                    _canDownload(player, video))
                                  _QueueRowAction.download:
                                      locals.musicDownloadAudio,
                                if (track?.canRename == true &&
                                    track?.fileName != null &&
                                    !LocalMusicLibrary.instance.busy)
                                  _QueueRowAction.rename:
                                      locals.localMusicRename,
                                if (canEdit) ...{
                                  if (canMoveUp)
                                    _QueueRowAction.moveUp:
                                        locals.musicQueueMoveUp,
                                  if (canMoveDown)
                                    _QueueRowAction.moveDown:
                                        locals.musicQueueMoveDown,
                                  _QueueRowAction.remove:
                                      locals.musicQueueRemove,
                                },
                              },
                              (action) => perform(
                                  () => rowAction(action, id, library)));
                        },
                      ),
                    ]),
            );
            // Hold a row to select it, then choose Remove selected. Horizontal
            // navigation must never remove a queue occurrence.
            return tile;
          },
        );
      },
    );
    final canSort = current() && player.canSortMusicQueueUpcoming;
    final colors = Theme.of(context).colorScheme;
    Widget sortButton({required bool compact}) =>
        PopupMenuButton<_QueueMenuCommand>(
          key: const ValueKey('music-queue-sort-upcoming'),
          tooltip: locals.musicQueueSortUpcoming,
          enabled: canSort,
          onSelected: (command) => unawaited(command()),
          itemBuilder: (_) {
            final occurrence = player.playbackOccurrenceRevision;
            final selectionRequest = player.musicSelectionRequestRevision;
            return _menuItems(
              {
                MusicQueueSort.titleAscending:
                    locals.musicQueueSortTitleAscending,
                MusicQueueSort.titleDescending:
                    locals.musicQueueSortTitleDescending,
                MusicQueueSort.artistAscending:
                    locals.musicQueueSortArtistAscending,
                MusicQueueSort.artistDescending:
                    locals.musicQueueSortArtistDescending,
              },
              (sort) async {
                if (current() &&
                    _selection == null &&
                    !settings.state.musicQueueLocked &&
                    player.playbackOccurrenceRevision == occurrence &&
                    player.musicSelectionRequestRevision == selectionRequest) {
                  player.sortMusicQueueUpcoming(sort);
                }
              },
            );
          },
          icon: compact ? const Icon(Icons.sort) : null,
          child: compact
              ? null
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: SizedBox(
                    height: 48,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.sort,
                          size: 18, color: canSort ? colors.primary : null),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(locals.musicQueueSortUpcoming,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelLarge?.copyWith(
                              color: canSort
                                  ? colors.primary
                                  : colors.onSurface.withValues(alpha: 0.38),
                            )),
                      ),
                    ]),
                  ),
                ),
        );
    Widget queueToolbar(BoxConstraints constraints) {
      final compact = constraints.maxWidth < 340 ||
          scaler.scale(text.labelLarge?.fontSize ?? 14) > 21;
      final sort =
          state.playQueue.length > 1 ? sortButton(compact: compact) : null;
      return ValueListenableBuilder<int>(
          valueListenable: player.playlistLoadingRevision,
          builder: (context, _, actions) {
            String? source = player.musicQueueTitle;
            if (hasDevice && !hasSaved) {
              source ??= locals.onDevice;
            } else if (hasSaved && !hasDevice) {
              source ??= locals.downloads;
            }
            final count = locals.musicTrackCount(videos.length);
            final title = source ?? (locked ? locals.musicQueueLocked : count);
            final summary = DefaultTextStyle(
              style: text.bodySmall!.copyWith(color: colors.onSurfaceVariant),
              child: Wrap(spacing: 12, children: [
                if (source != null || locked) Text(count),
                Text(_durationLabel(locals, videos,
                    complete: player.playlistComplete)),
                if (source != null && locked) Text(locals.musicQueueLocked),
              ]),
            );
            return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                        child: Padding(
                      padding: const EdgeInsetsDirectional.only(start: 20),
                      child: Tooltip(
                          message: title,
                          excludeFromSemantics: true,
                          child: Text(title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.titleMedium)),
                    )),
                    actions!,
                  ]),
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 12, 4),
                    child: compact || sort == null
                        ? summary
                        : Row(children: [
                            Expanded(child: summary),
                            Flexible(child: sort),
                          ]),
                  ),
                ]);
          },
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              key: const ValueKey('music-queue-jump-current'),
              tooltip: locals.musicQueueJumpCurrent,
              onPressed: active < 0
                  ? null
                  : () {
                      _pendingFollow = _QueueFollow.jump;
                      _scheduleFollow();
                    },
              icon: const Icon(Icons.my_location),
            ),
            const MusicShuffleButton(
                controlKey: ValueKey('music-queue-shuffle')),
            if (compact && sort != null) sort,
            IconButton(
              key: const ValueKey('music-queue-select-mode'),
              tooltip: locals.musicQueueSelect,
              onPressed:
                  videos.isEmpty ? null : () => setState(() => _selection = {}),
              icon: const Icon(Icons.checklist_rounded),
            ),
            IconButton(
              key: const ValueKey('music-queue-lock'),
              tooltip: locked ? locals.musicQueueUnlock : locals.musicQueueLock,
              isSelected: locked,
              onPressed: () => settings.saveSetting(
                  SettingsValue(musicQueueLockedSettingName, '${!locked}')),
              icon: const Icon(Icons.lock_open_rounded),
              selectedIcon: const Icon(Icons.lock_rounded),
            ),
          ]));
    }

    final toolbar = selection == null
        ? LayoutBuilder(
            builder: (context, constraints) => queueToolbar(constraints))
        : Row(children: [
            IconButton(
              tooltip: locals.cancel,
              onPressed: _closeSelection,
              icon: const Icon(Icons.close_rounded),
            ),
            Expanded(
                child: Text(locals.musicQueueSelected(selection.length),
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
            IconButton(
              tooltip: allSelected
                  ? locals.musicQueueDeselectAll
                  : locals.musicQueueSelectAll,
              onPressed: ids.isEmpty
                  ? null
                  : () =>
                      setState(() => _selection = allSelected ? {} : {...ids}),
              icon: Icon(allSelected
                  ? Icons.deselect_rounded
                  : Icons.select_all_rounded),
            ),
            PopupMenuButton<_QueueMenuCommand>(
              key: const ValueKey('music-queue-selection-menu'),
              enabled: selection.isNotEmpty,
              tooltip: locals.musicQueueSelect,
              onSelected: (command) => unawaited(command()),
              itemBuilder: (_) {
                final selectedIds = Set<String>.of(selection);
                final selected = videos
                    .where(
                        (entry) => selectedIds.contains(playbackQueueId(entry)))
                    .toList();
                return _menuItems(
                    {
                      _QueueSelectionAction.play: locals.musicPlay,
                      _QueueSelectionAction.shuffle: locals.musicShuffle,
                      if (_canEnqueueCopies(player, selected)) ...{
                        _QueueSelectionAction.next: locals.playNext,
                        _QueueSelectionAction.append: locals.addToQueueList,
                      },
                      if (selected
                          .every((entry) => _catalogSong(entry) != null))
                        _QueueSelectionAction.save: locals.musicSaveToPlaylist,
                      if (selected
                          .whereType<Video>()
                          .any((song) => _canDownload(player, song)))
                        _QueueSelectionAction.download:
                            locals.musicDownloadAudio,
                      if (!locked &&
                          selectedIds
                              .any((id) => !_isProtectedOccurrence(player, id)))
                        _QueueSelectionAction.remove:
                            locals.musicQueueRemoveSelected,
                    },
                    (action) =>
                        perform(() => selectedAction(action, selectedIds)));
              },
            ),
          ]);
    final content = Column(children: [
      toolbar,
      Expanded(
        child: Listener(
          onPointerDown: (event) => _scrollPointers.add(event.pointer),
          onPointerUp: _endScrollPointer,
          onPointerCancel: _endScrollPointer,
          child: NotificationListener<ScrollEndNotification>(
            onNotification: (notice) {
              if (notice.depth == 0) _scheduleFollow();
              return false;
            },
            child: list,
          ),
        ),
      ),
    ]);
    return PlayerModalBackHandler(
        active: selection != null,
        priority: 4,
        onBack: _closeSelection,
        child: content);
  }
}
