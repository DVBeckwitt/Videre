import 'package:clipious/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/player/states/player.dart';

import '../../../videos/views/components/compact_video.dart';

class DownloadedVideoView extends StatelessWidget {
  final DownloadedVideo video;

  const DownloadedVideoView({super.key, required this.video});

  void openVideoSheet(BuildContext context) {
    final cubit = context.read<DownloadManagerCubit>();
    final locals = AppLocalizations.of(context)!;
    final paused = cubit.state.pausedVideoIds.contains(video.videoId);
    showSafeModalBottomSheet<void>(
      enableDrag: true,
      showDragHandle: true,
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (!video.downloadComplete && !video.downloadFailed)
            ListTile(
              leading: Icon(paused ? Icons.play_arrow : Icons.pause),
              title:
                  Text(paused ? locals.resumeDownload : locals.pauseDownload),
              onTap: () {
                Navigator.of(ctx).pop();
                if (paused) {
                  cubit.retryDownload(video);
                } else {
                  cubit.pauseDownload(video);
                }
              },
            ),
          if (video.downloadFailed)
            ListTile(
              leading: const Icon(Icons.refresh),
              title: Text(locals.retry),
              onTap: () {
                Navigator.of(ctx).pop();
                cubit.retryDownload(video);
              },
            ),
          if (video.downloadComplete)
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
              await cubit.deleteVideo(video);
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(locals.videoDeleted)));
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
    final state = context.watch<DownloadManagerCubit>().state;
    final progress = state.downloadProgresses[video.videoId];
    final paused = state.pausedVideoIds.contains(video.videoId);
    final pending = !video.downloadComplete && !video.downloadFailed;
    final status = video.downloadFailed
        ? locals.videoFailedDownloadRetry
        : paused
            ? locals.downloadPaused
            : state.waitingForWifi
                ? locals.downloadsWaitingForWifi
                : progress == null
                    ? locals.downloadQueued
                    : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CompactVideo(
          offlineVideo: video,
          onTap: video.downloadComplete
              ? () => context.read<PlayerCubit>().playOfflineVideos([video])
              : () => openVideoSheet(context),
          trailing: [
            if (video.audioOnly) const Icon(Icons.audiotrack),
            if (pending && progress != null && !paused && !state.waitingForWifi)
              SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: progress.count == 0
                          ? null
                          : progress.count / progress.total)),
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
            child: Text(status, style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    );
  }
}
