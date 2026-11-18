import 'dart:io';

import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/download_playback_source.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/music/models/song_artwork.dart';
import 'package:clipious/music/views/components/community_music_artwork.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';

/// Artwork for the mounted Music source across mini and expanded playback.
class MusicPlaybackArtwork extends StatelessWidget {
  final MusicMetadata? music;
  final Video? video;
  final DownloadedVideo? offline;
  final bool showPlaceholder;
  final bool allowCommunityLookup;
  final double placeholderSize;
  final Widget? placeholder;

  const MusicPlaybackArtwork(
      {super.key,
      required this.music,
      this.video,
      this.offline,
      this.showPlaceholder = true,
      this.allowCommunityLookup = false,
      this.placeholderSize = 72,
      this.placeholder});

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
    final local = offline != null || video?.downloadPlaybackOnly == true;
    final videoId = video?.videoId ?? offline?.videoId;
    final Widget stock;
    if (local) {
      final download = offline ?? admittedMusicDownload(video);
      if (download == null || download.profileId != db.profileId) {
        return placeholder;
      }
      stock = _LocalSongCover(
          key: ValueKey((download, video?.playbackSourceId)),
          download: download,
          placeholder: placeholder);
    } else {
      final images = displaySongThumbnails(videoId ?? '',
          music?.thumbnails ?? const [], video?.videoThumbnails ?? const [],
          artTrack: music?.isArtTrack == true || video?.isStockArtTrack == true,
          instanceUrl: (video?.playbackConnection ?? video?.backendPlayback)
              ?.server
              .url);
      stock = images.isEmpty
          ? placeholder
          : Thumbnail(
              images: images,
              fallback: placeholder,
              decoration: const BoxDecoration());
    }
    return CommunityMusicArtwork(
        videoId: videoId,
        music: music,
        durationSeconds: video?.lengthSeconds ?? offline?.lengthSeconds,
        fallback: stock,
        allowLookup: allowCommunityLookup && !local);
  }
}

class _LocalSongCover extends StatefulWidget {
  const _LocalSongCover(
      {super.key, required this.download, required this.placeholder});

  final DownloadedVideo download;
  final Widget placeholder;

  @override
  State<_LocalSongCover> createState() => _LocalSongCoverState();
}

class _LocalSongCoverState extends State<_LocalSongCover> {
  late final Future<File?> _cover = widget.download.existingSongArtwork;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
        future: _cover,
        builder: (context, snapshot) {
          final file = snapshot.data;
          if (file == null) return widget.placeholder;
          return Image.file(file,
              fit: BoxFit.cover,
              frameBuilder: (context, child, frame, synchronous) =>
                  synchronous || frame != null ? child : widget.placeholder,
              errorBuilder: (context, error, stack) => widget.placeholder);
        });
  }
}
