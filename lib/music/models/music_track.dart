import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';

class MusicTrack {
  final String videoId;
  final String title;
  final List<String> artists;
  final List<MusicArtist> artistLinks;
  final String? albumId;
  final String? albumTitle;
  final int? durationSeconds;
  final List<ImageObject> thumbnails;

  /// Fresh metadata for immediate playback of an interactive song link.
  /// Ordinary conversion stays catalog-only so later selections and bookmarks
  /// do not reuse expired streams or carry request credentials.
  final Video? playbackVideo;

  const MusicTrack({
    required this.videoId,
    required this.title,
    this.artists = const [],
    this.artistLinks = const [],
    this.albumId,
    this.albumTitle,
    this.durationSeconds,
    this.thumbnails = const [],
    this.playbackVideo,
  });

  Video toVideo() => Video(
        videoId: videoId,
        title: title,
        author: artists.join(', '),
        lengthSeconds: durationSeconds,
        videoThumbnails: thumbnails,
        musicMetadata: MusicMetadata(
          title: title,
          artist: artists.join(', '),
          album: albumTitle,
          thumbnails: thumbnails,
        ),
      );
}
