import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';
import '../models/local_music_track.dart';

typedef LocalMusicVisibilityOwner = ({IDbClient database, String profileId});
typedef _ExclusionRules = ({
  bool recordings,
  Map<String, LocalMusicFolderLocation> folders,
  Set<String> kept,
});

/// Display metadata for a hidden file, including when Android cannot list it.
class HiddenLocalMusicTrack {
  final _HiddenFile _file;
  final LocalMusicVisibilityOwner _owner;
  final String title;
  final String? artist;
  final String? fileName;
  final bool isAvailable;

  HiddenLocalMusicTrack._(this._file, this._owner, LocalMusicTrack? track)
      : title = track?.title ?? _file.title,
        artist = track?.artist ?? _file.artist,
        fileName = track?.fileName ?? _file.fileName,
        isAvailable = track != null;

  String get id => _file.key;
}

class _HiddenFile {
  static final keyPattern = RegExp(r'^[a-f0-9]{64}$');
  static final _control = RegExp(r'[\x00-\x1f\x7f-\x9f]');
  final String key;
  final String revision;
  final String title;
  final String? artist;
  final String? fileName;
  final String? storageProof;

  const _HiddenFile(this.key, this.revision, this.title, this.artist,
      this.fileName, this.storageProof);

  factory _HiddenFile.fromTrack(
      String key, LocalMusicTrack track, String? storageProof) {
    final name = _name(track.fileName);
    return _HiddenFile(
      key,
      const Uuid().v4(),
      _text(track.title) ?? name ?? 'Audio',
      _text(track.artist),
      name,
      _proof(storageProof),
    );
  }

  _HiddenFile withStorageProof(String proof) =>
      _HiddenFile(key, revision, title, artist, fileName, proof);

  static String? _proof(Object? value) =>
      value is String && keyPattern.stringMatch(value) == value ? value : null;

  static _HiddenFile? parse(Object? row) {
    if (row is! Map) return null;
    final key = row['key'];
    final revision = row['revision'];
    final title = _text(row['title']);
    if (key is! String ||
        !keyPattern.hasMatch(key) ||
        revision is! String ||
        revision.length != 36 ||
        title == null) {
      return null;
    }
    return _HiddenFile(key, revision, title, _text(row['artist']),
        _name(row['fileName']), _proof(row['storageProof']));
  }

  static String? _text(Object? value) {
    if (value is! String) return null;
    final clean = value.replaceAll(_control, ' ').trim();
    if (clean.isEmpty) return null;
    return String.fromCharCodes(clean.runes.take(1024));
  }

  static String? _name(Object? value) {
    final name = _text(value);
    return name != null && !name.contains('/') && !name.contains(r'\')
        ? name
        : null;
  }

  Map<String, String?> toJson() => {
        'key': key,
        'revision': revision,
        'title': title,
        'artist': artist,
        'fileName': fileName,
        if (storageProof != null) 'storageProof': storageProof,
      };
}

class _HiddenChanges {
  String? stored;
  Map<String, _HiddenFile> files = const {};
  String? storedExclusions;
  _ExclusionRules exclusions = const (
    recordings: false,
    folders: <String, LocalMusicFolderLocation>{},
    kept: <String>{},
  );
  Future<void> writes = Future.value();
}

/// The active person's visibility decisions, stored in their app database.
/// The records carry opaque identity proofs and display text only.
class LocalMusicVisibility {
  static const _setting = 'device-music-hidden-files-v1';
  static const _exclusionSetting = 'device-music-exclusions-v1';
  static final _byDatabase = Expando<Map<String, _HiddenChanges>>();
  final LocalMusicVisibilityOwner owner;
  final IDbClient _database;
  final _HiddenChanges _changes;

  LocalMusicVisibility(this.owner)
      : _database = owner.database.forProfile(owner.profileId),
        _changes = (_byDatabase[owner.database] ??= {})
            .putIfAbsent(owner.profileId, _HiddenChanges.new);

  Map<String, _HiddenFile> _read() {
    final stored = _database.getSettings(_setting)?.value;
    if (stored == _changes.stored) return _changes.files;
    final files = <String, _HiddenFile>{};
    try {
      final value = jsonDecode(stored ?? 'null');
      if (value is List) {
        for (final row in value) {
          final file = _HiddenFile.parse(row);
          if (file != null) files[file.key] = file;
        }
      }
    } on FormatException {
      // A damaged preference cannot hide a file.
    }
    _changes.stored = stored;
    return _changes.files = files;
  }

  bool contains(String? key) => _read().containsKey(key);

  Set<String> get hiddenStorageProofs =>
      _read().values.map((file) => file.storageProof).nonNulls.toSet();

  _ExclusionRules _readExclusions() {
    final stored = _database.getSettings(_exclusionSetting)?.value;
    if (stored == _changes.storedExclusions) return _changes.exclusions;
    var recordings = false;
    final folders = <String, LocalMusicFolderLocation>{};
    final kept = <String>{};
    try {
      if (jsonDecode(stored ?? 'null') case final Map data) {
        recordings = data['recordings'] == true;
        if (data['folders'] case final Map saved) {
          for (final entry in saved.entries) {
            final key = _HiddenFile._proof(entry.key);
            final label = _HiddenFile._text(entry.value);
            if (key != null && label != null) {
              folders[key] = LocalMusicFolderLocation(key, label);
            }
          }
        }
        if (data['kept'] case final List saved) {
          kept.addAll(saved.map(_HiddenFile._proof).nonNulls);
        }
      }
    } on FormatException {
      // An unreadable setting cannot exclude a file.
    }
    _changes.storedExclusions = stored;
    return _changes.exclusions = (
      recordings: recordings,
      folders: folders,
      kept: kept,
    );
  }

