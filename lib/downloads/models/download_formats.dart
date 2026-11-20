import 'package:clipious/player/media_source.dart';
import 'package:clipious/player/models/video_quality.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/videos/models/adaptive_format.dart';

/// Stored in the download job's quality field for Music's audio-only action.
const highestAudioDownloadQuality = 'highest-audio';

String? downloadMediaUrl(AdaptiveFormat format, Server server) {
  final parsed = parseMediaUrl(format.url);
  return parsed == null
      ? null
      : validatedMediaUrl(proxyMediaUrl(parsed, server), server);
}

enum DownloadContainer {
  webm,
  mp4;

  String extension(bool audioOnly) => this == mp4 && audioOnly ? 'm4a' : name;

  String mimeType(bool audioOnly) => '${audioOnly ? 'audio' : 'video'}/$name';

  static DownloadContainer? forVideo(AdaptiveFormat format) =>
      switch ((_mimeType(format), format.encoding?.toLowerCase())) {
        ('video/webm', 'vp9') => webm,
        ('video/mp4', 'h264') => mp4,
        _ => null,
      };

  static DownloadContainer? forAudio(AdaptiveFormat format) =>
      switch ((_mimeType(format), format.encoding?.toLowerCase())) {
        ('audio/webm', _) => webm,
        ('audio/mp4', 'aac') => mp4,
        _ => null,
      };

  static String _mimeType(AdaptiveFormat format) =>
      format.type.split(';').first.trim().toLowerCase();
}

/// The sheet and worker must agree on pairs that can be muxed with stream copy.
class DownloadFormats {
  final List<AdaptiveFormat> _formats;
  final _audio = <DownloadContainer, AdaptiveFormat>{};

  DownloadFormats(List<AdaptiveFormat>? formats, {String? audioTrackId})
      : _formats = formats ?? const [] {
    final tracks = audioTracks;
    final selected = audioTrackId ??
        (_formats.any((format) =>
                DownloadContainer.forAudio(format) != null &&
                format.audioTrack == null)
            ? null
            : tracks.where((track) => track.audioIsDefault).firstOrNull?.id ??
                tracks.firstOrNull?.id);
    for (final format in _formats) {
      final container = DownloadContainer.forAudio(format);
      if (container == null || format.audioTrack?.id != selected) continue;
      final current = _audio[container];
      if (current == null || _bitrate(format) > _bitrate(current)) {
        _audio[container] = format;
      }
    }
  }

  List<AudioTrack> get audioTracks {
    final tracks = <String, AudioTrack>{};
    for (final format in _formats) {
      final track = format.audioTrack;
      if (DownloadContainer.forAudio(format) != null && track != null) {
        tracks.putIfAbsent(track.id, () => track);
      }
    }
    return tracks.values.toList();
  }

  DownloadContainer? get audioContainer =>
      DownloadContainer.values.where(_audio.containsKey).firstOrNull;

  DownloadContainer? get highestBitrateAudioContainer {
    final available = DownloadContainer.values.where(_audio.containsKey);
    if (available.isEmpty) return null;
    // Keep the existing container preference when the rates are equal or unknown.
    return available.reduce((best, next) =>
        _bitrate(_audio[next]!) > _bitrate(_audio[best]!) ? next : best);
  }

  AdaptiveFormat? audioFor(DownloadContainer? container) => _audio[container];

  List<AdaptiveFormat> videoOptions({DownloadContainer? container}) {
    final byQuality = <String, AdaptiveFormat>{};
    // Keep the existing WebM choice when both containers offer the same label.
    for (final candidate in DownloadContainer.values) {
      if ((container != null && container != candidate) ||
          !_audio.containsKey(candidate)) {
        continue;
      }
      for (final format in _formats) {
        final label = format.qualityLabel;
        if (label != null &&
            label.trim().isNotEmpty &&
            DownloadContainer.forVideo(format) == candidate) {
          byQuality.putIfAbsent(label, () => format);
        }
      }
    }
    return byQuality.values.toList()
      ..sort((a, b) => (_height(a) ?? 0).compareTo(_height(b) ?? 0));
  }

  AdaptiveFormat? videoFor(String quality, {DownloadContainer? container}) {
    final videos = videoOptions(container: container);
    final exact = videos.where((format) => format.qualityLabel == quality);
    if (exact.isNotEmpty) return exact.first;
    final index = preferredVideoQualityIndex(
        videos.map(_height).toList(), videoQualityHeight(quality));
    return index == null ? videos.firstOrNull : videos[index];
  }

  static int? _height(AdaptiveFormat format) =>
      videoQualityHeight(format.qualityLabel!);

  static int _bitrate(AdaptiveFormat format) =>
      int.tryParse(format.bitrate ?? '') ?? 0;
}
