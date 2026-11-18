import 'dart:convert';

import '../settings/models/db/settings.dart';
import 'playback_checkpoint.dart';
import 'recommendation_models.dart';

const recommendationMaximumBytes = 2 * 1024 * 1024;
const recommendationMaximumCandidates = 100;
const recommendationMaximumEvents = 2048;
const recommendationMaximumPending = 4;

String recommendationSettingName(RecommendationDomain domain) =>
    'recommendations-${domain.name}-v1';

/// A profile-owned envelope. Native algorithms own the internal state schema;
/// this envelope owns learning consent, local exclusions, and event deduping.
class RecommendationSnapshot {
  final bool enabled;
  final int revision;
  final Map<String, dynamic> state;
  final List<String> eventIds;
  final Set<String> blockedIds;
  final Set<String> blockedCreators;
  final Map<String, String> blockedCreatorLabels;
  final int learningEpoch;
  final List<PlaybackCheckpoint> pendingPlayback;

  const RecommendationSnapshot({
    this.enabled = true,
    this.revision = 0,
    this.state = const {},
    this.eventIds = const [],
    this.blockedIds = const {},
    this.blockedCreators = const {},
    this.blockedCreatorLabels = const {},
    this.learningEpoch = 0,
    this.pendingPlayback = const [],
  });

  RecommendationSnapshot copyWith({
    bool? enabled,
    int? revision,
    Map<String, dynamic>? state,
    List<String>? eventIds,
    Set<String>? blockedIds,
    Set<String>? blockedCreators,
    Map<String, String>? blockedCreatorLabels,
    int? learningEpoch,
    List<PlaybackCheckpoint>? pendingPlayback,
  }) =>
      RecommendationSnapshot(
        enabled: enabled ?? this.enabled,
        revision: revision ?? this.revision,
        state: state ?? this.state,
        eventIds: eventIds ?? this.eventIds,
        blockedIds: blockedIds ?? this.blockedIds,
        blockedCreators: blockedCreators ?? this.blockedCreators,
        blockedCreatorLabels: blockedCreatorLabels ?? this.blockedCreatorLabels,
        learningEpoch: learningEpoch ?? this.learningEpoch,
        pendingPlayback: pendingPlayback ?? this.pendingPlayback,
      );

  Map<String, Object?> toJson() => {
        'version': 1,
        'enabled': enabled,
        'revision': revision,
        'state': state,
        'eventIds': eventIds,
        'blockedIds': blockedIds.toList(),
        'blockedCreators': blockedCreators.toList(),
        if (blockedCreatorLabels.isNotEmpty)
          'blockedCreatorLabels': blockedCreatorLabels,
        if (learningEpoch != 0) 'learningEpoch': learningEpoch,
        if (pendingPlayback.isNotEmpty)
          'pendingPlayback':
              pendingPlayback.map((checkpoint) => checkpoint.toJson()).toList(),
      };

  String encode() => jsonEncode(toJson());

