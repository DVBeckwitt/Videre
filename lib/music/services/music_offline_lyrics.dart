import 'dart:convert';

import 'package:sembast/sembast.dart';

import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';
import '../../utils/sembast_sqflite_database.dart';
import '../../videos/models/music_metadata.dart';
import '../models/music_lyrics.dart';
import 'lrc_lyrics.dart';
import 'music_lyric_word_codec.dart';
import 'music_lyrics_corrections.dart';

const _settingPrefix = 'music-offline-lyrics-v1:';
const _maximumRecordingId = 1024;
const _maximumLabel = 1024;
const _maximumCues = 3000;
const _maximumRecordLength = 1024 * 1024;
final _labelWhitespace = RegExp(r'\s+');
final _catalogVideoId = RegExp(r'^[a-zA-Z0-9_-]{11}$');

typedef MusicOfflineLyricsRecording = ({
  String videoId,
  MusicMetadata track,
  int? durationSeconds,
});

/// A user's approved lyrics are stored with their recording, independently of
/// the playback queue occurrence and whether the same recording is downloaded.
class MusicOfflineLyrics {
  final IDbClient _owner;

  MusicOfflineLyrics(IDbClient owner)
      : _owner = owner.forProfile(owner.profileId);

  /// Emits the initial app database state and subsequent lyric setting changes
  /// for this profile, including explicit corrections and discards.
  Stream<void> get changes {
    final owner = _owner;
    if (owner is! SembastSqfDb) return const Stream<void>.empty();
    final filter = Filter.or([
      Filter.matches(Field.key, '^$_settingPrefix'),
      Filter.matches(Field.key, '^${MusicLyricsCorrections.settingPrefix}'),
    ]);
    return owner.settingsStore
        .query(finder: Finder(filter: filter))
        .onSnapshots(owner.db)
        .map((_) {});
  }

  /// Discovers saved catalog copies outside the current library or downloads.
  /// Use [read] with current recording metadata when available.
  Iterable<MusicOfflineLyricsRecording> catalogRecordings() sync* {
    for (final setting in _owner.getAllSettings()) {
      if (!setting.name.startsWith(_settingPrefix)) continue;
      final videoId = setting.name.substring(_settingPrefix.length);
      if (_catalogVideoId.stringMatch(videoId) != videoId) continue;
      final row = _readRecord(setting.value);
      if (row == null) continue;
      final labels = _readLabels(row['labels']);
      final duration = row['duration'];
      if (labels == null ||
          (duration != null && (duration is! int || duration <= 0))) {
        continue;
      }
      final original = _readLabels(row['displayLabels']);
      final display = original != null &&
              labels.indexed.every(
                  (label) => _normalizeLabel(original[label.$1]) == label.$2)
          ? original
          : labels;
      yield (
        videoId: videoId,
        track: MusicMetadata(
          title: display[0].trim().isEmpty ? videoId : display[0],
          artist: display[1],
          album: display[2].trim().isEmpty ? null : display[2],
        ),
        durationSeconds: duration as int?,
      );
    }
  }

  MusicLyrics? read(String recordingId,
      {required MusicMetadata track, required int? durationSeconds}) {
    if (!_validId(recordingId)) return null;
    final decoded =
        _readRecord(_owner.getSettings('$_settingPrefix$recordingId')?.value);
    if (decoded == null ||
        !_matchingLabels(decoded['labels'], _labels(track)) ||
        !_matchingDuration(
            decoded['duration'], _knownDuration(durationSeconds))) {
      return null;
    }
    return _decodeLyrics(decoded);
  }

  Future<void> save(String recordingId, MusicLyrics lyrics,
      {required MusicMetadata track, required int? durationSeconds}) async {
    if (!_validId(recordingId)) throw ArgumentError('Invalid recording ID');
    if (lyrics.kind == MusicLyricsKind.unavailable) {
      throw ArgumentError('Unavailable lyrics cannot be saved');
    }
    final labels = _labels(track);
    final display = [track.title, track.artist, track.album ?? ''];
    final source = lyrics.source;
    if (labels.any((label) => label.length > _maximumLabel) ||
        (source != null && source.length > _maximumLabel)) {
      throw ArgumentError('Lyrics metadata is too long');
    }
    final row = <String, Object?>{
      'kind': lyrics.kind.name,
      'labels': labels,
      if (display.every((label) => label.length <= _maximumLabel))
        'displayLabels': display,
      'duration': _knownDuration(durationSeconds),
      if (source != null) 'source': source,
      ..._encodeContent(lyrics),
    };
    var value = jsonEncode(row);
    if (value.length > _maximumRecordLength &&
        row.remove('displayLabels') != null) {
      value = jsonEncode(row);
    }
    if (value.length > _maximumRecordLength) {
      throw ArgumentError('Lyrics are too long');
    }
    await _owner
        .saveSetting(SettingsValue('$_settingPrefix$recordingId', value));
  }

  Future<void> remove(String recordingId) async {
    if (!_validId(recordingId)) return;
    await _owner.deleteSetting('$_settingPrefix$recordingId');
  }
}

bool _validId(String value) =>
    value.isNotEmpty && value.length <= _maximumRecordingId;

Map<String, dynamic>? _readRecord(String? value) {
  if (value == null || value.length > _maximumRecordLength) return null;
  try {
    final row = jsonDecode(value);
    return row is Map<String, dynamic> ? row : null;
  } on FormatException {
    return null;
  }
}

