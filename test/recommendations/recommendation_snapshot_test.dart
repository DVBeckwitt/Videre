import 'dart:convert';

import 'package:clipious/recommendations/recommendation_models.dart';
import 'package:clipious/recommendations/recommendation_snapshot.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/backup.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _videoState() => {
      'schemaVersion': 1,
      'domain': 'video',
      'globalVector': {
        'topics': {'astronomy': 1.5},
        'duration': 0.5,
        'pacing': 0.5,
        'complexity': 0.5,
        'isLive': 0.0,
        'formats': <String>[],
      },
      'totalInteractions': 4,
    };

Map<String, dynamic> _musicState() => {
      'schemaVersion': 1,
      'domain': 'music',
      'trackPlays': {
        'abcdefghijk': [1700000000000],
      },
      'trackMeta': {
        'abcdefghijk': {
          'title': 'Example song',
          'artist': 'Example artist',
          'artistKey': 'name:example artist',
          'thumbnail': '',
        },
      },
      'totalPlays': 1,
    };

SettingsValue _setting(RecommendationDomain domain, Map<String, dynamic> state,
        {Map<String, Object?> extraEnvelope = const {}}) =>
    SettingsValue(
      recommendationSettingName(domain),
      jsonEncode({
        ...RecommendationSnapshot(state: state).toJson(),
        ...extraEnvelope,
      }),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('both native domains and empty reset state are portable settings', () {
    expect(
        UserBackup.validSetting(
            _setting(RecommendationDomain.video, _videoState())),
        isTrue);
    expect(
        UserBackup.validSetting(
            _setting(RecommendationDomain.music, _musicState())),
        isTrue);
    for (final domain in RecommendationDomain.values) {
      expect(UserBackup.validSetting(_setting(domain, {})), isTrue);
    }
    expect(
        validRecommendationSetting(SettingsValue('recommendations-other-v1',
            const RecommendationSnapshot().encode())),
        isFalse);
  });

  test('actual native video and music snapshots pass the Dart bridge boundary',
      () {
    final captured = jsonDecode(_nativeInteropJson) as Map<String, dynamic>;
    for (final domain in RecommendationDomain.values) {
      final state = Map<String, dynamic>.from(captured[domain.name]['state']);
      expect(validNativeSnapshot(state), isTrue, reason: domain.name);
      // Session/co-listening context is valid in memory, but is not portable.
      expect(
          RecommendationSnapshot.tryParse(
              RecommendationSnapshot(state: state).encode()),
          isNull);
      state.remove(
          domain == RecommendationDomain.music ? 'sessionAnchor' : 'session');
      expect(UserBackup.validSetting(_setting(domain, state)), isTrue,
          reason: domain.name);
    }
  });

  test('native domain and schema must match the owning setting', () {
    final wrongStates = [
      _musicState(),
      {..._videoState(), 'domain': 'other'},
      {..._videoState(), 'schemaVersion': 2},
      {..._videoState(), 'schemaVersion': '1'},
      {..._videoState()}..remove('domain'),
      {..._videoState()}..remove('schemaVersion'),
    ];
    for (final state in wrongStates) {
      expect(
          UserBackup.validSetting(_setting(RecommendationDomain.video, state)),
          isFalse,
          reason: 'Invalid native state identity: ${state['domain']} / '
              '${state['schemaVersion']}');
    }
  });

  test('co-watch and category indexes stay device local when backing up',
      () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    const creator = 'UCaaaaaaaaaaaaaaaaaaaaaa';
    const related = 'UCbbbbbbbbbbbbbbbbbbbbbb';
    final state = {
      ..._videoState(),
      'coWatchSources': {
        'seedvideo01': {
          'channelId': creator,
          'related': [related],
          'at': 1800000000000,
        },
      },
      'channelCategories': {
        creator: {
          'counts': {'science': 3},
          'at': 1800000000000,
        },
      },
    };
    expect(validNativeSnapshot(state), isTrue);
    await database.saveSetting(_setting(RecommendationDomain.video, state));
    final backup = await database.exportBackup();
    final portable = backup.sections['settings']!.single as Map;
    final snapshot =
        RecommendationSnapshot.tryParse(portable['value'] as String)!;
    expect(snapshot.state['totalInteractions'], 4);
    expect(snapshot.state.containsKey('coWatchSources'), isFalse);
    expect(snapshot.state.containsKey('channelCategories'), isFalse);
    expect(
        validNativeSnapshot({
          ...state,
          'coWatchSources': {
            'seedvideo01': {
              'channelId': creator,
              'related': ['bad|channel'],
            },
          },
        }),
        isFalse);
  });

  test('unknown envelope fields cannot travel unchanged through backup', () {
    for (final name in ['authToken', 'streamUrl', 'futureField']) {
      final setting = _setting(RecommendationDomain.video, _videoState(),
          extraEnvelope: {name: 'test-only-sensitive-value'});
      expect(UserBackup.validSetting(setting), isFalse, reason: name);
    }
  });

  test('URL and credential structural fields are rejected', () {
    for (final name in [
      'authToken',
      'sidCookie',
      'authorization',
      'Authorization',
      'cookie',
      'password',
      'streamUrl',
      'mediaUrl',
      'url',
    ]) {
      final setting = _setting(RecommendationDomain.music, {
        ..._musicState(),
        name: 'test-only-sensitive-value',
      });
      expect(UserBackup.validSetting(setting), isFalse, reason: name);
    }
    final state = _musicState();
    (state['trackMeta']['abcdefghijk'] as Map)['thumbnail'] =
        'https://invidious.example/vi/abcdefghijk/default.jpg?token=temporary';
    expect(UserBackup.validSetting(_setting(RecommendationDomain.music, state)),
        isFalse);
    expect(
        UserBackup.validSetting(
            _setting(RecommendationDomain.music, _musicState())),
        isTrue);
  });

  test('ordinary learned topic words are not mistaken for credential fields',
      () {
    final state = _videoState();
    (state['globalVector'] as Map)['topics'] = {
      'cookie': 1.0,
      'password': 0.5,
    };
    state['idfWordFrequency'] = {'cookie': 2, 'password': 1};
    expect(UserBackup.validSetting(_setting(RecommendationDomain.video, state)),
        isTrue);
  });

  test('nested typed records reject secrets and unknown structural fields', () {
    final music = _musicState();
    music['artistAffinity'] = {
      'name:example artist': {'plays': 1, 'authToken': 'test-only-secret'},
    };
    expect(UserBackup.validSetting(_setting(RecommendationDomain.music, music)),
        isFalse);

    final video = _videoState();
    (video['globalVector'] as Map)['Authorization'] = 'test-only-secret';
    expect(UserBackup.validSetting(_setting(RecommendationDomain.video, video)),
        isFalse);
    final channelMemory = {
      ..._videoState(),
      'channelMemory': {
        'entries': {
          'UCabcdefghijklmnopqrstuv': {
            'name': 'Example channel',
            'url': 'https://example.test/?token=temporary',
          },
        },
      },
    };
    expect(
        UserBackup.validSetting(
            _setting(RecommendationDomain.video, channelMemory)),
        isFalse);
  });

  test('numeric vocabulary maps cannot carry arbitrary objects or strings', () {
    for (final invalidValue in [
      'test-only-secret',
      {'authToken': 'test-only-secret'},
      [1, 2],
      true,
    ]) {
      final state = _videoState();
      (state['globalVector'] as Map)['topics'] = {'cookie': invalidValue};
      expect(
          UserBackup.validSetting(_setting(RecommendationDomain.video, state)),
          isFalse);
    }
  });

  test('native numeric bounds and collection capacities survive admission', () {
    expect(
        validNativeSnapshot({
          ..._videoState(),
          'channelScores': {'UCabcdefghijklmnopqrstuv': 1.01},
        }),
        isFalse);
    expect(
        validNativeSnapshot({
          ..._videoState(),
          'idfWordFrequency': {'cookie': 2.5},
        }),
        isFalse);
    expect(
        validNativeSnapshot({
          ..._musicState(),
          'trackPlays': {'abcdefghijk': List.filled(9, 1700000000000)},
        }),
        isFalse);
    expect(
        validNativeSnapshot({
          ..._musicState(),
          'timeBuckets': {'WEEKDAY_MORNING': <String, Object?>{}},
        }),
        isFalse);
  });

  test('large and deeply nested snapshots are rejected before import', () {
    final tooLarge = ' ' * (recommendationMaximumBytes + 1);
    expect(RecommendationSnapshot.tryParse(tooLarge), isNull);
    expect(
        UserBackup.validSetting(
            SettingsValue('recommendations-video-v1', tooLarge)),
        isFalse);

    Object nested = 1;
    for (var i = 0; i < 15; i++) {
      nested = {'value': nested};
    }
    expect(validNativeSnapshot({..._videoState(), 'nested': nested}), isFalse);
    expect(
        validNativeSnapshot({
          ..._videoState(),
          'oversized': List.filled(20001, 0),
        }),
        isFalse);
    expect(
        validNativeSnapshot({
          ..._videoState(),
          'largeText': 'x' * 8001,
        }),
        isFalse);
  });

  test('non-finite or unsafe numeric state cannot be persisted', () {
    for (final number in [
      double.nan,
      double.infinity,
      -double.infinity,
      1e19
    ]) {
      expect(
          validNativeSnapshot({..._videoState(), 'totalInteractions': number}),
          isFalse);
    }
  });

  test('learning preferences and dedupe survive a bounded snapshot round trip',
      () {
    final snapshot = RecommendationSnapshot(
      enabled: false,
      revision: 7,
      state: _videoState(),
      eventIds: const ['play:session-one'],
      blockedIds: const {'abcdefghijk'},
      blockedCreators: const {'UCabcdefghijklmnopqrstuv'},
    );
    final restored = RecommendationSnapshot.tryParse(snapshot.encode())!;
    expect(restored.enabled, isFalse);
    expect(restored.revision, 7);
    expect(restored.eventIds, snapshot.eventIds);
    expect(restored.blockedIds, snapshot.blockedIds);
    expect(restored.blockedCreators, snapshot.blockedCreators);
    expect(restored.state, snapshot.state);
  });

  test('real profile backup restores both taste states without account secrets',
      () async {
    final source = await SembastSqfDb.createInMemory();
    final target = await SembastSqfDb.createInMemory();
    try {
      await source.upsertServer(const Server(
          url: 'https://invidious.example',
          authToken: 'source-test-token',
          sidCookie: 'source-test-cookie',
          customHeaders: {'X-Api-Key': 'source-test-key'}));
      final videoSetting = _setting(RecommendationDomain.video, _videoState());
      final musicSetting = _setting(RecommendationDomain.music, _musicState());
      await source.saveSettings([videoSetting, musicSetting]);
      final second = await source.createProfile('Another person');
      await source.forProfile(second.id).saveSetting(_setting(
          RecommendationDomain.video,
          {..._videoState(), 'totalInteractions': 999}));

      final encoded = (await source.exportBackup()).encode();
      expect(encoded, isNot(contains('source-test-token')));
      expect(encoded, isNot(contains('source-test-cookie')));
      expect(encoded, isNot(contains('source-test-key')));
      await target.restoreBackup(UserBackup.parse(encoded));
      expect(target.getSettings(videoSetting.name)?.value, videoSetting.value);
      expect(target.getSettings(musicSetting.name)?.value, musicSetting.value);
      expect(await target.getServers(), isEmpty);
    } finally {
      await source.close();
      await target.close();
    }
  });
}