  static RecommendationSnapshot? tryParse(String? value) {
    if (value == null) return const RecommendationSnapshot();
    if (utf8.encode(value).length > recommendationMaximumBytes) return null;
    try {
      final data = jsonDecode(value);
      if (data is! Map<String, dynamic> ||
          data.keys.any((key) => !const {
                'version',
                'enabled',
                'revision',
                'state',
                'eventIds',
                'blockedIds',
                'blockedCreators',
                'blockedCreatorLabels',
                'learningEpoch',
                'pendingPlayback',
              }.contains(key)) ||
          data['version'] != 1 ||
          data['enabled'] is! bool ||
          data['revision'] is! int ||
          (data['revision'] as int) < 0 ||
          (data['revision'] as int) > 9007199254740991 ||
          data['state'] is! Map<String, dynamic> ||
          !validNativeSnapshot(data['state'], allowSession: false)) {
        return null;
      }
      List<String>? strings(String key, int limit, int length) {
        final list = data[key];
        if (list is! List ||
            list.length > limit ||
            list.any((s) => s is! String || s.length > length)) {
          return null;
        }
        return list.cast<String>();
      }

      final events = strings('eventIds', recommendationMaximumEvents, 200);
      final ids = strings('blockedIds', 2000, 128);
      final creators = strings('blockedCreators', 2000, 400);
      if (events == null || ids == null || creators == null) return null;
      final rawLabels = data['blockedCreatorLabels'] ?? const {};
      final creatorKeys = creators.toSet();
      if (rawLabels is! Map ||
          rawLabels.length > creatorKeys.length ||
          rawLabels.entries.any((row) =>
              !creatorKeys.contains(row.key) ||
              row.value is! String ||
              (row.value as String).length > 320)) {
        return null;
      }
      final epoch = data['learningEpoch'] ?? 0;
      final journal = data['pendingPlayback'] ?? const [];
      if (epoch is! int ||
          epoch < 0 ||
          epoch > PlaybackCheckpoint.maxEpoch ||
          journal is! List ||
          journal.length > recommendationMaximumPending) {
        return null;
      }
      final pending = <PlaybackCheckpoint>[];
      final pendingIds = <String>{};
      for (final row in journal) {
        final checkpoint = PlaybackCheckpoint.tryParse(row);
        if (checkpoint == null ||
            checkpoint.epoch != epoch ||
            !pendingIds.add(checkpoint.id)) {
          return null;
        }
        pending.add(checkpoint);
      }
      return RecommendationSnapshot(
        enabled: data['enabled'] as bool,
        revision: data['revision'] as int,
        state: data['state'] as Map<String, dynamic>,
        eventIds: events,
        blockedIds: ids.toSet(),
        blockedCreators: creatorKeys,
        blockedCreatorLabels: Map<String, String>.from(rawLabels),
        learningEpoch: epoch,
        pendingPlayback: pending,
      );
    } on FormatException {
      return null;
    }
  }
}

/// Bounded JSON trees only. Native state never contains arbitrary objects,
/// playback URLs, or transport credentials. Validate before persisting/import.
bool validNativeSnapshot(Object? value, {bool allowSession = true}) {
  if (value is! Map) return false;
  if (value.isEmpty) return true;
  final domain = value['domain'];
  if (value['schemaVersion'] != 1 || (domain != 'video' && domain != 'music')) {
    return false;
  }
  if (!allowSession &&
      (value.containsKey('session') || value.containsKey('sessionAnchor'))) {
    return false;
  }
  // A separate tree budget keeps otherwise valid collections from combining
  // into an unbounded import. Typed checks below distinguish structural fields
  // from arbitrary vocabulary/creator keys; a topic named "cookie" is valid.
  var remaining = 100000;
  bool visit(Object? item, int depth) {
    if (--remaining < 0 || depth > 12) return false;
    if (item == null || item is bool) return true;
    if (item is num) return item.isFinite;
    if (item is String) return item.length <= 8000;
    if (item is List) {
      return item.length <= 20000 && item.every((e) => visit(e, depth + 1));
    }
    if (item is Map) {
      return item.length <= 20000 &&
          item.entries.every((entry) =>
              entry.key is String &&
              (entry.key as String).length <= 2048 &&
              visit(entry.value, depth + 1));
    }
    return false;
  }

  return visit(value, 0) &&
      _record(domain == 'music' ? _musicFields : _videoFields)(value);
}

typedef _StateCheck = bool Function(Object? value);

_StateCheck _number(
        {double minimum = 0, double maximum = 1e9, bool integral = false}) =>
    (value) =>
        value is num &&
        value.isFinite &&
        value >= minimum &&
        value <= maximum &&
        (!integral || value == value.truncateToDouble());

_StateCheck _text({int maximum = 512, bool nullable = false}) => (value) =>
    nullable && value == null || value is String && value.length <= maximum;

_StateCheck _list(_StateCheck item, int maximum) =>
    (value) => value is List && value.length <= maximum && value.every(item);

_StateCheck _dictionary(_StateCheck item, int maximum,
        {int keyLength = 512,
        bool nonemptyKeys = false,
        Set<String>? keys,
        RegExp? keyPattern}) =>
    (value) =>
        value is Map &&
        value.length <= maximum &&
        value.entries.every((entry) =>
            entry.key is String &&
            (entry.key as String).length <= keyLength &&
            (!nonemptyKeys || (entry.key as String).trim().isNotEmpty) &&
            (keys == null || keys.contains(entry.key)) &&
            (keyPattern == null || keyPattern.hasMatch(entry.key as String)) &&
            item(entry.value));

