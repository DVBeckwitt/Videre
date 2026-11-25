import 'dart:convert';

import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';
import '../models/music_lyrics.dart';
import '../models/music_lyrics_match.dart';
import 'lrc_lyrics.dart';

final _videoId = RegExp(r'^[a-zA-Z0-9_-]{11}$');
const _lrclib = 'LRCLIB';
// Matches the LRC parser's cue limit. The framing budget includes JSON escapes
// and the timestamp and line-table index for each cue.
const _maxCues = 3000;
const _maxRecordLength = maxLyricsCharacters * 6 + _maxCues * 32 + 256;

/// Device-local overrides keyed by recording in an already scoped profile.
class MusicLyricsCorrections {
  final IDbClient _owner;

  MusicLyricsCorrections(this._owner);

  /// Null follows automatic matching. Unavailable records an explicit discard.
  MusicLyricsCorrection? read(String videoId) {
    if (!_validVideoId(videoId)) return null;
    final value = _owner.getSettings(_key(videoId))?.value;
    if (value == null || value.length > _maxRecordLength) return null;
    try {
      final record = jsonDecode(value);
      if (record is! Map<String, dynamic>) return null;
      final source = record['source'] == _lrclib ? _lrclib : null;
      final edited = record['edited'] == true;
      final kind = record['kind'];
      switch (kind) {
        case 'unavailable':
          return const MusicLyricsCorrection(MusicLyrics.unavailable());
        case 'instrumental':
          return MusicLyricsCorrection(MusicLyrics.instrumental(source: source),
              edited: edited);
        case 'plain' when record['text'] is String:
          final clean = cleanLyricsText(record['text'] as String);
          return clean.isEmpty
              ? null
              : MusicLyricsCorrection(MusicLyrics.plain(clean, source: source),
                  edited: edited);
        case 'plain':
        case 'synced':
          final cues = _readCues(record);
          if (cues == null) return null;
          final lyrics = kind == 'synced'
              ? MusicLyrics.synced(cues, source: source)
              : MusicLyrics.plainCues(cues, source: source);
          return MusicLyricsCorrection(lyrics, edited: edited);
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  Future<void> save(String videoId, MusicLyricsCorrection correction) async {
    final key = _key(videoId);
    final lyrics = correction.lyrics;
    final text = lyrics.text;
    if ((text != null && text.length > maxLyricsCharacters) ||
        lyrics.cues.length > _maxCues) {
      throw const FormatException('Lyric correction is too large');
    }
    final lineIndexes = <String, int>{};
    final cues = <List<int>>[];
    var textLength = 0;
    for (final cue in lyrics.cues) {
      // LRC may repeat a single long line at many timestamps.
      final index = lineIndexes.putIfAbsent(cue.text, () {
        textLength += cue.text.length;
        if (textLength > maxLyricsCharacters) {
          throw const FormatException('Lyric correction is too large');
        }
        return lineIndexes.length;
      });
      cues.add([cue.start.inMicroseconds, index]);
    }
    await _owner.saveSetting(SettingsValue(
        key,
        jsonEncode({
          'kind': lyrics.kind.name,
          if (lyrics.source == _lrclib) 'source': _lrclib,
          if (correction.edited) 'edited': true,
          if (text != null) 'text': text,
          if (cues.isNotEmpty) 'lines': lineIndexes.keys.toList(),
          if (cues.isNotEmpty) 'cues': cues,
        })));
  }

  Future<void> clear(String videoId) async {
    await _owner.deleteSetting(_key(videoId));
  }

  static bool _validVideoId(String videoId) =>
      videoId.length == 11 && _videoId.hasMatch(videoId);

  static String _key(String videoId) {
    if (!_validVideoId(videoId)) {
      throw ArgumentError('A YouTube video ID is required');
    }
    return 'music-lyrics-correction-$videoId';
  }

  static List<MusicLyricCue>? _readCues(Map<String, dynamic> record) {
    final lines = record['lines'];
    final entries = record['cues'];
    if (lines is! List ||
        entries is! List ||
        lines.isEmpty ||
        lines.length > entries.length ||
        entries.length > _maxCues) {
      return null;
    }
    final texts = <String>[];
    var textLength = 0;
    for (final line in lines) {
      if (line is! String) return null;
      textLength += line.length;
      if (textLength > maxLyricsCharacters) return null;
      final clean = cleanLyricsText(line);
      if (clean.isEmpty) return null;
      texts.add(clean);
    }
    final cues = <MusicLyricCue>[];
    var previous = 0;
    for (final entry in entries) {
      if (entry case [final int start, final int index]
          when start >= previous && index >= 0 && index < texts.length) {
        cues.add((start: Duration(microseconds: start), text: texts[index]));
        previous = start;
      } else {
        return null;
      }
    }
    return List.unmodifiable(cues);
  }
}
