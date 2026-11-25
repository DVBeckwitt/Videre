import 'dart:io';

import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/download_playback_source.dart';
import 'package:clipious/downloads/services/explicit_music_download.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/music/models/song_artwork.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/views/components/community_music_artwork.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';

import 'device_music_artwork.dart';

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
    final videoId = video?.videoId ?? offline?.videoId;
    final offlineId = offline?.videoId;
    final videoPin = video?.explicitMusicDownload;
    final fingerprint = videoPin ?? offline?.explicitMusicDownload;
    if (fingerprint != null) {
      final id = videoPin != null ? video!.videoId : offline!.videoId;
      final download = readyMusicDownload(db, id, fingerprint: fingerprint);
      return download == null
          ? placeholder
          : _LocalSongCover(
              key: ValueKey(download),
              download: download,
              placeholder: placeholder);
    }
    final deviceId = isLocalMusicPlaybackId(offlineId) ? offlineId : videoId;
    if (isLocalMusicPlaybackId(deviceId)) {
      return ListenableBuilder(
          listenable: LocalMusicLibrary.instance,
          builder: (context, _) {
            final track = localMusicTrackForPlayback(deviceId);
            return track == null
                ? placeholder
                : DeviceMusicArtwork(track: track, placeholder: placeholder);
          });
    }
    final local = offline != null || video?.downloadPlaybackOnly == true;
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
              musicArtwork: true,
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
          return file == null
              ? widget.placeholder
              : _fileArtwork(file, widget.placeholder);
        });
  }
}

Widget _fileArtwork(File file, Widget placeholder) => Image.file(file,
    fit: BoxFit.cover,
    frameBuilder: (context, child, frame, synchronous) =>
        synchronous || frame != null ? child : placeholder,
    errorBuilder: (context, error, stack) => placeholder);
