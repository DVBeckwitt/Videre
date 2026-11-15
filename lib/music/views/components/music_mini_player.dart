import 'dart:io';

import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/backend_recovery.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/backend_recovery_notice.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Compact presentation for the already-mounted shared audio player.
class MusicMiniPlayer extends StatelessWidget {
  const MusicMiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerCubit>();
    final state = context.watch<PlayerCubit>().state;
    final video = state.currentlyPlaying;
    final offline = state.offlineCurrentlyPlaying;
    final music = video?.musicMetadata ?? offline?.musicMetadata;
    if (music == null) return const SizedBox.shrink();
    final locals = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final recovery = state.backendRecovery;
    final failed = player.playbackStatus == MediaState.error ||
        recovery?.phase == BackendRecoveryPhase.failed;
    final busy = !failed &&
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
    final errorIcon = Icon(Icons.error_outline,
        key: const ValueKey('music-mini-error'), size: 20, color: colors.error);
    final title = Text(music.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: text.bodyMedium?.copyWith(
            fontSize: 16,
            color: colors.onSurface,
            fontWeight: FontWeight.bold));

    return ColoredBox(
      color: colors.surfaceContainer,
      child: SizedBox(
        key: const ValueKey('music-mini-player'),
        height: targetHeight,
        child: Column(children: [
          Expanded(
            child: Row(children: [
              Expanded(
                child: Semantics(
                  button: true,
                  label:
                      '${locals.musicNowPlaying}, ${music.title}, ${music.artist}${statusLabel == null ? '' : ', $statusLabel'}',
                  onTap: player.showBigPlayer,
                  excludeSemantics: true,
                  child: InkWell(
                    key: const ValueKey('music-mini-expand'),
                    onTap: player.showBigPlayer,
                    excludeFromSemantics: true,
                    child: LayoutBuilder(
                        builder: (context, constraints) => Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              child: Row(children: [
                                if (constraints.maxWidth >= 110) ...[
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: SizedBox.square(
                                      key: const ValueKey('music-mini-artwork'),
                                      dimension: 48,
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          _Artwork(
                                              music: music,
                                              video: video,
                                              offline: offline),
                                          if (failed)
                                            ColoredBox(
                                              color: Colors.black
                                                  .withValues(alpha: 0.6),
                                              child: Center(child: errorIcon),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                ],
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (largeText)
                                        Flexible(
                                          child: LayoutBuilder(
                                            builder: (context, bounds) =>
                                                FittedBox(
                                              fit: BoxFit.scaleDown,
                                              alignment: Alignment.centerLeft,
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
                                              music.artist.isNotEmpty))
                                        Text(statusLabel ?? music.artist,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: text.bodySmall?.copyWith(
                                                fontSize: 12,
                                                color:
                                                    colors.onSurfaceVariant)),
                                    ],
                                  ),
                                ),
                                if (failed && constraints.maxWidth < 110)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 4),
                                    child: errorIcon,
                                  ),
                              ]),
                            )),
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('music-mini-play'),
                tooltip: state.isPlaying ? locals.musicPause : locals.musicPlay,
                onPressed: player.togglePlaying,
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
                  icon: const Icon(Icons.skip_next_rounded),
                ),
              IconButton(
                key: const ValueKey('music-mini-close'),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: player.hide,
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ]),
          ),
          LinearProgressIndicator(
            key: const ValueKey('music-mini-progress'),
            value: busy ? null : progress,
            minHeight: 3,
            color: failed ? colors.error : colors.primary,
            backgroundColor: colors.primary.withValues(alpha: 0.12),
            semanticsLabel: locals.musicPosition,
          ),
        ]),
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.music, this.video, this.offline});

  final MusicMetadata music;
  final Video? video;
  final DownloadedVideo? offline;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: const Center(child: Icon(Icons.music_note_rounded)),
    );
    if (offline case final downloaded?) {
      return FutureBuilder<String>(
          future: downloaded.thumbnailPath,
          builder: (context, snapshot) => snapshot.data == null
              ? placeholder
              : Image.file(File(snapshot.data!),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => placeholder));
    }
    final images = music.thumbnails.isNotEmpty
        ? music.thumbnails
        : video?.videoThumbnails ?? [];
    return images.isEmpty
        ? placeholder
        : Thumbnail(
            images: images,
            fallback: placeholder,
            decoration: const BoxDecoration());
  }
}
