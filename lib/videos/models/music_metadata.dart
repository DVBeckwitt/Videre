import '../../utils/models/image_object.dart';

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
}
