import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../playlists/models/playlist_reference.dart';
import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';
import '../models/music_track.dart';

class MusicDiscoverySnooze {
  final String videoId;
  final String title;
  final DateTime expiresAt;

  const MusicDiscoverySnooze._(this.videoId, this.title, this.expiresAt);
}

typedef _VisibilityRules = ({
  Map<String, Set<String>> hidden,
  Map<String, MusicDiscoverySnooze> snoozes,
});

/// Local, per-profile visibility choices for Music playlist and discovery views.
/// A playlist key includes its source and account, so identical IDs on
/// different accounts do not share rules.
class MusicVisibility extends ChangeNotifier {
  static const _setting = 'music-scoped-visibility-v1';
  static final _byDatabase = Expando<Map<String, MusicVisibility>>();

  final IDbClient _database;
  final DateTime Function() _now;
  String? _stored;
  _VisibilityRules _rules = (hidden: const {}, snoozes: const {});
  Future<void> _writes = Future.value();
  Timer? _expiryTimer;

  factory MusicVisibility.forProfile(IDbClient database, String profileId) =>
      (_byDatabase[database] ??= {}).putIfAbsent(
        profileId,
        () => MusicVisibility._(database.forProfile(profileId), DateTime.now),
      );

  MusicVisibility._(this._database, this._now);

  @visibleForTesting
  MusicVisibility.withClock(IDbClient database, DateTime Function() now)
      : this._(database, now);

  bool isHiddenInPlaylist(PlaylistReference playlist, String videoId) =>
      playlist.matchesOwner(_database) &&
      (_read().hidden[playlist.key]?.contains(videoId) ?? false);

  Future<void> setHiddenInPlaylist(
          PlaylistReference playlist, String videoId, bool hidden) =>
      _change((rules) {
        if (!playlist.matchesOwner(_database) || videoId.isEmpty) {
          return false;
        }
        final songs = {...?rules.hidden[playlist.key]};
        final changed = hidden ? songs.add(videoId) : songs.remove(videoId);
        if (songs.isEmpty) {
          rules.hidden.remove(playlist.key);
        } else {
          rules.hidden[playlist.key] = songs;
        }
        return changed;
      });

  bool isSnoozed(String videoId) =>
      _read().snoozes[videoId]?.expiresAt.isAfter(_now()) ?? false;

  List<MusicDiscoverySnooze> get activeSnoozes {
    final now = _now();
    return _read()
        .snoozes
        .values
        .where((song) => song.expiresAt.isAfter(now))
        .toList()
      ..sort((left, right) => left.expiresAt.compareTo(right.expiresAt));
  }

  Future<void> snooze(MusicTrack track, Duration duration) => _change((rules) {
        if (track.videoId.isEmpty || duration <= Duration.zero) return false;
        rules.snoozes[track.videoId] = MusicDiscoverySnooze._(
          track.videoId,
          track.title,
          _now().toUtc().add(duration),
        );
        return true;
      });

  Future<void> endSnooze(String videoId) =>
      _change((rules) => rules.snoozes.remove(videoId) != null);

  _VisibilityRules _read() {
    final stored = _database.getSettings(_setting)?.value;
    if (stored == _stored) return _rules;
    final hidden = <String, Set<String>>{};
    final snoozes = <String, MusicDiscoverySnooze>{};
    try {
      if (jsonDecode(stored ?? 'null') case final Map data) {
        if (data['hidden'] case final Map playlists) {
          for (final entry in playlists.entries) {
            if (entry.key case final String playlistKey) {
              if (entry.value case final List songs) {
                hidden[playlistKey] = songs.whereType<String>().toSet();
              }
            }
          }
        }
        if (data['snoozes'] case final List rows) {
          for (final row in rows.whereType<Map>()) {
            final id = row['videoId'];
            final title = row['title'];
            final expiry = row['expiresAt'];
            if (id is String && title is String && expiry is String) {
              final expiresAt = DateTime.tryParse(expiry)?.toUtc();
              if (expiresAt != null) {
                snoozes[id] = MusicDiscoverySnooze._(id, title, expiresAt);
              }
            }
          }
        }
      }
    } on FormatException {
      // Unreadable settings cannot hide any songs.
    }
    _stored = stored;
    return _rules = (hidden: hidden, snoozes: snoozes);
  }

  Future<void> _change(bool Function(_VisibilityRules) update) {
    final write = _writes.then((_) async {
      final current = _read();
      final next = (
        hidden: Map.of(current.hidden),
        snoozes: Map.of(current.snoozes),
      );
      if (!update(next)) return;
      final now = _now();
      next.snoozes.removeWhere((_, snooze) => !snooze.expiresAt.isAfter(now));
      final value = jsonEncode({
        'hidden':
            next.hidden.map((key, songs) => MapEntry(key, songs.toList())),
        'snoozes': [
          for (final snooze in next.snoozes.values)
            {
              'videoId': snooze.videoId,
              'title': snooze.title,
              'expiresAt': snooze.expiresAt.toIso8601String(),
            },
        ],
      });
      await _database.saveSetting(SettingsValue(_setting, value));
      _stored = value;
      _rules = next;
      _scheduleExpiry();
      notifyListeners();
    });
    _writes = write.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return write;
  }

  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (!hasListeners) return;
    final expiry = activeSnoozes.firstOrNull?.expiresAt;
    if (expiry == null) return;
    final remaining = expiry.difference(_now());
    _expiryTimer = Timer(remaining, () {
      _scheduleExpiry();
      notifyListeners();
    });
  }

  @override
  void addListener(VoidCallback listener) {
    final wasObserved = hasListeners;
    super.addListener(listener);
    if (!wasObserved) _scheduleExpiry();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) _scheduleExpiry();
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }
}
