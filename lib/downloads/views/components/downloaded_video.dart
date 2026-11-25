import 'package:clipious/utils/motion.dart';
import 'package:clipious/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';

import '../../../videos/views/components/compact_video.dart';
import 'download_retry_time.dart';

bool _canExportMusic(DownloadedVideo video) =>
    video.downloadComplete &&
    video.audioOnly &&
    video.musicMetadata != null &&
    (video.storageUri == null || !video.storeAsMusic);

class DownloadedVideoView extends StatelessWidget {
  final DownloadedVideo video;

  const DownloadedVideoView({super.key, required this.video});

  void openVideoSheet(BuildContext context) {
    final cubit = context.read<DownloadManagerCubit>();
    final locals = AppLocalizations.of(context)!;
    showSafeModalBottomSheet<void>(
      enableDrag: true,
      showDragHandle: true,
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (!video.downloadComplete &&
              !video.downloadFailed &&
              !video.authenticationRequired)
            BlocBuilder<DownloadManagerCubit, DownloadManagerState>(
                bloc: cubit,
                builder: (context, state) {
                  final paused = state.pausedVideoIds.contains(video.videoId);
                  return DownloadRetryAvailability(
                      retryAt: paused ? cubit.retryAtFor(video) : null,
                      builder: (_, waitUntil) => ListTile(
                            enabled: waitUntil == null,
                            leading:
                                Icon(paused ? Icons.play_arrow : Icons.pause),
                            title: Text(paused
                                ? locals.resumeDownload
                                : locals.pauseDownload),
                            subtitle: waitUntil == null
                                ? null
                                : Text(locals.downloadResumeAfter(waitUntil)),
                            onTap: waitUntil == null
                                ? () {
                                    Navigator.of(ctx).pop();
                                    if (paused) {
                                      cubit.retryDownload(video);
                                    } else {
                                      cubit.pauseDownload(video);
                                    }
                                  }
                                : null,
                          ));
                }),
          if (video.downloadFailed || video.authenticationRequired)
            ListTile(
              leading: const Icon(Icons.refresh),
              title: Text(locals.retry),
              subtitle: video.authenticationRequired
                  ? Text(locals.downloadSignInRequired)
                  : null,
              onTap: () {
                Navigator.of(ctx).pop();
                cubit.retryDownload(video);
              },
            ),
          if (_canExportMusic(video))
            BlocProvider.value(
              value: cubit,
              child: MusicDownloadExportAction(video: video),
            )
          else if (video.downloadComplete && video.storageUri == null)
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(locals.copyToDownloadFolder),
              onTap: () async {
                Navigator.of(ctx).pop();
                await cubit.copyToDownloadFolder(video);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(locals.fileCopiedToDownloadFolder)));
                }
              },
            ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(locals.delete),
            onTap: () async {
              Navigator.of(ctx).pop();
              final bool removed;
              try {
                removed = await cubit.deleteVideo(video);
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(locals.downloadFolderError)));
                }
                return;
              }
              if (context.mounted && removed) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(locals.videoDeleted)));
              } else if (context.mounted &&
                  video.audioOnly &&
                  cubit.isMusicDownloadRequiredByPlaylist(video.videoId)) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(locals.musicDownloadHeldByPlaylist)));
              }
            },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final cubit = context.watch<DownloadManagerCubit>();
    final state = cubit.state;
    final progress = state.downloadProgresses[video.videoId];
    final paused = state.pausedVideoIds.contains(video.videoId);
    final waitingForWifi = state.waitingForWifiFor(video);
    final pending = !video.downloadComplete && !video.downloadFailed;
    Widget label(String text) =>
        Text(text, style: Theme.of(context).textTheme.bodySmall);
    Widget? status;
    if (video.authenticationRequired) {
      status = label(locals.downloadSignInRequired);
    } else if (video.storageFailed) {
      status = label(locals.downloadFolderError);
    } else if (video.downloadFailed) {
      status = label(locals.videoFailedDownloadRetry);
    } else if (paused) {
      status = DownloadRetryAvailability(
        retryAt: cubit.retryAtFor(video),
        builder: (context, waitUntil) => label(waitUntil == null
            ? locals.downloadPaused
            : locals.downloadResumeAfter(waitUntil)),
      );
    } else if (waitingForWifi) {
      status = label(locals.downloadsWaitingForWifi);
    } else if (progress?.retryAt != null) {
      status = label(locals.downloadRetryWaiting);
    } else if (progress == null) {
      status = label(locals.downloadQueued);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CompactVideo(
          offlineVideo: video,
          onTap: video.downloadComplete
              ? () => context.read<PlayerCubit>().playOfflineVideos([video])
              : () => openVideoSheet(context),
          onLongPress: video.downloadComplete && video.audioOnly
              ? () {
                  final metadata = video.musicMetadata ??
                      MusicMetadata(
                          title: video.title, artist: video.author ?? '');
                  MusicLibraryActions.showSongMenu(
                    context,
                    Video(
                      videoId: video.videoId,
                      title: metadata.title,
                      author: metadata.artist,
                      lengthSeconds: video.lengthSeconds,
                      musicMetadata: metadata,
                      videoThumbnails: metadata.thumbnails,
                    ),
                    downloads: [video],
                    onPlay: () =>
                        context.read<PlayerCubit>().playOfflineVideos([video]),
                  );
                }
              : null,
          trailing: [
            if (video.audioOnly) const Icon(Icons.audiotrack),
            if (pending &&
                progress != null &&
                progress.retryAt == null &&
                !paused &&
                !waitingForWifi)
              SizedBox(
                  width: 20,
                  height: 20,
                  child: MotionLoadingIndicator(
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          value: progress.count == 0
                              ? null
                              : progress.count / progress.total))),
            IconButton(
              tooltip: locals.downloads,
              onPressed: () => openVideoSheet(context),
              icon: const Icon(Icons.more_vert),
            ),
          ],
        ),
        if (!video.downloadComplete && status != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: status,
          ),
      ],
    );
  }
}

