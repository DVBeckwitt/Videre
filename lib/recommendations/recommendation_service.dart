import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import '../content_filter/community_filter.dart';
import '../globals.dart' as globals;
import '../music/models/music_track.dart';
import '../settings/models/db/settings.dart';
import '../settings/models/db/video_filter.dart';
import '../utils/interfaces/db.dart';
import '../videos/models/video.dart';
import 'playback_checkpoint.dart';
import 'recommendation_models.dart';
import 'recommendation_snapshot.dart';

export 'recommendation_models.dart';

part 'music_dismissal.dart';

typedef RecommendationBridge = Future<Map<String, dynamic>> Function(
    Map<String, Object?> request);
typedef UndoMusicDismissal = Future<bool> Function();

/// Dart owns durable state and every network operation. The native Flow cores
/// receive bounded metadata batches and return a new, network-free snapshot.
class RecommendationService extends ChangeNotifier {
  RecommendationService._(IDbClient database, this.profileId,
      {RecommendationBridge? bridge,
      DateTime Function()? clock,
      bool Function()? isCurrent})
      : _root = database,
        _database = database.forProfile(profileId),
        _bridge = bridge ?? _nativeEvaluate,
        _clock = clock ?? DateTime.now,
        _extraCurrent = isCurrent {
    try {
      _globalOwner = identical(database, globals.db) ? database : null;
    } on Error {
      // Unit tests may construct a private database before global app startup.
    }
  }

  static final _owners = Expando<Map<String, RecommendationService>>();
  static final _live = <RecommendationService>{};
  static int _sessionGeneration = 0;
  static const _channel = MethodChannel('videre/recommendations');
  static final _log = Logger('RecommendationService');

  factory RecommendationService.forProfile(
      IDbClient database, String profileId) {
    final service = (_owners[database] ??= {}).putIfAbsent(
        profileId, () => RecommendationService._(database, profileId));
    _live.add(service);
    return service;
  }

  factory RecommendationService.forCurrentProfile() =>
      RecommendationService.forProfile(globals.db, globals.db.profileId);

  @visibleForTesting
  factory RecommendationService.forTesting(IDbClient database,
      {required RecommendationBridge bridge,
      DateTime Function()? clock,
      bool Function()? isCurrent}) {
    final service = RecommendationService._(database, database.profileId,
        bridge: bridge, clock: clock, isCurrent: isCurrent);
    _live.add(service);
    return service;
  }

  final IDbClient _root;
  final IDbClient _database;
  final String profileId;
  final RecommendationBridge _bridge;
  final DateTime Function() _clock;
  final bool Function()? _extraCurrent;
  IDbClient? _globalOwner;
  Future<void>? _pending;
  final _generations = <RecommendationDomain, int>{};
  final _sessionContexts = <RecommendationDomain, Map<String, dynamic>>{};
  bool _disposed = false;
  bool _restoring = false;
  int? _recoveredSession;
  int _feedbackSequence = 0;
  Object? _latestMusicDismissal;
  int _musicDismissalRevision = 0;

  Listenable get changes => this;

  /// Lets a rendered shelf update eligibility without replacing its order.
  int get musicDismissalRevision => _musicDismissalRevision;

  /// Call after finalizing the outgoing playback session. Already-running
  /// native calls may finish, but their old result can no longer be committed.
  static void invalidateSession() {
    _sessionGeneration++;
    for (final service in _live) {
      service._sessionContexts.clear();
    }
  }

  static Future<void> flushPending() =>
      Future.wait(List.of(_live).map((service) => service._pending).nonNulls);

  /// Dispose the inactive person's owner before deleting their database stores.
  /// Pending bridge work observes disposal and cannot resurrect the profile.
  static void forgetProfile(IDbClient database, String profileId) {
    _owners[database]?.remove(profileId)?.dispose();
  }

  int generation(RecommendationDomain domain) =>
      (_sessionGeneration << 32) + (_generations[domain] ?? 0);

  bool get isCurrent => _current;

  Map<String, dynamic> _nativeState(
          RecommendationDomain domain, RecommendationSnapshot snapshot) =>
      {
        ...snapshot.state,
        ...?_sessionContexts[domain],
      };

  bool get _current {
    if (_disposed || _restoring || _extraCurrent?.call() == false) return false;
    try {
      return _root.profileId == profileId &&
          _database.profileId == profileId &&
          (_globalOwner == null || identical(_globalOwner, globals.db));
    } on Object {
      return false;
    }
  }

  bool _valid(RecommendationDomain domain, int token) =>
      _current && generation(domain) == token;

