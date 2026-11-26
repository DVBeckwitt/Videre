import 'dart:convert';

import '../../downloads/models/downloaded_video.dart';
import '../../downloads/services/explicit_music_download.dart';
import '../../music/models/device_playlist_track.dart';
import '../../music/services/cached_music.dart';
import '../../utils/invidious_image.dart';
import '../../utils/models/image_object.dart';
import '../../videos/models/video.dart';
import '../../playlists/models/playlist_reference.dart';
import 'android_music_resumption.dart';
import 'playback_queue.dart';
import 'local_music_playback.dart';

const playbackSessionSetting = 'playback-session';

String? normalizedQueueTitle(Object? value) {
  if (value is! String || value.length > 512) return null;
  final title = value.trim();
  return title.isEmpty || RegExp(r'[\x00-\x1f\x7f]').hasMatch(title)
      ? null
      : title;
}

class PlaybackSession {
  final List<Video> videos;

  /// Ordered queue occurrence IDs. Ordinary downloads use their source ID or
  /// a saved copy key. Device entries retain their independent catalog IDs.
  final List<String> offlineIds;

  /// Only explicit saved-file selections are pinned, by queue occurrence.
  final Map<String, String> offlineFingerprints;
  final String currentId;
  bool get hasDeviceEntries =>
      offlineIds.any(isLocalMusicPlaybackId) ||
      videos.any((video) => isLocalMusicPlaybackId(video.videoId));
  String? get currentDeviceId => isLocalMusicPlaybackId(currentId)
      ? currentId
      : videos
          .where((video) =>
              playbackQueueId(video) == currentId &&
              isLocalMusicPlaybackId(video.videoId))
          .firstOrNull
          ?.videoId;
  Iterable<String> get deviceTrackIds => [
        ...offlineIds.where(isLocalMusicPlaybackId).map(localMusicTrackId),
        for (final video in videos)
          if (isLocalMusicPlaybackId(video.videoId)) video.videoId,
      ];
  String? get currentSavedDownloadId =>
      offlineIds.contains(currentId) ? savedDownloadSourceId(currentId) : null;
  final int seconds;
  final int positionFractionUs;
  final int? positionMilliseconds;
  Duration get position =>
      positionFractionUs == 0 && positionMilliseconds != null
          ? Duration(milliseconds: positionMilliseconds!)
          : Duration(seconds: seconds, microseconds: positionFractionUs);
  final String? namedQueueId;
  final String? ownerProfileId;
  final AndroidMusicResumption? androidResumption;
  final String? localSelectionId;
  final bool audio;

  /// Older sessions only recorded traversal, so their mode is unknown.
  final bool? musicQueueShuffled;

  /// Snapshots predating section history have no origin information.
  final Set<String>? musicHistoryEntries;
  final bool musicHistoryPlaylist;

  /// Opaque playlist source digests by queue occurrence, for taste learning.
  final Map<String, String> musicRecommendationSources;
  final List<String> played;
  final List<String> next;
  final PlaylistReference? playlistReference;
  final List<Video> playlistEntries;
  final bool playlistComplete;
  final String? queueTitle;
  final String? passageQueueId;

  const PlaybackSession({
    this.videos = const [],
    this.offlineIds = const [],
    this.offlineFingerprints = const {},
    required this.currentId,
    required this.seconds,
    this.positionFractionUs = 0,
    this.positionMilliseconds,
    this.namedQueueId,
    this.ownerProfileId,
    this.androidResumption,
    this.localSelectionId,
    this.audio = false,
    this.musicQueueShuffled,
    this.musicHistoryEntries = const {},
    this.musicHistoryPlaylist = false,
    this.musicRecommendationSources = const {},
    this.played = const [],
    this.next = const [],
    this.playlistReference,
    this.playlistEntries = const [],
    this.playlistComplete = false,
    this.queueTitle,
    this.passageQueueId,
  });

  int get _version {
    if (videos.any((video) => CachedMusicPlayback.of(video) != null)) return 5;
    if (offlineFingerprints.isNotEmpty ||
        (offlineIds.any(isLocalMusicPlaybackId) &&
            offlineIds.any((id) => !isLocalMusicPlaybackId(id))) ||
        [...videos, ...playlistEntries]
            .any((v) => devicePlaylistFileProof(v.videoId) != null) ||
        videos.any((v) => v.explicitMusicDownload != null)) {
      return 4;
    }
    return offlineIds.any(_isSavedCopy) ? 3 : 2;
  }

