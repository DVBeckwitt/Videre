import 'dart:convert';

import '../../network/youtube_privacy.dart';
import '../../player/media_source.dart';
import '../../player/models/playback_cache_identity.dart';
import '../../player/models/video_quality.dart';
import '../../settings/models/db/server.dart';
import '../../videos/models/adaptive_format.dart';
import '../../videos/models/video.dart';
import 'download_formats.dart';

/// Immutable byte identity of a complete downloaded input rendition.
///
/// Potentially untrusted descriptive and track fields are represented by their
/// hashes, using the same identity and admission policy as the playback cache.
/// Source URLs, signatures, headers and account credentials are never retained.
class RenditionIdentity {
  final String itag;
  final String clen;
  final String lmt;
  final String typeSha256;
  final String? audioTrackSha256;
  final String trackDimensionsSha256;

  const RenditionIdentity._({
    required this.itag,
    required this.clen,
    required this.lmt,
    required this.typeSha256,
    required this.audioTrackSha256,
    required this.trackDimensionsSha256,
  });

  static RenditionIdentity? fromFormat(AdaptiveFormat format, Server server) =>
      _fromSelection(
          Video(videoId: 'download-rendition', adaptiveFormats: [format]),
          format,
          server);

  static RenditionIdentity? _fromSelection(
      Video video, AdaptiveFormat format, Server server) {
    final parsed = parseMediaUrl(format.url);
    if (parsed == null) return null;
    final source = validatedMediaUrl(proxyMediaUrl(parsed, server), server);
    if (source == null) return null;
    final payload = playbackCacheIdentity(
        video: video,
        server: server,
        sourceUrl: source,
        sessionId: 'download-provenance');
    if (payload == null) return null;
    final resources = payload['resources'] as List<Map<String, Object?>>;
    final resource = resources.first;
    if (resource['url'] != source ||
        resource['persistent'] != true ||
        resource['manifest'] != false) {
      return null;
    }
    final fields = jsonDecode(resource['key'] as String);
    if (fields is! List ||
        fields.length != 7 ||
        fields[0] != 'representation') {
      return null;
    }
    return tryFromJson({
      'itag': fields[1],
      'clen': fields[2],
      'lmt': fields[3],
      'typeSha256': fields[4],
      'audioTrackSha256': fields[5],
      'trackDimensionsSha256': fields[6],
    });
  }

  static RenditionIdentity? tryFromJson(Object? value) {
    if (value is! Map || !value.containsKey('audioTrackSha256')) return null;
    final itag = _positiveInteger(value['itag']);
    final clen = _positiveInteger(value['clen']);
    final lmt = _positiveInteger(value['lmt']);
    final type = _digest(value['typeSha256']);
    final track = value['audioTrackSha256'];
    final dimensions = _digest(value['trackDimensionsSha256']);
    if (itag == null ||
        clen == null ||
        lmt == null ||
        type == null ||
        (track != null && _digest(track) == null) ||
        dimensions == null) {
      return null;
    }
    return RenditionIdentity._(
        itag: itag,
        clen: clen,
        lmt: lmt,
        typeSha256: type,
        audioTrackSha256: _digest(track),
        trackDimensionsSha256: dimensions);
  }

  Map<String, Object?> toJson() => {
        'itag': itag,
        'clen': clen,
        'lmt': lmt,
        'typeSha256': typeSha256,
        'audioTrackSha256': audioTrackSha256,
        'trackDimensionsSha256': trackDimensionsSha256,
      };

  bool matchesFormat(AdaptiveFormat format, Server server) =>
      this == fromFormat(format, server);

  @override
  bool operator ==(Object other) =>
      other is RenditionIdentity &&
      itag == other.itag &&
      clen == other.clen &&
      lmt == other.lmt &&
      typeSha256 == other.typeSha256 &&
      audioTrackSha256 == other.audioTrackSha256 &&
      trackDimensionsSha256 == other.trackDimensionsSha256;

  @override
  int get hashCode => Object.hash(
      itag, clen, lmt, typeSha256, audioTrackSha256, trackDimensionsSha256);
}

/// Provenance for reusing an explicitly saved, completed media file.
///
/// The fingerprint describes the final file, after any mux operation. Callers
/// must check the actual output with [matchesOutput] as well as the requested
/// selection with [matchesSelection]. A legacy download without this proof
/// remains an ordinary saved download, but cannot be an automatic cache source.
class DownloadPlaybackProvenance {
  static const version = 1;

