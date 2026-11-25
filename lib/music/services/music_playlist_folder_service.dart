import 'dart:convert';

import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/foundation.dart';
import 'package:sembast/sembast.dart';
import 'package:uuid/uuid.dart';

const musicPlaylistFolderSettingName = 'music-playlist-folders-v1';
const musicPlaylistFolderNameLimit = 120;

final _folderIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
final _controlCharacter = RegExp(r'[\x00-\x1f\x7f]');

String? normalizeMusicPlaylistFolderName(Object? value) {
  if (value is! String) return null;
  final name = value.trim();
  return name.isNotEmpty &&
          name.length <= musicPlaylistFolderNameLimit &&
          !_controlCharacter.hasMatch(name)
      ? name
      : null;
}

bool _validFolderId(Object? id) =>
    id is String && _folderIdPattern.stringMatch(id) == id;

class MusicPlaylistFolder {
  final String id;
  final String name;
  final String? parentId;

  const MusicPlaylistFolder._(this.id, this.name, this.parentId);

  static MusicPlaylistFolder? _parse(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final name = normalizeMusicPlaylistFolderName(value['name']);
    if (!_validFolderId(id) || name == null) return null;
    final parent = value['parentId'];
    return MusicPlaylistFolder._(
        id as String, name, _validFolderId(parent) ? parent as String : null);
  }

  Map<String, String> _toJson() => {
        'id': id,
        'name': name,
        if (parentId case final parent?) 'parentId': parent,
      };
}

class MusicPlaylistFolders {
  final Map<String, MusicPlaylistFolder> _folders;
  final Map<PlaylistReference, String> _memberships;

  const MusicPlaylistFolders._(this._folders, this._memberships);

  List<MusicPlaylistFolder> get folders => List.unmodifiable(_folders.values);

  MusicPlaylistFolder? folder(String? id) => _folders[id];

  String? folderFor(PlaylistReference playlist) => _memberships[playlist];

  List<MusicPlaylistFolder> pathTo(String id) {
    final path = <MusicPlaylistFolder>[];
    var current = folder(id);
    while (current != null) {
      path.add(current);
      current = folder(current.parentId);
    }
    return path.reversed.toList();
  }

  bool canMoveFolder(String folderId, String? parentId) =>
      _folders.containsKey(folderId) &&
      (parentId == null ||
          _folders.containsKey(parentId) &&
              !pathTo(parentId).any((folder) => folder.id == folderId));

  static MusicPlaylistFolders _read(String? stored, String profileId) {
    try {
      final value = jsonDecode(stored ?? '{}');
      if (value is Map && value['version'] == 1) {
        final folders = <String, MusicPlaylistFolder>{};
        final rows = value['folders'];
        if (rows is List) {
          for (final row in rows.take(musicLibraryMaximumEntries)) {
            if (MusicPlaylistFolder._parse(row) case final folder?) {
              folders.putIfAbsent(folder.id, () => folder);
            }
          }
        }
        _repairParents(folders);
        final memberships = <PlaylistReference, String>{};
        final assignments = value['memberships'];
        if (assignments is List) {
          for (final row in assignments.take(musicLibraryMaximumEntries)) {
            if (row is! Map) continue;
            final playlist = PlaylistReference.tryParse(row['playlist']);
            final folderId = row['folderId'];
            if (playlist != null &&
                playlist.profileId == profileId &&
                playlist.kind != PlaylistSourceKind.account &&
                folderId is String &&
                folders.containsKey(folderId)) {
              memberships[playlist] = folderId;
            }
          }
        }
        return MusicPlaylistFolders._(folders, memberships);
      }
    } on FormatException {
      // Optional folder metadata must not prevent opening existing playlists.
    }
    return const MusicPlaylistFolders._({}, {});
  }

  static void _repairParents(Map<String, MusicPlaylistFolder> folders) {
    final checked = <String>{};
    for (final folder in folders.values) {
      final path = <String>{};
      var current = folder;
      while (!checked.contains(current.id)) {
        final parentId = current.parentId;
        if (parentId == null) break;
        path.add(current.id);
        final parent = folders[parentId];
        if (parent == null || path.contains(parentId)) {
          folders[current.id] =
              MusicPlaylistFolder._(current.id, current.name, null);
          break;
        }
        current = parent;
      }
      checked.addAll(path);
    }
  }

  String _encode() => jsonEncode({
        'version': 1,
        'folders': _folders.values.map((folder) => folder._toJson()).toList(),
        'memberships': [
          for (final MapEntry(key: playlist, value: folderId)
              in _memberships.entries)
            {
              'playlist': {
                'kind': playlist.kind.name,
                'playlistId': playlist.playlistId,
                'profileId': playlist.profileId,
              },
              'folderId': folderId,
            },
        ],
      });
}

class _ProfileFolders extends ChangeNotifier {
  Future<void> writes = Future.value();
  String? stored;
  MusicPlaylistFolders snapshot = const MusicPlaylistFolders._({}, {});

  void changed() => notifyListeners();
}

/// Profile-local organization of saved Music playlists by their existing
/// source identities. Playlist data and playback state live in their own stores.
class MusicPlaylistFolderService {
  static final _owners = Expando<Map<String, _ProfileFolders>>();
  final IDbClient _database;
  final _ProfileFolders _changes;

