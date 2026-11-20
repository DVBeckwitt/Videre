import 'package:flutter/foundation.dart';

import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';

enum MusicCoverCorners {
  rounded,
  square;

  static final _revision = ValueNotifier(0);
  static ValueListenable<int> get revision => _revision;

  static MusicCoverCorners? fromStorage(String? name) =>
      values.asNameMap()[name];

  static MusicCoverCorners forDatabase(IDbClient database) =>
      fromStorage(database.getSettings(musicCoverCornersSettingName)?.value) ??
      rounded;

  Future<void> save(IDbClient database) async {
    await database
        .forProfile(database.profileId)
        .saveSetting(SettingsValue(musicCoverCornersSettingName, name));
    _revision.value++;
  }
}