/// Native codecs allow absent fields as defaults, but reject unknown fields
/// and mistyped supplied fields. Keep this schema aligned with their encoders.
_StateCheck _record(Map<String, _StateCheck> fields) => (value) =>
    value is Map &&
    value.entries.every((entry) =>
        entry.key is String &&
        fields.containsKey(entry.key) &&
        fields[entry.key]!(entry.value));

bool _boolean(Object? value) => value is bool;
final _timestamp = _number(maximum: 253402300799999, integral: true);
final _counter = _number(maximum: 2147481647, integral: true);
final _probability = _number(maximum: 1);
final _stringList = _text();
final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');
final _creatorId = RegExp(r'^UC[A-Za-z0-9_-]{22}$');
bool _isCreatorId(Object? value) =>
    value is String && _creatorId.hasMatch(value);
const _videoCategories = {
  'film',
  'autos',
  'music',
  'pets',
  'sports',
  'travel',
  'gaming',
  'people',
  'comedy',
  'entertainment',
  'news',
  'howto',
  'education',
  'science',
  'nonprofits',
};
const _videoBuckets = {
  'WEEKDAY_MORNING',
  'WEEKDAY_AFTERNOON',
  'WEEKDAY_EVENING',
  'WEEKDAY_NIGHT',
  'WEEKEND_MORNING',
  'WEEKEND_AFTERNOON',
  'WEEKEND_EVENING',
  'WEEKEND_NIGHT',
};
const _musicBuckets = {
  'WeekdayMorning',
  'WeekdayAfternoon',
  'WeekdayEvening',
  'WeekdayNight',
  'WeekendMorning',
  'WeekendAfternoon',
  'WeekendEvening',
  'WeekendNight',
};

final _vector = _record({
  'topics': _dictionary(_number(), 1000),
  'duration': _probability,
  'pacing': _probability,
  'complexity': _probability,
  'isLive': _probability,
  'formats': _list(_stringList, 100),
});

// Field types and limits mirror VideoStateCodec at the pinned Flow extraction.
final Map<String, _StateCheck> _videoFields = {
  'schemaVersion': (value) => value == 1,
  'domain': (value) => value == 'video',
  'timeVectors': _dictionary(_vector, 8, keys: _videoBuckets),
  'timeBucketCounts': _dictionary(_counter, 8, keys: _videoBuckets),
  'globalVector': _vector,
  'recentVector': _vector,
  'shortsVector': _vector,
  'channelScores': _dictionary(_probability, 500),
  'topicAffinities': _dictionary(_probability, 500),
  'totalInteractions': _counter,
  'consecutiveSkips': _number(maximum: 30, integral: true),
  'blockedTopics': _list(_stringList, 1000),
  'blockedChannels': _list(_stringList, 1000),
  'preferredTopics': _list(_stringList, 1000),
  'hasCompletedOnboarding': _boolean,
  'lastPersona': _text(nullable: true),
  'personaStability': _number(maximum: 10, integral: true),
  'idfWordFrequency': _dictionary(_number(integral: true), 20000),
  'idfTotalDocuments': _counter,
  'countedDocumentIds': _list(_stringList, 500),
  'watchHistoryMap': _dictionary(_probability, 2000),
  'seenShortsHistory': _dictionary(_timestamp, 3000),
  'channelTopicProfiles': _dictionary(_dictionary(_number(), 15), 200),
  'suppressedVideoIds': _dictionary(_timestamp, 5000),
  'suppressedChannels': _dictionary(_timestamp, 100),
  'rejectionPatterns': _dictionary(
      _record({
        'count': _counter,
        'lastRejectedAt': _timestamp,
      }),
      500),
  'feedHistory': _dictionary(
      _record({
        'lastShown': _timestamp,
        'showCount': _counter,
      }),
      3000),
  'recentQueryTokens': _list(_list(_stringList, 100), 100),
  'topicEvidence': _dictionary(
      _record({
        'positiveSignals': _counter,
        'negativeSignals': _counter,
        'watchSignals': _counter,
        'explicitSignals': _counter,
        'positiveScore': _number(maximum: 50),
        'videoIds': _list(_stringList, 6),
        'channelIds': _list(_stringList, 6),
        'firstSeenAt': _timestamp,
        'lastSeenAt': _timestamp,
      }),
      500),
  'recentRelatedSeeds': _dictionary(_timestamp, 60),
  'staleQueries': _dictionary(_timestamp, 40),
  'clusterRotation': _dictionary(_timestamp, 40),
  'tagAffinities': _dictionary(_probability, 2000),
  'recentShortsSeeds': _dictionary(_timestamp, 60),
  'channelMemory': _record({
    'clearedAt': _timestamp,
    'entries': _dictionary(
        _record({
          'name': _text(),
          'rejectedAt': _timestamp,
          'forgottenAt': _timestamp,
        }),
        200),
  }),
  'interestChips': _record({
    'masses': _dictionary(_number(), 4),
    'computedAt': _timestamp,
  }),
  'coWatchSources': _dictionary(
      (value) =>
          value is Map &&
          _isCreatorId(value['channelId']) &&
          _list(_isCreatorId, 10)(value['related']) &&
          _record({
            'channelId': _isCreatorId,
            'related': _list(_isCreatorId, 10),
            'at': _timestamp,
          })(value),
      200,
      keyPattern: _videoId),
  'channelCategories': _dictionary(
      _record({
        'counts': _dictionary(_counter, 15, keys: _videoCategories),
        'at': _timestamp,
      }),
      1000,
      keyPattern: _creatorId),
  'displayForms': _dictionary(
      _record({
        'form': _text(),
        'votes': _number(minimum: 1, maximum: 20, integral: true),
      }),
      2000),
  'formatAffinity': _dictionary(_probability, 100),
  'categoryAffinity': _dictionary(_number(maximum: 400), 100),
  'languageProfile': _text(maximum: 20, nullable: true),
  'languageVotes': _dictionary(_number(integral: true), 20000),
  'keyLanguage': _text(maximum: 20, nullable: true),
  'processedEventIds': _list(_stringList, 1000),
  'session': _record({
    'startedAt': _timestamp,
    'lastAt': _timestamp,
    'videoCount': _counter,
    'topics': _list(_stringList, 50),
    'momentum': _list(_record({'topic': _text(), 'positive': _boolean}), 10),
    'impressions': _dictionary(
        _record({
          'count': _counter,
          'lastSeen': _timestamp,
        }),
        500),
  }),
};

