import 'music_lyrics.dart';

class MusicLyricsMatch {
  final int id;
  final String trackName;
  final String artistName;
  final String albumName;
  final Duration duration;
  final MusicLyrics lyrics;

  const MusicLyricsMatch({
    required this.id,
    required this.trackName,
    required this.artistName,
    required this.albumName,
    required this.duration,
    required this.lyrics,
  });
}

typedef MusicLyricsSearch = Future<List<MusicLyricsMatch>> Function({
  required String trackName,
  required String artistName,
  required String albumName,
  required int? durationSeconds,
  required bool Function() isCurrent,
});

class MusicLyricsCorrection {
  /// An unavailable result explicitly discards the match for this recording.
  final MusicLyrics lyrics;
  final bool edited;

  const MusicLyricsCorrection(this.lyrics, {this.edited = false});
}
