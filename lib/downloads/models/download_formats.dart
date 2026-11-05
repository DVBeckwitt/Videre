import 'package:clipious/player/models/video_quality.dart';
import 'package:clipious/videos/models/adaptive_format.dart';

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

  DownloadFormats(List<AdaptiveFormat>? formats)
      : _formats = formats ?? const [] {
    for (final format in _formats) {
      final container = DownloadContainer.forAudio(format);
      if (container == null) continue;
      final current = _audio[container];
      if (current == null || _bitrate(format) > _bitrate(current)) {
        _audio[container] = format;
      }
    }
  }

  DownloadContainer? get audioContainer =>
      DownloadContainer.values.where(_audio.containsKey).firstOrNull;

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
