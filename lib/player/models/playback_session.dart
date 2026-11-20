import 'dart:convert';

import '../../videos/models/video.dart';
import '../../playlists/models/playlist_reference.dart';
import 'playback_queue.dart';
import 'local_music_playback.dart';

const playbackSessionSetting = 'playback-session';

class PlaybackSession {
  final List<Video> videos;
  final List<String> offlineIds;
  final String currentId;
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

  const PlaybackSession({
    this.videos = const [],
    this.offlineIds = const [],
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
  });

  String encode() => jsonEncode({
        'version': 2,
        // Stream URLs expire. Save enough to show the queue, then fetch on play.
        'videos': videos
            .map((v) => {
                  'videoId': v.videoId,
                  'title': v.title,
                  'author': v.author,
                  'lengthSeconds': v.lengthSeconds,
                  if (v.queueEntryId != null) 'queueEntryId': v.queueEntryId,
                  if (v.index != null) 'index': v.index,
                  if (v.indexId != null) 'indexId': v.indexId,
                  if (v.musicMetadata != null)
                    'musicMetadata': v.musicMetadata!.toJson(),
                  'videoThumbnails':
                      v.videoThumbnails.map((t) => t.toJson()).toList(),
                })
            .toList(),
        'offlineIds': offlineIds,
        'currentId': currentId,
        'seconds': seconds,
        if (localSelectionId != null && isLocalMusicPlaybackId(currentId))
          'localSelectionId': localSelectionId,
        'audio': audio,
        if (musicHistoryEntries != null)
          'musicHistoryEntries': musicHistoryEntries!.toList(),
        if (musicHistoryPlaylist) 'musicHistoryPlaylist': true,
        'played': played,
        'next': next,
        if (playlistReference != null)
          'playlistReference': playlistReference!.toJson(),
        if (playlistReference != null) 'playlistComplete': playlistComplete,
        if (playlistReference != null)
          'playlistEntries': playlistEntries
              .map((video) => {
                    'videoId': video.videoId,
                    'queueEntryId': video.queueEntryId,
                    if (video.index != null) 'index': video.index,
                    if (video.indexId != null) 'indexId': video.indexId,
                  })
              .toList(),
      });

  static PlaybackSession? decode(String? value) {
    if (value == null) return null;
    try {
      final json = jsonDecode(value) as Map<String, dynamic>;
      if (json['version'] != 1 && json['version'] != 2) return null;
      final playlistReference =
          PlaylistReference.tryParse(json['playlistReference']);
      if (json['playlistReference'] != null && playlistReference == null) {
        return null;
      }
      Video decodeVideo(dynamic value) {
        final entry = Map<String, dynamic>.from(value);
        return Video.fromJson(entry)
            .copyWith(queueEntryId: entry['queueEntryId'] as String?);
      }

      final videos = (json['videos'] as List).map(decodeVideo).toList();
      final offlineIds = List<String>.from(json['offlineIds']);
      final playlistEntries =
          (json['playlistEntries'] as List? ?? []).map(decodeVideo).toList();
      if ([...videos, ...playlistEntries]
              .any((v) => isLocalMusicPlaybackId(v.videoId)) ||
          (offlineIds.any(isLocalMusicPlaybackId) &&
              (offlineIds.any((id) => !isLocalMusicPlaybackId(id)) ||
                  offlineIds.toSet().length != offlineIds.length ||
                  playlistReference != null ||
                  playlistEntries.isNotEmpty))) {
        return null;
      }
      final currentId = json['currentId'] as String;
      final seconds = json['seconds'] as int;
      if (seconds < 0 ||
          (videos.isNotEmpty && offlineIds.isNotEmpty) ||
          !(videos.any((v) => playbackQueueId(v) == currentId) ||
              offlineIds.contains(currentId))) return null;
      final ids = {...videos.map(playbackQueueId), ...offlineIds};
      return PlaybackSession(
        videos: videos,
        offlineIds: offlineIds,
        currentId: currentId,
        seconds: seconds,
        localSelectionId: isLocalMusicPlaybackId(currentId)
            ? json['localSelectionId'] as String?
            : null,
        audio: json['audio'] == true,
        musicHistoryEntries: (json['musicHistoryEntries'] as List?)
            ?.whereType<String>()
            .where(ids.contains)
            .toSet(),
        musicHistoryPlaylist: json['musicHistoryPlaylist'] == true,
        played: List<String>.from(json['played'] ?? [])
            .where(ids.contains)
            .toList(),
        next:
            List<String>.from(json['next'] ?? []).where(ids.contains).toList(),
        playlistReference: playlistReference,
        playlistComplete: json['playlistComplete'] == true,
        playlistEntries: playlistEntries,
      );
    } catch (_) {
      // A damaged backup should not prevent the app from opening.
      return null;
    }
  }
}
