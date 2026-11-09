import 'package:clipious/music/models/music_album.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_track.dart';

class MusicArtistPage {
  final MusicArtist artist;
  final String? description;
  final List<MusicTrack> songs;
  final List<MusicAlbum> albums;
  final List<MusicAlbum> singles;

  const MusicArtistPage({
    required this.artist,
    this.description,
    this.songs = const [],
    this.albums = const [],
    this.singles = const [],
  });
}