String _normalizeLabel(String? value) => (value ?? '')
    .trim()
    .replaceAll(_labelWhitespace, ' ')
    .replaceAll('’', "'")
    .toLowerCase();

List<String> _labels(MusicMetadata track) => [
      _normalizeLabel(track.title),
      _normalizeLabel(track.artist),
      _normalizeLabel(track.album),
    ];

List<String>? _readLabels(Object? value) {
  if (value case [final String title, final String artist, final String album]
      when title.length <= _maximumLabel &&
          artist.length <= _maximumLabel &&
          album.length <= _maximumLabel) {
    return [title, artist, album];
  }
  return null;
}

bool _matchingLabels(Object? value, List<String> current) {
  final stored = _readLabels(value);
  if (stored == null) return false;
  for (var index = 0; index < current.length; index++) {
    final label = stored[index];
    if (label.isNotEmpty &&
        current[index].isNotEmpty &&
        label != current[index]) {
      return false;
    }
  }
  return true;
}

int? _knownDuration(int? value) => value != null && value > 0 ? value : null;

bool _matchingDuration(Object? stored, int? current) {
  if (stored == null) return true;
  return stored is int &&
      stored > 0 &&
      (current == null || (stored - current).abs() <= 2);
}

Map<String, Object?> _encodeContent(MusicLyrics lyrics) {
  if (lyrics.kind == MusicLyricsKind.instrumental) return {};
  final text = lyrics.text;
  if (text != null) {
    if (text.length > maxLyricsCharacters || text.trim().isEmpty) {
      throw ArgumentError('Invalid plain lyrics');
    }
    return {'text': text};
  }
  final cues = lyrics.cues;
  if (cues.isEmpty || cues.length + lyrics.breakStarts.length > _maximumCues) {
    throw ArgumentError('Invalid lyrics cues');
  }

  final lineIndices = <String, int>{};
  final entries = <List<int>>[];
  var characters = 0;
  int? previous;
  for (final cue in cues) {
    final start = cue.start.inMicroseconds;
    if ((previous != null && start < previous) || cue.text.isEmpty) {
      throw ArgumentError('Invalid lyrics cue');
    }
    final line = lineIndices.putIfAbsent(cue.text, () {
      characters += cue.text.length;
      if (characters > maxLyricsCharacters) {
        throw ArgumentError('Lyrics cues are too long');
      }
      return lineIndices.length;
    });
    entries.add([start, line]);
    previous = start;
  }
  final words = encodeStoredLyricWords(lyrics.wordsByCue);
  final displayText = encodeStoredLyricDisplayText(lyrics.displayTextByCue);
  return {
    'lines': lineIndices.keys.toList(),
    'cues': entries,
    if (words.isNotEmpty) 'words': words,
    if (displayText.isNotEmpty) 'displayText': displayText,
    if (lyrics.breakStarts.isNotEmpty)
      'breaks': [for (final t in lyrics.breakStarts) t.inMicroseconds],
  };
}

MusicLyrics? _decodeLyrics(Map<String, dynamic> record) {
  final source = record['source'];
  if (source != null && (source is! String || source.length > _maximumLabel)) {
    return null;
  }
  final attribution = source as String?;
  final kind = record['kind'];
  final text = record['text'];
  final lines = record['lines'];
  final entries = record['cues'];
  if (kind == MusicLyricsKind.instrumental.name) {
    return text == null && lines == null && entries == null
        ? MusicLyrics.instrumental(source: attribution)
        : null;
  }
  if (text != null) {
    return kind == MusicLyricsKind.plain.name &&
            text is String &&
            text.length <= maxLyricsCharacters &&
            text.trim().isNotEmpty &&
            lines == null &&
            entries == null
        ? MusicLyrics.plain(text, source: attribution)
        : null;
  }
  if (kind != MusicLyricsKind.plain.name &&
      kind != MusicLyricsKind.synced.name) {
    return null;
  }
  final cues = _decodeCues(lines, entries);
  if (cues == null) return null;
  return kind == MusicLyricsKind.synced.name
      ? MusicLyrics.synced(cues,
          source: attribution,
          wordsByCue: decodeStoredLyricWords(record['words'], cues),
          displayTextByCue:
              decodeStoredLyricDisplayText(record['displayText'], cues),
          breakStarts: decodeStoredLyricBreaks(record['breaks'], cues.length))
      : MusicLyrics.plainCues(cues, source: attribution);
}

List<MusicLyricCue>? _decodeCues(Object? lines, Object? entries) {
  if (lines is! List ||
      entries is! List ||
      lines.isEmpty ||
      entries.isEmpty ||
      lines.length > entries.length ||
      entries.length > _maximumCues) {
    return null;
  }
  final dictionary = <String>[];
  var characters = 0;
  for (final line in lines) {
    if (line is! String || line.isEmpty) return null;
    characters += line.length;
    if (characters > maxLyricsCharacters) return null;
    dictionary.add(line);
  }

  final cues = <MusicLyricCue>[];
  int? previous;
  for (final entry in entries) {
    if (entry case [final int start, final int line]
        when (previous == null || start >= previous) &&
            line >= 0 &&
            line < dictionary.length) {
      cues.add((start: Duration(microseconds: start), text: dictionary[line]));
      previous = start;
    } else {
      return null;
    }
  }
  return List.unmodifiable(cues);
}
