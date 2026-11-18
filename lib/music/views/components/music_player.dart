import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/services/music_lyrics_service.dart';
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
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'music_audio_quality_button.dart';
import 'music_library_actions.dart';
import 'music_lyrics_button.dart';
import 'music_playback_artwork.dart';
import 'music_sound_sheet.dart';
import 'music_sponsor_notice.dart';
import 'music_track_swipe.dart';

/// Presentation only: commands still reach the existing mounted audio decoder.
class MusicPlayer extends StatefulWidget {
  final bool television;
  final MusicLyricsLoader lyricsLoader;

  const MusicPlayer(
      {super.key,
      this.television = false,
      this.lyricsLoader = loadMusicLyrics});

  @override
  State<MusicPlayer> createState() => _MusicPlayerState();
}

class _MusicPlayerState extends State<MusicPlayer> {
  static const _canvas = Color(0xff121212);
  static const _playerColors = ColorScheme.dark(
    surface: _canvas,
    surfaceContainer: Color(0xff232323),
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

  bool? _queueVisibility;
  final _queueButtonFocus = FocusNode(debugLabel: 'Music queue');
  final _closeQueueFocus = FocusNode(debugLabel: 'Close music queue');
  final _queueScope = FocusScopeNode(debugLabel: 'Music queue overlay');
  double? _seekPosition;
  String? _queueId;
  int? _layoutMode;
  int _layoutRevision = 0;

  void _setQueueVisible(bool visible) {
    setState(() => _queueVisibility = visible);
    // Phone keyboards and remotes need the same entry point as TV. Wait for
    // the overlay to mount, or for ExcludeFocus to release the player controls.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _queueVisibility != visible) return;
      (visible ? _closeQueueFocus : _queueButtonFocus).requestFocus();
    });
  }

  @override
  void dispose() {
    _queueButtonFocus.dispose();
    _closeQueueFocus.dispose();
    _queueScope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appTheme = Theme.of(context);
    return Theme(
      data: appTheme.copyWith(
        brightness: Brightness.dark,
        colorScheme: _playerColors,
        iconTheme: const IconThemeData(color: Color(0xfff0f0f0)),
        textTheme: appTheme.textTheme.apply(
          bodyColor: _playerColors.onSurface,
          displayColor: _playerColors.onSurface,
        ),
      ),
      child: Material(
        color: _canvas,
        child: Builder(builder: _buildPlayer),
      ),
    );
  }

  Widget _buildPlayer(BuildContext context) {
    final player = context.read<PlayerCubit>();
    final state = context.watch<PlayerCubit>().state;
    final video = state.currentlyPlaying;
    final offline = state.offlineCurrentlyPlaying;
    final onDevice = isLocalMusicPlaybackId(video?.videoId ?? offline?.videoId);
    final recovery = onDevice ? null : state.backendRecovery;
    final queueId = state.currentQueueId;
    if (queueId != _queueId) {
      _queueId = queueId;
      _seekPosition = null;
    }
    final music = video?.musicMetadata ?? offline?.musicMetadata;
    if (music == null) return const SizedBox.shrink();
    final locals = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
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
      final showQueue = _queueVisibility ?? (wide && !widget.television);
      final sideQueue = wide && showQueue;
      final allowCommunityLookup = video != null &&
          !onDevice &&
          !video.downloadPlaybackOnly &&
          state.isAudio &&
          !state.isMini &&
          !state.isHidden &&
          !state.isClosing &&
          (!showQueue || sideQueue);
      final shortLandscape = !sideQueue &&
          constraints.maxWidth >= 480 &&
          constraints.maxWidth > constraints.maxHeight;
      final mode = shortLandscape
          ? 1
          : wide
              ? 2
              : 0;
      if (_layoutMode != mode) {
        _layoutMode = mode;
        _layoutRevision++;
        _seekPosition = null;
      }
      final nowPlaying = SingleChildScrollView(
        key: const ValueKey('music-now-playing-scroll'),
        padding: shortLandscape
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
            : const EdgeInsets.fromLTRB(30, 10, 30, 16),
        child: Center(
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: LayoutBuilder(builder: (context, panel) {
                  final textScale = MediaQuery.textScalerOf(context).scale(20);
                  final metadataHeight = (textScale - 20).clamp(0.0, 45.0);
                  // Give the two-line title, seek bar, transport and action
                  // strip room before sizing the cover on shorter phones.
                  final artArea = wide
                      ? math.max(
                          math.min(
                                  panel.maxWidth,
                                  (constraints.maxHeight * 0.59)
                                      .clamp(140.0, 432.0)) +
                              24,
                          constraints.maxHeight - 296 - metadataHeight * 2)
                      : math.max(140.0,
                          constraints.maxHeight - 356 - metadataHeight * 2);
                  final artworkSize =
                      math.min(panel.maxWidth, math.min(432.0, artArea - 24));
                  return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!shortLandscape) ...[
                          SizedBox(
                            height: artArea,
                            child: _artworkFrame(
                                music, video, offline, artworkSize,
                                allowCommunityLookup: allowCommunityLookup),
                          ),
                        ],
                        Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                  child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(music.title,
                                      key: const ValueKey('music-player-title'),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style:
                                          theme.textTheme.titleLarge?.copyWith(
                                        fontWeight: FontWeight.w700,
                                        height: 1.14,
                                      )),
                                  const SizedBox(height: 2),
                                  _artistByline(context, music, onDevice),
                                ],
                              )),
                              if (video != null && !onDevice) ...[
                                const SizedBox(width: 8),
                                MusicBookmarkButton(
                                  key: ValueKey(
                                      ('music-player-bookmark', video.videoId)),
                                  entry: MusicLibraryEntry.song(video),
                                  iconStyle: metadataButtonStyle,
                                ),
                                const SizedBox(width: 4),
                                MusicLibraryActions(
                                  videos: [video],
                                  iconStyle: metadataButtonStyle,
                                  inPlayer: true,
                                ),
                              ],
                            ]),
                        if (music.album?.isNotEmpty == true)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(music.album!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium
                                    ?.copyWith(color: colors.onSurfaceVariant)),
                          ),
                        SizedBox(height: shortLandscape ? 4 : 16),
                        if (player.playbackStatus == MediaState.loading ||
                            player.playbackStatus == MediaState.buffering)
                          const LinearProgressIndicator(),
                        if (recovery != null)
                          BackendRecoveryNotice(recovery: recovery),
                        if (player.playbackStatus == MediaState.error) ...[
                          Text(locals.musicPlaybackError,
                              textAlign: TextAlign.center),
                          TextButton.icon(
                            onPressed: state.hasVideo
                                ? player.retryCurrentVideo
                                : null,
                            icon: const Icon(Icons.refresh),
                            label: Text(locals.retry),
                          ),
                        ],
                        _progress(context, player, state),
                        SizedBox(height: shortLandscape ? 4 : 16),
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 0,
                          runSpacing: 8,
                          children: [
                            const _MusicShuffleButton(),
                            _trackTransport(context, player, state,
                                previous: true),
                            IconButton.filledTonal(
                                key: const ValueKey('music-player-play'),
                                autofocus: widget.television,
                                iconSize: 36,
                                style: IconButton.styleFrom(
                                    fixedSize:
                                        Size.square(shortLandscape ? 64 : 72),
                                    backgroundColor: colors.primaryContainer,
                                    foregroundColor: colors.onPrimaryContainer,
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(25))),
                                tooltip: state.isPlaying
                                    ? locals.musicPause
                                    : locals.musicPlay,
                                onPressed: player.togglePlaying,
                                icon: Icon(state.isPlaying
                                    ? Icons.pause_rounded
                                    : player.playbackStatus ==
                                            MediaState.completed
                                        ? Icons.replay_rounded
                                        : Icons.play_arrow_rounded)),
                            _trackTransport(context, player, state,
                                previous: false),
                            _repeat(context),
                          ],
                        ),
                        SizedBox(height: shortLandscape ? 8 : 20),
                        _options(context, player, state,
                            showQueue: showQueue, onDevice: onDevice),
                      ]);
                }))),
      );
      final queue = PlayerModalBackHandler(
          onBack: () => _setQueueVisible(false),
          child: Column(children: [
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
            Expanded(child: MusicQueue(television: widget.television)),
          ]));
      if (sideQueue) {
        return Row(children: [
          Expanded(child: nowPlaying),
          Expanded(
            child: Material(
              color: _canvas.withValues(alpha: 0.65),
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: queue,
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
                      math.min(constraints.maxWidth * 0.32,
                          math.max(1, constraints.maxHeight - 32)),
                      allowCommunityLookup: allowCommunityLookup)),
              Expanded(flex: 5, child: nowPlaying),
            ])
          : nowPlaying;
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
                child: FocusScope(node: _queueScope, child: queue),
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
              const ColoredBox(color: _canvas),
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
              const DecoratedBox(
                  decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    _canvas,
                    Color(0x6b121212),
                    Color(0x99121212),
                    _canvas
                  ],
                  stops: [0, 0.27, 0.76, 1],
                ),
              )),
            ]),
          ),
        ),
      ),
      Column(children: [
        if (!onDevice) const MusicSponsorNotice(),
        Expanded(child: view),
      ]),
    ]);
  }

  Widget _artistByline(
      BuildContext context, MusicMetadata music, bool onDevice) {
    final theme = Theme.of(context);
    final style = theme.textTheme.titleMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    if (onDevice || !music.artistCredits.any((credit) => credit.id != null)) {
      return Text(
          onDevice && music.artist.isEmpty
              ? AppLocalizations.of(context)!.onDevice
              : music.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style);
    }
    return Wrap(
      spacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final credit in music.artistCredits)
          if (credit.id case final id?)
            TextButton(
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    alignment: AlignmentDirectional.centerStart),
                onPressed: () => MusicScreen.openPlayingArtist(context, id,
                    television: widget.television),
                child: Text(credit.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        style?.copyWith(decoration: TextDecoration.underline)))
          else
            Text(credit.name,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
      ],
    );
  }

  Widget _artworkFrame(MusicMetadata music, Video? video,
          DownloadedVideo? offline, double size,
          {required bool allowCommunityLookup}) =>
      Center(
        child: Stack(children: [
          Semantics(
            image: true,
            label: music.album ?? music.title,
            child: MusicTrackSwipe(
                child: Container(
              key: const ValueKey('music-player-artwork'),
              width: size,
              height: size,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(size * 0.2),
                boxShadow: const [
                  BoxShadow(
                      color: Colors.black38,
                      blurRadius: 24,
                      offset: Offset(0, 12)),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(size * 0.2),
                child: MusicPlaybackArtwork(
                    music: music,
                    video: video,
                    offline: offline,
                    allowCommunityLookup: allowCommunityLookup),
              ),
            )),
          ),
          if (!isLocalMusicPlaybackId(video?.videoId ?? offline?.videoId))
            PositionedDirectional(
              start: 8,
              end: 8,
              bottom: 8,
              child: Align(
                alignment: AlignmentDirectional.bottomEnd,
                child: MusicLyricsButton(loader: widget.lyricsLoader),
              ),
            ),
        ]),
      );

  Widget _progress(
      BuildContext context, PlayerCubit player, PlayerState state) {
    final locals = AppLocalizations.of(context)!;
    final duration = math.max(
            0,
            state.currentlyPlaying?.lengthSeconds ??
                state.offlineCurrentlyPlaying?.lengthSeconds ??
                0) *
        1000;
    final canSeek = duration > 0 && !(state.currentlyPlaying?.liveNow ?? false);
    final queueId = state.currentQueueId;
    final layoutRevision = _layoutRevision;
    bool isCurrent() =>
        mounted &&
        queueId == player.state.currentQueueId &&
        layoutRevision == _layoutRevision;
    final maxPosition = math.max(1, duration).toDouble();
    final position = (_seekPosition ?? state.position.inMilliseconds.toDouble())
        .clamp(0.0, maxPosition);
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
                        : math.max(0, state.position.inMilliseconds)))),
                Text(duration > 0
                    ? prettyDurationCustom(Duration(milliseconds: duration))
                    : '--:--'),
              ])),
    ]);
  }

  // Port of Muzza Player.kt's combined click/long-click transport. Long press
  // seeks by Videre's existing preferred interval and never changes songs.
  Widget _trackTransport(
      BuildContext context, PlayerCubit player, PlayerState state,
      {required bool previous}) {
    final locals = AppLocalizations.of(context)!;
    final name = previous ? 'previous' : 'next';
    final label = previous ? locals.musicPrevious : locals.musicNext;
    final seekLabel = previous ? locals.musicRewind : locals.musicForward;
    final app = context.read<AppCubit>();
    final session = app.state;
    final occurrence = state.currentQueueId;
    final seconds = context.watch<SettingsCubit>().state.skipStep;
    final length = state.currentlyPlaying?.lengthSeconds ??
        state.offlineCurrentlyPlaying?.lengthSeconds ??
        0;
    final canSeek = length > 0 && state.currentlyPlaying?.liveNow != true;
    void seek() {
      if (player.isClosed ||
          app.isClosed ||
          app.state.globalLoading ||
          app.state.sessionRecoveryRequired ||
          app.state.sessionRevision != session.sessionRevision ||
          app.state.profileId != session.profileId ||
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
    }

    return Semantics(
      key: ValueKey(
          (name, occurrence, session.sessionRevision, session.profileId)),
      customSemanticsActions:
          canSeek ? {CustomSemanticsAction(label: seekLabel): seek} : null,
      child: GestureDetector(
        excludeFromSemantics: true,
        onLongPress: canSeek ? seek : null,
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

  Widget _repeat(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsCubit>();
    final repeat = settings.state.playerRepeatMode;
    return IconButton(
        key: const ValueKey('music-player-repeat'),
        tooltip: switch (repeat) {
          PlayerRepeat.noRepeat => locals.musicRepeatOff,
          PlayerRepeat.repeatAll => locals.musicRepeatAll,
          PlayerRepeat.repeatOne => locals.musicRepeatOne,
        },
        isSelected: repeat != PlayerRepeat.noRepeat,
        style: repeat != PlayerRepeat.noRepeat
            ? IconButton.styleFrom(
                backgroundColor:
                    Theme.of(context).colorScheme.secondaryContainer)
            : null,
        onPressed: settings.setNextRepeatMode,
        icon: Icon(repeat == PlayerRepeat.repeatOne
            ? Icons.repeat_one
            : Icons.repeat));
  }

  Widget _options(BuildContext context, PlayerCubit player, PlayerState state,
      {required bool showQueue, required bool onDevice}) {
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
          String name, String label, IconData icon, VoidCallback onPressed,
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
          action('queue', locals.musicQueue, Icons.queue_music,
              () => _setQueueVisible(!showQueue),
              active: showQueue, focusNode: _queueButtonFocus),
          action(
              'sleep',
              state.hasTimer ? locals.cancelSleepTimer : locals.sleepTimer,
              Icons.bedtime_outlined, () async {
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
          if (!onDevice) const MusicAudioQualityButton(),
          IconButton(
              tooltip: locals.musicRewind,
              onPressed: player.rewind,
              icon: const Icon(Icons.fast_rewind)),
          IconButton(
              tooltip: locals.musicForward,
              onPressed: player.fastForward,
              icon: const Icon(Icons.fast_forward)),
          if (!onDevice && canChoosePlayerBackend(state))
            IconButton(
                tooltip: locals.backendChoose,
                onPressed: () =>
                    showPlayerBackendPicker(context, player: player),
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

class _MusicShuffleButton extends StatelessWidget {
  final Key controlKey;

  const _MusicShuffleButton(
      {this.controlKey = const ValueKey('music-player-shuffle')});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerCubit>();
    final generation = player.playlistGeneration;
    final app = context.read<AppCubit>();
    final session = app.state;
    final settings = context.watch<SettingsCubit>();
    final shuffled = settings.state.playerShuffleMode;
    return IconButton(
        key: controlKey,
        tooltip: AppLocalizations.of(context)!.musicShuffle,
        isSelected: shuffled,
        style: shuffled
            ? IconButton.styleFrom(
                backgroundColor:
                    Theme.of(context).colorScheme.secondaryContainer)
            : null,
        onPressed: player.state.hasQueue
            ? () async {
                await settings.setShuffle(!shuffled);
                if (!player.isClosed &&
                    !app.isClosed &&
                    app.state.sessionRevision == session.sessionRevision &&
                    app.state.profileId == session.profileId &&
                    player.playlistGeneration == generation &&
                    !player.state.isClosing) {
                  player.generatePlayQueue();
                }
              }
            : null,
        icon: const Icon(Icons.shuffle));
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

class _MusicQueueState extends State<MusicQueue> {
  static const _lockSetting = 'music-queue-locked';
  final _scroll = ScrollController();
  ((String, int, int), String, double)? _scrollAnchor;
  ({
    (String, int, int) owner,
    List<String> order,
    List<String> upcoming,
    int from,
  })? _drag;
  Set<String>? _selection;
  (String, int, int)? _selectionOwner;

  List<IdedVideo> _sources(PlayerState state) =>
      state.videos.isNotEmpty ? state.videos : state.offlineVideos;

  List<IdedVideo> _entries(PlayerState state) =>
      playbackQueueTraversal(_sources(state),
          played: state.playedVideos,
          current: state.currentQueueId,
          upcoming: state.playQueue);

  void _followActiveRow(
      (String, int, int) owner, String? id, int index, double extent) {
    if (id == null || index < 0) return;
    final anchor = (owner, id, extent);
    if (anchor == _scrollAnchor) return;
    _scrollAnchor = anchor;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || _scrollAnchor != anchor) return;
      final position = _scroll.position;
      final top = index * extent - (position.viewportDimension - extent) / 2;
      _scroll.jumpTo(top.clamp(0.0, position.maxScrollExtent).toDouble());
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _closeSelection() => setState(() => _selection = null);

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerCubit>();
    final state = context.watch<PlayerCubit>().state;
    final videos = _entries(state);
    final onDevice = isLocalMusicPlaybackId(videos.firstOrNull?.videoId);
    final currentId = state.currentQueueId;
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
    final locked = settings.state.settings[_lockSetting]?.value == 'true';
    final locals = AppLocalizations.of(context)!;
    final order = videos.map(playbackQueueId).toList();
    final ids = order.toSet();
    final upcoming = state.playQueue.where(ids.contains).toList();
    if (_drag?.order.length != order.length) _drag = null;
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
    final editing = !locked && selection == null;
    bool current() =>
        mounted &&
        !player.isClosed &&
        !app.isClosed &&
        !app.state.globalLoading &&
        !app.state.sessionRecoveryRequired &&
        app.state.profileId == session.profileId &&
        app.state.sessionRevision == session.sessionRevision &&
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

    Future<void> selectedAction(_QueueSelectionAction action) async {
      if (!current() || _selection?.isNotEmpty != true) return;
      final selected = _entries(player.state)
          .where((entry) => _selection!.contains(playbackQueueId(entry)))
          .toList();
      final online = selected.whereType<Video>().toList();
      _closeSelection();
      if (selected.isEmpty) return;
      switch (action) {
        case _QueueSelectionAction.play:
        case _QueueSelectionAction.shuffle:
          if (action == _QueueSelectionAction.shuffle) selected.shuffle();
          if (selected.any((entry) => isLocalMusicPlaybackId(entry.videoId))) {
            final tracks = selected
                .map((entry) => localMusicTrackForPlayback(entry.videoId))
                .nonNulls
                .toList();
            if (tracks.length != selected.length) return;
            await player.playLocalMusic(tracks);
          } else if (online.length == selected.length) {
            await player.playVideo(selected.cast<Video>(), audio: true);
          } else {
            await player.playOfflineVideos(selected.cast<DownloadedVideo>());
          }
        case _QueueSelectionAction.next:
          player.enqueueQueueCopies(online, next: true);
        case _QueueSelectionAction.append:
          player.enqueueQueueCopies(online, next: false);
        case _QueueSelectionAction.save:
          await MusicLibraryActions.save(context, online);
        case _QueueSelectionAction.download:
          await MusicLibraryActions.download(context, online);
        case _QueueSelectionAction.remove:
          player.removeInactiveQueueOccurrences(
              selected.map(playbackQueueId).toSet());
      }
    }

    final list = ReorderableListView.builder(
      buildDefaultDragHandles: false,
      scrollController: _scroll,
      itemExtent: extent,
      footer: onDevice ? null : const PlaylistLoadingNotice(),
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      itemCount: videos.length,
      onReorderStart: (index) {
        _drag = (owner: owner, order: order, upcoming: upcoming, from: index);
      },
      onReorderEnd: (index) {
        if (_drag?.from == index) _drag = null;
      },
      onReorder: (from, to) {
        final drag = _drag;
        _drag = null;
        if (!current() ||
            _selection != null ||
            settings.state.settings[_lockSetting]?.value == 'true') {
          return;
        }
        // The drop indexes belong to the timeline the user picked up.
        if (drag != null && (drag.owner != owner || drag.from != from)) return;
        final expectedOrder = drag?.order ?? order;
        final expectedUpcoming = drag?.upcoming ?? upcoming;
        final latest = _entries(player.state).map(playbackQueueId).toList();
        if (!listEquals(latest, expectedOrder) ||
            !listEquals(player.state.playQueue.where(ids.contains).toList(),
                expectedUpcoming)) {
          return;
        }
        final moving = expectedOrder[from];
        final before = to == expectedOrder.length ? null : expectedOrder[to];
        player.moveQueueOccurrence(moving, beforeId: before);
      },
      itemBuilder: (context, index) {
        final item = videos[index];
        final id = playbackQueueId(item);
        final video = item is Video ? item : null;
        final offline = item is DownloadedVideo ? item : null;
        final music = video?.musicMetadata ?? offline?.musicMetadata;
        final artist = music?.artist ?? video?.author ?? offline?.author ?? '';
        final isActive = id == currentId;
        final mountedVideo = state.currentlyPlaying;
        final artworkVideo = isActive &&
                mountedVideo != null &&
                mountedVideo.videoId == video?.videoId
            ? mountedVideo
            : video;
        final isPlaying =
            state.isPlaying && player.playbackStatus == MediaState.playing;
        final nextIndex = upcoming.indexOf(id);
        final canMoveUp = nextIndex > 0;
        final canMoveDown = nextIndex >= 0 && nextIndex < upcoming.length - 1;
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
              leading: SizedBox.square(
                dimension: 46,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: Stack(fit: StackFit.expand, children: [
                    MusicPlaybackArtwork(
                        music: artworkVideo?.musicMetadata ?? music,
                        video: artworkVideo,
                        offline: offline,
                        placeholderSize: 22),
                    if (isActive)
                      ColoredBox(
                        color: Colors.black54,
                        child: Icon(
                            key: const ValueKey('music-queue-active'),
                            isPlaying
                                ? Icons.equalizer
                                : Icons.play_arrow_rounded,
                            semanticLabel: isPlaying
                                ? locals.musicPause
                                : locals.musicPlay,
                            color: Colors.white),
                      ),
                  ]),
                ),
              ),
              title: Text(music?.title ?? video?.title ?? offline?.title ?? '',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                  onDevice && artist.isEmpty ? locals.onDevice : artist,
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
                } else if (player.state.currentQueueId == id) {
                  player.togglePlaying();
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
                      semanticLabel:
                          music?.title ?? video?.title ?? offline?.title,
                    )
                  : !editing || isActive
                      ? null
                      : Row(mainAxisSize: MainAxisSize.min, children: [
                          if (canMoveUp || canMoveDown)
                            ReorderableDragStartListener(
                              key: ValueKey(
                                  'music-queue-drag-${playbackQueueId(item)}'),
                              index: index,
                              child: Tooltip(
                                message: AppLocalizations.of(context)!
                                    .musicQueueReorder,
                                child: const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: Icon(Icons.drag_handle_rounded),
                                ),
                              ),
                            ),
                          PopupMenuButton<int>(
                            key: ValueKey(
                                'music-queue-menu-${playbackQueueId(item)}'),
                            tooltip: AppLocalizations.of(context)!.musicQueue,
                            onSelected: (action) {
                              if (!current() ||
                                  settings.state.settings[_lockSetting]
                                          ?.value ==
                                      'true') {
                                return;
                              }
                              // A menu may outlive a queue update. Resolve the occurrence
                              // again rather than applying its old index to another song.
                              final latest = player.state.playQueue.toList();
                              final currentIndex = latest.indexOf(id);
                              if (action == -1 && currentIndex > 0) {
                                player.moveQueueOccurrence(id,
                                    beforeId: latest[currentIndex - 1]);
                              } else if (action == 1 &&
                                  currentIndex >= 0 &&
                                  currentIndex < latest.length - 1) {
                                player.moveQueueOccurrence(id,
                                    beforeId: currentIndex + 2 < latest.length
                                        ? latest[currentIndex + 2]
                                        : null);
                              } else if (action == 0 &&
                                  player.state.currentQueueId !=
                                      playbackQueueId(item)) {
                                player.removeVideoFromQueue(
                                    playbackQueueId(item));
                              }
                            },
                            itemBuilder: (context) => [
                              if (canMoveUp)
                                PopupMenuItem(
                                  value: -1,
                                  child: PlayerModalBackHandler(
                                    priority: 5,
                                    child: Text(locals.musicQueueMoveUp),
                                  ),
                                ),
                              if (canMoveDown)
                                PopupMenuItem(
                                  value: 1,
                                  child: !canMoveUp
                                      ? PlayerModalBackHandler(
                                          priority: 5,
                                          child:
                                              Text(locals.musicQueueMoveDown),
                                        )
                                      : Text(locals.musicQueueMoveDown),
                                ),
                              PopupMenuItem(
                                value: 0,
                                child: canMoveUp || canMoveDown
                                    ? Text(locals.delete)
                                    : PlayerModalBackHandler(
                                        priority: 5,
                                        child: Text(locals.delete)),
                              ),
                            ],
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
    final toolbar = selection == null
        ? Row(children: [
            Expanded(
                child: Padding(
              padding: const EdgeInsetsDirectional.only(start: 20),
              child: Text(locals.musicTrackCount(videos.length),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            )),
            const _MusicShuffleButton(
                controlKey: ValueKey('music-queue-shuffle')),
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
              onPressed: () => settings
                  .saveSetting(SettingsValue(_lockSetting, '${!locked}')),
              icon: Icon(locked ? Icons.lock_outline : Icons.lock_open_rounded),
            ),
          ])
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
              tooltip: locals.musicQueueSelectAll,
              onPressed: () => setState(() => _selection = {...ids}),
              icon: const Icon(Icons.select_all_rounded),
            ),
            PopupMenuButton<_QueueSelectionAction>(
              key: const ValueKey('music-queue-selection-menu'),
              enabled: selection.isNotEmpty,
              tooltip: locals.musicQueueSelect,
              onSelected: selectedAction,
              itemBuilder: (context) => [
                PopupMenuItem(
                    value: _QueueSelectionAction.play,
                    child: PlayerModalBackHandler(
                      priority: 5,
                      child: Text(locals.musicPlay),
                    )),
                PopupMenuItem(
                    value: _QueueSelectionAction.shuffle,
                    child: Text(locals.musicShuffle)),
                if (!onDevice && state.videos.isNotEmpty) ...[
                  PopupMenuItem(
                      value: _QueueSelectionAction.next,
                      child: Text(locals.playNext)),
                  PopupMenuItem(
                      value: _QueueSelectionAction.append,
                      child: Text(locals.addToQueueList)),
                  PopupMenuItem(
                      value: _QueueSelectionAction.save,
                      child: Text(locals.musicSaveToPlaylist)),
                  if (!isTv && !widget.television)
                    PopupMenuItem(
                        value: _QueueSelectionAction.download,
                        child: Text(locals.musicDownloadAudio)),
                ],
                if (!locked && selection.any((id) => id != currentId))
                  PopupMenuItem(
                      value: _QueueSelectionAction.remove,
                      child: Text(locals.musicQueueRemoveSelected)),
              ],
            ),
          ]);
    final content = Column(children: [toolbar, Expanded(child: list)]);
    return selection == null
        ? content
        : PlayerModalBackHandler(
            priority: 4, onBack: _closeSelection, child: content);
  }
}
