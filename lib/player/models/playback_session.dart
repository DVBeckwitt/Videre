import 'dart:convert';

import '../../videos/models/video.dart';

const playbackSessionSetting = 'playback-session';

class PlaybackSession {
  final List<Video> videos;
  final List<String> offlineIds;
  final String currentId;
  final int seconds;
  final bool audio;
  final List<String> played;
  final List<String> next;

  const PlaybackSession({
    this.videos = const [],
    this.offlineIds = const [],
    required this.currentId,
    required this.seconds,
    this.audio = false,
    this.played = const [],
    this.next = const [],
  });

  String encode() => jsonEncode({
        'version': 1,
        // Stream URLs expire. Save enough to show the queue, then fetch on play.
        'videos': videos
            .map((v) => {
                  'videoId': v.videoId,
                  'title': v.title,
                  'author': v.author,
                  'lengthSeconds': v.lengthSeconds,
                  'videoThumbnails':
                      v.videoThumbnails.map((t) => t.toJson()).toList(),
                })
            .toList(),
        'offlineIds': offlineIds,
        'currentId': currentId,
        'seconds': seconds,
        'audio': audio,
        'played': played,
        'next': next,
      });

  static PlaybackSession? decode(String? value) {
    if (value == null) return null;
    try {
      final json = jsonDecode(value) as Map<String, dynamic>;
      if (json['version'] != 1) return null;
      final videos = (json['videos'] as List)
          .map((v) => Video.fromJson(Map<String, dynamic>.from(v)))
          .toList();
      final offlineIds = List<String>.from(json['offlineIds']);
      final currentId = json['currentId'] as String;
      final seconds = json['seconds'] as int;
      if (seconds < 0 ||
          (videos.isNotEmpty && offlineIds.isNotEmpty) ||
          !(videos.any((v) => v.videoId == currentId) ||
              offlineIds.contains(currentId))) return null;
      final ids = {...videos.map((v) => v.videoId), ...offlineIds};
      return PlaybackSession(
        videos: videos,
        offlineIds: offlineIds,
        currentId: currentId,
        seconds: seconds,
        audio: json['audio'] == true,
        played: List<String>.from(json['played'] ?? [])
            .where(ids.contains)
            .toList(),
        next:
            List<String>.from(json['next'] ?? []).where(ids.contains).toList(),
      );
    } catch (_) {
      // A damaged backup should not prevent the app from opening.
      return null;
    }
  }
}
