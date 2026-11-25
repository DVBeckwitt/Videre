import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_mini_player_preferences.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/backend_recovery.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/backend_recovery_notice.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/settings/models/theme_palette.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils.dart' show DeviceType, getDeviceType;
import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_bloc/flutter_bloc.dart';

import 'music_library_actions.dart';
import 'music_player.dart' show MusicPlaybackTitles;
import 'music_playback_artwork.dart';
import 'music_playback_toggles.dart';
import 'music_playing_source.dart';
import 'music_track_swipe.dart';

/// Compact presentation for the already-mounted shared audio player.
class MusicMiniPlayer extends StatelessWidget {
  const MusicMiniPlayer({super.key});

  @override
  Widget build(BuildContext context) =>
      MusicPlaybackTitles(builder: _buildMiniPlayer);

  Widget _buildMiniPlayer(
      BuildContext context, String? Function(IdedVideo?) savedTitle) {
    final player = context.read<PlayerCubit>();
    final state = context.watch<PlayerCubit>().state;
    final pending = player.openingMusicEntry;
    final entry =
        pending ?? state.currentlyPlaying ?? state.offlineCurrentlyPlaying;
    final video = entry is Video ? entry : null;
    final offline = entry is DownloadedVideo ? entry : null;
    final music = video?.musicMetadata ?? offline?.musicMetadata;
    if (music == null) return const SizedBox.shrink();
    final displayTitle = savedTitle(entry) ?? music.title;
    final locals = AppLocalizations.of(context)!;
    final palette =
        context.select((SettingsCubit cubit) => cubit.state.themePalette);
    final colors =
        palette == ThemePalette.classicPurple ? ThemePalette.classicDark : null;
    final surface = colors?.primaryContainer ?? const Color(0xff232323);
    final foreground = colors?.onPrimaryContainer ?? const Color(0xfff0f0f0);
    final supporting = colors?.onPrimaryContainer ?? const Color(0xffc2c2c2);
    const error = Color(0xffffa8a8);
    final text = Theme.of(context).textTheme;
    final onDevice = isLocalMusicPlaybackId(video?.videoId ?? offline?.videoId);
    final openAlbum = onDevice ? openDeviceAlbumAction(context, player) : null;
    final compactOnline = video != null &&
        !onDevice &&
        !isTv &&
        getDeviceType() == DeviceType.phone;
    final (layout, shortcut) = context.select((SettingsCubit cubit) => isTv
        ? (MusicMiniPlayerLayout.automatic, MusicMiniPlayerShortcut.automatic)
        : (
            cubit.state.musicMiniPlayerLayout,
            cubit.state.musicMiniPlayerShortcut
          ));
    final compact = switch (layout) {
      MusicMiniPlayerLayout.automatic => compactOnline,
      MusicMiniPlayerLayout.compact => true,
      MusicMiniPlayerLayout.transport => false,
    };
    final assignedShortcut = shortcut != MusicMiniPlayerShortcut.automatic;
    final customControls =
        assignedShortcut || layout != MusicMiniPlayerLayout.automatic;
    final bookmark = video != null && !onDevice && (compact || customControls)
        ? MusicLibraryEntry.song(video)
        : null;
    final artist =
        onDevice && music.artist.isEmpty ? locals.onDevice : music.artist;
    final recovery = onDevice || pending != null ? null : state.backendRecovery;
    final failed = pending == null &&
        (player.playbackStatus == MediaState.error ||
            recovery?.phase == BackendRecoveryPhase.failed);
    final busy = pending != null ||
        !failed &&
            (player.playbackStatus == MediaState.loading ||
                player.playbackStatus == MediaState.buffering ||
                recovery?.phase == BackendRecoveryPhase.trying);
    final statusLabel = failed
        ? playbackFailureText(locals, player.playbackFailureReason,
            recovery: recovery, music: true)
        : recovery?.phase == BackendRecoveryPhase.trying
            ? locals.backendTryingNamed(recovery!.label.isEmpty
                ? locals.backendDefault
                : recovery.label)
            : recovery?.phase == BackendRecoveryPhase.ready
                ? locals.backendReadyPaused
                : recovery?.phase == BackendRecoveryPhase.succeeded
                    ? locals.backendPlaybackResumed
                    : null;
    final duration = video?.liveNow == true
        ? 0
        : (video?.lengthSeconds ?? offline?.lengthSeconds ?? 0) * 1000;
    final progress = duration <= 0
        ? 0.0
        : (state.position.inMilliseconds / duration).clamp(0.0, 1.0);
    final completed = !state.isPlaying &&
        duration > 0 &&
        player.playbackStatus == MediaState.completed;
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 22;
    const errorIcon = Icon(Icons.error_outline,
        key: ValueKey('music-mini-error'), size: 20, color: error);
    final title = Text(displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: text.bodyMedium?.copyWith(
            fontSize: 16,
            color: foreground,
            fontWeight: compact ? FontWeight.bold : FontWeight.w600));
    final controlStyle = IconButton.styleFrom(
      foregroundColor: foreground,
      padding: const EdgeInsets.all(10),
    );
    final close = IconButton(
      key: const ValueKey('music-mini-close'),
      tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
      onPressed: player.hide,
      style: controlStyle,
      icon: const Icon(Icons.close_rounded, size: 20),
    );
    final artwork = MusicPlaybackArtwork(
      music: music,
      video: video,
      offline: offline,
      placeholder: ColoredBox(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: const Center(child: Icon(Icons.music_note_rounded)),
      ),
    );

    return MusicTrackSwipe(
        compact: true,
        child: ColoredBox(
          color: surface,
          child: SizedBox(
            key: const ValueKey('music-mini-player'),
            height: targetHeight,
            child: Column(children: [
              Expanded(
                child: LayoutBuilder(builder: (context, bounds) {
                  final inlinePrevious =
                      !compact && state.hasQueue && bounds.maxWidth >= 366;
                  final inlineSave = compact &&
                      bookmark != null &&
                      (!assignedShortcut || bounds.maxWidth >= 350);
                  final inlineNext = shortcut == MusicMiniPlayerShortcut.next ||
                      (!compact &&
                          !assignedShortcut &&
                          (state.hasQueue || customControls));
                  final menu = _CompactQueueMenu(
                      style: controlStyle,
                      showPrevious: !inlinePrevious,
                      showNext: !inlineNext,
                      bookmark: inlineSave ? null : bookmark);
                  return Row(children: [
                    Expanded(
                      child: Semantics(
                        button: true,
                        label:
                            '${locals.musicNowPlaying}, $displayTitle, $artist${statusLabel == null ? '' : ', $statusLabel'}',
                        onTap: player.showBigPlayer,
                        onLongPress: openAlbum,
                        customSemanticsActions: openAlbum == null
                            ? null
                            : {
                                CustomSemanticsAction(
                                    label: locals.musicOpenAlbum): openAlbum,
                              },
                        excludeSemantics: true,
                        child: InkWell(
                          key: const ValueKey('music-mini-expand'),
                          onTap: player.showBigPlayer,
                          onLongPress: openAlbum,
                          excludeFromSemantics: true,
                          child: LayoutBuilder(
                              builder: (context, constraints) => Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    child: Row(children: [
                                      if (constraints.maxWidth >= 110) ...[
                                        ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(6),
                                          child: SizedBox.square(
                                            key: const ValueKey(
                                                'music-mini-artwork'),
                                            dimension: 48,
                                            child: Stack(
                                              fit: StackFit.expand,
                                              children: [
                                                artwork,
                                                if (failed)
                                                  ColoredBox(
                                                    color: Colors.black
                                                        .withValues(alpha: 0.6),
                                                    child: Center(
                                                        child: errorIcon),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                      ],
                                      Expanded(
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            if (largeText)
                                              Flexible(
                                                child: LayoutBuilder(
                                                  builder: (context, bounds) =>
                                                      FittedBox(
                                                    fit: BoxFit.scaleDown,
                                                    alignment:
                                                        Alignment.centerLeft,
                                                    child: SizedBox(
                                                        width: bounds.maxWidth,
                                                        child: title),
                                                  ),
                                                ),
                                              )
                                            else
                                              title,
                                            if (!largeText &&
                                                (statusLabel != null ||
                                                    artist.isNotEmpty))
                                              Text(statusLabel ?? artist,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: text.bodySmall
                                                      ?.copyWith(
                                                          fontSize: 12,
                                                          color: supporting)),
                                          ],
                                        ),
                                      ),
                                      if (failed && constraints.maxWidth < 110)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(left: 4),
                                          child: errorIcon,
                                        ),
                                    ]),
                                  )),
                        ),
                      ),
                    ),
                    if (compact)
                      ValueListenableBuilder<int>(
                        valueListenable: player.playlistLoadingRevision,
                        builder: (context, _, __) => customControls ||
                                state.hasQueue ||
                                !player.playlistComplete
                            ? menu
                            : close,
                      ),
                    if (inlineSave)
                      MusicBookmarkButton(
                        key: ValueKey(('music-mini-bookmark', bookmark.id)),
                        entry: bookmark,
                        iconStyle: controlStyle,
                      ),
                    if (inlinePrevious)
                      IconButton(
                        key: const ValueKey('music-mini-previous'),
                        tooltip: locals.musicPrevious,
                        onPressed: player.playPrevious,
                        style: controlStyle,
                        icon: const Icon(Icons.skip_previous_rounded),
                      ),
                    IconButton(
                      key: const ValueKey('music-mini-play'),
                      tooltip: state.isPlaying
                          ? locals.musicPause
                          : locals.musicPlay,
                      onPressed: pending == null ? player.togglePlaying : null,
                      style: controlStyle,
                      icon: Icon(state.isPlaying
                          ? Icons.pause_rounded
                          : completed
                              ? Icons.replay_rounded
                              : Icons.play_arrow_rounded),
                    ),
                    if (!customControls && inlineNext)
                      IconButton(
                        key: const ValueKey('music-mini-next'),
                        tooltip: locals.musicNext,
                        onPressed: player.playNext,
                        style: controlStyle,
                        icon: const Icon(Icons.skip_next_rounded),
                      ),
                    if (customControls && inlineNext)
                      _MiniNextButton(style: controlStyle),
                    if (shortcut == MusicMiniPlayerShortcut.repeat)
                      MusicRepeatButton(
                        controlKey: const ValueKey('music-mini-repeat'),
                        style: controlStyle,
                        selectedBackgroundColor:
                            foreground.withValues(alpha: 0.22),
                      ),
                    if (shortcut == MusicMiniPlayerShortcut.shuffle)
                      MusicShuffleButton(
                        controlKey: const ValueKey('music-mini-shuffle'),
                        style: controlStyle,
                        selectedBackgroundColor:
                            foreground.withValues(alpha: 0.22),
                      ),
                    if (!compact) customControls ? menu : close,
                  ]);
                }),
              ),
              LinearProgressIndicator(
                key: const ValueKey('music-mini-progress'),
                value: busy ? null : progress,
                minHeight: 3,
                color: failed ? error : foreground,
                backgroundColor: foreground.withValues(alpha: 0.15),
                semanticsLabel: locals.musicPosition,
              ),
            ]),
          ),
        ));
  }
}

