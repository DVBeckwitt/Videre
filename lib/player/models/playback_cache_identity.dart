import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../network/youtube_privacy.dart';
import '../../network/gateway_context.dart';
import '../../settings/models/db/server.dart';
import '../../videos/models/adaptive_format.dart';
import '../../videos/models/video.dart';
import '../media_source.dart';

/// Transient source metadata for the native playback cache, never HTTP headers.
///
/// Only native hashed keys may be persisted. Resource URLs retain their exact
/// signed spelling for matching the admitted media, and must not be stored in
/// the cache index. Missing immutable byte identity deliberately prevents reuse
/// across sessions, even when the content ID or format appears unchanged.
Map<String, Object?>? playbackCacheIdentity({
  required Video video,
  required Server server,
  required String sourceUrl,
  required String sessionId,
  bool mediaCompanions = false,
  AdaptiveFormat? progressiveMusicAudio,
}) {
  final serverUrl = parseMediaUrl(server.url);
  final admittedSource = mediaCompanions
      ? validatedPlaybackMediaUrl(sourceUrl, server)
      : validatedMediaUrl(sourceUrl, server);
  if (video.liveNow == true ||
      video.videoId.isEmpty ||
      video.videoId.length > 4096 ||
      sessionId.isEmpty ||
      sessionId.length > 4096 ||
      server.profileId.isEmpty ||
      server.profileId.length > 4096 ||
      server.accountId.isEmpty ||
      server.accountId.length > 4096 ||
      serverUrl == null ||
      admittedSource == null ||
      admittedSource.length > 32768 ||
      isOfficialYoutubeUrl(Uri.parse(serverUrl))) {
    return null;
  }

  String? admit(String? candidate, {bool adaptive = false}) {
    final parsed = parseMediaUrl(candidate);
    return parsed == null
        ? null
        : validatedMediaUrl(
            proxyMediaUrl(parsed, server, adaptive: adaptive), server);
  }

  final manifests = {
    if (video.dashUrl != null) admit(video.dashUrl, adaptive: true),
    if (video.hlsUrl != null) admit(video.hlsUrl, adaptive: true),
  }..remove(null);
  final resources = <String, Map<String, Object?>>{};

  Map<String, Object?> sessionResource(String url) => {
        'url': url,
        'key': jsonEncode(['session', sessionId, _digest(url)]),
        'persistent': false,
        'manifest': manifests.contains(url) || _isManifestUrl(url),
      };

  void add(String? url, String? representation) {
    // Reserve one entry for the selected source. A large remote format list
    // cannot exceed the native DTO's bounded resource table.
    if (url == null ||
        url.length > 32768 ||
        (resources.length >= 511 && !resources.containsKey(url))) {
      return;
    }
    final fallback = sessionResource(url);
    final resource = representation == null || fallback['manifest'] == true
        ? fallback
        : <String, Object?>{
            'url': url,
            'key': representation,
            'persistent': true,
            'manifest': false,
          };
    final previous = resources[url];
    // A URL described as two incompatible representations cannot safely inherit
    // either persistent identity. Exact session URL identity remains usable.
    resources[url] = previous != null && previous['key'] != resource['key']
        ? fallback
        : resource;
  }

  for (final format in video.adaptiveFormats ?? const []) {
    final url = admit(format.url);
    if (url == null) continue;
    add(
        url,
        _representationKey(
            url: url,
            itag: format.itag,
            clen: format.clen,
            lmt: format.lmt,
            type: format.type,
            audioTrack: format.audioTrack?.id));
  }
  for (final format in video.formatStreams ?? const []) {
    final url = admit(format.url);
    if (url == null) continue;
    final query = _query(url) ?? const <String, List<String>>{};
    add(
        url,
        _representationKey(
            url: url,
            itag: format.itag,
            clen: _single(query, 'clen'),
            lmt: _single(query, 'lmt'),
            type: format.type,
            audioTrack: format.audioTrack?.id));
  }
  resources.putIfAbsent(admittedSource, () => sessionResource(admittedSource));

  final music = video.musicMetadata;
  final seconds = video.lengthSeconds;
  final byteLength = int.tryParse(progressiveMusicAudio?.clen ?? '');
  final mime = progressiveMusicAudio?.type.split(';').first.trim();
  final musicSong = !mediaCompanions &&
          video.isUpcoming != true &&
          RegExp(r'^[a-zA-Z0-9_-]{1,128}$').stringMatch(video.videoId) ==
              video.videoId &&
          music != null &&
          music.title.trim().isNotEmpty &&
          seconds != null &&
          seconds > 0 &&
          byteLength != null &&
          byteLength > 0 &&
          (mime == 'audio/mp4' || mime == 'audio/webm') &&
          progressiveMusicAudio != null &&
          admit(progressiveMusicAudio.url) == admittedSource &&
          resources[admittedSource]?['persistent'] == true
      ? {
          'title': music.title,
          'artist': music.artist,
          'lengthSeconds': seconds,
          'byteLength': byteLength,
        }
      : null;

  return {
    'version': 1,
    'profileId': server.profileId,
    'accountId': server.accountId,
    'origin': Uri.parse(serverUrl).origin,
    'contentId': video.videoId,
    'sessionId': sessionId,
    // Unknown adaptive children are cacheable only with explicit VOD metadata.
    // A missing live flag is not evidence that a dynamic manifest is static.
    'adaptiveVod': video.liveNow == false,
    if (musicSong != null) 'musicSong': musicSong,
    if (GatewayRequestContext.forAccount(
            server.profileId, server.accountId, server.url)
        case final context?)
      'gatewayContext': context.encoded,
    'resources': [
      resources[admittedSource]!,
      ...resources.entries
          .where((entry) => entry.key != admittedSource)
          .take(511)
          .map((entry) => entry.value)
    ],
  };
}

