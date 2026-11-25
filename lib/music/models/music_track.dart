import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/song_artwork.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';

class MusicTrack {
  final String videoId;
  final String title;
  final List<String> _artists;
  final List<MusicArtist> _artistLinks;
  final List<MusicArtistCredit> _savedCredits;
  List<String> get artists =>
      _savedCredits.isEmpty ? _artists : _savedCredits.artistNames;
  List<MusicArtist> get artistLinks =>
      _savedCredits.isEmpty ? _artistLinks : _savedCredits.artistLinks;
  List<MusicArtistCredit> get artistCredits => _savedCredits.isEmpty
      ? MusicArtistCredit.fromCatalog(_artists, _artistLinks)
      : _savedCredits;
  final String? uploaderChannelId;
  final String? uploaderChannelUrl;
  final String? uploaderName;
  final String? albumId;
  String? get albumPlaylistId => validMusicAlbumPlaylistId(albumId);
  final String? albumTitle;
  final int? durationSeconds;
  final int? playlistIndex;
  final String? playlistIndexId;

  /// Catalog art and stock video images have different display roles.
  final List<ImageObject> thumbnails;
  final List<ImageObject> videoThumbnails;
  final bool isArtTrack;

  List<ImageObject> get displayThumbnails =>
      displaySongThumbnails(videoId, thumbnails, videoThumbnails,
          artTrack: isArtTrack);

  MusicMetadata get musicMetadata {
    final names =
        artists.isEmpty ? artistLinks.map((artist) => artist.name) : artists;
    return MusicMetadata(
      title: title,
      artist: names.join(', '),
      artistCredits: artistCredits,
      album: albumTitle,
      albumPlaylistId: albumPlaylistId,
      thumbnails: songCovers(thumbnails),
      isArtTrack: isArtTrack,
    );
  }

  /// Fresh metadata for immediate playback of an interactive song link.
  /// Ordinary conversion stays catalog-only so later selections and bookmarks
  /// do not reuse expired streams or carry request credentials.
  final Video? playbackVideo;

  const MusicTrack({
    required this.videoId,
    required this.title,
    List<String> artists = const [],
    List<MusicArtist> artistLinks = const [],
    List<MusicArtistCredit> artistCredits = const [],
    this.uploaderChannelId,
    this.uploaderChannelUrl,
    this.uploaderName,
    String? albumId,
    String? albumPlaylistId,
    this.albumTitle,
    this.durationSeconds,
    this.playlistIndex,
    this.playlistIndexId,
    this.thumbnails = const [],
    this.videoThumbnails = const [],
    this.isArtTrack = false,
    this.playbackVideo,
  })  : albumId = albumPlaylistId ?? albumId,
        _artists = artists,
        _artistLinks = artistLinks,
        _savedCredits = artistCredits;

  Video toVideo() => Video(
        videoId: videoId,
        title: title,
        author: uploaderName ?? artists.join(', '),
        authorId: uploaderChannelId,
        authorUrl: uploaderChannelUrl,
        lengthSeconds: durationSeconds,
        index: playlistIndex,
        indexId: playlistIndexId,
        videoThumbnails: videoThumbnails.isEmpty ? thumbnails : videoThumbnails,
        musicMetadata: musicMetadata,
      );
}
