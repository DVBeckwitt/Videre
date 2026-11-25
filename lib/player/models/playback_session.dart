import 'dart:convert';

import '../../downloads/models/downloaded_video.dart';
import '../../downloads/services/explicit_music_download.dart';
import '../../utils/invidious_image.dart';
import '../../utils/models/image_object.dart';
import '../../videos/models/video.dart';
import '../../playlists/models/playlist_reference.dart';
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
  bool get hasDeviceEntries => offlineIds.any(isLocalMusicPlaybackId);
  String? get currentSavedDownloadId =>
      offlineIds.contains(currentId) ? savedDownloadSourceId(currentId) : null;
  final int seconds;
  final String? localSelectionId;
  final bool audio;

  /// Snapshots predating section history have no origin information.
  final Set<String>? musicHistoryEntries;
  final bool musicHistoryPlaylist;
  final List<String> played;
  final List<String> next;
  final PlaylistReference? playlistReference;
  final List<Video> playlistEntries;
  final bool playlistComplete;
  final String? queueTitle;

  const PlaybackSession({
    this.videos = const [],
    this.offlineIds = const [],
    this.offlineFingerprints = const {},
    required this.currentId,
    required this.seconds,
    this.localSelectionId,
    this.audio = false,
    this.musicHistoryEntries = const {},
    this.musicHistoryPlaylist = false,
    this.played = const [],
    this.next = const [],
    this.playlistReference,
    this.playlistEntries = const [],
    this.playlistComplete = false,
    this.queueTitle,
  });

  int get _version {
    if (offlineFingerprints.isNotEmpty ||
        (hasDeviceEntries &&
            offlineIds.any((id) => !isLocalMusicPlaybackId(id))) ||
        videos.any((v) => v.explicitMusicDownload != null)) {
      return 4;
    }
    return offlineIds.any(_isSavedCopy) ? 3 : 2;
  }

  String encode() {
    final version = _version;
    return jsonEncode({
      'version': version,
      // Stream URLs expire. Save enough to show the queue, then fetch on play.
      'videos': (version == 4 ? videos.map(_portableArtwork) : videos)
          .map((v) => {
                'videoId': v.videoId,
                'title': v.title,
                'author': v.author,
                'lengthSeconds': v.lengthSeconds,
                if (v.queueEntryId != null) 'queueEntryId': v.queueEntryId,
                if (v.explicitMusicDownload != null)
                  'explicitMusicDownload': v.explicitMusicDownload,
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
      if (hasDeviceEntries && (version == 4 || localSelectionId != null))
        'localSelectionId': localSelectionId,
      'audio': audio,
      if (musicHistoryEntries != null)
        'musicHistoryEntries': musicHistoryEntries!.toList(),
      if (musicHistoryPlaylist) 'musicHistoryPlaylist': true,
      'played': played,
      'next': next,
      if (queueTitle != null) 'queueTitle': queueTitle,
      if (playlistReference != null)
        'playlistReference': playlistReference!.toJson(),
      if (playlistReference != null) 'playlistComplete': playlistComplete,
      if (playlistReference != null)
        'playlistEntries': playlistEntries
            .where((v) => v.explicitMusicDownload == null)
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

  static final _fingerprint = RegExp(r'^[a-f0-9]{64}$');
  static final _deviceOccurrence =
      RegExp(r'^device:[a-f0-9]{64}(#[1-9][0-9]*)?$');
  static final _selectionId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  static final _control = RegExp(r'[\x00-\x1f\x7f]');

  static bool _validFingerprint(Object? value) =>
      value is String && _fingerprint.stringMatch(value) == value;

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
    return DownloadedVideo.isSafeFileId(video.videoId) &&
        key.trim().isNotEmpty &&
        !_control.hasMatch(key) &&
        !isLocalMusicPlaybackId(key);
  }

  static PlaybackSession? decode(String? value) {
    if (value == null) return null;
    try {
      final json = jsonDecode(value) as Map<String, dynamic>;
      final version = json['version'];
      if (version != 1 && version != 2 && version != 3 && version != 4) {
        return null;
      }
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
            (version != 4 || source || !_validFingerprint(fingerprint))) {
          throw const FormatException('Invalid saved Music fingerprint');
        }
        if (version == 4) {
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
            explicitMusicDownload: fingerprint as String?);
        return version == 4 ? _portableArtwork(video) : video;
      }

      final videos = (json['videos'] as List).map(decodeVideo).toList();
      final offlineIds = List<String>.from(json['offlineIds']);
      final offlineMembership = offlineIds.toSet();
      final fingerprints = <String, String>{};
      if (json.containsKey('offlineFingerprints')) {
        final stored = json['offlineFingerprints'];
        if (version != 4 || stored is! Map || stored.isEmpty) return null;
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
      final marked =
          videos.where((v) => v.explicitMusicDownload != null).toList();
      final needsVersion4 =
          mixedOffline || marked.isNotEmpty || fingerprints.isNotEmpty;
      if ((version == 4) != needsVersion4) return null;
      if (version != 4 && ((version == 3) != savedCopies)) return null;
      if (version == 3 &&
          (playlistReference != null ||
              playlistEntries.isNotEmpty ||
              json['localSelectionId'] != null ||
              offlineMembership.length != offlineIds.length ||
              offlineIds.any((id) => savedDownloadSourceId(id) == null))) {
        return null;
      }
      if ([...videos, ...playlistEntries]
              .any((v) => isLocalMusicPlaybackId(v.videoId)) ||
          ((hasDevice || fingerprints.isNotEmpty) &&
              (offlineMembership.length != offlineIds.length ||
                  playlistReference != null ||
                  playlistEntries.isNotEmpty))) {
        return null;
      }
      if (version == 4) {
        final markedIds = marked.map(playbackQueueId).toSet();
        final selection = json['localSelectionId'];
        if (json['audio'] != true ||
            json.containsKey('localSelectionId') != mixedOffline ||
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
      if (seconds < 0 ||
          (videos.isNotEmpty && offlineIds.isNotEmpty) ||
          !(videos.any((v) => playbackQueueId(v) == currentId) ||
              offlineIds.contains(currentId))) {
        return null;
      }
      final ids = {...videos.map(playbackQueueId), ...offlineIds};
      final played = List<String>.from(json['played'] ?? []);
      final next = List<String>.from(json['next'] ?? []);
      final history = json['musicHistoryEntries'] as List?;
      if ((savedCopies || version == 4) &&
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
        localSelectionId:
            hasDevice ? json['localSelectionId'] as String? : null,
        audio: json['audio'] == true,
        musicHistoryEntries:
            history?.whereType<String>().where(ids.contains).toSet(),
        musicHistoryPlaylist: json['musicHistoryPlaylist'] == true,
        played: played.where(ids.contains).toList(),
        next: next.where(ids.contains).toList(),
        playlistReference: playlistReference,
        playlistComplete: json['playlistComplete'] == true,
        queueTitle: normalizedQueueTitle(json['queueTitle']),
        playlistEntries: playlistEntries,
      );
    } catch (_) {
      // A damaged backup should not prevent the app from opening.
      return null;
    }
  }
}