  MusicPlaylistFolderService.forProfile(IDbClient database, String profileId)
      : _database = database.forProfile(profileId),
        _changes =
            (_owners[database is SembastSqfDb ? database.db : database] ??= {})
                .putIfAbsent(profileId, _ProfileFolders.new);

  Listenable get changes => _changes;

  MusicPlaylistFolders get snapshot {
    final stored = _database.getSettings(musicPlaylistFolderSettingName)?.value;
    if (_changes.stored != stored) {
      _changes.stored = stored;
      _changes.snapshot =
          MusicPlaylistFolders._read(stored, _database.profileId);
    }
    return _changes.snapshot;
  }

  Future<MusicPlaylistFolder> createFolder(String name,
          {String? parentId, bool Function()? isCurrent}) =>
      _write((data) {
        _requireDestination(data, parentId);
        final folder = MusicPlaylistFolder._(
            const Uuid().v4(), _requireName(name), parentId);
        data._folders[folder.id] = folder;
        return folder;
      }, isCurrent: isCurrent);

  Future<void> renameFolder(String folderId, String name,
          {bool Function()? isCurrent}) =>
      _write((data) {
        final folder = _requireFolder(data, folderId);
        data._folders[folderId] = MusicPlaylistFolder._(
            folderId, _requireName(name), folder.parentId);
      }, isCurrent: isCurrent);

  Future<void> moveFolder(String folderId, String? parentId,
          {bool Function()? isCurrent}) =>
      _write((data) {
        final folder = _requireFolder(data, folderId);
        if (!data.canMoveFolder(folderId, parentId)) {
          throw StateError('Choose a valid destination folder');
        }
        data._folders[folderId] =
            MusicPlaylistFolder._(folderId, folder.name, parentId);
      }, isCurrent: isCurrent);

  Future<void> removeFolder(String folderId, {bool Function()? isCurrent}) =>
      _write((data) {
        final parentId = _requireFolder(data, folderId).parentId;
        data._folders.remove(folderId);
        data._folders.updateAll((id, folder) => folder.parentId == folderId
            ? MusicPlaylistFolder._(id, folder.name, parentId)
            : folder);
        if (parentId == null) {
          data._memberships.removeWhere((_, assigned) => assigned == folderId);
        } else {
          data._memberships.updateAll(
              (_, assigned) => assigned == folderId ? parentId : assigned);
        }
      }, isCurrent: isCurrent);

  Future<void> movePlaylist(PlaylistReference playlist, String? folderId,
          {bool Function()? isCurrent}) =>
      _write((data) {
        final reference = PlaylistReference.tryParse(playlist.toJson());
        if (reference == null ||
            !reference.matchesOwner(_database) ||
            reference.kind == PlaylistSourceKind.account) {
          throw StateError('Choose a playlist saved in this Music library');
        }
        _requireDestination(data, folderId);
        if (folderId == null) {
          data._memberships.remove(reference);
        } else {
          data._memberships[reference] = folderId;
        }
      }, isCurrent: isCurrent);

  static String _requireName(String name) =>
      normalizeMusicPlaylistFolderName(name) ??
      (throw ArgumentError('Choose a valid folder name'));

  static MusicPlaylistFolder _requireFolder(
          MusicPlaylistFolders data, String id) =>
      data.folder(id) ?? (throw StateError('The folder is unavailable'));

  static void _requireDestination(MusicPlaylistFolders data, String? id) {
    if (id != null) _requireFolder(data, id);
  }

  Future<T> _write<T>(T Function(MusicPlaylistFolders) update,
      {bool Function()? isCurrent}) {
    final write = _changes.writes.then((_) async {
      _requireCurrent(isCurrent);
      final current = snapshot;
      final data = MusicPlaylistFolders._(
          Map.of(current._folders), Map.of(current._memberships));
      final result = update(data);
      final value = data._encode();
      if (data._folders.length > musicLibraryMaximumEntries ||
          data._memberships.length > musicLibraryMaximumEntries ||
          utf8.encode(value).length > musicLibraryMaximumBytes) {
        throw StateError('The playlist folder library is full');
      }
      if (value != _changes.stored) {
        await _persist(
            SettingsValue(musicPlaylistFolderSettingName, value), isCurrent);
        _changes.changed();
      }
      return result;
    });
    _changes.writes = write.then<void>((_) {}, onError: (_, __) {});
    return write;
  }

  Future<void> _persist(
      SettingsValue setting, bool Function()? isCurrent) async {
    final database = _database;
    if (database is SembastSqfDb) {
      await database.db.transaction((transaction) async {
        await database.ensureProfileExists(transaction);
        _requireCurrent(isCurrent);
        await database.settingsStore
            .record(setting.name)
            .put(transaction, setting.toJson());
      });
    } else {
      _requireCurrent(isCurrent);
      await database.saveSetting(setting);
    }
  }

  static void _requireCurrent(bool Function()? isCurrent) {
    if (isCurrent?.call() == false) {
      throw StateError('The Music library selection changed');
    }
  }
}
