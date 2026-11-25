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

  double get preampDb {
    final stored = _database.getSettings(musicPreampSettingName)?.value;
    return clampMusicPreampDb(double.tryParse(stored ?? '') ?? 0);
  }

  Future<void> setMode(ReplayGainMode value) => _database.saveSetting(
        SettingsValue(musicReplayGainModeSettingName, value.name),
      );

  Future<void> setPreampDb(double value) => _database.saveSetting(
        SettingsValue(
            musicPreampSettingName, clampMusicPreampDb(value).toString()),
      );
}