_StateCheck _musicMap(_StateCheck item, int maximum) =>
    _dictionary(item, maximum, keyLength: 2048, nonemptyKeys: true);

// Music entity maps have independent capacities and artist/track semantics.
final Map<String, _StateCheck> _musicFields = {
  'schemaVersion': (value) => value == 1,
  'domain': (value) => value == 'music',
  'artistAffinity': _musicMap(
      _record({
        'plays': _number(maximum: 2147483647, integral: true),
        'score': _probability,
        'lastPlayed': _timestamp,
        'liked': _boolean,
        'display': _text(maximum: 4096),
      }),
      600),
  'genreAffinity': _musicMap(_probability, 200),
  'trackPlays': _musicMap(_list(_timestamp, 8), 400),
  'trackMeta': _musicMap(
      _record({
        'title': _text(maximum: 4096),
        'artist': _text(maximum: 4096),
        'artistKey': _text(maximum: 4096),
        // Older snapshots may contain the upstream placeholder; no URL is allowed.
        'thumbnail': (value) => value == '',
      }),
      400),
  'recentRotation': _musicMap(_probability, 400),
  'artistCooc': _musicMap(_number(maximum: 1e100), 2000),
  'artistRelated': _musicMap(_list(_stringList, 10), 300),
  'timeBuckets': _dictionary(_musicMap(_number(maximum: 1e100), 200), 8,
      keys: _musicBuckets),
  'seenArtists': _list(_stringList, 3000),
  'dislikedArtists': _musicMap(_timestamp, 200),
  'blockedArtists': _list(_stringList, 1000),
  'discoveryAppetite': _probability,
  'totalPlays': _number(maximum: 2147483647, integral: true),
  'lastRotationDecay': _timestamp,
  'backfilled': _boolean,
  'processedEventIds': _list(_stringList, 1000),
  'sessionAnchor': _record({
    'artistKey': _text(maximum: 4096),
    'atMs': _timestamp,
  }),
};

bool validRecommendationSetting(SettingsValue setting) {
  final domain = RecommendationDomain.values
      .where((domain) => recommendationSettingName(domain) == setting.name)
      .firstOrNull;
  final parsed = RecommendationSnapshot.tryParse(setting.value);
  return domain != null &&
      parsed != null &&
      (parsed.state.isEmpty || parsed.state['domain'] == domain.name);
}
