import '../../music/models/music_artist.dart';
import '../../utils/models/image_object.dart';
import '../../utils/invidious_image.dart';

final _albumPlaylist = RegExp(r'^OLAK5uy_[A-Za-z0-9_-]+$');

/// Stock Invidious can open public release playlists, including saved IDs.
String? validMusicAlbumPlaylistId(Object? value) => value is String &&
        value.length <= 128 &&
        _albumPlaylist.stringMatch(value) == value
    ? value
    : null;

/// Catalog labels retained when Invidious supplies playback URLs and metadata.
class MusicMetadata {
  final String title;
  final String artist;
  final List<MusicArtistCredit> artistCredits;
  final String? album;
  final String? _albumPlaylistId;
  String? get albumPlaylistId => validMusicAlbumPlaylistId(_albumPlaylistId);
  final List<ImageObject> thumbnails;

  /// The stock recording is an automatically generated Art Track. Its image
  /// candidates remain video thumbnails, distinct from catalog cover URLs.
  final bool isArtTrack;

  const MusicMetadata({
    required this.title,
    required this.artist,
    this.artistCredits = const [],
    this.album,
    String? albumPlaylistId,
    this.thumbnails = const [],
    this.isArtTrack = false,
  }) : _albumPlaylistId = albumPlaylistId;

  factory MusicMetadata.fromJson(Map<String, dynamic> json) => MusicMetadata(
        title: json['title'] as String,
        artist: json['artist'] as String,
        artistCredits: MusicArtistCredit.parseList(json['artistCredits']),
        album: json['album'] as String?,
        albumPlaylistId: validMusicAlbumPlaylistId(json['albumPlaylistId']),
        isArtTrack: json['isArtTrack'] == true,
        thumbnails: (json['thumbnails'] as List<dynamic>? ?? [])
            .map((value) =>
                ImageObject.fromJson(Map<String, dynamic>.from(value as Map)))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'artist': artist,
        if (artistCredits.isNotEmpty)
          'artistCredits': [
            for (final credit in artistCredits) credit.toJson()
          ],
        'album': album,
        if (albumPlaylistId != null) 'albumPlaylistId': albumPlaylistId,
        if (isArtTrack) 'isArtTrack': true,
        'thumbnails': thumbnails.map((image) => image.toJson()).toList(),
      };

  MusicMetadata withThumbnails(List<ImageObject> images) => MusicMetadata(
      title: title,
      artist: artist,
      artistCredits: artistCredits,
      album: album,
      albumPlaylistId: albumPlaylistId,
      thumbnails: images,
      isArtTrack: isArtTrack);

  /// Refresh stream metadata without losing the selected occurrence's release.
  MusicMetadata withAlbumFrom(MusicMetadata? source) {
    final id = source?.albumPlaylistId;
    if (id == null) return this;
    final releaseTitle = source?.album ?? album;
    if (id == albumPlaylistId && releaseTitle == album) return this;
    return MusicMetadata(
      title: title,
      artist: artist,
      artistCredits: artistCredits,
      album: releaseTitle,
      albumPlaylistId: id,
      thumbnails: thumbnails,
      isArtTrack: isArtTrack,
    );
  }

  /// Older bookmarks copied an instance fallback into their catalog artwork.
  /// Repair only URLs also present in the video's fallback list, keeping
  /// standalone catalog art and original YouTube image sources intact.
  MusicMetadata withoutVideoThumbnailFallbacks(List<ImageObject> fallbacks) {
    if (thumbnails.isEmpty || fallbacks.isEmpty) return this;
    final videoUrls = fallbacks.map((image) => image.url).toSet();
    final artwork = thumbnails
        .where((image) =>
            !videoUrls.contains(image.url) ||
            !isInvidiousThumbnailUrl(image.url))
        .toList();
    return artwork.length == thumbnails.length ? this : withThumbnails(artwork);
  }
}