bool _canAdvance(PlayerCubit player, PlayerRepeat repeat) =>
    player.state.playQueue.isNotEmpty ||
    !player.playlistComplete ||
    repeat != PlayerRepeat.noRepeat;

class _MiniNextButton extends StatelessWidget {
  final ButtonStyle style;

  const _MiniNextButton({required this.style});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerCubit>();
    final repeat =
        context.select((SettingsCubit cubit) => cubit.state.playerRepeatMode);
    final locals = AppLocalizations.of(context)!;
    return ValueListenableBuilder<int>(
      valueListenable: player.playlistLoadingRevision,
      builder: (context, _, __) => IconButton(
        key: const ValueKey('music-mini-next'),
        tooltip: locals.musicNext,
        onPressed: _canAdvance(player, repeat) ? player.playNext : null,
        style: style,
        icon: const Icon(Icons.skip_next_rounded),
      ),
    );
  }
}

class _CompactQueueMenu extends StatefulWidget {
  final ButtonStyle style;
  final bool showPrevious;
  final bool showNext;
  final MusicLibraryEntry? bookmark;

  const _CompactQueueMenu(
      {required this.style,
      required this.showPrevious,
      required this.showNext,
      this.bookmark});

  @override
  State<_CompactQueueMenu> createState() => _CompactQueueMenuState();
}

