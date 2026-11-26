import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';
import '../models/music_library_entry.dart';
import '../models/music_recording_rating.dart';

const musicRecordingRatingsSettingName = 'music-recording-ratings-v1';

class _ProfileRatings extends ChangeNotifier {
  Future<void> writes = Future.value();
  String? storedValue;
  Map<String, int> ratings = const {};

  void changed() => notifyListeners();
}

/// A profile's ratings are stored independently of bookmarks and Likes.
class MusicRecordingRatingStore {
  static final _owners = Expando<Map<String, _ProfileRatings>>();

  MusicRecordingRatingStore.forProfile(IDbClient database, String profileId)
      : _database = database.forProfile(profileId),
        _owner = (_owners[database] ??= {})
            .putIfAbsent(profileId, _ProfileRatings.new);

  final IDbClient _database;
  final _ProfileRatings _owner;

  Listenable get changes => _owner;

  Map<String, int> get ratings {
    final stored =
        _database.getSettings(musicRecordingRatingsSettingName)?.value;
    if (stored == _owner.storedValue) return _owner.ratings;
    _owner.storedValue = stored;
    _owner.ratings = const {};
    if (stored == null || stored.length > musicLibraryMaximumBytes) {
      return _owner.ratings;
    }
    try {
      final decoded = jsonDecode(stored);
      if (decoded
          case {'version': 1, 'ratings': final Map<String, dynamic> rows}) {
        _owner.ratings = Map.unmodifiable({
          for (final entry in rows.entries.take(musicLibraryMaximumEntries))
            if (isMusicRecordingRatingId(entry.key) &&
                isValidMusicRecordingRating(entry.value))
              entry.key: entry.value as int,
        });
      }
    } on FormatException {
      // Damaged metadata leaves the rest of the Music library usable.
    }
    return _owner.ratings;
  }

  /// A null rating removes the entry. Stale sessions skip queued writes.
  Future<void> setRating(String recordingId, int? rating,
      {required bool Function() isCurrent}) async {
    if (!isMusicRecordingRatingId(recordingId)) {
      throw ArgumentError('Invalid recording ID');
    }
    if (rating != null && !isValidMusicRecordingRating(rating)) {
      throw ArgumentError.value(rating, 'rating');
    }
    final write = _owner.writes.catchError((Object _) {}).then((_) async {
      if (!isCurrent()) return;
      final current = ratings;
      if (current[recordingId] == rating) return;
      final updated = Map.of(current);
      if (rating == null) {
        updated.remove(recordingId);
      } else {
        updated[recordingId] = rating;
      }
      if (updated.length > musicLibraryMaximumEntries) {
        throw StateError('The recording ratings are full');
      }
      await _database.saveSetting(SettingsValue(
        musicRecordingRatingsSettingName,
        jsonEncode({'version': 1, 'ratings': updated}),
      ));
      _owner.changed();
    });
    _owner.writes = write;
    await write;
  }
}