  String encode({
    bool portableArtwork = false,
    AndroidMusicResumption? androidResumption,
  }) {
    final version = _version;
    return jsonEncode({
      'version': version,
      // Stream URLs expire. Save enough to show the queue, then fetch on play.
      'videos': (version >= 4 || portableArtwork
              ? videos.map(_portableArtwork)
              : videos)
          .map((v) => {
                'videoId': v.videoId,
                'title': v.title,
                'author': v.author,
                'lengthSeconds': v.lengthSeconds,
                if (v.queueEntryId != null) 'queueEntryId': v.queueEntryId,
                if (v.explicitMusicDownload != null)
                  'explicitMusicDownload': v.explicitMusicDownload,
                if (CachedMusicPlayback.of(v) case final cache?)
                  'cachedMusic': cache.toJson(),
                if (v.index != null) 'index': v.index,
                if (v.indexId != null) 'indexId': v.indexId,
                if (v.musicMetadata != null)
                  'musicMetadata': v.musicMetadata!.toJson(),
                'videoThumbnails':
                    v.videoThumbnails.map((t) => t.toJson()).toList(),
              })
          .toList(),
      'offlineIds': offlineIds,
      if (offlineFingerprints.isNotEmpty)
        'offlineFingerprints': offlineFingerprints,
      'currentId': currentId,
      'seconds': seconds,
      if (positionFractionUs != 0) 'positionFractionUs': positionFractionUs,
      if (positionMilliseconds != null)
        'positionMilliseconds': positionMilliseconds,
      if (namedQueueId != null) 'namedQueueId': namedQueueId,
      if (ownerProfileId != null) 'ownerProfileId': ownerProfileId,
      if (androidResumption != null)
        'androidResumption': androidResumption.toJson(),
      if (hasDeviceEntries && (version >= 4 || localSelectionId != null))
        'localSelectionId': localSelectionId,
      'audio': audio,
      if (musicQueueShuffled != null) 'musicQueueShuffled': musicQueueShuffled,
      if (musicHistoryEntries != null)
        'musicHistoryEntries': musicHistoryEntries!.toList(),
      if (musicHistoryPlaylist) 'musicHistoryPlaylist': true,
      if (musicRecommendationSources.isNotEmpty)
        'musicRecommendationSources': musicRecommendationSources,
      'played': played,
      'next': next,
      if (queueTitle != null) 'queueTitle': queueTitle,
      if (passageQueueId != null) 'passageQueueId': passageQueueId,
      if (playlistReference != null)
        'playlistReference': playlistReference!.toJson(),
      if (playlistReference != null) 'playlistComplete': playlistComplete,
      if (playlistReference != null)
        'playlistEntries': playlistEntries
            .where((v) =>
                v.explicitMusicDownload == null &&
                CachedMusicPlayback.of(v) == null)
            .map((video) => {
                  'videoId': video.videoId,
                  'queueEntryId': video.queueEntryId,
                  if (video.index != null) 'index': video.index,
                  if (video.indexId != null) 'indexId': video.indexId,
                })
            .toList(),
    });
  }

  static bool _isSavedCopy(String id) =>
      !isLocalMusicPlaybackId(id) && id.contains('#');

  static final _deviceOccurrence =
      RegExp(r'^device:[a-f0-9]{64}(#[1-9][0-9]*)?$');
  static final _selectionId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  static final _control = RegExp(r'[\x00-\x1f\x7f]');

  /// Restore public display images without retaining local file references,
  /// credentials, or expiring query parameters alongside a file fingerprint.
  static Video _portableArtwork(Video video) {
    List<ImageObject> images(List<ImageObject> items) {
      final result = <ImageObject>[];
      for (final image in items) {
        final uri = Uri.tryParse(image.url);
        if (uri == null ||
            uri.userInfo.isNotEmpty ||
            image.url.contains('\\')) {
          continue;
        }
        final remote = (uri.scheme == 'https' || uri.scheme == 'http') &&
            uri.host.isNotEmpty;
        final relative = !uri.hasAuthority &&
            !uri.hasScheme &&
            image.url.startsWith('/') &&
            isInvidiousThumbnailUrl(image.url);
        if (!remote && !relative) continue;
        final url = Uri(
                scheme: remote ? uri.scheme : null,
                host: remote ? uri.host : null,
                port: uri.hasPort ? uri.port : null,
                path: uri.path)
            .toString();
        result.add(ImageObject(image.quality, url, image.width, image.height));
      }
      return result;
    }

    final music = video.musicMetadata;
    return video.copyWith(
        videoThumbnails: images(video.videoThumbnails),
        musicMetadata: music?.withThumbnails(images(music.thumbnails)));
  }

  static bool _validCatalogKey(Video video) {
    final key = playbackQueueId(video);
    final deviceEntry = devicePlaylistFileProof(video.videoId) != null;
    return (DownloadedVideo.isSafeFileId(video.videoId) || deviceEntry) &&
        key.trim().isNotEmpty &&
        !_control.hasMatch(key) &&
        (deviceEntry || !isLocalMusicPlaybackId(key));
  }

