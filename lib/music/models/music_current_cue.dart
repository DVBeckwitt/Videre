import 'music_lyrics.dart';

typedef MusicCurrentCue = ({int index, String? text});

/// The first cue at the latest started timestamp, or -1 before any cue.
int activeMusicLyricIndex(List<MusicLyricCue> cues, Duration position) {
  final latest = _firstAfter(cues, (cue) => cue.start <= position) - 1;
  if (latest < 0) return -1;
  final latestStart = cues[latest].start;
  return _firstAfter(cues, (cue) => cue.start < latestStart);
}

/// Selects the line in playback time, keeping its index as an anchor during
/// a silent break. A positive delay moves cue starts and breaks later.
MusicCurrentCue? currentMusicCueAt(
    MusicLyrics lyrics, Duration position, Duration delay) {
  if (lyrics.kind != MusicLyricsKind.synced) return null;
  final lyricTime = position - delay;
  final index = activeMusicLyricIndex(lyrics.cues, lyricTime);
  if (index < 0) return (index: index, text: null);
  final pause =
      _firstAfter(lyrics.breakStarts, (time) => time <= lyricTime) - 1;
  final pauseStart = pause < 0 ? null : lyrics.breakStarts[pause];
  var first = index;
  while (first >= 0) {
    final start = lyrics.cues[first].start;
    if (pauseStart != null && pauseStart > start) break;
    for (var i = first;
        i < lyrics.cues.length && lyrics.cues[i].start == start;
        i++) {
      final end = lyrics.metadataByCue[i]?.end;
      if (end == null ? first == index : lyricTime < end) {
        final text = lyrics.cues[i].text.trim();
        return (index: i, text: text.isEmpty ? null : text);
      }
    }
    // A longer SRT/TTML cue can still be playing when a shorter part ends.
    if (first == 0) break;
    final earlier = lyrics.cues[first - 1].start;
    do {
      first--;
    } while (first > 0 && lyrics.cues[first - 1].start == earlier);
  }
  return (index: index, text: null);
}

int _firstAfter<T>(List<T> entries, bool Function(T) precedesBoundary) {
  var start = 0;
  var end = entries.length;
  while (start < end) {
    final middle = (start + end) ~/ 2;
    if (precedesBoundary(entries[middle])) {
      start = middle + 1;
    } else {
      end = middle;
    }
  }
  return start;
}
