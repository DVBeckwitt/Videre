import '../../utils/models/image_object.dart';
import '../../utils/invidious_image.dart';

/// Catalog labels retained when Invidious supplies playback URLs and metadata.
class MusicMetadata {
  final String title;
  final String artist;
  final String? album;
  final List<ImageObject> thumbnails;

  const MusicMetadata({
    required this.title,
    required this.artist,
    this.album,
    this.thumbnails = const [],
  });

  factory MusicMetadata.fromJson(Map<String, dynamic> json) => MusicMetadata(
        title: json['title'] as String,
        artist: json['artist'] as String,
        album: json['album'] as String?,
        thumbnails: (json['thumbnails'] as List<dynamic>? ?? [])
            .map((value) =>
                ImageObject.fromJson(Map<String, dynamic>.from(value as Map)))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'artist': artist,
        'album': album,
        'thumbnails': thumbnails.map((image) => image.toJson()).toList(),
      };

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
    return artwork.length == thumbnails.length
        ? this
        : MusicMetadata(
            title: title, artist: artist, album: album, thumbnails: artwork);
  }
}
