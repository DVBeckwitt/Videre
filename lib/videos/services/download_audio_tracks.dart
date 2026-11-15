import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../../player/dash_manifest_resolver.dart';
import '../../player/media_source.dart';
import '../../settings/models/db/server.dart';
import '../models/adaptive_format.dart';
import '../models/video.dart';

/// Invidious can expose alternate languages only in its DASH manifest.
/// Keep manifest discovery on the download's account and selected media origin.
Future<Video> loadDownloadAudioTracks(Video video, Server server,
    {required http.Client client}) async {
  final raw = parseMediaUrl(video.dashUrl);
  if (raw == null || video.liveNow == true) return video;
  final url =
      validatedMediaUrl(proxyMediaUrl(raw, server, adaptive: true), server);
  if (url == null) return video;
  String? body;
  final resolved = await DashManifestResolver(client).resolve(
      url, video.videoId, server,
      requireManifest: true, onManifest: (content) => body = content);
  if (body == null || resolved == null) return video;
  final tracks = downloadAudioTracksFromManifest(body!, resolved, server);
  return tracks.isEmpty
      ? video
      : video.copyWith(adaptiveFormats: [...?video.adaptiveFormats, ...tracks]);
}

XmlElement? _child(XmlElement element, String name) => element.childElements
    .where((child) => child.name.local == name)
    .firstOrNull;

Uri? _resolveBase(Uri? parent, String? relative) {
  if (relative == null || relative.isEmpty) return parent;
  final parsed = Uri.tryParse(relative);
  return parsed == null ? null : parent?.resolveUri(parsed);
}

/// Only complete-file VOD representations can feed the resumable downloader.
/// Segmented/live manifests remain the player's responsibility.
List<AdaptiveFormat> downloadAudioTracksFromManifest(
    String content, String manifestUrl, Server server) {
  final XmlElement root;
  try {
    root = XmlDocument.parse(content).rootElement;
  } on XmlException {
    return [];
  }
  if (root.name.local != 'MPD' || root.getAttribute('type') != 'static') {
    return [];
  }
  final periods =
      root.childElements.where((child) => child.name.local == 'Period');
  if (periods.length != 1) return [];
  final formats = <AdaptiveFormat>[];
  final seen = <(String, String)>{};
  for (final adaptation in periods.single.childElements
      .where((child) => child.name.local == 'AdaptationSet')) {
    for (final representation in adaptation.childElements
        .where((child) => child.name.local == 'Representation')) {
      final mime = representation.getAttribute('mimeType') ??
          adaptation.getAttribute('mimeType');
      final codec = representation.getAttribute('codecs') ??
          adaptation.getAttribute('codecs');
      final encoding = switch ((mime, codec?.split('.').first)) {
        ('audio/mp4', 'mp4a') => 'aac',
        ('audio/webm', 'opus') => 'opus',
        ('audio/webm', 'vorbis') => 'vorbis',
        _ => null,
      };
      final base = _child(representation, 'BaseURL')?.innerText.trim();
      final segment = _child(representation, 'SegmentBase') ??
          _child(adaptation, 'SegmentBase');
      final itag = representation.getAttribute('id');
      if (encoding == null ||
          base == null ||
          base.isEmpty ||
          segment == null ||
          itag == null ||
          _child(representation, 'SegmentTemplate') != null ||
          _child(adaptation, 'SegmentTemplate') != null ||
          _child(representation, 'SegmentList') != null ||
          _child(adaptation, 'SegmentList') != null) {
        continue;
      }
      var parentUrl = Uri.tryParse(manifestUrl);
      for (final parent in [root, periods.single, adaptation]) {
        final inherited = _child(parent, 'BaseURL')?.innerText.trim();
        parentUrl = _resolveBase(parentUrl, inherited);
      }
      final absolute = _resolveBase(parentUrl, base)?.toString();
      final parsed = parseMediaUrl(absolute);
      if (parsed == null) continue;
      final url = validatedMediaUrl(proxyMediaUrl(parsed, server), server);
      if (url == null) continue;
      final language = representation.getAttribute('lang') ??
          adaptation.getAttribute('lang') ??
          'und';
      final role = _child(adaptation, 'Role')?.getAttribute('value') ?? '';
      final label = (adaptation.getAttribute('label') ??
              _child(adaptation, 'Label')?.innerText ??
              language)
          .replaceFirst(RegExp(r'\s*\[\d+(?:\.\d+)?k\]\s*$'), '')
          .trim();
      // Adaptation IDs and signatures can change on every metadata refresh.
      final id = 'dash:${Uri.encodeComponent(language)}:'
          '${Uri.encodeComponent(role)}:${Uri.encodeComponent(label)}';
      if (!seen.add((id, itag))) continue;
      final query = Uri.parse(url).queryParameters;
      formats.add(AdaptiveFormat(
          segment.getAttribute('indexRange'),
          representation.getAttribute('bandwidth'),
          _child(segment, 'Initialization')?.getAttribute('range'),
          url,
          itag,
          '$mime; codecs="$codec"',
          query['clen'] ?? '',
          query['lmt'] ?? '',
          'RECTANGULAR',
          mime == 'audio/mp4' ? 'mp4' : 'webm',
          encoding,
          null,
          null,
          audioTrack: AudioTrack(
              id: id,
              displayName: label.isEmpty ? language : label,
              audioIsDefault: role == 'main')));
    }
  }
  return formats;
}
