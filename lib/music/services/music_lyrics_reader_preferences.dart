import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';

const _textSizeSetting = 'music-lyrics-text-size';
const _textAlignmentSetting = 'music-lyrics-text-alignment';

enum MusicLyricsTextSize {
  small(16),
  medium(20),
  large(26);

  const MusicLyricsTextSize(this.fontSize);

  final double fontSize;
}

enum MusicLyricsTextAlignment { start, center }

class MusicLyricsReaderPreferences {
  final MusicLyricsTextSize size;
  final MusicLyricsTextAlignment alignment;

  const MusicLyricsReaderPreferences({
    this.size = MusicLyricsTextSize.medium,
    this.alignment = MusicLyricsTextAlignment.start,
  });

  static MusicLyricsReaderPreferences forDatabase(IDbClient database) =>
      MusicLyricsReaderPreferences(
        size: MusicLyricsTextSize.values
                .asNameMap()[database.getSettings(_textSizeSetting)?.value] ??
            MusicLyricsTextSize.medium,
        alignment: MusicLyricsTextAlignment.values.asNameMap()[
                database.getSettings(_textAlignmentSetting)?.value] ??
            MusicLyricsTextAlignment.start,
      );

  MusicLyricsReaderPreferences copyWith({
    MusicLyricsTextSize? size,
    MusicLyricsTextAlignment? alignment,
  }) =>
      MusicLyricsReaderPreferences(
        size: size ?? this.size,
        alignment: alignment ?? this.alignment,
      );

  Future<void> save(IDbClient database) =>
      database.forProfile(database.profileId).saveSettings([
        SettingsValue(_textSizeSetting, size.name),
        SettingsValue(_textAlignmentSetting, alignment.name),
      ]);
}
