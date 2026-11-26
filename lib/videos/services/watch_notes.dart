import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';

class WatchNote {
  final String id;
  final String text;
  final Duration? position;

  const WatchNote._(this.id, this.text, this.position);

  static WatchNote? _decode(Object? row) {
    if (row
        case {
          'id': final String id,
          'text': final String text,
          'positionMs': final int? milliseconds,
        }) {
      final position =
          milliseconds == null ? null : Duration(milliseconds: milliseconds);
      if (id.isNotEmpty &&
          text.trim().isNotEmpty &&
          (milliseconds == null ||
              (milliseconds >= 0 &&
                  position!.inMilliseconds == milliseconds))) {
        return WatchNote._(id, text, position);
      }
    }
    return null;
  }

  Map<String, Object?> _encode() => {
        'id': id,
        'text': text,
        'positionMs': position?.inMilliseconds,
      };
}

typedef _NoteScope = ({String profileId, String videoId});

/// Local notes for one video in the profile captured when the list opens.
class WatchNotes {
  static final _pendingWrites = Expando<Map<_NoteScope, Future<void>>>();

  final IDbClient _profile;
  final Map<_NoteScope, Future<void>> _writes;
  final _NoteScope _scope;

  WatchNotes._(this._profile, this._writes, this._scope);

  /// Use the shared app database so concurrent writes to a video stay ordered.
  factory WatchNotes.forVideo(IDbClient database, String videoId) {
    final profileId = database.profileId;
    return WatchNotes._(
      database.forProfile(profileId),
      _pendingWrites[database] ??= {},
      (profileId: profileId, videoId: videoId),
    );
  }

  String get _settingName => '$watchNotesSettingPrefix${_scope.videoId}';

  List<WatchNote> list() => List.unmodifiable(_read());

  List<WatchNote> _read() {
    final raw = _profile.getSettings(_settingName)?.value;
    if (raw == null) return [];
    try {
      final rows = jsonDecode(raw);
      final ids = <String>{};
      if (rows is List) {
        return [
          for (final row in rows)
            if (WatchNote._decode(row) case final note?)
              if (ids.add(note.id)) note,
        ];
      }
    } on FormatException {
      return [];
    }
    return [];
  }

  Future<void> save({
    WatchNote? existing,
    required String text,
    required Duration? position,
  }) async {
    final body = text.trim();
    if (body.isEmpty) throw ArgumentError('Watch note text is empty');
    if (position?.isNegative == true) {
      throw ArgumentError('Watch note position is negative');
    }
    final previous = _writes[_scope] ?? Future<void>.value();
    final write = previous.catchError((Object _) {}).then((_) async {
      final notes = _read();
      if (existing == null) {
        notes.add(WatchNote._(const Uuid().v4(), body, position));
      } else {
        final index = notes.indexWhere((note) => note.id == existing.id);
        if (index < 0) throw StateError('Watch note no longer exists');
        notes[index] = WatchNote._(existing.id, body, position);
      }
      await _profile.saveSetting(
        SettingsValue(
          _settingName,
          jsonEncode(notes.map((note) => note._encode()).toList()),
        ),
      );
    });
    _writes[_scope] = write;
    try {
      await write;
    } finally {
      if (identical(_writes[_scope], write)) _writes.remove(_scope);
    }
  }
}