  RecommendationSnapshot _read(RecommendationDomain domain) {
    if (!_current) return const RecommendationSnapshot(enabled: false);
    final raw = _database.getSettings(recommendationSettingName(domain))?.value;
    // A damaged snapshot must not silently re-enable learning.
    if (raw != null &&
        !validRecommendationSetting(
            SettingsValue(recommendationSettingName(domain), raw))) {
      return const RecommendationSnapshot(enabled: false);
    }
    return RecommendationSnapshot.tryParse(raw) ??
        const RecommendationSnapshot(enabled: false);
  }

  bool learningEnabled(RecommendationDomain domain) => _read(domain).enabled;

  int blockedCount(RecommendationDomain domain) {
    final snapshot = _read(domain);
    return snapshot.blockedIds.length + snapshot.blockedCreators.length;
  }

  String _nativeBlockField(RecommendationDomain domain) =>
      domain == RecommendationDomain.video
          ? 'blockedChannels'
          : 'blockedArtists';

  Set<String> _nativeCreatorBlocks(
      RecommendationDomain domain, RecommendationSnapshot snapshot) {
    final keys = snapshot.state[_nativeBlockField(domain)];
    return keys is List ? keys.whereType<String>().toSet() : const {};
  }

  List<({String key, String label})> blockedCreators(
      RecommendationDomain domain) {
    final snapshot = _read(domain);
    final creators = {
      ...snapshot.blockedCreators,
      ..._nativeCreatorBlocks(domain, snapshot),
    };
    final affinities = snapshot.state['artistAffinity'];
    String labelFor(String key) {
      final saved = snapshot.blockedCreatorLabels[key];
      if (saved != null && saved.isNotEmpty) return saved;
      final affinity = affinities is Map ? affinities[key] : null;
      final display = affinity is Map ? affinity['display'] : null;
      if (display is String && display.isNotEmpty) return display;
      return key.replaceFirst(RegExp(r'^(?:uploader|name|track):'), '');
    }

    return [for (final key in creators) (key: key, label: labelFor(key))]
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  }

  /// Flow's individual unblock removes the hard block and preserves affinity,
  /// past listens and temporary rejection/cooldown state.
  Future<void> unblockCreator(RecommendationDomain domain, String creatorKey) {
    final token = generation(domain);
    return _serialized(() async {
      if (!_valid(domain, token)) return;
      final snapshot = _read(domain);
      final local = {...snapshot.blockedCreators};
      final native = {..._nativeCreatorBlocks(domain, snapshot)};
      final removedLocal = local.remove(creatorKey);
      final removedNative = native.remove(creatorKey);
      if (!removedLocal && !removedNative) return;
      final next = snapshot.copyWith(
          state: {
            ...snapshot.state,
            if (removedNative) _nativeBlockField(domain): native.toList(),
          },
          blockedCreators: local,
          blockedCreatorLabels: {...snapshot.blockedCreatorLabels}
            ..remove(creatorKey),
          revision: snapshot.revision + 1);
      await _write(domain, next, token);
      if (_valid(domain, token)) notifyListeners();
    });
  }

  bool _allowed(Video video,
          {required bool music,
          List<VideoFilter>? filters,
          bool includeCommunityHidden = false}) =>
      !video.filtered &&
      !video.filterHide &&
      !(filters ?? _database.getAllFilters())
          .any((f) => f.filterVideo(video)) &&
      (includeCommunityHidden ||
          !communityFilters
              .match(
                  authorId: video.authorId,
                  authorUrl: video.authorUrl,
                  music: music)
              .any((match) => match.action == CommunityAction.hide));

  List<T> _eligible<T>(RecommendationDomain domain, Iterable<T> values,
      RecommendationCandidate Function(T) metadata, Video Function(T) toVideo,
      {bool includeCommunityHidden = false}) {
    if (!_current) return const [];
    final snapshot = _read(domain);
    late final filters = _database.getAllFilters();
    // MusicBrain can escalate repeated dislikes without a host-side block.
    // Local shelves and fallback results must honor that exclusion too.
    final blockedCreators = {
      ...snapshot.blockedCreators,
      ..._nativeCreatorBlocks(domain, snapshot),
    };
    final ids = <String>{};
    final result = <T>[];
    for (final value in values) {
      final candidate = metadata(value);
      if (!candidate.valid ||
          snapshot.blockedIds.contains(candidate.id) ||
          blockedCreators.contains(candidate.creatorKey) ||
          !_allowed(toVideo(value),
              music: domain == RecommendationDomain.music,
              filters: filters,
              includeCommunityHidden: includeCommunityHidden) ||
          !ids.add(candidate.id)) {
        continue;
      }
      result.add(value);
      if (result.length == recommendationMaximumCandidates) break;
    }
    return result;
  }

  /// Admission is useful even when native ranking is unavailable. Callers can
  /// show an honestly labeled unranked shelf without restoring excluded items.
  List<Video> eligibleVideos(Iterable<Video> videos,
          {bool includeCommunityHidden = false}) =>
      _eligible(RecommendationDomain.video, videos,
          RecommendationCandidate.video, (video) => video,
          includeCommunityHidden: includeCommunityHidden);

