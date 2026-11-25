import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';

const _setting = 'music-passage-bookmarks-v1';
final _identifier = RegExp(r'[A-Za-z0-9_:#.-]+');

bool _isIdentifier(String value) =>
    value.isNotEmpty && _identifier.stringMatch(value) == value;

class PassageBookmark {
  final String id;
  final String name;
  final String recordingId;
  final String occurrenceId;
  final Duration position;

  const PassageBookmark._(
    this.id,
    this.name,
    this.recordingId,
    this.occurrenceId,
    this.position,
  );

  static PassageBookmark? _decode(Object? row) {
    if (row
        case {
          'id': final String id,
          'name': final String name,
          'recordingId': final String recordingId,
          'occurrenceId': final String occurrenceId,
          'positionMs': final int milliseconds,
        }) {
      final position = Duration(milliseconds: milliseconds);
      if (_isIdentifier(id) &&
          name.trim().isNotEmpty &&
          _isIdentifier(recordingId) &&
          _isIdentifier(occurrenceId) &&
          milliseconds >= 0 &&
          position.inMilliseconds == milliseconds) {
        return PassageBookmark._(
          id,
          name.trim(),
          recordingId,
          occurrenceId,
          position,
        );
      }
    }
    return null;
  }

  Map<String, Object> _encode() => {
        'id': id,
        'name': name,
        'recordingId': recordingId,
        'occurrenceId': occurrenceId,
        'positionMs': position.inMilliseconds,
      };
}

class _ProfileWrites {
  Future<bool> pending = Future.value(false);
}

/// Pass the shared application database so all views of one profile serialize
/// their edits. Each edit reads the latest value after preceding edits finish.
class MusicPassageBookmarks {
  static final _owners = Expando<Map<String, _ProfileWrites>>();
  final IDbClient _database;
  final _ProfileWrites _writes;

  MusicPassageBookmarks(IDbClient database, String profileId)
      : _database = database.forProfile(profileId),
        _writes = (_owners[database] ??= {}).putIfAbsent(
          profileId,
          _ProfileWrites.new,
        );

  List<PassageBookmark> list(String recordingId) => List.unmodifiable(
        _read().where((bookmark) => bookmark.recordingId == recordingId),
      );

  Future<bool> add({
    required String recordingId,
    required String occurrenceId,
    required Duration position,
    required String name,
    required bool Function() isCurrent,
  }) {
    final label = name.trim();
    if (label.isEmpty ||
        position.isNegative ||
        !_isIdentifier(recordingId) ||
        !_isIdentifier(occurrenceId)) {
      return Future.value(false);
    }
    return _mutate(isCurrent, (bookmarks) {
      bookmarks.add(
        PassageBookmark._(
          const Uuid().v4(),
          label,
          recordingId,
          occurrenceId,
          Duration(milliseconds: position.inMilliseconds),
        ),
      );
      return true;
    });
  }

  Future<bool> rename(
    PassageBookmark bookmark,
    String name, {
    required bool Function() isCurrent,
  }) {
    final label = name.trim();
    if (label.isEmpty) return Future.value(false);
    return _mutate(isCurrent, (bookmarks) {
      final index = bookmarks.indexWhere((item) => item.id == bookmark.id);
      if (index < 0) return false;
      final current = bookmarks[index];
      bookmarks[index] = PassageBookmark._(
        current.id,
        label,
        current.recordingId,
        current.occurrenceId,
        current.position,
      );
      return true;
    });
  }

  Future<bool> remove(
    PassageBookmark bookmark, {
    required bool Function() isCurrent,
  }) =>
      _mutate(isCurrent, (bookmarks) {
        final index = bookmarks.indexWhere((item) => item.id == bookmark.id);
        if (index < 0) return false;
        bookmarks.removeAt(index);
        return true;
      });

  List<PassageBookmark> _read() {
    final value = _database.getSettings(_setting)?.value;
    if (value == null) return [];
    try {
      final rows = jsonDecode(value);
      final ids = <String>{};
      if (rows is List) {
        return [
          for (final row in rows)
            if (PassageBookmark._decode(row) case final bookmark?)
              if (ids.add(bookmark.id)) bookmark,
        ];
      }
    } on FormatException {
      // Keep reading available when old or damaged local metadata is present.
    }
    return [];
  }

  Future<bool> _mutate(
    bool Function() isCurrent,
    bool Function(List<PassageBookmark>) edit,
  ) {
    return _writes.pending =
        _writes.pending.catchError((Object _) => false).then((_) async {
      if (!isCurrent()) return false;
      final bookmarks = _read();
      if (!edit(bookmarks)) return false;
      await _database.saveSetting(
        SettingsValue(
          _setting,
          jsonEncode(bookmarks.map((item) => item._encode()).toList()),
        ),
      );
      return true;
    });
  }
}