  final String profileId;
  final String accountId;
  final String origin;
  final String contentId;
  final bool audioOnly;
  final DownloadContainer container;
  final RenditionIdentity audio;
  final RenditionIdentity? videoFormat;
  final int? videoHeight;
  final bool defaultAudioTrack;
  final int byteLength;
  final String sha256;

  const DownloadPlaybackProvenance._({
    required this.profileId,
    required this.accountId,
    required this.origin,
    required this.contentId,
    required this.audioOnly,
    required this.container,
    required this.audio,
    required this.videoFormat,
    required this.videoHeight,
    required this.defaultAudioTrack,
    required this.byteLength,
    required this.sha256,
  });

  /// Construct only after the selected renditions have been fully downloaded
  /// and the final output has been hashed. Missing proof is a safe null result.
  static DownloadPlaybackProvenance? create({
    required Video video,
    required Server server,
    required bool audioOnly,
    required DownloadContainer container,
    required AdaptiveFormat audio,
    AdaptiveFormat? videoFormat,
    required int byteLength,
    required String sha256,
  }) {
    final origin = _serverOrigin(server);
    final digest = _digest(sha256);
    final height = videoFormat == null
        ? null
        : videoQualityHeight(videoFormat.qualityLabel ?? '');
    if (origin == null ||
        !_validId(server.profileId) ||
        !_validAccountId(server.accountId) ||
        !_validId(video.videoId) ||
        video.liveNow == true ||
        (!audioOnly && (height == null || height <= 0)) ||
        byteLength <= 0 ||
        digest == null ||
        !_validFormatPair(audioOnly, container, audio, videoFormat)) {
      return null;
    }
    final audioIdentity =
        RenditionIdentity._fromSelection(video, audio, server);
    final videoIdentity = videoFormat == null
        ? null
        : RenditionIdentity._fromSelection(video, videoFormat, server);
    // Checking each supplied format as well protects against a stale selection
    // whose URL was reused for changed metadata in the current video response.
    if (audioIdentity == null ||
        !audioIdentity.matchesFormat(audio, server) ||
        (videoFormat != null &&
            (videoIdentity == null ||
                !videoIdentity.matchesFormat(videoFormat, server)))) {
      return null;
    }
    return DownloadPlaybackProvenance._(
        profileId: server.profileId,
        accountId: server.accountId,
        origin: origin,
        contentId: video.videoId,
        audioOnly: audioOnly,
        container: container,
        audio: audioIdentity,
        videoFormat: videoIdentity,
        videoHeight: height,
        defaultAudioTrack: audio.audioTrack?.audioIsDefault ?? true,
        byteLength: byteLength,
        sha256: digest);
  }

  static DownloadPlaybackProvenance? tryFromJson(Object? value) {
    if (value is! Map ||
        value['version'] is! int ||
        value['version'] != version) {
      return null;
    }
    final profile = value['profileId'];
    final account = value['accountId'];
    final origin = value['origin'];
    final content = value['contentId'];
    final audioOnly = value['audioOnly'];
    final container = switch (value['container']) {
      'webm' => DownloadContainer.webm,
      'mp4' => DownloadContainer.mp4,
      _ => null,
    };
    final audio = RenditionIdentity.tryFromJson(value['audio']);
    final video = RenditionIdentity.tryFromJson(value['videoFormat']);
    final height = value['videoHeight'];
    final defaultTrack = value['defaultAudioTrack'];
    final length = value['byteLength'];
    final digest = _digest(value['sha256']);
    if (!_validId(profile) ||
        !_validAccountId(account) ||
        !_validId(content) ||
        origin is! String ||
        _canonicalOrigin(origin) != origin ||
        audioOnly is! bool ||
        container == null ||
        audio == null ||
        (audioOnly ? value['videoFormat'] != null : video == null) ||
        !value.containsKey('videoHeight') ||
        (audioOnly ? height != null : height is! int || height <= 0) ||
        defaultTrack is! bool ||
        length is! int ||
        length <= 0 ||
        digest == null) {
      return null;
    }
    return DownloadPlaybackProvenance._(
        profileId: profile as String,
        accountId: account as String,
        origin: origin,
        contentId: content as String,
        audioOnly: audioOnly,
        container: container,
        audio: audio,
        videoFormat: video,
        videoHeight: height as int?,
        defaultAudioTrack: defaultTrack,
        byteLength: length,
        sha256: digest);
  }

