import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_playlist.dart';

class MusicCountry {
  final String code;
  final String name;

  const MusicCountry({required this.code, required this.name});
}

class MusicCharts {
  final String country;
  final List<MusicCountry> countries;
  final List<MusicPlaylist> playlists;

  /// Public chart artist cards do not establish a numerical ranking.
  final List<MusicArtist> artists;

  const MusicCharts({
    required this.country,
    this.countries = const [],
    this.playlists = const [],
    this.artists = const [],
  });
}

class MusicMoodCategory {
  final String title;
  final String params;
  final String group;

  const MusicMoodCategory({
    required this.title,
    required this.params,
    required this.group,
  });
}
