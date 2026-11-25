import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../network/content_link.dart';
import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';

/// An opt-in, device-local record of this person's explicit Online searches.
class MusicOnlineRecents extends ChangeNotifier {
  // This personal setting is intentionally absent from portable backups.
  static const _settingName = 'music-online-recents-v1';
  static const _queryLimit = 20;
  static const maxQueryLength = 200;
  static final _owners = Expando<Map<String, MusicOnlineRecents>>();

  /// Use the root database so the views for one profile share their write queue
  /// and notifications. Writes use a fixed profile even if selection changes.
  factory MusicOnlineRecents.forProfile(IDbClient database, String profileId) =>
      (_owners[database] ??= {}).putIfAbsent(
        profileId,
        () => MusicOnlineRecents._(database.forProfile(profileId), profileId),
      );

  MusicOnlineRecents._(this._database, this._profileId);

  final IDbClient _database;
  final String _profileId;
  Future<void> _writes = Future.value();
  int _recordEpoch = 0;

  bool get enabled => _read() != null;
  List<String> get queries => _read() ?? const [];

  Future<void> setEnabled(bool enabled, {bool Function()? isCurrent}) =>
      _update((previous) => enabled ? previous ?? const [] : null,
          isCurrent: isCurrent, retireRecords: !enabled);

  Future<void> clear({bool Function()? isCurrent}) =>
      _update((previous) => previous == null ? null : const [],
          isCurrent: isCurrent, retireRecords: true);

  Future<void> remove(String query, {bool Function()? isCurrent}) =>
      _update((previous) => previous?.where((item) => item != query).toList(),
          isCurrent: isCurrent);

  Future<void> rename(String query, String replacement,
      {bool Function()? isCurrent}) {
    final text = _queryText(replacement);
    if (text == null || text == query) return Future.value();
    return _update((previous) {
      if (previous == null || !previous.contains(query)) return previous;
      return [
        for (final item in previous)
          if (item != text) item == query ? text : item,
      ];
    }, isCurrent: isCurrent);
  }

  static bool canSaveQuery(String query) => _queryText(query) != null;

  Future<void> recordSubmission(String query,
      {required bool Function() isCurrent}) {
    final text = _queryText(query);
    if (text == null) return Future.value();
    final epoch = _recordEpoch;
    return _update(
      (previous) => previous == null
          ? null
          : [text, ...previous.where((item) => item != text)]
              .take(_queryLimit)
              .toList(),
      isCurrent: () => epoch == _recordEpoch && isCurrent(),
    );
  }

  Future<void> _update(List<String>? Function(List<String>?) change,
      {bool Function()? isCurrent, bool retireRecords = false}) {
    if (isCurrent?.call() == false) return Future.value();
    // Invalidate queued submissions immediately. Keep privacy operations in
    // invocation order so re-enabling cannot cancel the preceding deletion.
    if (retireRecords) _recordEpoch++;
    final write = _writes.then((_) async {
      // A confirmed clear or opt-out still belongs to its captured profile
      // after the user leaves the page or switches profiles.
      if ((!retireRecords && isCurrent?.call() == false) || !_ownerAvailable) {
        return;
      }
      final previous = _database.getSettings(_settingName)?.value;
      final updated = change(_decode(previous));
      final next = updated == null
          ? null
          : jsonEncode({'version': 1, 'queries': updated});
      if (previous == next) return;
      try {
        if (next == null) {
          await _database.deleteSetting(_settingName);
        } else {
          await _database.saveSetting(SettingsValue(_settingName, next));
        }
      } on StateError {
        // The fixed owner may have been deleted while its write queued.
        if (_ownerAvailable) rethrow;
        return;
      }
      if (_ownerAvailable) notifyListeners();
    });
    _writes = write.catchError((Object _) {});
    return write;
  }

  bool get _ownerAvailable {
    try {
      return _database.profileId == _profileId;
    } on StateError {
      return false;
    }
  }

  List<String>? _read() => _ownerAvailable
      ? _decode(_database.getSettings(_settingName)?.value)
      : null;

  static List<String>? _decode(String? stored) {
    if (stored == null) return null;
    try {
      if (jsonDecode(stored)
          case {
            'version': 1,
            'queries': final List<Object?> rows,
          }
          when rows.length <= _queryLimit &&
              rows.every((row) => row is String && _queryText(row) == row) &&
              rows.toSet().length == rows.length) {
        return List<String>.unmodifiable(rows);
      }
    } on FormatException {
      // Invalid or older records cannot opt a person in.
    }
    return null;
  }

  static String? _queryText(String query) {
    final text = query.trim();
    return text.isEmpty ||
            text.runes.take(maxQueryLength + 1).length > maxQueryLength ||
            ContentLink.completeWebAddress(text) != null
        ? null
        : text;
  }
}
