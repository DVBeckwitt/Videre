import '../../music/models/music_artist.dart';
import '../../utils/models/image_object.dart';
import '../../utils/invidious_image.dart';

/// Catalog labels retained when Invidious supplies playback URLs and metadata.
class MusicMetadata {
  final String title;
  final String artist;
  final List<MusicArtistCredit> artistCredits;
  final String? album;
  final List<ImageObject> thumbnails;

  /// The stock recording is an automatically generated Art Track. Its image
  /// candidates remain video thumbnails, distinct from catalog cover URLs.
  final bool isArtTrack;

  const MusicMetadata({
    required this.title,
    required this.artist,
    this.artistCredits = const [],
    this.album,
    this.thumbnails = const [],
    this.isArtTrack = false,
  });

  factory MusicMetadata.fromJson(Map<String, dynamic> json) => MusicMetadata(
        title: json['title'] as String,
        artist: json['artist'] as String,
        artistCredits: MusicArtistCredit.parseList(json['artistCredits']),
        album: json['album'] as String?,
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
        if (isArtTrack) 'isArtTrack': true,
        'thumbnails': thumbnails.map((image) => image.toJson()).toList(),
      };

  MusicMetadata withThumbnails(List<ImageObject> images) => MusicMetadata(
      title: title,
      artist: artist,
      artistCredits: artistCredits,
      album: album,
      thumbnails: images,
      isArtTrack: isArtTrack);

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
