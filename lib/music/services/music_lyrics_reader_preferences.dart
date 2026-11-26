import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';
import '../models/music_lyrics.dart';

const _textSizeSetting = 'music-lyrics-text-size';
const _textAlignmentSetting = 'music-lyrics-text-alignment';
const _multilineSetting = 'music-lyrics-multiline';
const _trimSetting = 'music-lyrics-trim';

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
  final bool multiline;
  final bool trim;

  const MusicLyricsReaderPreferences({
    this.size = MusicLyricsTextSize.medium,
    this.alignment = MusicLyricsTextAlignment.start,
    this.multiline = true,
    this.trim = false,
  });

  static MusicLyricsReaderPreferences forDatabase(IDbClient database) =>
      MusicLyricsReaderPreferences(
        size: MusicLyricsTextSize.values
                .asNameMap()[database.getSettings(_textSizeSetting)?.value] ??
            MusicLyricsTextSize.medium,
        alignment: MusicLyricsTextAlignment.values.asNameMap()[
                database.getSettings(_textAlignmentSetting)?.value] ??
            MusicLyricsTextAlignment.start,
        multiline: database.getSettings(_multilineSetting)?.value != 'false',
        trim: database.getSettings(_trimSetting)?.value == 'true',
      );

  MusicLyricsReaderPreferences copyWith({
    MusicLyricsTextSize? size,
    MusicLyricsTextAlignment? alignment,
    bool? multiline,
    bool? trim,
  }) =>
      MusicLyricsReaderPreferences(
        size: size ?? this.size,
        alignment: alignment ?? this.alignment,
        multiline: multiline ?? this.multiline,
        trim: trim ?? this.trim,
      );

  Future<void> save(IDbClient database) =>
      database.forProfile(database.profileId).saveSettings([
        SettingsValue(_textSizeSetting, size.name),
        SettingsValue(_textAlignmentSetting, alignment.name),
        SettingsValue(_multilineSetting, multiline.toString()),
        SettingsValue(_trimSetting, trim.toString()),
      ]);

  String syncedCueText(MusicLyrics lyrics, int index) {
    var text = lyrics.displayTextByCue[index] ?? lyrics.cues[index].text;
    if (!multiline) {
      final newline = text.indexOf('\n');
      if (newline >= 0) text = text.substring(0, newline);
    }
    return trim ? text.trim() : text;
  }
}

/// Timing belongs to one recording within the reader's captured profile.
class MusicLyricsTimingPreference {
  static const stepMilliseconds = 100;
  static const limitMilliseconds = 10000;

  final IDbClient _owner;
  final String _key;

  MusicLyricsTimingPreference(this._owner, String recordingId)
      : _key = 'music-lyrics-timing-$recordingId';

  int read() {
    final value = int.tryParse(_owner.getSettings(_key)?.value ?? '') ?? 0;
    return value >= -limitMilliseconds && value <= limitMilliseconds
        ? value
        : 0;
  }

  Future<void> save(int milliseconds) async {
    if (milliseconds == 0) {
      await _owner.deleteSetting(_key);
    } else {
      await _owner.saveSetting(SettingsValue(_key, milliseconds.toString()));
    }
  }
}