String? _representationKey({
  required String url,
  required String itag,
  required String? clen,
  required String? lmt,
  required String type,
  String? audioTrack,
}) {
  final format = _positiveInteger(itag);
  final length = _positiveInteger(clen);
  final modified = _positiveInteger(lmt);
  if (format == null ||
      length == null ||
      modified == null ||
      type.isEmpty ||
      type.length > 256) {
    return null;
  }
  final query = _query(url);
  if (query == null) return null;
  // A partial URL has a different byte-zero from the complete representation.
  // Treat it conservatively until a segment-aware identity is explicitly given.
  if (query.keys.any((name) => const {
        'range',
        'sq',
        'segment',
        'segment_index',
        'start',
        'end',
      }.contains(name.toLowerCase()))) {
    return null;
  }
  for (final field in [
    ('itag', format),
    ('clen', length),
    ('lmt', modified),
  ]) {
    if (query.containsKey(field.$1) &&
        _positiveInteger(_single(query, field.$1)) != field.$2) {
      return null;
    }
  }
  // Language/track dimensions can appear in an Invidious URL even when its
  // parsed metadata omitted audioTrack. Hash only these known dimensions, never
  // a signature or arbitrary query, into the immutable representation identity.
  final trackDimensions = <String, List<String>>{};
  for (final name in const [
    'audio_track_id',
    'audioTrackId',
    'lang',
    'language',
    'track',
    'track_id',
    'xtags',
  ]) {
    final values = query[name];
    if (values != null) trackDimensions[name] = values;
  }
  return jsonEncode([
    'representation',
    format,
    length,
    modified,
    _digest(type),
    audioTrack == null ? null : _digest(audioTrack),
    _digest(jsonEncode(trackDimensions)),
  ]);
}

String? _single(Map<String, List<String>> query, String name) {
  final values = query[name];
  return values?.length == 1 ? values!.single : null;
}

Map<String, List<String>>? _query(String value) {
  try {
    return Uri.parse(value).queryParametersAll;
  } on FormatException {
    return null;
  }
}

String? _positiveInteger(String? value) {
  if (value == null || !RegExp(r'^[0-9]{1,19}$').hasMatch(value)) return null;
  final number = int.tryParse(value);
  return number != null && number > 0 ? number.toString() : null;
}

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

bool _isManifestUrl(String value) {
  final path = Uri.parse(value).path.toLowerCase();
  return path.contains('/api/manifest/') ||
      path.endsWith('.mpd') ||
      path.endsWith('.m3u') ||
      path.endsWith('.m3u8');
}
