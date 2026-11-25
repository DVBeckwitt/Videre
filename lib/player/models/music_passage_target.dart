import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../downloads/models/downloaded_video.dart';
import '../../downloads/services/explicit_music_download.dart';
import '../../videos/models/ided_video.dart';
import '../../videos/models/video.dart';
import 'local_music_playback.dart';
import 'playback_queue.dart';

String _passageId(List<Object?> parts) =>
    sha256.convert(utf8.encode(jsonEncode(parts))).toString();

String musicPassageRecordingId(IdedVideo entry) =>
    isLocalMusicPlaybackId(entry.videoId)
        ? _passageId(['device', localMusicTrackId(entry.videoId)])
        : _passageId(['remote', entry.videoId]);

/// Queue keys can be reused. Include the source and, for queue-specific keys,
/// the originating queue. Persist digests so the saved identity contains no
/// storage URIs or account origins.
String musicPassageOccurrenceId(IdedVideo entry, String? queueScope) {
  final rendition = switch (entry) {
    DownloadedVideo() when isLocalMusicPlaybackId(entry.videoId) => 'device',
    DownloadedVideo() =>
      entry.explicitMusicDownload ?? musicDownloadFingerprint(entry),
    Video() => entry.explicitMusicDownload,
    _ => null,
  };
  return _passageId([
    musicPassageRecordingId(entry),
    playbackQueueId(entry),
    rendition,
    queueScope,
  ]);
}
