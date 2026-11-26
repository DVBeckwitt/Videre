import 'package:clipious/music/models/replay_gain.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/interfaces/db.dart';

/// Playback preferences for one profile across Music listening sessions.
class MusicReplayGainPreferences {
  final IDbClient _database;

  const MusicReplayGainPreferences(this._database);

  ReplayGainMode get mode {
    final stored = _database.getSettings(musicReplayGainModeSettingName)?.value;
    return ReplayGainMode.values.asNameMap()[stored] ?? ReplayGainMode.off;
  }

  double get taggedPreampDb => _preampDb(musicTaggedPreampSettingName);
  double get untaggedPreampDb => _preampDb(musicUntaggedPreampSettingName);

  double _preampDb(String key) {
    // Each setting inherits the legacy value until it is edited. Keeping
    // the old value as the fallback makes a partial migration safe to retry.
    final stored = _database.getSettings(key)?.value ??
        _database.getSettings(musicPreampSettingName)?.value;
    return clampMusicPreampDb(double.tryParse(stored ?? '') ?? 0);
  }

  Future<void> setMode(ReplayGainMode value) => _database.saveSetting(
        SettingsValue(musicReplayGainModeSettingName, value.name),
      );

  Future<void> setTaggedPreampDb(double value) =>
      _setPreampDb(musicTaggedPreampSettingName, value);

  Future<void> setUntaggedPreampDb(double value) =>
      _setPreampDb(musicUntaggedPreampSettingName, value);

  Future<void> _setPreampDb(String key, double value) => _database.saveSetting(
        SettingsValue(key, clampMusicPreampDb(value).toString()),
      );
}
