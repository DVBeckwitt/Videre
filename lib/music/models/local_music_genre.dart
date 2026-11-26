import 'local_music_track.dart';

String? localMusicGenreKey(LocalMusicTrack track) =>
    track.genre?.trim().toLowerCase();

String localMusicGenreNameKey(String name) => name.trim().toLowerCase();

/// Retains the first display spelling for each device genre key.
Map<String, String> groupLocalMusicGenres(Iterable<LocalMusicTrack> tracks) {
  final labels = <String, String>{};
  for (final track in tracks) {
    for (final genre in track.genres) {
      final name = genre.trim();
      if (name.isNotEmpty) {
        labels.putIfAbsent(localMusicGenreNameKey(name), () => name);
      }
    }
  }
  return labels;
}
