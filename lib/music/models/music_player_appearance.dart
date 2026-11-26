import 'package:flutter/foundation.dart';

import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';

enum MusicNowPlayingStyle {
  classic,
  largeArtwork,
  compact;

  static MusicNowPlayingStyle? fromStorage(String? name) =>
      values.asNameMap()[name];

  static MusicNowPlayingStyle forDatabase(IDbClient database) =>
      fromStorage(
        database.getSettings(musicNowPlayingStyleSettingName)?.value,
      ) ??
      classic;

  Future<void> save(IDbClient database) => MusicPlayerAppearance._save(
        database,
        musicNowPlayingStyleSettingName,
        name,
      );
}

enum MusicPlayerBackground {
  artwork,
  solid,
  gradient,
  movingArtwork;

  static MusicPlayerBackground? fromStorage(String? name) =>
      values.asNameMap()[name];

  static MusicPlayerBackground forDatabase(IDbClient database) =>
      fromStorage(
        database.getSettings(musicPlayerBackgroundSettingName)?.value,
      ) ??
      artwork;

  Future<void> save(IDbClient database) => MusicPlayerAppearance._save(
        database,
        musicPlayerBackgroundSettingName,
        name,
      );
}

enum MusicScrubberStyle {
  gapped,
  continuous,
  wave;

  static MusicScrubberStyle? fromStorage(String? name) =>
      values.asNameMap()[name];

  static MusicScrubberStyle forDatabase(IDbClient database) =>
      fromStorage(database.getSettings(musicScrubberStyleSettingName)?.value) ??
      gapped;

  Future<void> save(IDbClient database) => MusicPlayerAppearance._save(
        database,
        musicScrubberStyleSettingName,
        name,
      );
}

abstract final class MusicPlayerAppearance {
  static final _revision = ValueNotifier(0);
  static ValueListenable<int> get revision => _revision;

  static Future<void> _save(
    IDbClient database,
    String setting,
    String value,
  ) async {
    await database
        .forProfile(database.profileId)
        .saveSetting(SettingsValue(setting, value));
    _revision.value++;
  }
}
