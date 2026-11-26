import 'package:clipious/videos/models/music_metadata.dart';

typedef MusicLyricCue = ({Duration start, String text});

typedef MusicLyricTranslation = ({String text, String? language});

class MusicLyricCueMetadata {
  final Duration? end;
  final String? language;
  final String? voice;
  final String? role;
  final List<MusicLyricTranslation> translations;

  const MusicLyricCueMetadata({
    this.end,
    this.language,
    this.voice,
    this.role,
    this.translations = const [],
  });

  bool get isBackgroundVocal =>
      role?.split(RegExp(r'\s+')).contains('x-bg') ?? false;

  bool get hasDetails =>
      voice != null || isBackgroundVocal || translations.isNotEmpty;
}

/// A timed segment in a cue, using UTF-16 offsets into the displayed text.
/// The start offset is inclusive and the end offset is exclusive.
typedef MusicLyricWord = ({Duration start, int startOffset, int endOffset});

typedef MusicLyricsLoader = Future<MusicLyrics> Function(
  MusicMetadata track,
  int? durationSeconds,
  String videoId,
);

enum MusicLyricsKind { synced, plain, instrumental, unavailable }

class MusicLyrics {
  final MusicLyricsKind kind;
  final String? source;
  final List<MusicLyricCue> cues;

  /// Explicit blank timestamps in playback order, separate from display rows.
  final List<Duration> breakStarts;
  final Map<int, List<MusicLyricWord>> wordsByCue;

  /// Timed lines with their original spacing and untimed continuations.
  /// Cues with identical display and canonical text are omitted.
  final Map<int, String> displayTextByCue;
  final String? text;

  /// Metadata keyed by cue index so simultaneous parts keep their own voice.
  final Map<int, MusicLyricCueMetadata> metadataByCue;

  const MusicLyrics.synced(
    this.cues, {
    this.source,
    this.wordsByCue = const {},
    this.metadataByCue = const {},
    this.displayTextByCue = const {},
    this.breakStarts = const [],
  })  : kind = MusicLyricsKind.synced,
        text = null;
  const MusicLyrics.plain(String this.text, {this.source})
      : kind = MusicLyricsKind.plain,
        cues = const [],
        displayTextByCue = const {},
        breakStarts = const [],
        metadataByCue = const {},
        wordsByCue = const {};

  /// Keeps repeated cue texts by reference when their joined form is too large.
  /// Plain lyrics never expose cue timings in the player.
  const MusicLyrics.plainCues(this.cues, {this.source})
      : kind = MusicLyricsKind.plain,
        displayTextByCue = const {},
        breakStarts = const [],
        metadataByCue = const {},
        wordsByCue = const {},
        text = null;
  const MusicLyrics.instrumental({this.source})
      : kind = MusicLyricsKind.instrumental,
        cues = const [],
        displayTextByCue = const {},
        breakStarts = const [],
        metadataByCue = const {},
        wordsByCue = const {},
        text = null;
  const MusicLyrics.unavailable()
      : kind = MusicLyricsKind.unavailable,
        source = null,
        cues = const [],
        displayTextByCue = const {},
        breakStarts = const [],
        metadataByCue = const {},
        wordsByCue = const {},
        text = null;
}