  static PlaybackSession? decode(String? value) {
    if (value == null) return null;
    try {
      final json = jsonDecode(value) as Map<String, dynamic>;
      final version = json['version'];
      if (version is! int || version < 1 || version > 5) return null;
      final playlistReference =
          PlaylistReference.tryParse(json['playlistReference']);
      if (json['playlistReference'] != null && playlistReference == null) {
        return null;
      }
      Video decodeVideo(dynamic value, {bool source = false}) {
        final entry = Map<String, dynamic>.from(value);
        final marked = entry.containsKey('explicitMusicDownload');
        final fingerprint = entry['explicitMusicDownload'];
        if (marked &&
            (version < 4 ||
                source ||
                !isValidOfflineMusicFingerprint(fingerprint))) {
          throw const FormatException('Invalid saved Music fingerprint');
        }
        final cache = CachedMusicPlayback.tryParse(entry['cachedMusic']);
        if (entry.containsKey('cachedMusic') &&
            (version != 5 || source || marked || cache == null)) {
          throw const FormatException('Invalid cached Music rendition');
        }
        if (version >= 4) {
          // Playback transports and local file locations are never session data.
          entry.removeWhere((key, _) => !const {
                'videoId',
                'title',
                'author',
                'lengthSeconds',
                'queueEntryId',
                'index',
                'indexId',
                'musicMetadata',
                'videoThumbnails'
              }.contains(key));
        }
        final video = Video.fromJson(entry).copyWith(
            queueEntryId: entry['queueEntryId'] as String?,
            explicitMusicDownload: fingerprint as String?,
            playbackSourceId: cache);
        return version >= 4 ? _portableArtwork(video) : video;
      }

      final videos = (json['videos'] as List).map(decodeVideo).toList();
      final offlineIds = List<String>.from(json['offlineIds']);
      final offlineMembership = offlineIds.toSet();
      final fingerprints = <String, String>{};
      if (json.containsKey('offlineFingerprints')) {
        final stored = json['offlineFingerprints'];
        if (version < 4 || stored is! Map || stored.isEmpty) return null;
        for (final entry in stored.entries) {
          final id = entry.key;
          final digest = entry.value;
          if (id is! String ||
              !offlineMembership.contains(id) ||
              savedDownloadSourceId(id) == null ||
              !isValidOfflineMusicFingerprint(digest)) {
            return null;
          }
          fingerprints[id] = digest as String;
        }
      }
      final playlistEntries = (json['playlistEntries'] as List? ?? [])
          .map((e) => decodeVideo(e, source: true))
          .toList();
      final savedCopies = offlineIds.any(_isSavedCopy);
      final hasDevice = offlineIds.any(isLocalMusicPlaybackId);
      final mixedOffline =
          hasDevice && offlineIds.any((id) => !isLocalMusicPlaybackId(id));
      final hasDeviceVideos =
          videos.any((v) => isLocalMusicPlaybackId(v.videoId));
      final devicePlaylist = [...videos, ...playlistEntries]
          .where((v) => isLocalMusicPlaybackId(v.videoId));
      final marked =
          videos.where((v) => v.explicitMusicDownload != null).toList();
      final cached = videos.where((v) => CachedMusicPlayback.of(v) != null);
      if ((version == 5) != cached.isNotEmpty ||
          cached.any((v) => v.musicMetadata?.title.trim().isNotEmpty != true)) {
        return null;
      }
      final needsVersion4 = mixedOffline ||
          devicePlaylist.isNotEmpty ||
          marked.isNotEmpty ||
          fingerprints.isNotEmpty;
      if (version < 5 && (version == 4) != needsVersion4) return null;
      if (version < 4 && ((version == 3) != savedCopies)) return null;
      if (version == 3 &&
          (playlistReference != null ||
              playlistEntries.isNotEmpty ||
              json['localSelectionId'] != null ||
              offlineMembership.length != offlineIds.length ||
              offlineIds.any((id) => savedDownloadSourceId(id) == null))) {
        return null;
      }
      if (devicePlaylist.any((v) =>
              devicePlaylistFileProof(v.videoId) == null ||
              v.explicitMusicDownload != null) ||
          (hasDeviceVideos && offlineIds.isNotEmpty) ||
          (devicePlaylist.isNotEmpty &&
              playlistReference != null &&
              playlistReference.kind != PlaylistSourceKind.local) ||
          ((hasDevice || fingerprints.isNotEmpty) &&
              (offlineMembership.length != offlineIds.length ||
                  playlistReference != null ||
                  playlistEntries.isNotEmpty))) {
        return null;
      }
      if (version >= 4) {
        final markedIds = marked.map(playbackQueueId).toSet();
        final selection = json['localSelectionId'];
        if (json['audio'] != true ||
            json.containsKey('localSelectionId') !=
                (mixedOffline || hasDeviceVideos) ||
            (selection != null &&
                (selection is! String ||
                    _selectionId.stringMatch(selection) != selection)) ||
            offlineIds.any((id) => isLocalMusicPlaybackId(id)
                ? _deviceOccurrence.stringMatch(id) != id
                : savedDownloadSourceId(id) == null) ||
            ![...videos, ...playlistEntries].every(_validCatalogKey) ||
            videos.map(playbackQueueId).toSet().length != videos.length ||
            playlistEntries.map(playbackQueueId).toSet().length !=
                playlistEntries.length ||
            (playlistReference == null && playlistEntries.isNotEmpty) ||
            playlistEntries
                .any((v) => markedIds.contains(playbackQueueId(v))) ||
            marked.any((v) =>
                v.musicMetadata?.title.trim().isNotEmpty != true ||
                savedDownloadSourceId(playbackQueueId(v)) != v.videoId)) {
          return null;
        }
      }
      final currentId = json['currentId'] as String;
      final seconds = json['seconds'] as int;
      final fraction = json['positionFractionUs'];
      if (json.containsKey('positionFractionUs') &&
          (fraction is! int ||
              fraction <= 0 ||
              fraction >= Duration.microsecondsPerSecond ||
              (!isLocalMusicPlaybackId(currentId) &&
                  !videos.any((video) =>
                      playbackQueueId(video) == currentId &&
                      isLocalMusicPlaybackId(video.videoId))))) {
        return null;
      }
      final milliseconds = json['positionMilliseconds'];
      final namedQueueId = json['namedQueueId'];
      if (seconds < 0 ||
          (videos.isNotEmpty && offlineIds.isNotEmpty) ||
          !(videos.any((v) => playbackQueueId(v) == currentId) ||
              offlineIds.contains(currentId))) {
        return null;
      }
      final ids = {...videos.map(playbackQueueId), ...offlineIds};
      final sources = json['musicRecommendationSources'];
      final musicRecommendationSources = <String, String>{
        if (sources is Map)
          for (final entry in sources.entries)
            if (ids.contains(entry.key) &&
                isValidOfflineMusicFingerprint(entry.value))
              entry.key as String: entry.value as String,
      };
      final played = List<String>.from(json['played'] ?? []);
      final next = List<String>.from(json['next'] ?? []);
      final history = json['musicHistoryEntries'] as List?;
      if ((savedCopies || version >= 4) &&
          (!played.every(ids.contains) ||
              !next.every(ids.contains) ||
              (history != null && !history.every(ids.contains)))) {
        return null;
      }
      return PlaybackSession(
        videos: videos,
        offlineIds: offlineIds,
        offlineFingerprints: fingerprints,
        currentId: currentId,
        seconds: seconds,
        positionFractionUs: fraction as int? ?? 0,
        positionMilliseconds: milliseconds is int &&
                milliseconds >= 0 &&
                milliseconds ~/ 1000 == seconds
            ? milliseconds
            : null,
        namedQueueId: namedQueueId is String &&
                _selectionId.stringMatch(namedQueueId) == namedQueueId
            ? namedQueueId
            : null,
        ownerProfileId: normalizedQueueTitle(json['ownerProfileId']),
        androidResumption: json['audio'] == true
            ? AndroidMusicResumption.tryParse(json['androidResumption'])
            : null,
        localSelectionId: hasDevice || hasDeviceVideos
            ? json['localSelectionId'] as String?
            : null,
        audio: json['audio'] == true,
        musicQueueShuffled: json['musicQueueShuffled'] as bool?,
        musicHistoryEntries:
            history?.whereType<String>().where(ids.contains).toSet(),
        musicHistoryPlaylist: json['musicHistoryPlaylist'] == true,
        musicRecommendationSources: musicRecommendationSources,
        played: played.where(ids.contains).toList(),
        next: next.where(ids.contains).toList(),
        playlistReference: playlistReference,
        playlistComplete: json['playlistComplete'] == true,
        queueTitle: normalizedQueueTitle(json['queueTitle']),
        passageQueueId: _passageQueueId(json['passageQueueId']),
        playlistEntries: playlistEntries,
      );
    } catch (_) {
      // A damaged backup should not prevent the app from opening.
      return null;
    }
  }
}

String? _passageQueueId(Object? value) => value is String &&
        RegExp(
              r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$',
            ).stringMatch(value) ==
            value
    ? value
    : null;
