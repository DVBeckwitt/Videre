import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/utils/models/image_object.dart';

class MusicCollection {
  final String id;
  final String title;
  final List<String> artists;
  final List<MusicArtist> artistLinks;
  final List<ImageObject> thumbnails;
  final List<MusicTrack> tracks;

  const MusicCollection({
    required this.id,
    required this.title,
    this.artists = const [],
    this.artistLinks = const [],
    this.thumbnails = const [],
    this.tracks = const [],
  });
}