  List<MusicTrack> eligibleMusic(Iterable<MusicTrack> tracks,
          {bool includeCommunityHidden = false}) =>
      _eligible(RecommendationDomain.music, tracks,
          RecommendationCandidate.music, (track) => track.toVideo(),
          includeCommunityHidden: includeCommunityHidden);

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final work = (_pending ?? Future<void>.value()).then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    _pending = work;
    unawaited(work.whenComplete(() {
      if (identical(_pending, work)) _pending = null;
    }));
    return completer.future;
  }

  static Future<Map<String, dynamic>> _nativeEvaluate(
      Map<String, Object?> request) async {
    final value = await _channel.invokeMethod<Object?>('evaluate', request);
    if (value is! Map) {
      throw const FormatException('Invalid recommendation response');
    }
    return jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  }

  Future<RecommendationResult<Video>> rankVideos(List<Video> videos,
      {String surface = 'home',
      Set<String> onlineSubscriptionCreators = const {},
      Map<String, String>? subscriptionChannels}) async {
    final token = generation(RecommendationDomain.video);
    if (!_valid(RecommendationDomain.video, token)) {
      return const RecommendationResult.cancelled();
    }
    final subscriptions = <String, String>{
      for (final id in onlineSubscriptionCreators) id: '',
      ...?subscriptionChannels,
    };
    if (subscriptionChannels == null) {
      try {
        subscriptions.addEntries((await _database.getOfflineSubscriptions())
            .map((row) => MapEntry(row.channelId, row.channelName)));
      } on UnsupportedError {
        // Some isolated database adapters do not store subscriptions.
      }
    }
    if (!_valid(RecommendationDomain.video, token)) {
      return const RecommendationResult.cancelled();
    }
    return _rank(RecommendationDomain.video, videos,
        RecommendationCandidate.video, (v) => v.videoId,
        surface: surface,
        subscriptionChannels: subscriptions,
        expectedGeneration: token,
        toVideo: (v) => v);
  }

  Future<RecommendationResult<MusicTrack>> rankMusic(List<MusicTrack> tracks,
          {String surface = 'quick_picks',
          Map<String, String> subscriptionChannels = const {}}) =>
      _rank(RecommendationDomain.music, tracks, RecommendationCandidate.music,
          (track) => track.videoId,
          surface: surface,
          subscriptionChannels: subscriptionChannels,
          toVideo: (track) => track.toVideo());

  Map<String, String> _subscriptionInput(
      RecommendationDomain domain,
      RecommendationSnapshot snapshot,
      Map<String, String> channels,
      List<VideoFilter> allFilters) {
    final music = domain == RecommendationDomain.music;
    final filters = allFilters.where(
        (filter) => filter.filterAll || filter.type == FilterType.channelName);
    final admitted = <String, String>{};
    for (final entry in channels.entries) {
      final id = entry.key.trim();
      final name = String.fromCharCodes(entry.value.trim().runes.take(150));
      if (!_channelId.hasMatch(id) ||
          snapshot.blockedCreators.contains(id) ||
          (music &&
              (snapshot.blockedCreators.contains('uploader:$id') ||
                  snapshot.blockedCreators
                      .contains('name:${name.toLowerCase()}'))) ||
          filters.any((filter) => filter
              .filterVideo(Video(videoId: '', authorId: id, author: name))) ||
          communityFilters
              .match(authorId: id, music: music)
              .any((match) => match.action == CommunityAction.hide)) {
        continue;
      }
      admitted[id] = name;
      if (admitted.length == 200) break;
    }
    return admitted;
  }

  Future<RecommendationResult<T>> _rank<T>(
      RecommendationDomain domain,
      List<T> values,
      RecommendationCandidate Function(T) metadata,
      String Function(T) id,
      {required String surface,
      required Map<String, String> subscriptionChannels,
      int? expectedGeneration,
      required Video Function(T) toVideo}) {
    final token = expectedGeneration ?? generation(domain);
    return _serialized(() async {
      if (!_valid(domain, token)) {
        return RecommendationResult<T>.cancelled();
      }
      final snapshot = _read(domain);
      late final filters = _database.getAllFilters();
      final subscriptions = snapshot.enabled && subscriptionChannels.isNotEmpty
          ? _subscriptionInput(domain, snapshot, subscriptionChannels, filters)
          : const <String, String>{};
      final blockedCreators = {
        ...snapshot.blockedCreators,
        ..._nativeCreatorBlocks(domain, snapshot),
      };
      final items = <String, T>{};
      final candidates = <Map<String, Object?>>[];
      for (final item in values) {
        final candidate = metadata(item);
        if (!candidate.valid ||
            items.containsKey(id(item)) ||
            snapshot.blockedIds.contains(candidate.id) ||
            blockedCreators.contains(candidate.creatorKey) ||
            !_allowed(toVideo(item),
                music: domain == RecommendationDomain.music,
                filters: filters)) {
          continue;
        }
        items[id(item)] = item;
        candidates.add({
          ...candidate.data,
          if (domain == RecommendationDomain.video)
            'isSubscribed':
                subscriptions.containsKey(candidate.data['authorId']),
        });
        if (items.length == recommendationMaximumCandidates) break;
      }
      try {
        final response = await _bridge({
          'domain': domain.name,
          'state': _nativeState(domain, snapshot),
          'candidates': candidates,
          'events': <Object?>[],
          if (subscriptions.isNotEmpty)
            'subscriptionChannels': [
              for (final entry in subscriptions.entries)
                {'id': entry.key, 'name': entry.value},
            ],
          'surface': surface,
          'nowMs': _clock().millisecondsSinceEpoch,
          'seed': 0,
        });
        if (!_valid(domain, token)) {
          return RecommendationResult<T>.cancelled();
        }
        final rows = response['ranked'];
        if (rows is! List || rows.length > recommendationMaximumCandidates) {
          throw const FormatException('Invalid recommendation ranking');
        }
        final seen = <String>{};
        final ranked = <RecommendedItem<T>>[];
        for (final row in rows) {
          if (row is! Map || row['id'] is! String) continue;
          final key = row['id'] as String;
          final item = items[key];
          final score = row['score'];
          final reason = row['reason'];
          if (item == null ||
              !seen.add(key) ||
              score is! num ||
              !score.isFinite ||
              reason is! String ||
              reason.length > 1000) {
            continue;
          }
          ranked.add(
              RecommendedItem(item, score: score.toDouble(), reason: reason));
        }
        final summary = response['summary'];
        if (domain == RecommendationDomain.video && surface == 'home') {
          // Flow keeps the last chosen chip set so labels and order do not
          // reshuffle on every render. Preserve only this rank bookkeeping.
          final state = response['state'];
          final chips = state is Map ? state['interestChips'] : null;
          final previous = snapshot.state['interestChips'];
          if (chips is Map &&
              chips['masses'] is Map &&
              ((chips['masses'] as Map).isNotEmpty || previous != null) &&
              validNativeSnapshot({
                'schemaVersion': 1,
                'domain': 'video',
                'interestChips': chips,
              }) &&
              jsonEncode(chips) != jsonEncode(previous) &&
              _read(domain).encode() == snapshot.encode()) {
            try {
              await _write(
                  domain,
                  snapshot.copyWith(state: {
                    ...snapshot.state,
                    'schemaVersion': 1,
                    'domain': 'video',
                    'interestChips': chips,
                  }),
                  token);
            } on FormatException {
              // A full snapshot can still serve the new in-memory ranking.
            }
            if (!_valid(domain, token)) return RecommendationResult.cancelled();
          }
        }
        return RecommendationResult(
            items: List.unmodifiable(ranked),
            available: true,
            summary:
                summary is Map ? Map<String, dynamic>.from(summary) : const {});
      } on MissingPluginException {
        return RecommendationResult<T>.unavailable('unavailable');
      } on PlatformException {
        return RecommendationResult<T>.unavailable('failed');
      } on FormatException {
        return RecommendationResult<T>.unavailable('failed');
      }
    });
  }

  Future<void> recordPlayback(Video video,
      {required RecommendationDomain domain,
      required Duration played,
      required Duration duration,
      required String sessionId,
      bool skipped = false,
      bool completed = false,
      int? expectedGeneration}) {
    final event = _playbackEvent(video, domain, played, duration, sessionId);
    if (event == null) return Future.value();
    return _learn(
        domain, {...event, 'skipped': skipped, 'completed': completed},
        playbackVideo: video,
        relatedVideos: domain == RecommendationDomain.video
            ? video.recommendedVideos
            : const [],
        expectedGeneration: expectedGeneration);
  }

  Map<String, Object?>? _playbackEvent(Video video, RecommendationDomain domain,
      Duration played, Duration duration, String sessionId) {
    if (played.inMilliseconds <= 0 ||
        duration <= Duration.zero ||
        sessionId.isEmpty ||
        sessionId.length > 180) {
      return null;
    }
    final candidate = domain == RecommendationDomain.music
        ? RecommendationCandidate.fromMusicVideo(video)
        : RecommendationCandidate.video(video);
    if (!candidate.valid) return null;
    return {
      'id': 'play:$sessionId',
      'type': 'listen',
      'candidate': candidate.data,
      'playedMs':
          played.inMilliseconds.clamp(0, PlaybackCheckpoint.maxPlayedMs),
      'durationMs':
          duration.inMilliseconds.clamp(1, PlaybackCheckpoint.maxPlayedMs),
      'timeMs': _clock().millisecondsSinceEpoch,
    };
  }

  /// Persist cumulative confirmed time for this occurrence. A checkpoint does
  /// not apply any learning or notify recommendation shelves.
  Future<void> checkpointPlayback(Video video,
      {required RecommendationDomain domain,
      required Duration played,
      required Duration duration,
      required String sessionId,
      required int expectedGeneration}) {
    final event = _playbackEvent(video, domain, played, duration, sessionId);
    if (event == null) return Future.value();
    return _serialized(() async {
      if (!_valid(domain, expectedGeneration)) return;
      final snapshot = _read(domain);
      if (!snapshot.enabled ||
          snapshot.eventIds.contains(event['id']) ||
          !_admittedPlayback(domain, snapshot, video, event)) {
        return;
      }
      await _storeCheckpoint(domain, snapshot, event, expectedGeneration);
    });
  }

  bool _admittedPlayback(
      RecommendationDomain domain,
      RecommendationSnapshot snapshot,
      Video video,
      Map<String, Object?> event) {
    final candidate = event['candidate'] as Map<String, Object?>;
    final creator = candidate['artistKey'] ?? candidate['authorId'];
    return !snapshot.blockedIds.contains(video.videoId) &&
        !snapshot.blockedCreators.contains(creator) &&
        !_nativeCreatorBlocks(domain, snapshot).contains(creator) &&
        _allowed(video, music: domain == RecommendationDomain.music);
  }

  Future<void> _retirePlaybackCheckpoint(RecommendationDomain domain,
      RecommendationSnapshot snapshot, String eventId, int token) async {
    final pending =
        snapshot.pendingPlayback.where((entry) => entry.id != eventId).toList();
    if (pending.length == snapshot.pendingPlayback.length) return;
    await _write(domain, snapshot.copyWith(pendingPlayback: pending), token);
  }

  Future<RecommendationSnapshot> _storeCheckpoint(
      RecommendationDomain domain,
      RecommendationSnapshot snapshot,
      Map<String, Object?> event,
      int token) async {
    final checkpoint = PlaybackCheckpoint.create(
        id: event['id'] as String,
        epoch: snapshot.learningEpoch,
        playedMs: event['playedMs'] as int,
        durationMs: event['durationMs'] as int,
        timeMs: event['timeMs'] as int,
        candidate: event['candidate'] as Map<String, Object?>);
    if (PlaybackCheckpoint.tryParse(checkpoint.toJson()) == null) {
      return snapshot;
    }
    final previous = snapshot.pendingPlayback
        .where((entry) => entry.id == checkpoint.id)
        .firstOrNull;
    if (previous != null && previous.playedMs >= checkpoint.playedMs) {
      return snapshot;
    }
    final pending = [
      ...snapshot.pendingPlayback.where((entry) => entry.id != checkpoint.id),
      checkpoint,
    ];
    final next = snapshot.copyWith(
        pendingPlayback: pending.length > recommendationMaximumPending
            ? pending.sublist(pending.length - recommendationMaximumPending)
            : pending);
    await _write(domain, next, token);
    return next;
  }

  /// Called once per profile activation before new playback records can queue.
  /// Every recovered occurrence uses its saved time with no skip/completion.
  Future<void> recoverPlayback() async {
    if (!_current || _recoveredSession == _sessionGeneration) return;
    _recoveredSession = _sessionGeneration;
    final saved = [
      for (final domain in RecommendationDomain.values)
        for (final checkpoint in _read(domain).pendingPlayback)
          (domain, checkpoint, generation(domain)),
    ]..sort((a, b) => a.$2.timeMs.compareTo(b.$2.timeMs));
    await Future.wait([
      for (final (domain, checkpoint, token) in saved)
        _learn(domain, checkpoint.event,
            recovery: checkpoint, expectedGeneration: token),
    ]);
  }

  /// The backup transaction owns this profile until its replacement is done.
  /// Drain old work and invalidate IDs held by a closing player first.
  Future<void> restoreBackup(Future<void> Function() restore) async {
    _restoring = true;
    for (final domain in RecommendationDomain.values) {
      _generations[domain] = (_generations[domain] ?? 0) + 1;
    }
    _sessionContexts.clear();
    try {
      await _pending;
      await restore();
    } finally {
      _restoring = false;
      if (_current) notifyListeners();
    }
  }

  Future<void> recordSearch(String query, RecommendationDomain domain,
      {int? expectedGeneration}) {
    if (!_current ||
        _database.getSettings(useSearchHistorySettingName)?.value == 'false') {
      return Future.value();
    }
    final text = String.fromCharCodes(query.trim().runes.take(200));
    if (text.isEmpty) return Future.value();
    return _learn(
        domain,
        {
          'id':
              'search:${_clock().microsecondsSinceEpoch}:${_feedbackSequence++}',
          'type': 'search',
          'query': text,
          'timeMs': _clock().millisecondsSinceEpoch,
        },
        expectedGeneration: expectedGeneration);
  }

  /// Only the owning viewport supplies cards it has actually shown.
  /// Impressions affect the next ranking without reranking an active scroll.
  Future<void> recordVideoImpressions(List<Video> videos,
      {int? expectedGeneration, bool Function()? isCurrent}) {
    const domain = RecommendationDomain.video;
    final token = expectedGeneration ?? generation(domain);
    final seenAt = _clock();
    bool active() => _valid(domain, token) && isCurrent?.call() != false;
    return _serialized(() async {
      try {
        if (!active()) return;
        final snapshot = _read(domain);
        if (!snapshot.enabled) return;
        final admitted = eligibleVideos(videos).take(24).toList();
        if (admitted.isEmpty) return;
        final result = await _evaluateLearning(domain, snapshot, [
          for (final video in admitted)
            {
              'id':
                  'impression:${video.videoId}:${seenAt.microsecondsSinceEpoch}:${_feedbackSequence++}',
              'type': 'impression',
              'candidate': {'id': video.videoId},
              'timeMs': seenAt.millisecondsSinceEpoch,
            },
        ]);
        // The native Flow window rejects a repeated sighting within 30 minutes.
        if (!active() ||
            result.applied == 0 ||
            _read(domain).encode() != snapshot.encode()) {
          return;
        }
        await _write(
            domain,
            snapshot.copyWith(
                state: result.state, revision: snapshot.revision + 1),
            token);
        if (_valid(domain, token)) _sessionContexts[domain] = result.session;
      } on Object {
        // Optional exposure learning cannot interrupt a feed. Avoid recording
        // errors that may contain full settings values or candidate metadata.
        _log.fine('Could not record local video impressions');
      }
    });
  }

  Future<void> recordVideoClick(Video video,
      {required String occurrenceId, int? expectedGeneration}) {
    final candidate = RecommendationCandidate.video(video);
    if (!candidate.valid || occurrenceId.isEmpty || occurrenceId.length > 180) {
      return Future.value();
    }
    return _learn(
        RecommendationDomain.video,
        {
          'id': 'click:$occurrenceId',
          'type': 'click',
          'candidate': candidate.data,
          'timeMs': _clock().millisecondsSinceEpoch,
        },
        passiveVideo: video,
        expectedGeneration: expectedGeneration);
  }

  Future<void> feedback(Video video, RecommendationDomain domain,
          RecommendationFeedback feedback, {int? expectedGeneration}) =>
      _recordFeedback(video, domain, feedback,
          expectedGeneration: expectedGeneration);

  /// Records a dismissal and returns an action for the latest dismissal in
  /// the current profile session. A stale or already excluded item has no undo.
  Future<UndoMusicDismissal?> dismissMusicRecommendation(
      MusicTrack track, RecommendationFeedback feedback) async {
    if (feedback != RecommendationFeedback.notInterested &&
        feedback != RecommendationFeedback.block) {
      throw ArgumentError.value(feedback, 'feedback');
    }
    const domain = RecommendationDomain.music;
    final token = generation(domain);
    final identity = Object();
    UndoMusicDismissal? undo;
    await _recordFeedback(track.toVideo(), domain, feedback,
        expectedGeneration: token, onDismissed: (dismissal) {
      _latestMusicDismissal = identity;
      _musicDismissalRevision++;
      undo = () => _serialized(() async {
            if (!_valid(domain, token) ||
                !identical(_latestMusicDismissal, identity)) {
              return false;
            }
            final snapshot = _read(domain);
            final restored = dismissal.restore(snapshot);
            if (restored == null) return false;
            await _write(domain, restored, token);
            if (!_valid(domain, token)) return false;
            _latestMusicDismissal = null;
            _musicDismissalRevision++;
            notifyListeners();
            return true;
          });
    });
    return undo;
  }

  Future<void> _recordFeedback(
      Video video, RecommendationDomain domain, RecommendationFeedback feedback,
      {int? expectedGeneration, ValueChanged<_MusicDismissal>? onDismissed}) {
    final candidate = domain == RecommendationDomain.music
        ? RecommendationCandidate.fromMusicVideo(video)
        : RecommendationCandidate.video(video);
    return _learn(
        domain,
        {
          'id':
              'feedback:${_clock().microsecondsSinceEpoch}:${_feedbackSequence++}',
          'type': feedback.name,
          'candidate': candidate.data,
          'timeMs': _clock().millisecondsSinceEpoch,
        },
        explicit: true,
        candidate: candidate,
        feedback: feedback,
        relatedVideos: domain == RecommendationDomain.video &&
                (feedback == RecommendationFeedback.like ||
                    feedback == RecommendationFeedback.save)
            ? video.recommendedVideos
            : const [],
        expectedGeneration: expectedGeneration,
        onDismissed: onDismissed);
  }

  Future<void> _learn(RecommendationDomain domain, Map<String, Object?> event,
      {int? expectedGeneration,
      bool explicit = false,
      RecommendationCandidate? candidate,
      RecommendationFeedback? feedback,
      Video? passiveVideo,
      Video? playbackVideo,
      PlaybackCheckpoint? recovery,
      List<Video> relatedVideos = const [],
      ValueChanged<_MusicDismissal>? onDismissed}) {
    final token = expectedGeneration ?? generation(domain);
    bool searchAllowed() =>
        event['type'] != 'search' ||
        _database.getSettings(useSearchHistorySettingName)?.value != 'false';
    return _serialized(() async {
      if (!_valid(domain, token) || !searchAllowed()) return;
      var snapshot = _read(domain);
      if (onDismissed != null &&
          (!candidate!.valid ||
              snapshot.blockedIds.contains(candidate.id) ||
              snapshot.blockedCreators.contains(candidate.creatorKey) ||
              _nativeCreatorBlocks(domain, snapshot)
                  .contains(candidate.creatorKey))) {
        return;
      }
      if (!explicit && !snapshot.enabled) return;
      if (passiveVideo != null &&
          !_admittedPlayback(domain, snapshot, passiveVideo, event)) {
        return;
      }
      final eventId = event['id'] as String;
      if (recovery != null &&
          (recovery.epoch != snapshot.learningEpoch ||
              !snapshot.pendingPlayback.any((entry) => entry.id == eventId))) {
        return;
      }
      final playback = playbackVideo ?? recovery?.video;
      if (snapshot.eventIds.contains(eventId) ||
          (playback != null &&
              !_admittedPlayback(domain, snapshot, playback, event))) {
        if (playback != null) {
          await _retirePlaybackCheckpoint(domain, snapshot, eventId, token);
        }
        return;
      }
      if (playbackVideo != null) {
        try {
          snapshot = await _storeCheckpoint(domain, snapshot, event, token);
        } on FormatException {
          // A large model can still accept an event without extra journal data.
        }
        if (!_valid(domain, token)) return;
      }
      final relatedChannels = <String>{};
      if (snapshot.enabled && relatedVideos.isNotEmpty) {
        // The source already came from Videre's admitted playback metadata.
        // Never supplement a missing related list with a hidden network lookup.
        for (final video in eligibleVideos(relatedVideos.take(100))) {
          final channel = video.authorId;
          if (channel != null && _channelId.hasMatch(channel)) {
            relatedChannels.add(channel);
          }
          if (relatedChannels.length == 10) break;
        }
      }
      final ids = {...snapshot.blockedIds};
      final creators = {...snapshot.blockedCreators};
      final creatorLabels = {...snapshot.blockedCreatorLabels};
      if (candidate != null && candidate.valid) {
        switch (feedback) {
          case RecommendationFeedback.notInterested:
          case RecommendationFeedback.dislike:
            ids.add(candidate.id);
          case RecommendationFeedback.block:
            if (candidate.creatorKey.isNotEmpty &&
                candidate.creatorKey.length <= 400) {
              creators.add(candidate.creatorKey);
              final display =
                  candidate.data['artist'] ?? candidate.data['author'];
              if (display is String && display.isNotEmpty) {
                creatorLabels[candidate.creatorKey] =
                    String.fromCharCodes(display.trim().runes.take(160));
              }
            } else {
              ids.add(candidate.id);
            }
          case RecommendationFeedback.unblock:
            ids.remove(candidate.id);
            creators.remove(candidate.creatorKey);
            creatorLabels.remove(candidate.creatorKey);
          case RecommendationFeedback.like:
            ids.remove(candidate.id);
          default:
            break;
        }
      }
      // Explicit exclusions work even if native ranking is temporarily absent.
      final exclusionsChanged = !setEquals(ids, snapshot.blockedIds) ||
          !setEquals(creators, snapshot.blockedCreators);
      final boundedCreators = creators.take(2000).toSet();
      var next = snapshot.copyWith(
          blockedIds: ids.take(2000).toSet(),
          blockedCreators: boundedCreators,
          blockedCreatorLabels: {
            for (final entry in creatorLabels.entries)
              if (boundedCreators.contains(entry.key)) entry.key: entry.value,
          });
      if (onDismissed != null &&
          !next.blockedIds.contains(candidate!.id) &&
          !next.blockedCreators.contains(candidate.creatorKey)) {
        throw const FormatException('Recommendation exclusions are full');
      }
      Map<String, dynamic>? nextSession;
      try {
        final result = await _evaluateLearning(domain, snapshot, [
          {
            ...event,
            if (relatedChannels.isNotEmpty)
              'relatedChannels': relatedChannels.toList(),
          },
        ]);
        if (!_valid(domain, token)) return;
        nextSession = result.session;
        next = next.copyWith(state: result.state);
      } on MissingPluginException {
        if (!exclusionsChanged) {
          if (explicit) rethrow;
          return;
        }
      } on PlatformException {
        if (!exclusionsChanged) {
          if (explicit) rethrow;
          return;
        }
      } on FormatException {
        if (!exclusionsChanged) {
          if (explicit) rethrow;
          return;
        }
      }
      if (!_valid(domain, token) || !searchAllowed()) return;
      // An import/restore can replace settings without using this service.
      // Never overwrite that newer choice with a late native snapshot.
      if (_read(domain).encode() != snapshot.encode()) return;
      if (playback != null &&
          !_admittedPlayback(domain, snapshot, playback, event)) {
        await _retirePlaybackCheckpoint(domain, snapshot, eventId, token);
        return;
      }
      final events = [...snapshot.eventIds, eventId];
      next = next.copyWith(
          revision: snapshot.revision + 1,
          pendingPlayback: snapshot.pendingPlayback
              .where((entry) => entry.id != eventId)
              .toList(),
          eventIds: events.length > recommendationMaximumEvents
              ? events.sublist(events.length - recommendationMaximumEvents)
              : events);
      await _write(domain, next, token);
      if (_valid(domain, token)) {
        if (nextSession != null) _sessionContexts[domain] = nextSession;
        if (onDismissed != null) {
          onDismissed(_MusicDismissal(candidate!, eventId, snapshot, next));
        }
        notifyListeners();
      }
    });
  }

  Future<
          ({
            Map<String, dynamic> state,
            Map<String, dynamic> session,
            int? applied,
          })>
      _evaluateLearning(
          RecommendationDomain domain,
          RecommendationSnapshot snapshot,
          List<Map<String, Object?>> events) async {
    final response = await _bridge({
      'domain': domain.name,
      'state': _nativeState(domain, snapshot),
      'candidates': <Object?>[],
      'events': events,
      'nowMs': _clock().millisecondsSinceEpoch,
      'seed': 0,
    });
    final state = response['state'];
    if (state is! Map ||
        !validNativeSnapshot(state) ||
        (state['domain'] != null && state['domain'] != domain.name)) {
      throw const FormatException('Invalid recommendation snapshot');
    }
    final durable = Map<String, dynamic>.from(state);
    final key =
        domain == RecommendationDomain.music ? 'sessionAnchor' : 'session';
    final ephemeral = durable.remove(key);
    final summary = response['summary'];
    final applied = summary is Map ? summary['appliedEvents'] : null;
    return (
      state: durable,
      session: {if (ephemeral != null) key: ephemeral},
      applied: applied is int ? applied : null,
    );
  }

  static final _channelId = RegExp(r'^UC[A-Za-z0-9_-]{22}$');

  Future<void> _write(RecommendationDomain domain,
      RecommendationSnapshot snapshot, int token) async {
    if (!_valid(domain, token)) return;
    final text = snapshot.encode();
    if (utf8.encode(text).length > recommendationMaximumBytes) {
      throw const FormatException('Recommendation state is too large');
    }
    await _database
        .saveSetting(SettingsValue(recommendationSettingName(domain), text));
  }

  Future<void> setLearningEnabled(RecommendationDomain domain, bool value) {
    _generations[domain] = (_generations[domain] ?? 0) + 1;
    _sessionContexts.remove(domain);
    final token = generation(domain);
    return _serialized(() async {
      if (!_valid(domain, token)) return;
      final snapshot = _read(domain);
      await _write(
          domain,
          snapshot.copyWith(
              enabled: value,
              revision: snapshot.revision + 1,
              learningEpoch: _nextEpoch(snapshot),
              pendingPlayback: const []),
          token);
      if (_valid(domain, token)) notifyListeners();
    });
  }

  Future<void> reset(RecommendationDomain domain) {
    _generations[domain] = (_generations[domain] ?? 0) + 1;
    _sessionContexts.remove(domain);
    final token = generation(domain);
    return _serialized(() async {
      if (!_valid(domain, token)) return;
      final previous = _read(domain);
      await _write(
          domain,
          RecommendationSnapshot(
              enabled: previous.enabled,
              revision: previous.revision + 1,
              learningEpoch: _nextEpoch(previous)),
          token);
      if (_valid(domain, token)) notifyListeners();
    });
  }

  static int _nextEpoch(RecommendationSnapshot snapshot) =>
      snapshot.learningEpoch == PlaybackCheckpoint.maxEpoch
          ? 1
          : snapshot.learningEpoch + 1;

  @override
  void dispose() {
    _disposed = true;
    _live.remove(this);
    super.dispose();
  }
}
