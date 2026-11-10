import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_progress.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/services/watch_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy progress resumes from its fraction and preserves its JSON', () {
    final json = {'videoId': 'video', 'progress': 0.35};
    final progress = Progress.fromJson(json);
    expect(progress.toJson(), json);
    expect(progress.resumePosition(durationSeconds: 200),
        const Duration(seconds: 70));
    expect(Progress(1, 'video').resumePosition(durationSeconds: 200),
        Duration.zero);
    expect(Progress(0.35, 'video').resumePosition(), Duration.zero);
  });

  test('precise resume survives the watched threshold and a shorter edit', () {
    final progress = Progress.fromJson({
      'videoId': 'video',
      'progress': 1,
      'positionSeconds': 950,
      'durationSeconds': 1000,
    });
    expect(progress.resumePosition(), const Duration(seconds: 950));
    expect(progress.resumePosition(durationSeconds: 900),
        const Duration(seconds: 900));
    final restored = Progress.fromJson(progress.toJson());
    expect(restored.positionSeconds, 950);
    expect(restored.durationSeconds, 1000);
    expect(restored.progress, 1);
  });

  test('a seek to zero is retained instead of falling back to old fraction',
      () {
    final progress = Progress(0.7, 'video', positionSeconds: 0);
    expect(progress.resumePosition(durationSeconds: 100), Duration.zero);
  });

  test('invalid precise times cannot overflow into a negative resume seek', () {
    const invalidSeconds = maximumPlaybackSeconds + 1;
    final progress = Progress(0.5, 'video',
        positionSeconds: invalidSeconds, durationSeconds: invalidSeconds);
    expect(progress.resumePosition(), Duration.zero);
    expect(progress.resumePosition(durationSeconds: 100),
        const Duration(seconds: 50));
    expect(
        Progress(0.5, 'video',
                positionSeconds: 25, durationSeconds: invalidSeconds)
            .resumePosition(),
        const Duration(seconds: 25));
    expect(
        Progress(0.5, 'video', durationSeconds: 100)
            .resumePosition(durationSeconds: invalidSeconds),
        const Duration(seconds: 50));
    expect(
        Progress(1, 'video', positionSeconds: maximumPlaybackSeconds)
            .resumePosition()
            .inSeconds,
        maximumPlaybackSeconds);
  });

  test('precise progress belongs to its original profile', () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    final owner = database.forProfile(database.profileId);
    await owner.saveProgress(
        Progress(1, 'video', positionSeconds: 95, durationSeconds: 100));
    final other = await database.createProfile('Other viewer');
    await database.useProfile(other.id);
    expect(database.getVideoPlaybackProgress('video').resumePosition(),
        Duration.zero);
    expect(owner.getVideoPlaybackProgress('video').resumePosition(),
        const Duration(seconds: 95));
  });

  test('unwatched and history edits invalidate the affected playlist cursors',
      () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    final repository = WatchRepository(database);
    final checkpoints =
        PlaylistProgressService.forProfile(database, database.profileId);
    final first = PlaylistReference(
        kind: PlaylistSourceKind.public,
        playlistId: 'PLfirst',
        profileId: database.profileId);
    final second = PlaylistReference(
        kind: PlaylistSourceKind.public,
        playlistId: 'PLsecond',
        profileId: database.profileId);
    const video = Video(videoId: 'video');
    const other = Video(videoId: 'other');
    final revision = await repository.beginPlayback(video.videoId);
    await checkpoints.save(first, video, watchRevision: revision);
    await checkpoints.save(second, other);
    await repository.mark(video.videoId, false);
    expect(checkpoints.get(first), isNull);
    expect(checkpoints.get(second), isNotNull);
    await checkpoints.save(first, video, watchRevision: revision);
    expect(checkpoints.get(first), isNull);
    await database.deleteLocalHistory(other.videoId);
    expect(checkpoints.get(second), isNull);
    final restarted = await repository.beginPlayback(video.videoId);
    await checkpoints.save(first, video, watchRevision: restarted);
    await database.clearLocalHistory();
    expect(checkpoints.get(first), isNull);
    await checkpoints.save(first, video, watchRevision: restarted);
    expect(checkpoints.get(first), isNull);
  });

  for (final clearAll in [false, true]) {
    test(
        'history ${clearAll ? 'clear' : 'deletion'} rejects old progress events',
        () async {
      final database = await SembastSqfDb.createInMemory();
      addTearDown(database.close);
      final repository = WatchRepository(database);
      final old = await repository.beginPlayback('video');
      await repository.recordPlayback('video', 1, old,
          positionSeconds: 95, durationSeconds: 100);
      if (clearAll) {
        await database.clearLocalHistory();
      } else {
        await database.deleteLocalHistory('video');
      }
      expect(
          await repository.recordPlayback('video', 1, old,
              positionSeconds: 96, durationSeconds: 100),
          isFalse);
      expect(database.getVideoPlaybackProgress('video').resumePosition(),
          Duration.zero);
      final next = await repository.beginPlayback('video');
      expect(next, isNot(old));
      expect(
          await repository.recordPlayback('video', 0.2, next,
              positionSeconds: 20, durationSeconds: 100),
          isTrue);
      expect(
          await repository.recordPlayback('video', 1, old,
              positionSeconds: 97, durationSeconds: 100),
          isFalse);
      expect(database.getVideoPlaybackProgress('video').resumePosition(),
          const Duration(seconds: 20));
    });
  }
}
