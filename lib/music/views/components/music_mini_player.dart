import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/backend_recovery.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/backend_recovery_notice.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'music_playback_artwork.dart';
import 'music_track_swipe.dart';

/// Compact presentation for the already-mounted shared audio player.
class MusicMiniPlayer extends StatelessWidget {
  const MusicMiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerCubit>();
    final state = context.watch<PlayerCubit>().state;
    final pending = player.openingMusicEntry;
    final entry =
        pending ?? state.currentlyPlaying ?? state.offlineCurrentlyPlaying;
    final video = entry is Video ? entry : null;
    final offline = entry is DownloadedVideo ? entry : null;
    final music = video?.musicMetadata ?? offline?.musicMetadata;
    if (music == null) return const SizedBox.shrink();
    final locals = AppLocalizations.of(context)!;
    const surface = Color(0xff232323);
    const foreground = Color(0xfff0f0f0);
    const supporting = Color(0xffc2c2c2);
    const error = Color(0xffffa8a8);
    final text = Theme.of(context).textTheme;
    final onDevice = isLocalMusicPlaybackId(video?.videoId ?? offline?.videoId);
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
        ? recovery == null
            ? locals.musicPlaybackError
            : backendRecoveryFailureText(locals, recovery)
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
    final title = Text(music.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: text.bodyMedium?.copyWith(
            fontSize: 16, color: foreground, fontWeight: FontWeight.w600));
    final controlStyle = IconButton.styleFrom(
      foregroundColor: foreground,
      padding: const EdgeInsets.all(10),
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
                child: LayoutBuilder(
                    builder: (context, bounds) => Row(children: [
                          Expanded(
                            child: Semantics(
                              button: true,
                              label:
                                  '${locals.musicNowPlaying}, ${music.title}, $artist${statusLabel == null ? '' : ', $statusLabel'}',
                              onTap: player.showBigPlayer,
                              excludeSemantics: true,
                              child: InkWell(
                                key: const ValueKey('music-mini-expand'),
                                onTap: player.showBigPlayer,
                                excludeFromSemantics: true,
                                child: LayoutBuilder(
                                    builder: (context, constraints) => Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8),
                                          child: Row(children: [
                                            if (constraints.maxWidth >=
                                                110) ...[
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
                                                              .withValues(
                                                                  alpha: 0.6),
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
                                                        builder:
                                                            (context, bounds) =>
                                                                FittedBox(
                                                          fit: BoxFit.scaleDown,
                                                          alignment: Alignment
                                                              .centerLeft,
                                                          child: SizedBox(
                                                              width: bounds
                                                                  .maxWidth,
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
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: text.bodySmall
                                                            ?.copyWith(
                                                                fontSize: 12,
                                                                color:
                                                                    supporting)),
                                                ],
                                              ),
                                            ),
                                            if (failed &&
                                                constraints.maxWidth < 110)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                    left: 4),
                                                child: errorIcon,
                                              ),
                                          ]),
                                        )),
                              ),
                            ),
                          ),
                          if (state.hasQueue && bounds.maxWidth >= 366)
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
                            onPressed:
                                pending == null ? player.togglePlaying : null,
                            style: controlStyle,
                            icon: Icon(state.isPlaying
                                ? Icons.pause_rounded
                                : completed
                                    ? Icons.replay_rounded
                                    : Icons.play_arrow_rounded),
                          ),
                          if (state.hasQueue)
                            IconButton(
                              key: const ValueKey('music-mini-next'),
                              tooltip: locals.musicNext,
                              onPressed: player.playNext,
                              style: controlStyle,
                              icon: const Icon(Icons.skip_next_rounded),
                            ),
                          IconButton(
                            key: const ValueKey('music-mini-close'),
                            tooltip: MaterialLocalizations.of(context)
                                .closeButtonTooltip,
                            onPressed: player.hide,
                            style: controlStyle,
                            icon: const Icon(Icons.close_rounded, size: 20),
                          ),
                        ])),
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
