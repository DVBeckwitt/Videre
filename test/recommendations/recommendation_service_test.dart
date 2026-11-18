import 'dart:async';
import 'dart:convert';

import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/recommendations/recommendation_snapshot.dart';
import 'package:clipious/settings/models/db/app_logs.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const sample = Video(
    videoId: 'abcdefghijk',
    title: 'A recording',
    author: 'Creator',
    authorId: 'UCabcdefghijklmnopqrstuv',
    lengthSeconds: 200);

class _FailingImpressionDatabase extends Fake implements IDbClient {
  _FailingImpressionDatabase(this.database);

  final IDbClient database;
  var attempts = 0;

  @override
  String get profileId => database.profileId;

  @override
  IDbClient forProfile(String id) => this;

  @override
  SettingsValue? getSettings(String name) => database.getSettings(name);

  @override
  List<VideoFilter> getAllFilters() => database.getAllFilters();

  @override
  Future<void> upsertServer(Server server) async =>
      await database.upsertServer(server);

  @override
  Future<void> insertLogs(AppLog log) async => await database.insertLogs(log);

  @override
  Future<void> saveSetting(SettingsValue setting) async {
    if (++attempts == 1) throw StateError('Temporary disk failure');
    await database.saveSetting(setting);
  }
}

Map<String, dynamic> evaluate(Map<String, Object?> request) {
  final state = Map<String, dynamic>.from(request['state']! as Map);
  final events = request['events']! as List;
  final countKey =
      request['domain'] == 'music' ? 'totalPlays' : 'totalInteractions';
  return {
    'state': {
      ...state,
      'schemaVersion': 1,
      'domain': request['domain'],
      countKey: ((state[countKey] as num?) ?? 0) + events.length,
    },
    'ranked': [
      for (final candidate in request['candidates']! as List)
        {'id': (candidate as Map)['id'], 'score': 1.0, 'reason': 'Local taste'},
    ],
    'summary': <String, dynamic>{},
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SembastSqfDb database;
  late RecommendationService service;
  late List<Map<String, Object?>> calls;

  RecommendationSnapshot snapshot(RecommendationDomain domain) =>
      RecommendationSnapshot.tryParse(
          database.getSettings(recommendationSettingName(domain))?.value)!;

  Future<void> play(String id,
          {RecommendationDomain domain = RecommendationDomain.video,
          int? token}) =>
      service.recordPlayback(sample,
          domain: domain,
          played: const Duration(seconds: 80),
          duration: const Duration(seconds: 200),
          sessionId: id,
          expectedGeneration: token);

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    calls = [];
    service =
        RecommendationService.forTesting(database, bridge: (request) async {
      calls.add(request);
      return evaluate(request);
    });
  });

  tearDown(() async {
    await RecommendationService.flushPending();
    service.dispose();
    await database.close();
  });

  test('serial writes preserve concurrent events and deduplicate a session',
      () async {
    await Future.wait([play('one'), play('two'), play('one')]);
    expect(snapshot(RecommendationDomain.video).state['totalInteractions'], 2);
    expect(snapshot(RecommendationDomain.video).eventIds,
        ['play:one', 'play:two']);
    expect(calls, hasLength(2));
  });

  test('watching and listening never share learned state', () async {
    await play('one');
    await play('two', domain: RecommendationDomain.music);
    await play('three', domain: RecommendationDomain.music);
    expect(snapshot(RecommendationDomain.video).state['totalInteractions'], 1);
    expect(snapshot(RecommendationDomain.music).state['totalPlays'], 2);
    expect(calls.last['domain'], 'music');
    final candidate =
        ((calls.last['events']! as List).single as Map)['candidate'] as Map;
    expect(candidate['artistKey'], startsWith('uploader:'));
  });

  test(
      'ranking is metadata-only, bounded and does not notify learning listeners',
      () async {
    var notifications = 0;
    service.addListener(() => notifications++);
    final result = await service.rankVideos([
      sample.copyWith(dashUrl: 'https://secret.example/?token=private'),
      sample,
      sample.copyWith(videoId: 'hidden00000', filtered: true),
      for (var i = 0; i < 130; i++)
        sample.copyWith(videoId: 'v${i.toString().padLeft(10, '0')}'),
    ]);
    expect(result.available, isTrue);
    expect(result.items, hasLength(recommendationMaximumCandidates));
    expect(result.items.map((entry) => entry.item.videoId),
        isNot(contains('hidden00000')));
    expect(jsonEncode(calls.single), isNot(contains('secret.example')));
    expect(notifications, 0);
    expect(
        database
            .getSettings(recommendationSettingName(RecommendationDomain.video)),
        isNull);
  });

  test('known local subscriptions reach the native scoring input', () async {
    await database.addOfflineSubscription(OfflineSubscription(
        channelId: sample.authorId!, channelName: sample.author!));
    await service.rankVideos([sample]);
    expect(((calls.single['candidates'] as List).single as Map)['isSubscribed'],
        isTrue);
  });

  test('viewport batches admitted cards without changing the active ranking',
      () async {
    var notifications = 0;
    service.addListener(() => notifications++);
    await service.recordVideoImpressions([
      sample.copyWith(dashUrl: 'https://example.invalid/secret'),
      sample,
      sample.copyWith(videoId: 'hidden00000', filterHide: true),
    ]);
    final batch = (calls.single['events']! as List).cast<Map>();
    expect(batch, hasLength(1));
    expect(batch.single['type'], 'impression');
    expect(batch.single['candidate'], {'id': sample.videoId});
    expect(notifications, 0);

    await service.setLearningEnabled(RecommendationDomain.video, false);
    await service.recordVideoImpressions([sample]);
    expect(calls, hasLength(1));
  });

  test('leaving the viewport during native impression work discards it',
      () async {
    service.dispose();
    final entered = Completer<void>();
    final release = Completer<void>();
    service =
        RecommendationService.forTesting(database, bridge: (request) async {
      entered.complete();
      await release.future;
      return evaluate(request);
    });
    var current = true;
    final pending =
        service.recordVideoImpressions([sample], isCurrent: () => current);
    await entered.future;
    current = false;
    release.complete();
    await pending;
    expect(snapshot(RecommendationDomain.video).revision, 0);
  });

  test('a failed impression write preserves taste and the next batch can save',
      () async {
    const domain = RecommendationDomain.video;
    await play('previous');
    final original = snapshot(domain);
    final failing = _FailingImpressionDatabase(database);
    service.dispose();
    service =
        RecommendationService.forTesting(failing, bridge: (request) async {
      calls.add(request);
      return {
        ...evaluate(request),
        'summary': {'appliedEvents': 1}
      };
    });
    var notifications = 0;
    service.addListener(() => notifications++);

    await service.recordVideoImpressions([sample]);
    expect(failing.attempts, 1);
    expect(snapshot(domain).encode(), original.encode());

    await service.recordVideoImpressions([sample]);
    expect(failing.attempts, 2);
    expect(snapshot(domain).revision, original.revision + 1);
    expect(snapshot(domain).eventIds, original.eventIds);
    expect(notifications, 0);
  });

  test('creator unblock preserves neighboring and other-mode blocks', () async {
    const video = RecommendationDomain.video;
    const music = RecommendationDomain.music;
    const neighbor = 'UCbbbbbbbbbbbbbbbbbbbbbb';
    await service.feedback(sample, video, RecommendationFeedback.block);
    expect(service.blockedCreators(video).single.label, sample.author);
    await database.saveSetting(SettingsValue(
        recommendationSettingName(video),
        snapshot(video).copyWith(state: {
          ...snapshot(video).state,
          'blockedChannels': [sample.authorId, neighbor],
          'suppressedChannels': {sample.authorId!: 10},
        }).encode()));
    await service.feedback(sample, music, RecommendationFeedback.block);

    await service.unblockCreator(video, sample.authorId!);
    expect(service.blockedCreators(video).single.key, neighbor);
    expect(service.blockedCreators(music).single.key,
        'uploader:${sample.authorId}');
    expect(snapshot(video).state['suppressedChannels'], {sample.authorId!: 10});
    expect(snapshot(video).blockedCreatorLabels, isEmpty);
  });

  test('missing native engine does not fabricate ranked results', () async {
    service.dispose();
    service = RecommendationService.forTesting(database,
        bridge: (_) => throw MissingPluginException());
    final result = await service.rankVideos([sample]);
    expect(result.available, isFalse);
    expect(result.items, isEmpty);
    await play('one');
    expect(snapshot(RecommendationDomain.video).state, isEmpty);
  });

  test('late snapshot cannot restore preferences after reset', () async {
    service.dispose();
    final entered = Completer<void>();
    final response = Completer<Map<String, dynamic>>();
    service = RecommendationService.forTesting(database, bridge: (request) {
      entered.complete();
      return response.future;
    });
    final oldToken = service.generation(RecommendationDomain.video);
    final pending = play('one');
    await entered.future;
    final reset = service.reset(RecommendationDomain.video);
    response.complete({
      'state': {'schemaVersion': 1, 'domain': 'video', 'totalInteractions': 99},
      'ranked': <Object?>[],
    });
    await Future.wait([pending, reset]);
    expect(snapshot(RecommendationDomain.video).state, isEmpty);
    expect(service.generation(RecommendationDomain.video), isNot(oldToken));
    await play('two', token: oldToken);
    expect(snapshot(RecommendationDomain.video).state, isEmpty);
  });

  test('pause invalidates old elapsed sessions, explicit feedback still works',
      () async {
    final oldToken = service.generation(RecommendationDomain.video);
    await service.setLearningEnabled(RecommendationDomain.video, false);
    await play('before-pause', token: oldToken);
    await play('during-pause');
    expect(calls, isEmpty);
    await service.feedback(
        sample, RecommendationDomain.video, RecommendationFeedback.like);
    expect(snapshot(RecommendationDomain.video).enabled, isFalse);
    expect(((calls.single['events'] as List).single as Map)['type'], 'like');
  });

  test('profile change rejects an in-flight rank', () async {
    service.dispose();
    final entered = Completer<void>();
    final response = Completer<Map<String, dynamic>>();
    service = RecommendationService.forTesting(database, bridge: (request) {
      entered.complete();
      return response.future;
    });
    final pending = service.rankVideos([sample]);
    await entered.future;
    final person = await database.createProfile('Another person');
    await database.useProfile(person.id);
    response.complete({
      'ranked': [
        {'id': sample.videoId, 'score': 1.0, 'reason': 'Old taste'}
      ]
    });
    expect((await pending).cancelled, isTrue);
  });

  test('profile deletion cannot recreate state from an in-flight event',
      () async {
    service.dispose();
    final original = database.profileId;
    final entered = Completer<void>();
    final response = Completer<Map<String, dynamic>>();
    service = RecommendationService.forTesting(database, bridge: (request) {
      entered.complete();
      return response.future;
    });
    final pending = play('one');
    await entered.future;
    final another = await database.createProfile('Another person');
    await database.useProfile(another.id);
    await database.deleteProfile(original);
    response.complete({
      'state': {'schemaVersion': 1, 'domain': 'video', 'totalInteractions': 99},
    });
    await pending;
    expect(database.profileExists(original), isFalse);
    expect(
        database
            .getSettings(recommendationSettingName(RecommendationDomain.video)),
        isNull);
  });

  test('external restored snapshot wins over pending native mutation',
      () async {
    service.dispose();
    final entered = Completer<void>();
    final response = Completer<Map<String, dynamic>>();
    service = RecommendationService.forTesting(database, bridge: (_) {
      entered.complete();
      return response.future;
    });
    final pending = play('one');
    await entered.future;
    await database.saveSetting(SettingsValue(
        recommendationSettingName(RecommendationDomain.video),
        const RecommendationSnapshot(revision: 50, state: {
          'schemaVersion': 1,
          'domain': 'video',
          'totalInteractions': 12
        }).encode()));
    response.complete({
      'state': {'schemaVersion': 1, 'domain': 'video', 'totalInteractions': 99}
    });
    await pending;
    expect(snapshot(RecommendationDomain.video).state['totalInteractions'], 12);
  });

  test('explicit exclusion persists and cannot be returned by native ranking',
      () async {
    await service.feedback(sample, RecommendationDomain.video,
        RecommendationFeedback.notInterested);
    final result = await service.rankVideos([sample]);
    expect(result.items, isEmpty);
    expect(calls.last['candidates'], isEmpty);
    expect(service.blockedCount(RecommendationDomain.video), 1);
  });

  test('blocked creator applies to other videos and supports unblock',
      () async {
    await service.feedback(
        sample, RecommendationDomain.video, RecommendationFeedback.block);
    final other = sample.copyWith(videoId: 'zyxwvutsrqp');
    expect((await service.rankVideos([other])).items, isEmpty);
    await service.feedback(
        sample, RecommendationDomain.video, RecommendationFeedback.unblock);
    expect((await service.rankVideos([other])).items, hasLength(1));
  });

  for (final domain in RecommendationDomain.values) {
    test(
        '${domain.name} native creator blocks apply before ranking and locally',
        () async {
      final music = domain == RecommendationDomain.music;
      final creator = music ? 'uploader:${sample.authorId}' : sample.authorId!;
      final field = music ? 'blockedArtists' : 'blockedChannels';
      final other = sample.copyWith(
          videoId: 'zyxwvutsrqp', authorId: 'UCbbbbbbbbbbbbbbbbbbbbbb');
      final tracks = [
        for (final video in [sample, other])
          MusicTrack(
              videoId: video.videoId,
              title: video.title!,
              artists: [video.author!],
              uploaderChannelId: video.authorId),
      ];
      // MusicBrain can escalate repeated dislikes into a native artist block
      // without adding that artist to the host's explicit creator-block set.
      await database.saveSetting(SettingsValue(
          recommendationSettingName(domain),
          RecommendationSnapshot(state: {
            'schemaVersion': 1,
            'domain': domain.name,
            field: [creator],
          }).encode()));
      expect(snapshot(domain).blockedCreators, isEmpty);

      List<String> eligibleIds() => music
          ? service.eligibleMusic(tracks).map((track) => track.videoId).toList()
          : service
              .eligibleVideos([sample, other])
              .map((video) => video.videoId)
              .toList();
      expect(eligibleIds(), [other.videoId]);
      if (music) {
        expect(service.eligibleVideos([sample]), [sample]);
        await service.rankMusic(tracks);
      } else {
        expect(service.eligibleMusic([tracks.first]), [tracks.first]);
        await service.rankVideos([sample, other]);
      }
      expect(
          (calls.last['candidates']! as List).map((row) => (row as Map)['id']),
          [other.videoId]);

      await service.unblockCreator(domain, creator);
      expect(eligibleIds(), [sample.videoId, other.videoId]);
    });
  }

  test('search privacy setting prevents learning the query', () async {
    await database
        .saveSetting(SettingsValue(useSearchHistorySettingName, 'false'));
    await service.recordSearch('private query', RecommendationDomain.video);
    expect(calls, isEmpty);
    await database
        .saveSetting(SettingsValue(useSearchHistorySettingName, 'true'));
    await service.recordSearch('a public topic', RecommendationDomain.video);
    expect(((calls.single['events']! as List).single as Map)['query'],
        'a public topic');
  });

  test(
      'music session anchor stays live but is not persisted or reused on switch',
      () async {
    service.dispose();
    service =
        RecommendationService.forTesting(database, bridge: (request) async {
      calls.add(request);
      return {
        ...evaluate(request),
        'state': {
          'domain': 'music',
          'schemaVersion': 1,
          'sessionAnchor': {'artistKey': 'artist', 'atMs': 100}
        }
      };
    });
    await play('one', domain: RecommendationDomain.music);
    expect(snapshot(RecommendationDomain.music).state,
        isNot(contains('sessionAnchor')));
    await service
        .rankMusic([const MusicTrack(videoId: 'abcdefghijk', title: 'Song')]);
    expect(calls.last['state'], contains('sessionAnchor'));
    RecommendationService.invalidateSession();
    await service
        .rankMusic([const MusicTrack(videoId: 'abcdefghijk', title: 'Song')]);
    expect(calls.last['state'], isNot(contains('sessionAnchor')));
  });

  test('queued search rechecks consent after earlier learning finishes',
      () async {
    service.dispose();
    final entered = Completer<void>();
    final release = Completer<void>();
    service =
        RecommendationService.forTesting(database, bridge: (request) async {
      calls.add(request);
      entered.complete();
      await release.future;
      return evaluate(request);
    });
    final first = play('one');
    await entered.future;
    final search =
        service.recordSearch('private later', RecommendationDomain.video);
    await database
        .saveSetting(SettingsValue(useSearchHistorySettingName, 'false'));
    release.complete();
    await Future.wait([first, search]);
    expect(calls, hasLength(1));
  });

  test('rejected pre-restore reply cannot update ephemeral music context',
      () async {
    service.dispose();
    final entered = Completer<void>();
    final release = Completer<void>();
    var callCount = 0;
    service =
        RecommendationService.forTesting(database, bridge: (request) async {
      calls.add(request);
      if (callCount++ == 0) {
        entered.complete();
        await release.future;
      }
      return {
        ...evaluate(request),
        'state': {
          'schemaVersion': 1,
          'domain': 'music',
          'totalPlays': 99,
          'sessionAnchor': {'artistKey': 'old artist', 'atMs': 100},
        }
      };
    });
    final pending = play('one', domain: RecommendationDomain.music);
    await entered.future;
    await database.saveSetting(SettingsValue(
        recommendationSettingName(RecommendationDomain.music),
        const RecommendationSnapshot(state: {
          'schemaVersion': 1,
          'domain': 'music',
          'totalPlays': 4,
        }).encode()));
    release.complete();
    await pending;
    await service
        .rankMusic([const MusicTrack(videoId: 'abcdefghijk', title: 'Song')]);
    expect(calls.last['state'], isNot(contains('sessionAnchor')));
    expect(snapshot(RecommendationDomain.music).state['totalPlays'], 4);
  });

  test('malformed returned state never replaces durable learning data',
      () async {
    await play('one');
    service.dispose();
    service = RecommendationService.forTesting(database,
        bridge: (_) async => {
              'state': {'authToken': 'must not persist'},
            });
    await play('two');
    expect(snapshot(RecommendationDomain.video).state['totalInteractions'], 1);
    expect(snapshot(RecommendationDomain.video).eventIds, ['play:one']);
  });
}
