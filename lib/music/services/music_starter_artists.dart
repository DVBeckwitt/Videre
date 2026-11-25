import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';
import '../models/music_search_text.dart';
import '../models/music_track.dart';

const musicStarterArtistsSettingName = 'music-starter-artists-v1';

/// Explicit discovery preferences stored in the active person's settings.
class MusicStarterArtists {
  static const maxPicks = 3;
  static const maxNameLength = 100;
  static final _owners = Expando<Map<String, ValueNotifier<int>>>();
  static final _whitespace = RegExp(r'\s+');
  static final _control = RegExp(r'[\x00-\x1f\x7f-\x9f]');

  final IDbClient _root;
  final String _profileId;
  final IDbClient _database;
  final ValueNotifier<int> _changes;

  MusicStarterArtists(IDbClient database, String profileId)
      : _root = database,
        _profileId = profileId,
        _database = database.forProfile(profileId),
        _changes = (_owners[database] ??= {})
            .putIfAbsent(profileId, () => ValueNotifier(0));

  Listenable get changes => _changes;

  /// Null means undecided. An empty list records an explicit skip or clear.
  List<String>? get picks {
    final raw = _database.getSettings(musicStarterArtistsSettingName)?.value;
    if (raw == null || raw.length > maxPicks * maxNameLength * 2 + 16) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.length > maxPicks) return null;
      final names = <String>[];
      final keys = <String>{};
      for (final value in decoded) {
        final name = value is String ? cleanName(value) : null;
        if (name == null || !keys.add(artistKey(name))) return null;
        names.add(name);
      }
      return List.unmodifiable(names);
    } on FormatException {
      return null;
    }
  }

  Future<void> save(Iterable<String> names) async {
    if (_root.profileId != _profileId) return;
    final picks = <String>[];
    final keys = <String>{};
    var hasNames = false;
    for (final raw in names) {
      hasNames = true;
      final name = cleanName(raw);
      if (name == null || !keys.add(artistKey(name))) continue;
      picks.add(name);
      if (picks.length == maxPicks) break;
    }
    if (picks.isEmpty && hasNames) {
      throw const FormatException('No valid starter-artist names');
    }
    await _database.saveSetting(
        SettingsValue(musicStarterArtistsSettingName, jsonEncode(picks)));
    if (_root.profileId == _profileId) _changes.value++;
  }

  static String? cleanName(String raw) {
    final name = raw.replaceAll(_whitespace, ' ').trim();
    if (name.isEmpty ||
        name.runes.length > maxNameLength ||
        _control.hasMatch(name) ||
        artistKey(name).isEmpty) {
      return null;
    }
    return name;
  }

  static String artistKey(String raw) =>
      normalizeMusicSearchText(raw).replaceAll(_whitespace, ' ').trim();

  static bool matches(MusicTrack track, Set<String> keys) =>
      keys.isNotEmpty &&
      (track.artists.any((name) => keys.contains(artistKey(name))) ||
          track.artistCredits
              .any((credit) => keys.contains(artistKey(credit.name))));
}
