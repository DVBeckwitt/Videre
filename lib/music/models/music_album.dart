import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/utils/models/image_object.dart';

class MusicAlbum {
  final String id;
  final String title;
  final List<String> artists;
  final List<MusicArtist> artistLinks;
  final List<ImageObject> thumbnails;

  const MusicAlbum({
    required this.id,
    required this.title,
    this.artists = const [],
    this.artistLinks = const [],
    this.thumbnails = const [],
  });
}
