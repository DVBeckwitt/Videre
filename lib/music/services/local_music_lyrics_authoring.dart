import 'package:sembast/sembast.dart';

import '../../utils/interfaces/db.dart';
import '../../utils/sembast_sqflite_database.dart';
import '../models/local_music_track.dart';
import '../models/music_lyrics.dart';
import 'lrc_lyrics.dart';
import 'music_timed_lyrics_draft.dart';

export 'music_timed_lyrics_draft.dart' show musicTimedLyricsDraftFrom;

/// Profile-local overrides keyed by the device track's canonical identity.
/// Callers guard the active session and authorization for the recording.
class LocalMusicLyricsAuthoring {
  static const _timed = 'lrc';
  static const _plain = 'plain';

  final SembastSqfDb _database;
  final String _trackId;
  final Duration duration;
  final bool Function() _isCurrent;

  const LocalMusicLyricsAuthoring._(
      this._database, this._trackId, this.duration, this._isCurrent);

  static LocalMusicLyricsAuthoring? forTrack({
    required IDbClient database,
    required LocalMusicTrack track,
    required bool Function() isCurrent,
  }) {
    final duration = Duration(milliseconds: track.durationMs);
    if (database is! SembastSqfDb || !isCurrent()) {
      return null;
    }
    final profile = database.profileId;
    return LocalMusicLyricsAuthoring._(
      database.forProfile(profile),
      track.playbackId,
      duration,
      () => isCurrent() && database.profileId == profile,
    );
  }

  bool get current => _isCurrent() && _database.isProfileAvailable;

  String? readDraft() => _read(_timed);

  String? readPlainDraft() => _read(_plain);

  String? _read(String field) {
    if (!current) return null;
    final text = _database.authoredMusicLyricsStore
        .record(_trackId)
        .getSync(_database.db)?[field];
    return text is String && text.length <= maxLyricsCharacters ? text : null;
  }

  MusicLyrics? load({required String source}) {
    final text = readDraft();
    if (text == null) return null;
    final parsed = parseEnhancedLrc(text, playbackDuration: duration);
    if (parsed.lines.isEmpty || parsed.lines.last.start >= duration) {
      return null;
    }
    return MusicLyrics.synced(parsed.lines,
        source: source,
        wordsByCue: parsed.wordsByCue,
        displayTextByCue: parsed.displayTextByCue,
        breakStarts: parsed.breakStarts);
  }

  Future<bool> save(String draft, {required String? previousDraft}) async {
    final valid = validatedMusicTimedLyricsDraft(draft, duration);
    return valid != null && await _write(_timed, valid, previousDraft);
  }

  Future<bool> remove({required String previousDraft}) =>
      _write(_timed, null, previousDraft);

  Future<bool> savePlain(String draft, {required String? previousDraft}) async {
    final valid = validatedMusicPlainLyricsDraft(draft);
    return valid != null && await _write(_plain, valid, previousDraft);
  }

  Future<bool> removePlain({required String previousDraft}) =>
      _write(_plain, null, previousDraft);

  Future<bool> _write(String field, String? value, String? previous) async {
    if (!current) return false;
    final record = _database.authoredMusicLyricsStore.record(_trackId);
    try {
      return await _database.db.transaction((transaction) async {
        if (!current) return false;
        await _database.ensureProfileExists(transaction);
        final stored = await record.get(transaction);
        if (stored?[field] != previous || !current) return false;
        final updated = {...?stored};
        if (value == null) {
          updated.remove(field);
        } else {
          updated[field] = value;
        }
        if (updated.isEmpty) {
          await record.delete(transaction);
        } else {
          await record.put(transaction, updated);
        }
        if (!current) throw const _AuthoredTrackChanged();
        return true;
      });
    } on _AuthoredTrackChanged {
      return false;
    }
  }
}

class _AuthoredTrackChanged implements Exception {
  const _AuthoredTrackChanged();
}

final _plainLineTime =
    RegExp('^[ \\t]*\\[$lrcTimestampPattern\\]', multiLine: true);
final _plainWordTime = RegExp('<$lrcTimestampPattern>');
final _plainControls = RegExp(r'[\u0000-\u0008\u000b-\u001f\u007f-\u009f]');

/// Normalizes line endings and rejects timed text without altering lyric lines.
String? validatedMusicPlainLyricsDraft(String draft) {
  if (draft.length > maxLyricsCharacters || draft.trim().isEmpty) return null;
  final text = draft.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (_plainControls.hasMatch(text) ||
      _plainLineTime.hasMatch(text) ||
      _plainWordTime.hasMatch(text)) {
    return null;
  }
  return text;
}