class _CompactQueueMenuState extends State<_CompactQueueMenu> {
  final _focus = FocusNode(debugLabel: 'Music mini player menu');
  bool _saving = false;

  Future<void> _saveBookmark(
      AppCubit app, MusicLibraryEntry bookmark, bool saved) async {
    final session = MusicLibrarySession(app);
    if (_saving || !session.isCurrent) return;
    setState(() => _saving = true);
    try {
      await session.setBookmark(bookmark, saved: saved);
    } catch (_) {
      if (mounted && session.isCurrent) {
        final locals = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(locals.musicLibraryActionError)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerCubit>();
    final state = player.state;
    final app = context.read<AppCubit>();
    final session = app.state;
    final generation = player.playlistGeneration;
    final locals = AppLocalizations.of(context)!;
    final material = MaterialLocalizations.of(context);
    final repeat =
        context.select((SettingsCubit cubit) => cubit.state.playerRepeatMode);
    final canAdvance = _canAdvance(player, repeat);

    String? displayedOccurrence() {
      final opening = player.openingMusicEntry;
      return opening == null
          ? player.state.currentQueueId
          : playbackQueueId(opening);
    }

    final occurrence = displayedOccurrence();
    final previous = state.playedVideos.lastOrNull;
    final next = state.playQueue.firstOrNull;

    // MenuItemButton restores focus before invoking its command on the next
    // frame. The player or its owning profile may have changed in between.
    bool stillCurrent() =>
        mounted &&
        !app.isClosed &&
        !player.isClosed &&
        !app.state.globalLoading &&
        !app.state.sessionRecoveryRequired &&
        app.state.sessionRevision == session.sessionRevision &&
        app.state.profileId == session.profileId &&
        app.state.server == session.server &&
        player.playlistGeneration == generation &&
        player.state.isMini &&
        !player.state.isHidden &&
        !player.state.isClosing &&
        displayedOccurrence() == occurrence;

    return MenuAnchor(
      childFocusNode: _focus,
      consumeOutsideTap: true,
      // Keep large menu labels inside the overlay on narrow screens.
      crossAxisUnconstrained: false,
      menuChildren: [
        if (widget.showPrevious)
          MenuItemButton(
            key: const ValueKey('music-mini-previous'),
            onPressed: () {
              if (stillCurrent() &&
                  player.state.playedVideos.lastOrNull == previous) {
                player.playPrevious();
              }
            },
            leadingIcon: const Icon(Icons.skip_previous_rounded),
            child: Text(locals.musicPrevious),
          ),
        if (widget.showNext)
          MenuItemButton(
            key: const ValueKey('music-mini-next'),
            onPressed: canAdvance
                ? () {
                    if (stillCurrent() &&
                        player.state.playQueue.firstOrNull == next) {
                      player.playNext();
                    }
                  }
                : null,
            leadingIcon: const Icon(Icons.skip_next_rounded),
            child: Text(locals.musicNext),
          ),
        if (widget.bookmark case final bookmark?)
          Builder(builder: (context) {
            final library = MusicLibraryService.forProfile(db, db.profileId);
            return ListenableBuilder(
              listenable: library.changes,
              builder: (context, _) {
                final saved = library.contains(bookmark.kind, bookmark.id);
                return MenuItemButton(
                  key: const ValueKey('music-mini-bookmark-menu'),
                  onPressed: _saving
                      ? null
                      : () {
                          if (stillCurrent()) {
                            unawaited(_saveBookmark(app, bookmark, !saved));
                          }
                        },
                  leadingIcon:
                      Icon(saved ? Icons.favorite : Icons.favorite_border),
                  child: Text(
                      saved ? locals.musicRemoveSong : locals.musicSaveSong),
                );
              },
            );
          }),
        MenuItemButton(
          key: const ValueKey('music-mini-close'),
          onPressed: () {
            if (stillCurrent()) player.hide();
          },
          leadingIcon: const Icon(Icons.close_rounded),
          child: Text(material.closeButtonTooltip),
        ),
      ],
      builder: (context, controller, _) => PlayerModalBackHandler(
        active: controller.isOpen,
        onBack: () {
          controller.close();
          _focus.requestFocus();
        },
        child: IconButton(
          key: const ValueKey('music-mini-more'),
          tooltip: material.showMenuTooltip,
          style: widget.style,
          focusNode: _focus,
          onPressed: controller.isOpen ? controller.close : controller.open,
          icon: const Icon(Icons.more_vert_rounded),
        ),
      ),
    );
  }
}