  Map<String, Object?> toJson() => {
        'version': version,
        'profileId': profileId,
        'accountId': accountId,
        'origin': origin,
        'contentId': contentId,
        'audioOnly': audioOnly,
        'container': container.name,
        'audio': audio.toJson(),
        'videoFormat': videoFormat?.toJson(),
        'videoHeight': videoHeight,
        'defaultAudioTrack': defaultAudioTrack,
        'byteLength': byteLength,
        'sha256': sha256,
      };

  static Map<String, Object?>? optionalToJson(
          DownloadPlaybackProvenance? value) =>
      value?.toJson();

  /// Check a saved source before fetching current remote metadata. This proves
  /// the recorded ownership and requested mode/quality; the native reader must
  /// still validate the completed file's fingerprint and current authorization.
  bool matchesScope({
    required Server server,
    required String contentId,
    required bool audioOnly,
    int? preferredQuality,
  }) =>
      profileId == server.profileId &&
      accountId == server.accountId &&
      origin == _serverOrigin(server) &&
      this.contentId == contentId &&
      this.audioOnly == audioOnly &&
      defaultAudioTrack &&
      (audioOnly ||
          preferredQuality == null ||
          preferredQuality <= 0 ||
          videoHeight == preferredQuality);

  bool matchesSelection({
    required Video video,
    required Server server,
    required bool audioOnly,
    required DownloadContainer container,
    required AdaptiveFormat audio,
    AdaptiveFormat? videoFormat,
  }) {
    if (profileId != server.profileId ||
        accountId != server.accountId ||
        origin != _serverOrigin(server) ||
        contentId != video.videoId ||
        this.audioOnly != audioOnly ||
        this.container != container) {
      return false;
    }
    final requested = create(
        video: video,
        server: server,
        audioOnly: audioOnly,
        container: container,
        audio: audio,
        videoFormat: videoFormat,
        byteLength: byteLength,
        sha256: sha256);
    return requested != null &&
        this.audio == requested.audio &&
        this.videoFormat == requested.videoFormat &&
        videoHeight == requested.videoHeight;
  }

  bool matchesOutput({required int byteLength, required String sha256}) =>
      this.byteLength == byteLength && this.sha256 == _digest(sha256);

  @override
  bool operator ==(Object other) =>
      other is DownloadPlaybackProvenance &&
      profileId == other.profileId &&
      accountId == other.accountId &&
      origin == other.origin &&
      contentId == other.contentId &&
      audioOnly == other.audioOnly &&
      container == other.container &&
      audio == other.audio &&
      videoFormat == other.videoFormat &&
      videoHeight == other.videoHeight &&
      defaultAudioTrack == other.defaultAudioTrack &&
      byteLength == other.byteLength &&
      sha256 == other.sha256;

  @override
  int get hashCode => Object.hash(
      profileId,
      accountId,
      origin,
      contentId,
      audioOnly,
      container,
      audio,
      videoFormat,
      videoHeight,
      defaultAudioTrack,
      byteLength,
      sha256);
}

bool _validFormatPair(bool audioOnly, DownloadContainer container,
        AdaptiveFormat audio, AdaptiveFormat? video) =>
    DownloadContainer.forAudio(audio) == container &&
    (audioOnly
        ? video == null
        : video != null && DownloadContainer.forVideo(video) == container);

bool _validId(Object? value) =>
    value is String && value.trim().isNotEmpty && value.length <= 4096;

bool _validAccountId(Object? value) {
  if (!_validId(value)) return false;
  final uri = Uri.tryParse(value as String);
  // Older account IDs are endpoint URLs. Keep those stable, but never retain a
  // credential-bearing URL as an identity if an old account has such a value.
  return uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      (uri.userInfo.isEmpty && !uri.hasQuery && !uri.hasFragment);
}

String? _positiveInteger(Object? value) {
  if (value is! String || !RegExp(r'^[0-9]{1,19}$').hasMatch(value)) {
    return null;
  }
  final number = int.tryParse(value);
  return number != null && number > 0 ? number.toString() : null;
}

String? _digest(Object? value) =>
    value is String && RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(value)
        ? value.toLowerCase()
        : null;

String? _serverOrigin(Server server) {
  final parsed = parseMediaUrl(server.url);
  return parsed == null ? null : _canonicalOrigin(Uri.parse(parsed).origin);
}

String? _canonicalOrigin(String value) {
  final parsed = parseMediaUrl(value);
  if (parsed == null) return null;
  final uri = Uri.parse(parsed);
  return isOfficialYoutubeUrl(uri) ? null : uri.origin;
}
