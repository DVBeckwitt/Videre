import '../../../downloads/models/downloaded_video.dart';
import '../../../downloads/services/explicit_music_download.dart';
import '../../../downloads/states/download_manager.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/motion.dart';
import '../../../videos/models/video.dart';
import 'package:flutter/material.dart';

Video musicDownloadSelectionEntry(DownloadedVideo file, {String? fingerprint}) {
  final song = file.musicMetadata!;
  return Video(
    videoId: file.videoId,
    title: song.title,
    author: song.artist,
    lengthSeconds: file.lengthSeconds,
    musicMetadata: song,
    videoThumbnails: song.thumbnails,
    explicitMusicDownload: fingerprint ?? musicDownloadFingerprint(file),
  );
}

/// Confirms the current job incarnations and leaves playlist-kept files alone.
Future<int?> confirmMusicDownloadRemoval(
  BuildContext context,
  DownloadManagerCubit manager,
  List<DownloadedVideo> downloads, {
  required bool Function() isCurrent,
  Future<bool> Function(List<DownloadedVideo>)? revalidate,
}) async {
  if (downloads.isEmpty || !isCurrent()) return null;
  final locals = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);
  final removable = downloads
      .where((file) => !manager.isMusicDownloadRequiredByPlaylist(file.videoId))
      .toList();
  if (removable.isEmpty) {
    messenger.showSnackBar(
        SnackBar(content: Text(locals.musicDownloadHeldByPlaylist)));
    return 0;
  }

  final approval = manager.captureMusicDeletion(removable);
  final confirmed = await showDialog<bool>(
    context: context,
    useRootNavigator: false,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (context) => AlertDialog(
      title: Text(locals.musicRemoveSelectedDownloadsConfirm(removable.length)),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(locals.cancel)),
        TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(locals.musicRemoveSelectedDownloads)),
      ],
    ),
  );
  if (confirmed != true || !context.mounted || !isCurrent()) return null;

  final verified = await revalidate?.call(removable);
  if (!context.mounted || !isCurrent()) return null;
  final removed = verified == false
      ? 0
      : await manager.deleteMusicSelection(approval, isCurrent: isCurrent);
  if (messenger.mounted && isCurrent() && removed < removable.length) {
    messenger
        .showSnackBar(SnackBar(content: Text(locals.musicLibraryActionError)));
  }
  return removed;
}
