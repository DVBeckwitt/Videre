import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';

enum MusicDownloadFormat {
  mp3('MP3'),
  opus('Opus'),
  m4a('M4A (AAC)');

  final String label;
  const MusicDownloadFormat(this.label);

  String get extension => switch (this) {
        mp3 => 'mp3',
        opus => 'ogg',
        m4a => 'm4a',
      };

  String get mimeType => switch (this) {
        mp3 => 'audio/mpeg',
        opus => 'audio/ogg',
        m4a => 'audio/mp4',
      };

  static MusicDownloadFormat forDatabase(IDbClient database) =>
      values.asNameMap()[
          database.getSettings(musicDownloadFormatSettingName)?.value] ??
      mp3;

  Future<void> save(IDbClient database) => database
      .forProfile(database.profileId)
      .saveSetting(SettingsValue(musicDownloadFormatSettingName, name));
}
