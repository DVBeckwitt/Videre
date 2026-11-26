import 'package:clipious/music/models/music_album.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_track.dart';

class MusicArtistPage {
  final MusicArtist artist;
  final String? description;
  final List<MusicTrack> songs;
  final bool loadsUploadsSeparately;
  final List<MusicAlbum> albums;
  final List<MusicAlbum> singles;

  const MusicArtistPage({
    required this.artist,
    this.description,
    this.songs = const [],
    this.loadsUploadsSeparately = false,
    this.albums = const [],
    this.singles = const [],
  });
}

/// One page of uploads exposed by the artist's channel.
class MusicArtistUploads {
  final List<MusicTrack> songs;
  final String? continuation;

  const MusicArtistUploads({this.songs = const [], this.continuation});
}

/// A page of public release playlists from the artist's channel.
class MusicArtistReleases {
  final List<MusicCollection> releases;
  final String? continuation;

  const MusicArtistReleases({this.releases = const [], this.continuation});
}
