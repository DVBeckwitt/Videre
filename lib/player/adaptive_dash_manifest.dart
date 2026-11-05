import 'dart:convert';

import '../videos/models/adaptive_format.dart';

final _mediaType = RegExp(
    r'^(video/mp4|video/webm|audio/mp4|audio/webm);\s*codecs="([a-zA-Z0-9.]+)"$');
final _byteRange = RegExp(r'^(\d+)-(\d+)$');
final _videoSize = RegExp(r'^(\d+)x(\d+)$');
const _escape = HtmlEscape(HtmlEscapeMode.element);

({int start, int end})? _parseRange(String? value) {
  final match = value == null ? null : _byteRange.firstMatch(value);
  if (match == null) return null;
  final start = int.tryParse(match[1]!);
  final end = int.tryParse(match[2]!);
  return start != null && end != null && end >= start
      ? (start: start, end: end)
      : null;
}

/// Builds a VOD manifest from the byte ranges of the instance's adaptive tracks.
/// [resolveMediaUrl] applies the same URL and proxy policy as ordinary playback.
String? buildAdaptiveDashManifest({
  required Iterable<AdaptiveFormat> formats,
  required Duration duration,
  required String? Function(String) resolveMediaUrl,
}) {
  if (duration <= Duration.zero) return null;

  final groups = <(String mime, String codecFamily), List<String>>{};
  final itags = <int>{};
  for (final format in formats) {
    final type = _mediaType.firstMatch(format.type.trim());
    final itag = int.tryParse(format.itag);
    final bitrate = int.tryParse(format.bitrate ?? '');
    final length = int.tryParse(format.clen);
    final init = _parseRange(format.init);
    final index = _parseRange(format.index);
    if (type == null ||
        itag == null ||
        itag <= 0 ||
        itags.contains(itag) ||
        bitrate == null ||
        bitrate <= 0 ||
        bitrate > 0x7fffffff ||
        length == null ||
        init == null ||
        index == null ||
        init.start != 0 ||
        init.end >= index.start ||
        index.end >= length) {
      continue;
    }

    final mime = type[1]!;
    final codec = type[2]!;
    final codecFamily = codec.split('.').first.toLowerCase();
    final family = switch ((mime, codecFamily)) {
      ('video/mp4', 'avc1' || 'avc3' || 'av01') => codecFamily,
      ('video/webm', 'vp8' || 'vp9' || 'vp09') =>
        codecFamily == 'vp09' ? 'vp9' : codecFamily,
      ('audio/mp4', 'mp4a') || ('audio/webm', 'opus' || 'vorbis') => codec,
      _ => null,
    };
    if (family == null) continue;

    var dimensions = '';
    if (mime.startsWith('video/')) {
      final size = _videoSize.firstMatch(format.size ?? '');
      final width = int.tryParse(size?[1] ?? '');
      final height = int.tryParse(size?[2] ?? '');
      if (width == null ||
          height == null ||
          width <= 0 ||
          height <= 0 ||
          width > 16384 ||
          height > 16384) {
        continue;
      }
      dimensions = ' width="$width" height="$height"';
      final fps = format.fps;
      if (fps != null && fps > 0) dimensions += ' frameRate="$fps"';
    }

    final url = resolveMediaUrl(format.url);
    if (url == null) continue;
    itags.add(itag);
    groups.putIfAbsent((mime, family), () => []).add(
        '<Representation id="$itag" bandwidth="$bitrate" codecs="$codec"$dimensions>'
        '<BaseURL>${_escape.convert(url)}</BaseURL>'
        '<SegmentBase indexRange="${index.start}-${index.end}">'
        '<Initialization range="${init.start}-${init.end}"/>'
        '</SegmentBase></Representation>');
  }

  if (!groups.keys.any((group) => group.$1.startsWith('video/')) ||
      !groups.keys.any((group) => group.$1.startsWith('audio/'))) {
    return null;
  }

  final profiles = [
    if (groups.keys.any((group) => group.$1.endsWith('/mp4')))
      'urn:mpeg:dash:profile:isoff-on-demand:2011',
    if (groups.keys.any((group) => group.$1.endsWith('/webm')))
      'urn:webm:dash:profile:webm-on-demand:2012',
  ];
  final durationSeconds = duration.inMilliseconds / 1000;
  final mpd = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>'
      '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static"'
      ' profiles="${profiles.join(',')}" minBufferTime="PT1.5S"'
      ' mediaPresentationDuration="PT${durationSeconds}S">'
      '<Period start="PT0S">');
  var groupId = 0;
  for (final group in groups.entries) {
    mpd.write('<AdaptationSet id="${groupId++}" mimeType="${group.key.$1}">');
    mpd.writeAll(group.value);
    mpd.write('</AdaptationSet>');
  }
  mpd.write('</Period></MPD>');
  return mpd.toString();
}
