import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/song_artwork.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';

class MusicTrack {
  final String videoId;
  final String title;
  final List<String> artists;
  final List<MusicArtist> artistLinks;
  final String? uploaderChannelId;
  final String? uploaderChannelUrl;
  final String? albumId;
  final String? albumTitle;
  final int? durationSeconds;

  /// Catalog art and stock video images have different display roles.
  final List<ImageObject> thumbnails;
  final List<ImageObject> videoThumbnails;
  final bool isArtTrack;

  List<ImageObject> get displayThumbnails =>
      displaySongThumbnails(videoId, thumbnails, videoThumbnails,
          artTrack: isArtTrack);

  MusicMetadata get musicMetadata => MusicMetadata(
        title: title,
        artist: artists.join(', '),
        album: albumTitle,
        thumbnails: songCovers(thumbnails),
        isArtTrack: isArtTrack,
      );

  /// Fresh metadata for immediate playback of an interactive song link.
  /// Ordinary conversion stays catalog-only so later selections and bookmarks
  /// do not reuse expired streams or carry request credentials.
  final Video? playbackVideo;

  const MusicTrack({
    required this.videoId,
    required this.title,
    this.artists = const [],
    this.artistLinks = const [],
    this.uploaderChannelId,
    this.uploaderChannelUrl,
    this.albumId,
    this.albumTitle,
    this.durationSeconds,
    this.thumbnails = const [],
    this.videoThumbnails = const [],
    this.isArtTrack = false,
    this.playbackVideo,
  });

  Video toVideo() => Video(
        videoId: videoId,
        title: title,
        author: artists.join(', '),
        authorId: uploaderChannelId,
        authorUrl: uploaderChannelUrl,
        lengthSeconds: durationSeconds,
        videoThumbnails: videoThumbnails.isEmpty ? thumbnails : videoThumbnails,
        musicMetadata: musicMetadata,
      );
}
