import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../playlists/models/playlist_reference.dart';
import '../settings/models/db/settings.dart';
import '../utils/interfaces/db.dart';

/// Keep titles, account identity and origin out of stored learning controls.
String musicPlaylistRecommendationKey(PlaylistReference reference) =>
    sha256.convert(utf8.encode(reference.key)).toString();

String _settingName(String key) => 'music-playlist-learning-exclusion-v1-$key';

bool isMusicPlaylistRecommendationExcluded(
        IDbClient profileDatabase, String sourceKey) =>
    profileDatabase.getSettings(_settingName(sourceKey)) != null;

class MusicPlaylistRecommendationExclusions extends ChangeNotifier {
  static final _owners = Expando<MusicPlaylistRecommendationExclusions>();

  factory MusicPlaylistRecommendationExclusions.forDatabase(
          IDbClient database) =>
      _owners[database] ??= MusicPlaylistRecommendationExclusions._(database);

  MusicPlaylistRecommendationExclusions._(this._database);

  final IDbClient _database;
  Future<void> _writes = Future.value();

  Future<void> setExcluded(PlaylistReference reference,
      {required bool excluded, required bool Function() isCurrent}) {
    return _writes = _writes.catchError((Object _) {}).then((_) async {
      if (!isCurrent() || !reference.matchesOwner(_database)) {
        throw StateError('The active profile changed.');
      }
      final owner = _database.forProfile(reference.profileId);
      final key = musicPlaylistRecommendationKey(reference);
      if (isMusicPlaylistRecommendationExcluded(owner, key) == excluded) {
        return;
      }
      final name = _settingName(key);
      if (excluded) {
        await owner.saveSetting(SettingsValue(name, 'true'));
      } else {
        await owner.deleteSetting(name);
      }
      notifyListeners();
    });
  }
}