class MusicDownloadExportAction extends StatefulWidget {
  const MusicDownloadExportAction({
    super.key,
    required this.video,
    this.compact = false,
  });

  final DownloadedVideo video;
  final bool compact;

  @override
  State<MusicDownloadExportAction> createState() =>
      _MusicDownloadExportActionState();
}

class _MusicDownloadExportActionState extends State<MusicDownloadExportAction> {
  bool _busy = false;

  Future<void> _export() async {
    if (_busy) return;
    final video = widget.video;
    final manager = context.read<DownloadManagerCubit>();
    final locals = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    String? message;
    try {
      if (await manager.exportMusic(video)) {
        message = locals.musicDownloadExported;
      }
    } catch (_) {
      message = locals.musicDownloadExportFailed;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted ||
        widget.video.videoId != video.videoId ||
        widget.video.profileId != video.profileId) {
      return;
    }
    if (!widget.compact && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop();
    }
    if (message != null) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    if (!_canExportMusic(video)) {
      return const SizedBox.shrink();
    }
    final label = AppLocalizations.of(context)!.exportMusicDownload;
    final key = ValueKey('export-music-${video.videoId}');
    final icon = _busy
        ? const SizedBox.square(
            dimension: 20,
            child: MotionLoadingIndicator(
                child: CircularProgressIndicator(strokeWidth: 2)))
        : const Icon(Icons.file_copy_outlined);
    return widget.compact
        ? IconButton(
            key: key,
            tooltip: label,
            icon: icon,
            onPressed: _busy ? null : _export)
        : ListTile(
            key: key,
            leading: icon,
            title: Text(label),
            enabled: !_busy,
            onTap: _busy ? null : _export);
  }
}
