import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sembast/sembast.dart';

import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';
import '../../utils/sembast_sqflite_database.dart';
import '../../videos/models/db/progress.dart';
import '../../videos/models/video.dart';
import '../models/playlist_reference.dart';

const playlistProgressSettingName = 'playlist-progress-v1';
const _maximumCheckpoints = 500;

Map<String, dynamic> _readProgress(String? stored) {
  try {
    final value = jsonDecode(stored ?? '{}');
    if (value is Map<String, dynamic> &&
        value['version'] == 1 &&
        value['epoch'] is int &&
        (value['epoch'] as int) >= 0 &&
        value['entries'] is List) {
      return value;
    }
  } on FormatException {
    // Broken optional progress must never prevent opening the library.
  }
  return {'version': 1, 'epoch': 0, 'entries': <dynamic>[]};
}

/// Use inside the history mutation's transaction. Retain an epoch tombstone so
/// an already queued checkpoint cannot resurrect cleared history afterward.
String resetPlaylistProgress(String? stored, {String? videoId}) {
  final data = _readProgress(stored);
  return jsonEncode({
    'version': 1,
    'epoch': (data['epoch'] as int) + 1,
    'entries': videoId == null
        ? []
        : (data['entries'] as List)
            .where((value) => value is Map && value['videoId'] != videoId)
            .toList(),
  });
}

class PlaylistResumeTarget {
  final int index;
  final Video video;

  /// The original entry disappeared; ask before continuing at its successor.
  final bool missing;

  const PlaylistResumeTarget(this.index, this.video, {this.missing = false});
}

class _EntryIdentity {
  final String entryId;
  final String videoId;
  final String? indexId;
  final int occurrence;
  final int indexHint;

  const _EntryIdentity(this.entryId, this.videoId, this.indexId,
      this.occurrence, this.indexHint);

  static _EntryIdentity? tryParse(Object? value) {
    if (value is! Map) return null;
    final entry = value['entryId'];
    final video = value['videoId'];
    final indexId = value['indexId'];
    final occurrence = value['occurrence'];
    final index = value['indexHint'];
    if (entry is! String ||
        entry.isEmpty ||
        entry.length > 8192 ||
        video is! String ||
        video.isEmpty ||
        video.length > 2048 ||
        (indexId != null && (indexId is! String || indexId.length > 2048)) ||
        occurrence is! int ||
        occurrence < 0 ||
        index is! int ||
        index < 0) {
      return null;
    }
    return _EntryIdentity(entry, video, indexId as String?, occurrence, index);
  }

  static _EntryIdentity at(List<Video> entries, int index) {
    final video = entries[index];
    var stableId = video.indexId;
    // Older queue snapshots preserved only the occurrence key. Its stable
    // source ID still identifies a repeated entry after the playlist changes.
    if (stableId == null && video.queueEntryId!.startsWith('playlist:')) {
      try {
        final key =
            jsonDecode(video.queueEntryId!.substring('playlist:'.length));
        if (key is List &&
            key.length == 3 &&
            key[0] == 'id' &&
            key[1] is String &&
            key[2] == video.videoId) {
          stableId = key[1] as String;
        }
      } on FormatException {
        // Non-source queue IDs continue to use duplicate occurrence matching.
      }
    }
    return _EntryIdentity(
        video.queueEntryId!,
        video.videoId,
        stableId,
        entries
            .take(index)
            .where((entry) => entry.videoId == video.videoId)
            .length,
        index);
  }

  Map<String, dynamic> toJson() => {
        'entryId': entryId,
        'videoId': videoId,
        if (indexId != null) 'indexId': indexId,
        'occurrence': occurrence,
        'indexHint': indexHint,
      };

  int locate(List<Video> entries) {
    if (indexId != null && indexId!.isNotEmpty) {
      final index = entries.indexWhere(
          (entry) => entry.indexId == indexId && entry.videoId == videoId);
      if (index >= 0) return index;
      // A different stable ID means a different occurrence of the same upload.
      if (entries
          .any((entry) => entry.videoId == videoId && entry.indexId != null)) {
        return -1;
      }
    }
    final candidates = <int>[
      for (var i = 0; i < entries.length; i++)
        if (entries[i].videoId == videoId) i,
    ];
    if (occurrence < candidates.length) return candidates[occurrence];
    return -1;
  }
}

