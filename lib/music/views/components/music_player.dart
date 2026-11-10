import 'dart:io';
import 'dart:math' as math;

import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/backend_recovery_notice.dart';
import 'package:clipious/player/views/components/playback_speed_controls.dart';
import 'package:clipious/player/views/components/player_backend_picker.dart';
import 'package:clipious/player/views/components/sleep_timer.dart';
import 'package:clipious/player/views/components/playlist_loading_notice.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'music_library_actions.dart';
import 'music_sponsor_notice.dart';

/// Presentation only: commands still reach the existing mounted audio decoder.
class MusicPlayer extends StatefulWidget {
  const MusicPlayer({super.key});

  @override
  State<MusicPlayer> createState() => _MusicPlayerState();
}

class _MusicPlayerState extends State<MusicPlayer> {
  bool _showQueue = false;
  double? _seekPosition;
  String? _queueId;

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerCubit>();
    final state = context.watch<PlayerCubit>().state;
    final video = state.currentlyPlaying;
    final offline = state.offlineCurrentlyPlaying;
    final queueId = state.currentQueueId;
    if (queueId != _queueId) {
      _queueId = queueId;
      _seekPosition = null;
    }
    final music = video?.musicMetadata ?? offline?.musicMetadata;
    if (music == null) return const SizedBox.shrink();
    final locals = AppLocalizations.of(context)!;
    final view = LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 720;
      final nowPlaying = SingleChildScrollView(
        key: const ValueKey('music-now-playing-scroll'),
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(builder: (context, panel) {
          final artworkSize = math.min(panel.maxWidth, wide ? 300.0 : 340.0);
          return Column(children: [
            Semantics(
              image: true,
              label: music.album ?? music.title,
              child: SizedBox.square(
                key: const ValueKey('music-player-artwork'),
                dimension: artworkSize,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: _MusicArtwork(
                      music: music, video: video, offline: offline),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(music.title,
                key: const ValueKey('music-player-title'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 6),
            Text(music.artist,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
            if (music.album?.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(music.album!, textAlign: TextAlign.center),
              ),
            const SizedBox(height: 12),
            if (state.mediaEvent.state == MediaState.loading ||
                state.mediaEvent.state == MediaState.buffering)
              const LinearProgressIndicator(),
            if (state.backendRecovery case final recovery?)
              BackendRecoveryNotice(recovery: recovery),
            if (state.mediaEvent.state == MediaState.error) ...[
              Text(locals.musicPlaybackError, textAlign: TextAlign.center),
              TextButton.icon(
                onPressed: video != null
                    ? () => player.switchToVideo(video, startAt: state.position)
                    : offline != null
                        ? () => player.switchToOfflineVideo(offline)
                        : null,
                icon: const Icon(Icons.refresh),
                label: Text(locals.retry),
              ),
            ],
            _progress(context, player, state),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                IconButton(
                    key: const ValueKey('music-player-previous'),
                    tooltip: locals.musicPrevious,
                    onPressed: state.hasQueue ? player.playPrevious : null,
                    icon: const Icon(Icons.skip_previous)),
                IconButton(
                    tooltip: locals.musicRewind,
                    onPressed: player.rewind,
                    icon: const Icon(Icons.fast_rewind)),
                IconButton.filled(
                    key: const ValueKey('music-player-play'),
                    iconSize: 36,
                    padding: const EdgeInsets.all(16),
                    tooltip:
                        state.isPlaying ? locals.musicPause : locals.musicPlay,
                    onPressed: player.togglePlaying,
                    icon:
                        Icon(state.isPlaying ? Icons.pause : Icons.play_arrow)),
                IconButton(
                    tooltip: locals.musicForward,
                    onPressed: player.fastForward,
                    icon: const Icon(Icons.fast_forward)),
                IconButton(
                    key: const ValueKey('music-player-next'),
                    tooltip: locals.musicNext,
                    onPressed: state.hasQueue ? player.playNext : null,
                    icon: const Icon(Icons.skip_next)),
              ],
            ),
            const SizedBox(height: 8),
            _options(context, player, state, video),
          ]);
        }),
      );
      final queue = Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            Expanded(
                child: Text(locals.musicQueue,
                    style: Theme.of(context).textTheme.titleLarge)),
            if (!wide)
              IconButton(
                  key: const ValueKey('music-player-close-queue'),
                  tooltip: locals.musicNowPlaying,
                  onPressed: () => setState(() => _showQueue = false),
                  icon: const Icon(Icons.album_outlined)),
          ]),
        ),
        const Expanded(child: MusicQueue()),
      ]);
      return wide
          ? Row(children: [
              Expanded(child: nowPlaying),
              const VerticalDivider(),
              Expanded(child: queue),
            ])
          : _showQueue
              ? queue
              : nowPlaying;
    });
    return Column(children: [
      const MusicSponsorNotice(),
      Expanded(child: view),
    ]);
  }

  Widget _progress(
      BuildContext context, PlayerCubit player, PlayerState state) {
    final locals = AppLocalizations.of(context)!;
    final duration = player.duration.inMilliseconds;
    final queueId = state.currentQueueId;
    bool isCurrent() => mounted && queueId == player.state.currentQueueId;
    final maxPosition = math.max(1, duration).toDouble();
    final position = (_seekPosition ?? state.position.inMilliseconds.toDouble())
        .clamp(0.0, maxPosition);
    return Column(children: [
      Semantics(
        label: locals.musicPosition,
        child: Slider(
          key: const ValueKey('music-player-progress'),
          min: 0,
          max: maxPosition,
          value: position,
          semanticFormatterCallback: (value) =>
              prettyDurationCustom(Duration(milliseconds: value.round())),
          onChanged: duration <= 0
              ? null
              : (value) {
                  if (isCurrent()) setState(() => _seekPosition = value);
                },
          onChangeEnd: duration <= 0
              ? null
              : (value) {
                  if (!isCurrent()) return;
                  player.seek(Duration(milliseconds: value.round()));
                  setState(() => _seekPosition = null);
                },
        ),
      ),
      Wrap(alignment: WrapAlignment.spaceBetween, spacing: 16, children: [
        Text(prettyDurationCustom(Duration(milliseconds: position.round()))),
        Text(prettyDurationCustom(player.duration)),
      ]),
    ]);
  }

  Widget _options(BuildContext context, PlayerCubit player, PlayerState state,
      Video? video) {
    final locals = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsCubit>();
    final repeat = settings.state.playerRepeatMode;
    final shuffled = settings.state.playerShuffleMode;
    return Wrap(alignment: WrapAlignment.center, spacing: 8, children: [
      IconButton(
          key: const ValueKey('music-player-shuffle'),
          tooltip: locals.musicShuffle,
          isSelected: shuffled,
          onPressed: state.hasQueue
              ? () async {
                  await settings.setShuffle(!shuffled);
                  if (!player.isClosed) player.generatePlayQueue();
                }
              : null,
          icon: const Icon(Icons.shuffle)),
      IconButton(
          key: const ValueKey('music-player-repeat'),
          tooltip: switch (repeat) {
            PlayerRepeat.noRepeat => locals.musicRepeatOff,
            PlayerRepeat.repeatAll => locals.musicRepeatAll,
            PlayerRepeat.repeatOne => locals.musicRepeatOne,
          },
          isSelected: repeat != PlayerRepeat.noRepeat,
          onPressed: settings.setNextRepeatMode,
          icon: Icon(repeat == PlayerRepeat.repeatOne
              ? Icons.repeat_one
              : Icons.repeat)),
      IconButton(
          key: const ValueKey('music-player-queue'),
          tooltip: locals.musicQueue,
          onPressed: () => setState(() => _showQueue = true),
          icon: const Icon(Icons.queue_music)),
      IconButton(
          tooltip: locals.playbackSpeed,
          onPressed: () => showPlaybackSpeedSheet(context,
              initialSpeed: state.speed,
              onChanged: player.setSpeed,
              initialPitchSemitones: state.pitchSemitones,
              onPitchChanged:
                  !kIsWeb && defaultTargetPlatform == TargetPlatform.android
                      ? player.setPitchSemitones
                      : null),
          icon: const Icon(Icons.speed)),
      IconButton(
          key: const ValueKey('music-player-sleep'),
          tooltip: state.hasTimer ? locals.cancelSleepTimer : locals.sleepTimer,
          isSelected: state.hasTimer,
          onPressed: () async {
            if (player.state.hasTimer) {
              player.cancelSleep();
              return;
            }
            final timer = await SleepTimerSheet.show(context);
            if (timer != null && !player.isClosed) player.sleep(timer);
          },
          icon: const Icon(Icons.bedtime_outlined)),
      if (canChoosePlayerBackend(state))
        IconButton(
            tooltip: locals.backendChoose,
            onPressed: () => showPlayerBackendPicker(context, player: player),
            icon: const Icon(Icons.dns_outlined)),
      if (video != null) MusicLibraryActions(videos: [video]),
    ]);
  }
}

