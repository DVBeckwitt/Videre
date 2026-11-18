import 'dart:io';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Artwork for the mounted Music source across mini and expanded playback.
class MusicPlaybackArtwork extends StatelessWidget {
  final MusicMetadata? music;
  final Video? video;
  final DownloadedVideo? offline;
  final bool showPlaceholder;
  final double placeholderSize;
  final Widget? placeholder;

  const MusicPlaybackArtwork(
      {super.key,
      required this.music,
      this.video,
      this.offline,
      this.showPlaceholder = true,
      this.placeholderSize = 72,
      this.placeholder});

  DownloadedVideo? _automaticDownload(BuildContext context) {
    final source = video;
    if (source == null || !source.downloadPlaybackOnly) return null;
    final session = context.watch<AppCubit>().state;
    final selected = session.server;
    final owner = db;
    if (selected == null ||
        session.globalLoading ||
        session.sessionRecoveryRequired ||
        session.profileId != owner.profileId ||
        selected.profileId != session.profileId ||
        source.playbackConnection?.matches(selected) != true) {
      return null;
    }
    try {
      final saved = owner
          .forProfile(session.profileId)
          .getDownloadByVideoId(source.videoId);
      if (saved == null ||
          !saved.downloadComplete ||
          saved.downloadFailed ||
          saved.storageFailed ||
          saved.authenticationRequired ||
          !saved.audioOnly ||
          saved.profileId != session.profileId ||
          saved.accountId != selected.accountId ||
          saved.playbackProvenance?.matchesScope(
                  server: selected,
                  contentId: source.videoId,
                  audioOnly: true) !=
              true) {
        return null;
      }
      return saved;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget placeholder = this.placeholder ??
        (showPlaceholder
            ? ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Center(
                    child: Icon(Icons.music_note, size: placeholderSize)),
              )
            : const SizedBox.expand());
    final images = music?.thumbnails.isNotEmpty == true
        ? music!.thumbnails
        : video?.videoThumbnails ?? [];
    final fallback = offline != null || images.isEmpty
        ? placeholder
        : Thumbnail(
            images: images,
            fallback: placeholder,
            decoration: const BoxDecoration());
    final downloaded = offline ?? _automaticDownload(context);
    return downloaded == null
        ? fallback
        : _MusicDownloadArtwork(
            key: ValueKey((
              downloaded.profileId,
              downloaded.accountId,
              downloaded.videoId
            )),
            download: downloaded,
            placeholder: placeholder,
            fallback: fallback);
  }
}

class _MusicDownloadArtwork extends StatefulWidget {
  final DownloadedVideo download;
  final Widget placeholder;
  final Widget fallback;

  const _MusicDownloadArtwork(
      {super.key,
      required this.download,
      required this.placeholder,
      required this.fallback});

  @override
  State<_MusicDownloadArtwork> createState() => _MusicDownloadArtworkState();
}

class _MusicDownloadArtworkState extends State<_MusicDownloadArtwork> {
  late final _path = widget.download.thumbnailPath;

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
      future: _path,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return widget.placeholder;
        }
        final path = snapshot.data;
        return path == null
            ? widget.fallback
            : Image.file(File(path),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) => widget.fallback);
      });
}