class PlaylistCheckpoint {
  final PlaylistReference reference;
  final _EntryIdentity _entry;
  final List<_EntryIdentity> _successors;
  final bool completed;

  /// Old checkpoints omit the mode and retain the usual media-type inference.
  final bool? audio;

  const PlaylistCheckpoint._(this.reference, this._entry, this._successors,
      this.completed, this.audio);

  String get entryId => _entry.entryId;
  String get videoId => _entry.videoId;
  String? get indexId => _entry.indexId;
  int get occurrence => _entry.occurrence;
  int get indexHint => _entry.indexHint;

  static PlaylistCheckpoint? tryParse(Object? value) {
    if (value is! Map) return null;
    final reference = PlaylistReference.tryParse(value['reference']);
    final entry = _EntryIdentity.tryParse(value);
    final successors = value['successors'];
    if (reference == null ||
        entry == null ||
        value['completed'] is! bool ||
        (value['audio'] != null && value['audio'] is! bool) ||
        successors is! List ||
        successors.length > 32) {
      return null;
    }
    return PlaylistCheckpoint._(
        reference,
        entry,
        successors
            .map(_EntryIdentity.tryParse)
            .whereType<_EntryIdentity>()
            .toList(),
        value['completed'] as bool,
        value['audio'] as bool?);
  }

  Map<String, dynamic> toJson() => {
        'reference': reference.toJson(),
        ..._entry.toJson(),
        'completed': completed,
        if (audio != null) 'audio': audio,
        'successors': _successors.map((entry) => entry.toJson()).toList(),
      };

  PlaylistResumeTarget? resolve(List<Video> videos) {
    final entries = assignPlaylistEntryIds(videos);
    bool playable(Video video) =>
        !video.filtered && !video.filterHide && video.isUpcoming != true;
    final current = _entry.locate(entries);
    if (current >= 0) {
      if (!completed && playable(entries[current])) {
        return PlaylistResumeTarget(current, entries[current]);
      }
      for (var i = current + 1; i < entries.length; i++) {
        if (playable(entries[i])) {
          return PlaylistResumeTarget(i, entries[i], missing: !completed);
        }
      }
      return null;
    }
    // Use saved neighbors, never the unrelated upload now at the old index.
    for (final successor in _successors) {
      final index = successor.locate(entries);
      if (index >= 0 && playable(entries[index])) {
        return PlaylistResumeTarget(index, entries[index], missing: true);
      }
    }
    return null;
  }
}

class _ProfileWrites extends ChangeNotifier {
  Future<void> writes = Future.value();
  void changed() => notifyListeners();
}

/// Playlist cursors contain no second copy of video playback time. Resume reads
/// the current profile's canonical video progress when the user requests it.
class PlaylistProgressService {
  static final _owners = Expando<Map<String, _ProfileWrites>>();
  final IDbClient _database;
  final _ProfileWrites _changes;

  PlaylistProgressService.forProfile(IDbClient database, String profileId)
      : _database = database.forProfile(profileId),
        _changes =
            (_owners[database is SembastSqfDb ? database.db : database] ??= {})
                .putIfAbsent(profileId, _ProfileWrites.new);

  String get profileId => _database.profileId;
  Listenable get changes => _changes;

  List<PlaylistCheckpoint> _entries(Map<String, dynamic> data) =>
      (data['entries'] as List)
          .map(PlaylistCheckpoint.tryParse)
          .whereType<PlaylistCheckpoint>()
          .where((checkpoint) => checkpoint.reference.profileId == profileId)
          .take(_maximumCheckpoints)
          .toList();

  PlaylistCheckpoint? get(PlaylistReference reference) {
    if (!reference.matchesOwner(_database)) return null;
    return _entries(_readProgress(
            _database.getSettings(playlistProgressSettingName)?.value))
        .where((checkpoint) => checkpoint.reference == reference)
        .firstOrNull;
  }

