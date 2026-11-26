import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';
import 'music_library_search.dart';

/// The last metadata categories selected in Library Search for one profile.
class MusicLibrarySearchPreferences {
  static const _settingName = 'music-library-search-categories-v1';
  static final _owners = Expando<Map<String, MusicLibrarySearchPreferences>>();

  factory MusicLibrarySearchPreferences.forProfile(
          IDbClient database, String profileId) =>
      (_owners[database] ??= {}).putIfAbsent(
        profileId,
        () => MusicLibrarySearchPreferences._(database.forProfile(profileId)),
      );

  MusicLibrarySearchPreferences._(this._database);

  final IDbClient _database;
  Future<void> _writes = Future.value();
  Set<MusicLibrarySearchType>? _pending;

  Set<MusicLibrarySearchType> get categories {
    if (_pending case final pending?) return pending;
    final stored =
        _database.getSettings(_settingName)?.value.split(',').toSet() ??
            const <String>{};
    final legacyArtists =
        stored.contains('channel') || stored.contains('channels');
    final selected = {
      for (final type in MusicLibrarySearchType.categories)
        if (stored.contains(type.name) ||
            (type == MusicLibrarySearchType.artists && legacyArtists))
          type,
    };
    return selected.isEmpty
        ? MusicLibrarySearchType.categories
        : Set.unmodifiable(selected);
  }

  Future<void> save(Set<MusicLibrarySearchType> types) {
    final selection = Set<MusicLibrarySearchType>.unmodifiable(types);
    _pending = selection;
    final write = _writes.then((_) async {
      final value = MusicLibrarySearchType.categories
          .where(selection.contains)
          .map((type) => type.name)
          .join(',');
      try {
        await _database.saveSetting(SettingsValue(_settingName, value));
      } finally {
        if (identical(_pending, selection)) _pending = null;
      }
    });
    _writes = write.catchError((Object _) {});
    return write;
  }
}
