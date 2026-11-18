import 'package:clipious/videos/models/music_metadata.dart';

typedef MusicLyricCue = ({Duration start, String text});
typedef MusicLyricsLoader = Future<MusicLyrics> Function(
    MusicMetadata track, int? durationSeconds, String videoId);

enum MusicLyricsKind { synced, plain, instrumental, unavailable }

class MusicLyrics {
  final MusicLyricsKind kind;
  final String? source;
  final List<MusicLyricCue> cues;
  final String? text;

  const MusicLyrics.synced(this.cues, {this.source})
      : kind = MusicLyricsKind.synced,
        text = null;
  const MusicLyrics.plain(String this.text, {this.source})
      : kind = MusicLyricsKind.plain,
        cues = const [];

  /// Keeps repeated cue texts by reference when their joined form is too large.
  /// Plain lyrics never expose cue timings in the player.
  const MusicLyrics.plainCues(this.cues, {this.source})
      : kind = MusicLyricsKind.plain,
        text = null;
  const MusicLyrics.instrumental({this.source})
      : kind = MusicLyricsKind.instrumental,
        cues = const [],
        text = null;
  const MusicLyrics.unavailable()
      : kind = MusicLyricsKind.unavailable,
        source = null,
        cues = const [],
        text = null;
}
