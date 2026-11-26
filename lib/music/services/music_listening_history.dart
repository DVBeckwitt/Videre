import 'package:flutter/foundation.dart';

import '../../player/models/local_music_playback.dart';
import '../../utils/interfaces/db.dart';
import '../../videos/models/db/progress.dart';
import '../models/music_listening_event.dart';

export '../models/music_listening_event.dart';

String musicListeningTrackId(String playbackId) =>
    isLocalMusicPlaybackId(playbackId)
        ? localMusicTrackId(playbackId)
        : playbackId;

/// A captured profile's local Music history, separate from learning and the
/// Invidious account's combined history.
class MusicListeningHistory {
  MusicListeningHistory.forProfile(IDbClient database, String profileId)
      : _database = database.forProfile(profileId);

  final IDbClient _database;

  Listenable get changes => playbackHistoryRevision;

  bool get recordingPaused => _database.musicHistoryRecordingPaused;

  Future<void> setRecordingPaused(bool paused) =>
      _database.setMusicHistoryRecordingPaused(paused);

  List<MusicListeningEvent> events({String? trackId}) =>
      _database.getMusicListeningEvents(trackId: trackId);

  /// Recordings with only unmeasured events have no total.
  Map<String, Duration> listenedTimeByTrack() {
    final totals = <String, Duration>{};
    for (final event in events()) {
      final elapsed = event.elapsed;
      if (elapsed == null) continue;
      totals.update(event.trackId, (total) => total + elapsed,
          ifAbsent: () => elapsed);
    }
    return totals;
  }

  Future<void> removeTracks(Set<String> trackIds) =>
      _database.removeMusicListeningTracks(trackIds);

  Future<void> removeEvents(Iterable<MusicListeningEvent> events) =>
      _database.removeMusicListeningEvents(events);

  Future<void> clear() => _database.removeMusicListeningTracks(null);

  /// Import explicit history without changing the automatic recording setting.
  Future<int> merge(Iterable<MusicListeningEvent> events) =>
      _database.mergeMusicListeningEvents(events);
}
