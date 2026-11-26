import 'dart:convert';

import 'package:clipious/music/services/music_listening_history.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/utils/backup.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

const _song = 'abcdefghijk';
const _other = 'zbcdefghijk';
final _device = 'device:${'a' * 64}';
const _music = PlaybackHistoryOrigin.music;
const _video = PlaybackHistoryOrigin.video;

HistoryVideoCache _entry(String id, int day, {String? account}) =>
    HistoryVideoCache(id, 'Song', 'Artist', '',
        musicMetadata: const MusicMetadata(
            title: 'Song', artist: 'Artist', album: 'Album'),
        playedFromDownload: account != null,
        downloadAccountId: account)
      ..created = DateTime.utc(2026, 11, day);

void main() {
  late SembastSqfDb database;
  late MusicListeningHistory history;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    history = MusicListeningHistory.forProfile(database, database.profileId);
  });

  test('legacy latest dates coexist with confirmed plays and device identity',
      () async {
    await database.recordPlaybackHistory(_music, _entry(_song, 2));
    await database.recordPlaybackHistory(_video, _entry(_other, 3));
    final first = database.beginMusicListening(_song)!;
    await first.record(_entry(_song, 10));
    await first.record(_entry(_song, 11));
    await database.beginMusicListening(_song)!.record(_entry(_song, 12));
    final trackId = musicListeningTrackId('$_device#occurrence');
    await database.beginMusicListening(trackId)!.record(_entry(trackId, 13));

    final timeline = history.events(trackId: _song);
    expect(timeline.map((event) => event.playedAt.day), [12, 10, 2]);
    expect(timeline.map((event) => event.isLegacy), [false, false, true]);
    expect(timeline.map((event) => event.id).toSet(), hasLength(3));
    expect(history.events().first.trackId, _device);
    expect(history.events().first.source, MusicListeningSource.device);
    expect(database.getPlaybackHistory(_music).single.created.day, 12);
    expect(database.getPlaybackHistory(_video).single.videoId, _other);
  });

  test('pause and deletion fence pending writes for the captured profile',
      () async {
    final original = database.profileId;
    final other = await database.createProfile('Other');
    final pausedPlay = database.beginMusicListening(_song)!;
    await history.setRecordingPaused(true);
    expect(history.recordingPaused, isTrue);
    expect(database.beginMusicListening(_song), isNull);
    await database.recordPlaybackHistory(_video, _entry(_song, 5));
    await history.setRecordingPaused(false);
    await pausedPlay.record(_entry(_song, 6));
    expect(history.events(), isEmpty);

    await database.recordPlaybackHistory(_music, _entry(_song, 7));
    await database.beginMusicListening(_song)!.record(_entry(_song, 8));
    await database.beginMusicListening(_other)!.record(_entry(_other, 9));
    final pending = database.beginMusicListening(_song)!;
    await database.useProfile(other.id);
    final otherHistory = MusicListeningHistory.forProfile(database, other.id);
    await database.beginMusicListening(_song)!.record(_entry(_song, 10));
    await history.removeTracks({_song});
    await pending.record(_entry(_song, 11));
    expect(history.events().single.trackId, _other);
    expect(otherHistory.events().single.trackId, _song);
    await history.clear();
    expect(history.events(), isEmpty);
    expect(
        database.forProfile(original).getPlaybackHistory(_video), hasLength(1));
    expect(otherHistory.events(), hasLength(1));
    await database.deleteProfile(original);
    expect(() => history.events(), throwsStateError);
  });

  test('totals use measured time per occurrence and retain measured zero',
      () async {
    await database.recordPlaybackHistory(_music, _entry(_song, 2));
    await database.beginMusicListening(_device)!.record(_entry(_device, 3));
    final first = database.beginMusicListening(_song)!;
    await Future.wait([
      first.record(_entry(_song, 4), trackElapsed: true),
      first.recordListeningTime(const Duration(seconds: 4)),
      first.recordListeningTime(const Duration(seconds: 2)),
    ]);
    first.cancel();
    final second = database.beginMusicListening(_song)!;
    await second.record(_entry(_song, 5), trackElapsed: true);
    await second.recordListeningTime(const Duration(milliseconds: 1500));
    second.cancel();
    final skipped = database.beginMusicListening(_other)!;
    await skipped.record(_entry(_other, 6), trackElapsed: true);
    skipped.cancel();

    expect(history.events(trackId: _song).map((event) => event.elapsed),
        [const Duration(milliseconds: 1500), const Duration(seconds: 4), null]);
    expect(history.listenedTimeByTrack(), {
      _song: const Duration(milliseconds: 5500),
      _other: Duration.zero,
    });
  });

  test('privacy edits fence elapsed writes for an already started event',
      () async {
    const observed = Duration(seconds: 3);
    const stale = Duration(seconds: 30);
    final first = database.beginMusicListening(_song)!;
    await first.record(_entry(_song, 4), trackElapsed: true);
    await first.recordListeningTime(observed);
    await history.setRecordingPaused(true);
    await first.recordListeningTime(stale);
    await history.setRecordingPaused(false);
    await first.recordListeningTime(stale);
    expect(history.events().single.elapsed, observed);

    final next = database.beginMusicListening(_other)!;
    await next.record(_entry(_other, 5), trackElapsed: true);
    await next.recordListeningTime(observed);
    final backup = await database.exportBackup();
    await database.restoreBackup(backup, replace: true);
    await next.recordListeningTime(stale);
    expect(history.events(trackId: _other).single.elapsed, observed);

    final cleared = database.beginMusicListening(_song)!;
    await cleared.record(_entry(_song, 6), trackElapsed: true);
    final removed = history.events(trackId: _song).first;
    await history.removeTracks({_song});
    await cleared.recordListeningTime(stale);
    expect(history.events(trackId: _song), isEmpty);
    expect(await history.merge([removed]), 1);
    await cleared.recordListeningTime(stale);
    expect(history.events(trackId: _song).single.elapsed, Duration.zero);
    expect(history.events(trackId: _other).single.elapsed, observed);
  });

  test('portable history round-trips and merges repeated plays by event ID',
      () async {
    await database.recordPlaybackHistory(_music, _entry(_song, 2));
    final playlist = PlaylistReference(
        kind: PlaylistSourceKind.public,
        playlistId: 'PLcollection',
        profileId: database.profileId,
        displayTitle: 'Collection');
    final measured = database.beginMusicListening(_song)!;
    await measured.record(_entry(_song, 11),
        playlist: playlist, trackElapsed: true);
    await measured.recordListeningTime(const Duration(microseconds: 2345678));
    measured.cancel();
    await database
        .beginMusicListening(_song)!
        .record(_entry(_song, 12, account: 'private-download-owner'));
    await database.beginMusicListening(_device)!.record(_entry(_device, 13));

    final text = (await database.exportBackup()).encode();
    expect(text, isNot(contains('private-download-owner')));
    final restored = await database.createProfile('Restored');
    final owner = database.forProfile(restored.id);
    final restoredHistory =
        MusicListeningHistory.forProfile(owner, restored.id);
    await restoredHistory.setRecordingPaused(true);
    final backup = UserBackup.parse(text);
    await owner.restoreBackup(backup, replace: true);
    await owner.restoreBackup(backup);
    expect(restoredHistory.recordingPaused, isTrue);
    final events = restoredHistory.events();
    expect(events.map((event) => event.id),
        history.events().map((event) => event.id));
    expect(events[1].source, MusicListeningSource.download);
    expect(events[1].entry.playedFromDownload, isFalse);
    expect(events[2].playlist?.profileId, restored.id);
    expect(events[2].playlist?.displayTitle, 'Collection');
    expect(events.map((event) => event.elapsed), [
      null,
      null,
      const Duration(microseconds: 2345678),
      null,
    ]);

    final old = jsonDecode(text) as Map<String, dynamic>;
    old.remove('musicListeningEvents');
    await owner.restoreBackup(UserBackup.parse(jsonEncode(old)), replace: true);
    expect(restoredHistory.events().single.isLegacy, isTrue);
  });

  test('explicit import while paused deduplicates only overlapping snapshots',
      () async {
    await database.recordPlaybackHistory(_music, _entry(_song, 2));
    await database.beginMusicListening(_song)!.record(_entry(_song, 4));
    await history.setRecordingPaused(true);
    final snapshots = [
      for (final day in [2, 3, 4, 5])
        MusicListeningEvent.legacy(_entry(_song, day)),
    ];
    expect(await history.merge(snapshots), 2);
    expect(await history.merge(snapshots), 0);
    expect(history.recordingPaused, isTrue);
    expect(history.events().map((event) => event.playedAt.day), [5, 4, 3, 2]);
    expect(history.events().map((event) => event.isLegacy),
        [true, false, true, true]);
  });
}