// Captured from NativeSnapshotInteropTest, using the actual Kotlin evaluators
// and Flutter StandardMessageCodec. Synthetic metadata only; no network calls.
const _nativeInteropJson = r'''
{"video":{"state":{"schemaVersion":1,"domain":"video","timeVectors":{"WEEKDAY_NIGHT":{"topics":{"melodi":0.02597335808379364,"guitar":0.02597335808379364},"duration":0.504920500686019,"pacing":0.5,"complexity":0.5026168431373982,"isLive":0.0,"formats":[]}},"timeBucketCounts":{"WEEKDAY_NIGHT":1},"globalVector":{"topics":{"melodi":0.02597335808379364,"guitar":0.02597335808379364},"duration":0.504920500686019,"pacing":0.5,"complexity":0.5026168431373982,"isLive":0.0,"formats":[]},"recentVector":{"topics":{"melodi":0.23138587708989833,"guitar":0.23138587708989833},"duration":0.504920500686019,"pacing":0.5,"complexity":0.5026168431373982,"isLive":0.0,"formats":[]},"shortsVector":{"topics":{},"duration":0.5,"pacing":0.5,"complexity":0.5,"isLive":0.0,"formats":[]},"channelScores":{"UCfixture":0.525},"topicAffinities":{"guitar|melodi":0.03},"totalInteractions":1,"consecutiveSkips":0,"blockedTopics":[],"blockedChannels":[],"preferredTopics":[],"hasCompletedOnboarding":false,"lastPersona":"INITIATE","personaStability":1,"idfWordFrequency":{"melodi":1,"guitar melodi":1,"guitar":1},"idfTotalDocuments":1,"countedDocumentIds":["fixture-track"],"watchHistoryMap":{"fixture-track":0.9166666865348816},"seenShortsHistory":{},"channelTopicProfiles":{"UCfixture":{"guitar":0.07071067811865475,"melodi":0.07071067811865475}},"suppressedVideoIds":{},"suppressedChannels":{},"rejectionPatterns":{},"feedHistory":{},"recentQueryTokens":[],"topicEvidence":{"guitar":{"positiveSignals":1,"negativeSignals":0,"watchSignals":1,"explicitSignals":0,"positiveScore":1.5,"videoIds":["fixture-track"],"channelIds":["UCfixture"],"firstSeenAt":1800000000000,"lastSeenAt":1800000000000},"melodi":{"positiveSignals":1,"negativeSignals":0,"watchSignals":1,"explicitSignals":0,"positiveScore":1.5,"videoIds":["fixture-track"],"channelIds":["UCfixture"],"firstSeenAt":1800000000000,"lastSeenAt":1800000000000}},"recentRelatedSeeds":{},"staleQueries":{},"clusterRotation":{},"tagAffinities":{},"recentShortsSeeds":{},"channelMemory":{"clearedAt":0,"entries":{}},"interestChips":{"masses":{},"computedAt":0},"displayForms":{"melodi":{"form":"melody","votes":1},"guitar":{"form":"Guitar","votes":1}},"formatAffinity":{},"categoryAffinity":{},"languageProfile":"en","languageVotes":{},"keyLanguage":"en","processedEventIds":["fixture-listen"],"session":{"startedAt":1800000000000,"lastAt":1800000000000,"videoCount":1,"topics":["guitar"],"momentum":[{"topic":"guitar","positive":true}],"impressions":{}}},"ranked":[{"id":"fixture-track","score":0.026541729052514798,"reason":"Explore from available videos"}],"summary":{"totalInteractions":1,"appliedEvents":1,"ignoredEvents":0,"topTopics":[],"blockedChannels":[],"blockedTopics":[],"discoveryQueries":["Guitar melody"],"scoresArePreDiversity":true},"schemaVersion":1,"domain":"video"},"music":{"state":{"schemaVersion":1,"domain":"music","artistAffinity":{"UCfixtureArtist":{"plays":1,"score":0.27718124999999993,"lastPlayed":1800000000000,"liked":false,"display":"Fixture Artist"}},"genreAffinity":{"rock":0.15},"trackPlays":{"fixture-track":[1800000000000]},"trackMeta":{"fixture-track":{"title":"Guitar melody","artist":"Fixture Artist","artistKey":"UCfixtureArtist"}},"recentRotation":{"UCfixtureArtist":0.35},"artistCooc":{},"artistRelated":{},"timeBuckets":{"WeekdayNight":{"rock":1.0}},"seenArtists":["UCfixtureArtist"],"dislikedArtists":{},"blockedArtists":[],"discoveryAppetite":0.32999999999999996,"totalPlays":1,"lastRotationDecay":1800000000000,"backfilled":true,"processedEventIds":["fixture-listen"],"sessionAnchor":{"artistKey":"UCfixtureArtist","atMs":1800000000000}},"ranked":[{"id":"fixture-track","score":0.46763769324350773,"reason":"A song you have been listening to"}],"summary":{"domain":"music","totalPlays":1,"artistCount":1,"discoveryAppetite":0.32999999999999996,"appliedEvents":1,"ignoredEvents":0,"scoresArePreDiversity":true,"topArtists":[{"key":"UCfixtureArtist","name":"Fixture Artist","score":0.27718124999999993}],"blockedArtists":[],"hiddenArtists":[],"onRepeat":["fixture-track"],"rediscover":[],"timeOfDay":[],"dailyMixes":[]},"schemaVersion":1,"domain":"music"}}
''';