/// Reuses the player queue operations with rows that can grow for large text.
class MusicQueue extends StatelessWidget {
  const MusicQueue({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerCubit>();
    final state = context.watch<PlayerCubit>().state;
    final List<IdedVideo> videos =
        state.videos.isNotEmpty ? state.videos : state.offlineVideos;
    final currentId = state.currentQueueId;
    return ReorderableListView.builder(
      footer: const PlaylistLoadingNotice(),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: videos.length,
      onReorder: player.onQueueReorder,
      itemBuilder: (context, index) {
        final item = videos[index];
        final video = item is Video ? item : null;
        final offline = item is DownloadedVideo ? item : null;
        final music = video?.musicMetadata ?? offline?.musicMetadata;
        final selected = playbackQueueId(item) == currentId;
        return ListTile(
          key: ValueKey('music-queue-${playbackQueueId(item)}'),
          selected: selected,
          leading: Icon(selected ? Icons.equalizer : Icons.music_note),
          title: Text(music?.title ?? video?.title ?? offline?.title ?? ''),
          subtitle:
              Text(music?.artist ?? video?.author ?? offline?.author ?? ''),
          onTap: selected ? null : () => player.skipToVideo(index),
          trailing: selected
              ? null
              : IconButton(
                  tooltip: AppLocalizations.of(context)!.delete,
                  icon: const Icon(Icons.close),
                  onPressed: () =>
                      player.removeVideoFromQueue(playbackQueueId(item)),
                ),
        );
      },
    );
  }
}

class _MusicArtwork extends StatelessWidget {
  final MusicMetadata music;
  final Video? video;
  final DownloadedVideo? offline;

  const _MusicArtwork({required this.music, this.video, this.offline});

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: const Center(child: Icon(Icons.music_note, size: 72)),
    );
    if (offline case final downloaded?) {
      return FutureBuilder<String>(
          future: downloaded.thumbnailPath,
          builder: (context, snapshot) => snapshot.data == null
              ? placeholder
              : Image.file(File(snapshot.data!),
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stack) => placeholder));
    }
    final images = music.thumbnails.isNotEmpty
        ? music.thumbnails
        : video?.videoThumbnails ?? [];
    return images.isEmpty
        ? placeholder
        : Thumbnail(
            images: images,
            useInvidiousProxy: music.thumbnails.isEmpty,
            decoration: const BoxDecoration());
  }
}
