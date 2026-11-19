import 'package:river_player/river_player.dart';

import '../../player/media_source.dart';
import '../../player/models/video_quality.dart';
import '../../videos/models/video.dart';

bool hasMusicVideoSource(Video video) => musicVideoSources(video).isNotEmpty;

/// Only consider sources admitted by the connection which supplied this video.
/// Prefer one video-only rendition sized for the artwork slot. DASH can also
/// omit the audio adaptation set when the native renderer is in video-only mode.
List<DataSource> musicVideoSources(Video video) {
  final connection = video.backendPlayback ?? video.playbackConnection;
  if (connection == null || video.downloadPlaybackOnly) return [];
  final server = connection.server;
  final sources = <DataSource>[];
  final seen = <String>{};

  String? routed(String? raw, {bool manifest = false}) {
    final url = parseMediaUrl(raw);
    return url == null
        ? null
        : validatedMediaUrl(
            proxyMediaUrl(url, server, adaptive: manifest), server);
  }

  void add(String? url, VideoFormat format) {
    if (url == null || !seen.add(url)) return;
    sources.add(DataSource(
      sourceType: DataSourceType.network,
      uri: url,
      formatHint: format,
      videoOnly: true,
      headers: mediaHeaders(server, url),
    ));
  }

  final adaptive = [
    for (final track in video.adaptiveFormats ?? [])
      if (track.type.toLowerCase().startsWith('video/'))
        if (routed(track.url) case final String url)
          (
            url: url,
            mp4: track.type.toLowerCase().startsWith('video/mp4'),
            height: videoQualityHeight(
                track.qualityLabel ?? track.resolution ?? ''),
          ),
  ];
  final mp4 = adaptive.where((track) => track.mp4).toList();
  final candidates = mp4.isEmpty ? adaptive : mp4;
  if (candidates.isNotEmpty) {
    final index = preferredVideoQualityIndex(
        candidates.map((track) => track.height).toList(), 720);
    add(candidates[index ?? 0].url, VideoFormat.other);
  }
  add(routed(video.dashUrl, manifest: true), VideoFormat.dash);
  for (final stream in video.formatStreams ?? []) {
    if (stream.isLegacyHd720 ||
        !stream.type.toLowerCase().startsWith('video/')) {
      continue;
    }
    final url = routed(stream.url);
    if (url != null && !seen.contains(url)) {
      add(url, VideoFormat.other);
      break;
    }
  }
  add(routed(video.hlsUrl, manifest: true), VideoFormat.hls);
  return sources;
}
