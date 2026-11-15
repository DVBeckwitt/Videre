import 'dart:io';
import 'dart:math' as math;

import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/backend_recovery_notice.dart';
import 'package:clipious/player/views/components/player_backend_picker.dart';
import 'package:clipious/player/views/components/sleep_timer.dart';
import 'package:clipious/player/views/components/playlist_loading_notice.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'music_library_actions.dart';
import 'music_sound_sheet.dart';
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
  int? _layoutMode;
  int _layoutRevision = 0;

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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final view = LayoutBuilder(builder: (context, constraints) {
      final shortLandscape =
          constraints.maxWidth >= 640 && constraints.maxHeight < 480;
      final wide = constraints.maxWidth >= 640 && !shortLandscape;
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
            : const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Center(
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: LayoutBuilder(builder: (context, panel) {
                  final artworkSize = math.min(panel.maxWidth,
                      (constraints.maxHeight * 0.43).clamp(180.0, 360.0));
                  return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!shortLandscape) ...[
                          _artworkFrame(
                              context, music, video, offline, artworkSize),
                          const SizedBox(height: 32),
                        ],
                        Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                  child: Text(music.title,
                                      key: const ValueKey('music-player-title'),
                                      style: (shortLandscape
                                              ? theme.textTheme.titleLarge
                                              : theme.textTheme.headlineSmall)
                                          ?.copyWith(
                                              fontWeight: FontWeight.w800))),
                              if (video != null)
                                DecoratedBox(
                                    decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: colors.surfaceContainerHighest),
                                    child:
                                        MusicLibraryActions(videos: [video])),
                            ]),
                        const SizedBox(height: 6),
                        Text(music.artist,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(color: colors.onSurfaceVariant)),
                        if (music.album?.isNotEmpty == true)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(music.album!,
                                style: theme.textTheme.bodyMedium
                                    ?.copyWith(color: colors.onSurfaceVariant)),
                          ),
                        SizedBox(height: shortLandscape ? 4 : 16),
                        if (player.playbackStatus == MediaState.loading ||
                            player.playbackStatus == MediaState.buffering)
                          const LinearProgressIndicator(),
                        if (state.backendRecovery case final recovery?)
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
                            _shuffle(context, player, state),
                            IconButton.filledTonal(
                                key: const ValueKey('music-player-previous'),
                                tooltip: locals.musicPrevious,
                                iconSize: 28,
                                onPressed:
                                    state.hasQueue ? player.playPrevious : null,
                                icon: const Icon(Icons.skip_previous)),
                            IconButton.filledTonal(
                                key: const ValueKey('music-player-play'),
                                iconSize: 36,
                                style: IconButton.styleFrom(
                                    fixedSize:
                                        Size.square(shortLandscape ? 64 : 72),
                                    backgroundColor: colors.primaryContainer,
                                    foregroundColor: colors.onPrimaryContainer,
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(24))),
                                tooltip: state.isPlaying
                                    ? locals.musicPause
                                    : locals.musicPlay,
                                onPressed: player.togglePlaying,
                                icon: Icon(state.isPlaying
                                    ? Icons.pause
                                    : Icons.play_arrow)),
                            IconButton.filledTonal(
                                key: const ValueKey('music-player-next'),
                                tooltip: locals.musicNext,
                                iconSize: 28,
                                onPressed:
                                    state.hasQueue ? player.playNext : null,
                                icon: const Icon(Icons.skip_next)),
                            _repeat(context),
                          ],
                        ),
                        const SizedBox(height: 24),
                        _options(context, player, state),
                      ]);
                }))),
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
              : shortLandscape
                  ? Row(children: [
                      Expanded(
                          flex: 3,
                          child: _artworkFrame(
                              context,
                              music,
                              video,
                              offline,
                              math.min(constraints.maxWidth * 0.32,
                                  math.max(1, constraints.maxHeight - 32)))),
                      Expanded(flex: 5, child: nowPlaying),
                    ])
                  : nowPlaying;
    });
    return DecoratedBox(
        decoration: BoxDecoration(
            gradient: RadialGradient(
          center: const Alignment(0, -0.15),
          radius: 0.85,
          colors: [
            colors.primaryContainer.withValues(alpha: 0.55),
            colors.surfaceContainer,
            colors.surface,
          ],
          stops: const [0, 0.55, 1],
        )),
        child: Column(children: [
          const MusicSponsorNotice(),
          Expanded(child: view),
        ]));
  }

  Widget _artworkFrame(BuildContext context, MusicMetadata music, Video? video,
          DownloadedVideo? offline, double size) =>
      Center(
        child: Semantics(
          image: true,
          label: music.album ?? music.title,
          child: Container(
            key: const ValueKey('music-player-artwork'),
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(size * 0.18),
              boxShadow: [
                BoxShadow(
                    color: Theme.of(context)
                        .colorScheme
                        .primaryContainer
                        .withValues(alpha: 0.25),
                    blurRadius: 48,
                    spreadRadius: 12,
                    offset: const Offset(0, 16))
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(size * 0.18),
              child:
                  _MusicArtwork(music: music, video: video, offline: offline),
            ),
          ),
        ),
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

  Widget _shuffle(BuildContext context, PlayerCubit player, PlayerState state) {
    final locals = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsCubit>();
    final shuffled = settings.state.playerShuffleMode;
    return IconButton.filledTonal(
        key: const ValueKey('music-player-shuffle'),
        tooltip: locals.musicShuffle,
        isSelected: shuffled,
        onPressed: state.hasQueue
            ? () async {
                await settings.setShuffle(!shuffled);
                if (!player.isClosed) player.generatePlayQueue();
              }
            : null,
        icon: const Icon(Icons.shuffle));
  }

  Widget _repeat(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsCubit>();
    final repeat = settings.state.playerRepeatMode;
    return IconButton.filledTonal(
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
            : Icons.repeat));
  }

  Widget _options(BuildContext context, PlayerCubit player, PlayerState state) {
    final locals = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      key: const ValueKey('music-player-actions'),
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        TextButton.icon(
            key: const ValueKey('music-player-queue'),
            onPressed: () => setState(() => _showQueue = true),
            icon: const Icon(Icons.queue_music),
            label: Text(locals.musicQueue)),
        TextButton.icon(
            key: const ValueKey('music-player-sleep'),
            style: state.hasTimer
                ? TextButton.styleFrom(
                    backgroundColor:
                        Theme.of(context).colorScheme.secondaryContainer)
                : null,
            onPressed: () async {
              if (player.state.hasTimer) {
                player.cancelSleep();
                return;
              }
              final timer = await SleepTimerSheet.show(context);
              if (timer != null && !player.isClosed) player.sleep(timer);
            },
            icon: const Icon(Icons.bedtime_outlined),
            label: Text(
                state.hasTimer ? locals.cancelSleepTimer : locals.sleepTimer)),
        TextButton.icon(
            key: const ValueKey('music-player-sound'),
            onPressed: () => showMusicSoundSheet(context, player),
            icon: const Icon(Icons.tune),
            label: Text(locals.musicSound)),
        IconButton(
            tooltip: locals.musicRewind,
            onPressed: player.rewind,
            icon: const Icon(Icons.fast_rewind)),
        IconButton(
            tooltip: locals.musicForward,
            onPressed: player.fastForward,
            icon: const Icon(Icons.fast_forward)),
        if (canChoosePlayerBackend(state))
          IconButton(
              tooltip: locals.backendChoose,
              onPressed: () => showPlayerBackendPicker(context, player: player),
              icon: const Icon(Icons.dns_outlined)),
      ]),
    );
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
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          selectedTileColor: Theme.of(context)
              .colorScheme
              .primaryContainer
              .withValues(alpha: 0.5),
          leading: SizedBox.square(
              dimension: 40,
              child: Center(
                  child: selected
                      ? const Icon(Icons.equalizer)
                      : Text('${index + 1}',
                          style: Theme.of(context).textTheme.labelLarge))),
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
        : Thumbnail(images: images, decoration: const BoxDecoration());
  }
}
