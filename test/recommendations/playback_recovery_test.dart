import 'dart:async';

import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/recommendations/recommendation_snapshot.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';

const _track = Video(
    videoId: 'abcdefghijk',
    title: 'Saved listening',
    author: 'Artist',
    authorId: 'UCabcdefghijklmnopqrstuv',
    lengthSeconds: 100,
    description: 'Temporary stream https://example.invalid/private',
    dashUrl: 'https://example.invalid/secret',
    musicMetadata: MusicMetadata(title: 'Saved listening', artist: 'Artist'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DatabaseFactory factory;
  late SembastSqfDb db;
  late RecommendationService owner;
  late List<Map> events;
  late DateTime clock;
  const music = RecommendationDomain.music;
  const video = RecommendationDomain.video;

  Map<String, dynamic> evaluate(Map<String, Object?> call) {
    final state = Map<String, dynamic>.from(call['state']! as Map);
    final input = (call['events']! as List).cast<Map>();
    events.addAll(input);
    final counter =
        call['domain'] == 'music' ? 'totalPlays' : 'totalInteractions';
    return {
      'state': {
        ...state,
        'schemaVersion': 1,
        'domain': call['domain'],
        counter: (state[counter] as int? ?? 0) + input.length,
      },
      'ranked': [],
    };
  }

  Future<void> open({RecommendationBridge? bridge}) async {
    db = SembastSqfDb(await factory.openDatabase('recommendation-journal'));
    await db.getProfiles();
    owner = RecommendationService.forTesting(db,
        clock: () => clock, bridge: bridge ?? ((call) async => evaluate(call)));
  }

  Future<void> reopen({RecommendationBridge? bridge}) async {
    owner.dispose();
    await db.close();
    await open(bridge: bridge);
  }

  RecommendationSnapshot snapshot(RecommendationDomain domain) =>
      RecommendationSnapshot.tryParse(
          db.getSettings(recommendationSettingName(domain))?.value)!;

  Future<void> checkpoint(RecommendationDomain domain, int seconds,
          {int? token, String id = 'occurrence'}) =>
      owner.checkpointPlayback(_track,
          domain: domain,
          played: Duration(seconds: seconds),
          duration: const Duration(seconds: 100),
          sessionId: id,
          expectedGeneration: token ?? owner.generation(domain));

  Future<void> finish(RecommendationDomain domain, int seconds) =>
      owner.recordPlayback(_track,
          domain: domain,
          played: Duration(seconds: seconds),
          duration: const Duration(seconds: 100),
          sessionId: 'occurrence',
          completed: true);

  setUp(() async {
    factory = newDatabaseFactoryMemory();
    clock = DateTime.utc(2026, 1, 1);
    events = [];
    await open();
  });

  tearDown(() async {
    owner.dispose();
    await db.close();
  });

  for (final domain in RecommendationDomain.values) {
    test('${domain.name} recovery learns one cumulative event across reopen',
        () async {
      await checkpoint(domain, 15);
      clock = clock.add(const Duration(seconds: 40));
      await checkpoint(domain, 55);
      await checkpoint(domain, 30);
      final savedTime = clock.millisecondsSinceEpoch;
      final stored = snapshot(domain);
      expect(stored.pendingPlayback.single.id, 'play:occurrence');
      expect(stored.pendingPlayback.single.playedMs, 55000);
      expect(stored.state, isEmpty);
      expect(events, isEmpty);
      expect(stored.encode(), isNot(contains('example.invalid')));

      await reopen();
      clock = clock.add(const Duration(days: 1));
      await owner.recoverPlayback();
      expect(events, hasLength(1));
      expect(events.single['id'], 'play:occurrence');
      expect(events.single['playedMs'], 55000);
      expect(events.single['timeMs'], savedTime);
      expect(events.single['skipped'], isFalse);
      expect(events.single['completed'], isFalse);
      expect(snapshot(domain).pendingPlayback, isEmpty);
      expect(snapshot(domain).eventIds.single, 'play:occurrence');

      await reopen();
      await owner.recoverPlayback();
      expect(events, hasLength(1),
          reason: 'taste and retirement committed together');
    });
  }

  test('normal completion learns the latest cumulative time once', () async {
    await checkpoint(music, 15);
    await checkpoint(music, 51);
    await finish(music, 94);
    expect(events, hasLength(1));
    expect(events.single['playedMs'], 94000);
    expect(events.single['completed'], isTrue);
    expect(snapshot(music).state['totalPlays'], 1);
    expect(snapshot(music).pendingPlayback, isEmpty);
    await reopen();
    await owner.recoverPlayback();
    expect(events, hasLength(1));
  });

  test('a filter added during playback retires the finished occurrence',
      () async {
    await checkpoint(music, 15);
    final filter = VideoFilter(value: null, channelId: _track.authorId)
      ..filterAll = true;
    await db.saveFilter(filter);
    await finish(music, 94);

    expect(events, isEmpty);
    expect(snapshot(music).pendingPlayback, isEmpty);
    expect(snapshot(music).eventIds, isEmpty);

    await db.deleteFilter(filter);
    await reopen();
    await owner.recoverPlayback();
    expect(events, isEmpty);
  });

  test('a filter added during final evaluation discards the native update',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    await reopen(bridge: (call) async {
      entered.complete();
      await release.future;
      return evaluate(call);
    });
    final finishing = finish(video, 52);
    await entered.future;
    try {
      final filter = VideoFilter(value: null, channelId: _track.authorId)
        ..filterAll = true;
      await db.saveFilter(filter);
    } finally {
      release.complete();
    }
    await finishing;

    expect(events.single['id'], 'play:occurrence');
    expect(snapshot(video).state, isEmpty);
    expect(snapshot(video).eventIds, isEmpty);
    expect(snapshot(video).pendingPlayback, isEmpty);
  });

  test('failed final evaluation leaves latest time recoverable', () async {
    await checkpoint(music, 15);
    await reopen(bridge: (_) async => throw PlatformException(code: 'busy'));
    await finish(music, 54);
    expect(snapshot(music).pendingPlayback.single.playedMs, 54000);
    expect(snapshot(music).eventIds, isEmpty);
    await reopen();
    await owner.recoverPlayback();
    expect(events.single['playedMs'], 54000);
    expect(events.single['completed'], isFalse);
    expect(snapshot(music).pendingPlayback, isEmpty);
  });

  test('checkpoint follows its profile when the selected profile changes',
      () async {
    await checkpoint(video, 35);
    final original = db.profileId;
    final other = await db.createProfile('Other viewer');
    await db.useProfile(other.id);
    await reopen();
    await owner.recoverPlayback();
    expect(events, isEmpty);
    expect(snapshot(video).pendingPlayback, isEmpty);

    await db.useProfile(original);
    await reopen();
    await owner.recoverPlayback();
    expect(events.single['playedMs'], 35000);
    expect(snapshot(video).pendingPlayback, isEmpty);
  });

  for (final reset in [true, false]) {
    test('${reset ? 'reset' : 'disable'} rejects a queued old checkpoint',
        () async {
      await checkpoint(music, 20);
      final entered = Completer<void>();
      final release = Completer<void>();
      await reopen(bridge: (call) async {
        entered.complete();
        await release.future;
        return evaluate(call);
      });
      final rank = owner.rankMusic([]);
      await entered.future;
      final stale = owner.generation(music);
      final writing = checkpoint(music, 60, token: stale);
      final clearing =
          reset ? owner.reset(music) : owner.setLearningEnabled(music, false);
      release.complete();
      await rank;
      await Future.wait([writing, clearing]);
      expect(snapshot(music).pendingPlayback, isEmpty);
      expect(snapshot(music).learningEpoch, 1);
      await reopen();
      await owner.recoverPlayback();
      expect(events, isEmpty);
    });
  }

  test('portable settings omit pending occurrences and their device epoch',
      () async {
    await owner.setLearningEnabled(music, true);
    await checkpoint(music, 33);
    final backup = await db.exportBackup();
    expect(backup.encode(), isNot(contains('play:occurrence')));
    expect(backup.encode(), isNot(contains('learningEpoch')));
    expect(snapshot(music).pendingPlayback.single.playedMs, 33000);
  });
}