  /// Returns whether the checkpoint committed. A history edit can reject an
  /// already queued save, so callers must not cache a rejected write as saved.
  Future<bool> save(PlaylistReference reference, Video video,
      {List<Video>? entries,
      bool completed = false,
      bool? audio,
      int? watchRevision,
      bool Function()? isCurrent}) {
    if (!reference.matchesOwner(_database)) {
      return Future.error(
          StateError('The playlist belongs to another profile'));
    }
    final ordered = assignPlaylistEntryIds(entries ?? [video]);
    var index = ordered.indexWhere((entry) =>
        entry.videoId == video.videoId &&
        entry.queueEntryId == video.queueEntryId);
    if (index < 0 && video.indexId != null) {
      index = ordered.indexWhere((entry) =>
          entry.videoId == video.videoId && entry.indexId == video.indexId);
    }
    if (index < 0 && entries != null && video.queueEntryId != null) {
      return Future.value(false);
    }
    if (index < 0) {
      index = ordered.indexWhere((entry) => entry.videoId == video.videoId);
    }
    if (index < 0) return Future.value(false);
    final checkpoint = PlaylistCheckpoint._(
        reference,
        _EntryIdentity.at(ordered, index),
        [
          for (var i = index + 1; i < ordered.length && i <= index + 32; i++)
            _EntryIdentity.at(ordered, i),
        ],
        completed,
        audio);
    final epoch = _readProgress(
        _database.getSettings(playlistProgressSettingName)?.value)['epoch'];
    return _write((data) {
      if (data['epoch'] != epoch) return null;
      final checkpoints = _entries(data)
        ..removeWhere((entry) => entry.reference == reference);
      checkpoints.insert(0, checkpoint);
      return jsonEncode({
        'version': 1,
        'epoch': epoch,
        'entries': checkpoints
            .take(_maximumCheckpoints)
            .map((entry) => entry.toJson())
            .toList(),
      });
    },
        videoId: video.videoId,
        watchRevision: watchRevision,
        isCurrent: isCurrent);
  }

  Future<void> remove(PlaylistReference reference) => _write((data) {
        if (!reference.matchesOwner(_database)) return null;
        return jsonEncode({
          'version': 1,
          'epoch': (data['epoch'] as int) + 1,
          'entries': _entries(data)
              .where((entry) => entry.reference != reference)
              .map((entry) => entry.toJson())
              .toList(),
        });
      }).then((_) {});

  Future<void> removeForVideo(String videoId) => _write(
          (data) => resetPlaylistProgress(jsonEncode(data), videoId: videoId))
      .then((_) {});

  Future<void> clear() =>
      _write((data) => resetPlaylistProgress(jsonEncode(data))).then((_) {});

  Future<bool> _write(String? Function(Map<String, dynamic>) update,
      {String? videoId, int? watchRevision, bool Function()? isCurrent}) {
    var changed = false;
    final write =
        _changes.writes = _changes.writes.catchError((_) {}).then((_) async {
      if (isCurrent?.call() == false) return;
      final database = _database;
      if (database is SembastSqfDb) {
        await database.db.transaction((transaction) async {
          await database.ensureProfileExists(transaction);
          if (isCurrent?.call() == false) return;
          if (watchRevision != null && videoId != null) {
            final state = await stringMapStoreFactory
                .store('watchState:$profileId')
                .record(videoId)
                .get(transaction);
            final revision = state?['revision'];
            if ((revision != null && revision is! num) ||
                ((revision as num?)?.toInt() ?? 0) != watchRevision) {
              return;
            }
          }
          final record =
              database.settingsStore.record(playlistProgressSettingName);
          final stored = await record.get(transaction);
          final value = update(_readProgress(stored?['value'] as String?));
          if (value == null || isCurrent?.call() == false) return;
          await record.put(transaction,
              SettingsValue(playlistProgressSettingName, value).toJson());
          changed = true;
        });
      } else {
        final value = update(_readProgress(
            database.getSettings(playlistProgressSettingName)?.value));
        if (value != null && isCurrent?.call() != false) {
          await database
              .saveSetting(SettingsValue(playlistProgressSettingName, value));
          changed = true;
        }
      }
      if (changed) {
        _changes.changed();
        playbackHistoryRevision.value++;
      }
    });
    return write.then((_) => changed);
  }
}