  bool get excludesRecordings => _readExclusions().recordings;

  Iterable<LocalMusicFolderLocation> get savedFolders =>
      _readExclusions().folders.values;

  bool isFolderExcluded(String key) =>
      _readExclusions().folders.containsKey(key);

  bool hasOverride(LocalMusicTrack track) =>
      _readExclusions().kept.contains(track.visibilityKey);

  bool isExcluded(LocalMusicTrack track) =>
      !_read().containsKey(track.visibilityKey) &&
      _isExcluded(track, _readExclusions());

  bool _isExcluded(LocalMusicTrack track, _ExclusionRules rules) =>
      !rules.kept.contains(track.visibilityKey) &&
      (rules.recordings && track.isRecording ||
          track.folderLocations
              .any((folder) => rules.folders.containsKey(folder.key)));

  List<LocalMusicTrack> excluded(List<LocalMusicTrack> tracks) {
    final rules = _readExclusions();
    if (!rules.recordings && rules.folders.isEmpty) return const [];
    final files = _read();
    return List.unmodifiable(tracks.where((track) =>
        !files.containsKey(track.visibilityKey) && _isExcluded(track, rules)));
  }

  List<LocalMusicTrack> visible(List<LocalMusicTrack> tracks) {
    final files = _read();
    final rules = _readExclusions();
    if (files.isEmpty && !rules.recordings && rules.folders.isEmpty) {
      return tracks;
    }
    return List.unmodifiable(tracks.where((track) =>
        !files.containsKey(track.visibilityKey) && !_isExcluded(track, rules)));
  }

  bool isVisible(LocalMusicTrack track) =>
      !_read().containsKey(track.visibilityKey) &&
      !_isExcluded(track, _readExclusions());

  Future<bool> setExcludeRecordings(bool value, bool Function() active) =>
      _serialize(() async {
        if (!active()) return false;
        final rules = _readExclusions();
        if (rules.recordings == value) return false;
        await _saveExclusions(
            (recordings: value, folders: rules.folders, kept: rules.kept));
        return true;
      });

  Future<bool> setFolderExcluded(LocalMusicFolderLocation folder, bool value,
          bool Function() eligible) =>
      _serialize(() async {
        if (!eligible()) return false;
        final key = _HiddenFile._proof(folder.key);
        final label = _HiddenFile._text(folder.label);
        if (key == null || label == null) return false;
        final rules = _readExclusions();
        if (rules.folders.containsKey(key) == value) return false;
        final folders = Map.of(rules.folders);
        if (value) {
          folders[key] = LocalMusicFolderLocation(key, label);
        } else {
          folders.remove(key);
        }
        await _saveExclusions(
            (recordings: rules.recordings, folders: folders, kept: rules.kept));
        return true;
      });

  Future<bool> setOverride(bool value, LocalMusicTrack? Function() eligible) =>
      _serialize(() async {
        final track = eligible();
        final key = _HiddenFile._proof(track?.visibilityKey);
        if (track == null || key == null) return false;
        final rules = _readExclusions();
        if (rules.kept.contains(key) == value ||
            (value && !isExcluded(track))) {
          return false;
        }
        final kept = {...rules.kept};
        if (value) {
          kept.add(key);
        } else {
          kept.remove(key);
        }
        await _saveExclusions(
            (recordings: rules.recordings, folders: rules.folders, kept: kept));
        return true;
      });

  Future<void> _saveExclusions(_ExclusionRules rules) =>
      _database.saveSetting(SettingsValue(
          _exclusionSetting,
          jsonEncode({
            'recordings': rules.recordings,
            'folders': {
              for (final entry in rules.folders.entries)
                entry.key: entry.value.label
            },
            'kept': rules.kept.toList(),
          })));

  List<HiddenLocalMusicTrack> records(Map<String, LocalMusicTrack> available) =>
      List.unmodifiable(_read().values.map(
          (file) => HiddenLocalMusicTrack._(file, owner, available[file.key])));

  Future<HiddenLocalMusicTrack?> hide(LocalMusicTrack? Function() eligible,
          {String? storageProof}) =>
      _serialize(() async {
        final track = eligible();
        final key = track?.visibilityKey;
        if (track == null || key == null) return null;
        final files = _read();
        if (files.containsKey(key)) return null;
        final file = _HiddenFile.fromTrack(key, track, storageProof);
        await _save({...files, key: file});
        return HiddenLocalMusicTrack._(file, owner, track);
      });

  Future<bool> rememberDownloadAliases(
          Map<String, String> Function() eligible) =>
      _serialize(() async {
        final files = Map.of(_read());
        var changed = false;
        for (final entry in eligible().entries) {
          final file = files[entry.key];
          final proof = _HiddenFile._proof(entry.value);
          if (file == null || proof == null || file.storageProof == proof) {
            continue;
          }
          files[entry.key] = file.withStorageProof(proof);
          changed = true;
        }
        if (changed) await _save(files);
        return changed;
      });

  Future<bool> restore(HiddenLocalMusicTrack record, bool Function() active) =>
      _serialize(() async {
        if (record._owner != owner ||
            !active() ||
            _read()[record.id]?.revision != record._file.revision) {
          return false;
        }
        final files = Map.of(_read())..remove(record.id);
        await _save(files);
        return true;
      });

  Future<void> _save(Map<String, _HiddenFile> files) async {
    await _database.saveSetting(
        SettingsValue(_setting, jsonEncode(files.values.toList())));
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final write = _changes.writes.then((_) => action());
    _changes.writes =
        write.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return write;
  }
}
