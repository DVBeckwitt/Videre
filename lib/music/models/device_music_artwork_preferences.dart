import 'package:flutter/foundation.dart';

import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';

enum DeviceMusicArtworkSource {
  preferAdjacent,
  embeddedOnly;

  static DeviceMusicArtworkSource? fromStorage(String? value) =>
      values.asNameMap()[value];
}

enum DeviceMusicArtworkQuality {
  balanced,
  high;

  static DeviceMusicArtworkQuality? fromStorage(String? value) =>
      values.asNameMap()[value];
}

enum DeviceMusicArtworkCrop {
  crop,
  fit;

  static DeviceMusicArtworkCrop? fromStorage(String? value) =>
      values.asNameMap()[value];
}

class DeviceMusicArtworkPreferences {
  final DeviceMusicArtworkSource source;
  final DeviceMusicArtworkQuality quality;
  final DeviceMusicArtworkCrop crop;

  const DeviceMusicArtworkPreferences._(this.source, this.quality, this.crop);

  static final _revision = ValueNotifier(0);
  static ValueListenable<int> get revision => _revision;

  static DeviceMusicArtworkPreferences forDatabase(IDbClient database) =>
      DeviceMusicArtworkPreferences._(
        DeviceMusicArtworkSource.fromStorage(database
                .getSettings(deviceMusicArtworkSourceSettingName)
                ?.value) ??
            DeviceMusicArtworkSource.preferAdjacent,
        DeviceMusicArtworkQuality.fromStorage(database
                .getSettings(deviceMusicArtworkQualitySettingName)
                ?.value) ??
            DeviceMusicArtworkQuality.balanced,
        DeviceMusicArtworkCrop.fromStorage(database
                .getSettings(deviceMusicArtworkCropSettingName)
                ?.value) ??
            DeviceMusicArtworkCrop.crop,
      );

  static Future<void> setSource(
          IDbClient database, DeviceMusicArtworkSource value) =>
      _save(database, deviceMusicArtworkSourceSettingName, value);

  static Future<void> setQuality(
          IDbClient database, DeviceMusicArtworkQuality value) =>
      _save(database, deviceMusicArtworkQualitySettingName, value);

  static Future<void> setCrop(
          IDbClient database, DeviceMusicArtworkCrop value) =>
      _save(database, deviceMusicArtworkCropSettingName, value);

  static Future<void> _save(
      IDbClient database, String settingName, Enum value) async {
    await database
        .forProfile(database.profileId)
        .saveSetting(SettingsValue(settingName, value.name));
    _revision.value++;
  }
}
