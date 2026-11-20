import 'dart:async';
import 'dart:convert';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart' show listEquals, mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../app/states/app.dart';
import '../../../content_filter/community_filter.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../network/network_proxy.dart';
import '../../../player/states/player.dart' show PlayerCubit;
import '../../../recommendations/candidate_sources.dart';
import '../../../recommendations/recommendation_service.dart';
import '../../../recommendations/subscription_recommendations.dart';
import '../../../recommendations/subscription_revision.dart';
import '../../../recommendations/views/recommendation_settings.dart';
import '../../../router.dart';
import '../../../settings/models/errors/invidious_service_error.dart';
import '../../../settings/states/settings.dart';
import '../../../utils/interfaces/db.dart';
import '../../../utils/models/paginated_list.dart';
import '../../../utils/views/tv/components/tv_horizontal_item_list.dart';
import '../../../videos/views/tv/components/video_item.dart';
import '../../../videos/models/community_video_filter.dart';
import '../../../videos/models/db/progress.dart';
import '../../../videos/models/video.dart';
import '../../../videos/services/watch_history.dart';
import '../../../videos/views/components/community_browse.dart';
import '../../../videos/views/components/video_in_list.dart';
import '../../../videos/views/components/video_modal_sheet.dart';
import '../../../videos/views/components/recommendation_actions.dart';
import '../../models/db/home_layout.dart';
import '../../models/home_tabs_layout.dart';
import '../screens/home_tabs_editor.dart';

/// Flow's HomeScreen/HomeFeedGrid at 565d1f7 is the presentation reference.
/// This Flutter implementation retains Videre's local state and Invidious
/// provider. No upstream URL, extractor, image loader or asset is used.
class FlowVideoHome extends StatefulWidget {
  final bool active;
  final bool television;
  final List<Widget> leadingChips;
  final Widget? editAction;
  final Widget Function(Widget? continueWatching)? configuredFeed;
  final ValueChanged<List<RecommendationInterest>>? onEdit;

  const FlowVideoHome(
      {super.key,
      this.active = true,
      this.television = false,
      this.leadingChips = const [],
      this.editAction,
      this.configuredFeed,
      this.onEdit});

  @override
  State<FlowVideoHome> createState() => _FlowVideoHomeState();
}

/// The compact, scrolling feed filter row used by both Home views.
class FlowHomeChipStrip extends StatelessWidget {
  final List<Widget> chips;
  final Widget? trailing;

  const FlowHomeChipStrip({super.key, required this.chips, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        chipTheme: theme.chipTheme.copyWith(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          selectedColor: theme.colorScheme.surfaceContainerHighest,
          showCheckmark: true,
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 4),
            child: Row(children: [
              for (var i = 0; i < chips.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                chips[i],
              ],
            ]),
          ),
        ),
        if (trailing case final action?) action,
      ]),
    );
  }
}

/// Resume suggestions only use cached metadata; opening Home never resolves
/// missing history through a network endpoint.
List<Video> continuingVideos(IDbClient owner, {int limit = 12}) {
  final watched = WatchRepository.forDatabase(owner);
  final filters = owner.getAllFilters();
  return owner
      .getLocalHistory()
      .where((entry) {
        if (entry.musicMetadata != null) return false;
        final progress = owner.getVideoPlaybackProgress(entry.videoId);
        return progress.progress.isFinite &&
            progress.progress > 0 &&
            progress.progress < watchedProgressThreshold &&
            watched?.isWatched(entry.videoId) != true &&
            !filters.any((filter) => filter.filterVideo(entry.toVideo()));
      })
      .take(limit)
      .map((entry) => entry.toVideo())
      .toList();
}

typedef _PreparedTab = ({
  List<Video> found,
  List<Video> ranked,
  Map<String, String> reasons,
  bool available,
});

typedef _TabRequest = ({String tab, List<String> queries, Video? seed});

String _requestKey(_TabRequest request) =>
    jsonEncode([request.tab, request.queries, request.seed?.videoId]);

class _FlowVideoHomeState extends State<FlowVideoHome>
    with WidgetsBindingObserver {
  late final String _profile = db.profileId;
  late final IDbClient _owner = db.forProfile(_profile);
  late final RecommendationService _engine =
      RecommendationService.forProfile(db, _profile);
  late final AppCubit _app = context.read<AppCubit>();
  late final SettingsCubit _settings = context.read<SettingsCubit>();
  late HomeTabsLayout _layout = _settings.state.homeTabsLayout;
  late String? _selectedTab = _initialSelection(_layout);
  bool _feedsVisited = false;
  bool _discoveryPrepared = false;
  String? _enteredQuery;
  bool _catalogKnown = false;
  Video? _discoverySeed;
  final _preparedTabs = <String, _PreparedTab?>{};
  Object? _preparation;
  bool _preparationStopped = false;
  DateTime? _retryNotBefore;
  late String _region = _settings.state.country.code;
  late final int _session = _app.state.sessionRevision;
  late final RecommendationCandidates _sources =
      RecommendationCandidates(db, isCurrent: () => _sessionCurrent);
  late final _subscriptionSource = SubscriptionRecommendationSource(db);
  final ScrollController _scroll = ScrollController();
  final Set<Key> _impressionKeys = {};
  final Map<String, Timer> _visibleDwell = {};
  final Set<String> _seenInViewport = {};
  final Map<String, Video> _impressionBatch = {};
  Timer? _impressionFlush;
  bool _impressionSurface = false;
  bool _discoveryVisible = false;
  bool _visibilityScheduled = false;
  int _viewportGeneration = 0;
  AppLifecycleState? _lifecycle;
  final Set<String> _historyRemovals = {};
  final List<Video> _discovered = [];
  final List<Video> _interestVideos = [];
  RecommendationInterest? _selectedInterest;
  List<RecommendationInterest> _interests = const [];
  List<String> _discoveryQueries = const [];
  late int _tasteGeneration;
  List<Video> _videos = [];
  ({
    List<Video> videos,
    Map<String, String> reasons,
    bool available
  })? _lastForYou;
  Map<String, String> _followedChannels = const {};
  List<Video> _followedVideos = const [];
  Map<String, String> _reasons = {};
  bool _loading = false;
  bool _discovering = false;
  bool _available = false;
  bool _failed = false;
  int _revision = 0;
  int _subscriptionRevision = 0;
  bool _subscriptionRankWaiting = false;
  late final StreamSubscription<AppState> _appChanges;
  late final StreamSubscription<SettingsState> _settingsChanges;
  late AppState _previousAppState;

  bool get _current =>
      _sessionCurrent &&
      _selectedTab != null &&
      _selectedTab != HomeTabsLayout.yourFeeds;

  bool get _sessionCurrent {
    if (!mounted || !widget.active) {
      return false;
    }
    try {
      return db.profileId == _profile &&
          _app.state.profileId == _profile &&
          _app.state.sessionRevision == _session &&
          !_app.state.globalLoading &&
          !_app.state.sessionRecoveryRequired;
    } on Object {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lifecycle = WidgetsBinding.instance.lifecycleState;
    _scroll.addListener(_scheduleVisibilityUpdate);
    _tasteGeneration = _engine.generation(RecommendationDomain.video);
    _engine.changes.addListener(_changed);
    playbackHistoryRevision.addListener(_changed);
    communityFilters.changes.addListener(_changed);
    recommendationSubscriptionRevision.addListener(_subscriptionsChanged);
    NetworkProxy.instance.addBeforeApply(_resetForProxy);
    _previousAppState = _app.state;
    _appChanges = _app.stream.listen(_appChanged);
    _settingsChanges = _settings.stream.listen(_layoutChanged);
    _feedsVisited = _selectedTab == HomeTabsLayout.yourFeeds;
    if (_selectedTab == HomeTabsLayout.yourFeeds) {
      unawaited(_resolveTopicCatalog());
    } else {
      unawaited(_load());
    }
    unawaited(_warmSubscriptions());
  }

  List<String> get _availableTabIds => [
        HomeTabsLayout.forYou,
        if (widget.configuredFeed != null) HomeTabsLayout.yourFeeds,
        HomeTabsLayout.discover,
        for (final interest in _interests) HomeTabsLayout.topicId(interest.id),
      ];

  String? _initialSelection(HomeTabsLayout layout) =>
      (layout.enabledOrder ?? HomeTabsLayout.fixedIds)
          .where((id) =>
              id != HomeTabsLayout.yourFeeds || widget.configuredFeed != null)
          .firstOrNull;

  Future<void> _resolveTopicCatalog() async {
    final order = _layout.enabledOrder;
    if (!_sessionCurrent ||
        order?.isEmpty == true ||
        (order != null &&
            !order.any((id) =>
                id.startsWith('topic:') || id == HomeTabsLayout.discover))) {
      return;
    }
    final revision = _revision;
    final orderSnapshot = _layout.enabledOrder;
    final generation = _engine.generation(RecommendationDomain.video);
    bool valid() =>
        _sessionCurrent &&
        revision == _revision &&
        listEquals(orderSnapshot, _layout.enabledOrder) &&
        generation == _engine.generation(RecommendationDomain.video);
    final local =
        RecommendationCandidates(db, isCurrent: () => _sessionCurrent);
    final candidates = local.localVideos();
    final result = await _engine.rankVideos(candidates);
    if (!valid()) return;
    final previous = _selectedTab;
    final previousInterest = _selectedInterest;
    setState(() {
      _catalogKnown = true;
      _discoverySeed = _engine.eligibleVideos(candidates).firstOrNull;
      _discoveryQueries = result.discoveryQueries;
      _interests = result.interests;
      final enabled = _layout.orderedIds(_availableTabIds);
      if (!enabled.contains(_selectedTab)) _selectedTab = enabled.firstOrNull;
      _feedsVisited |= _selectedTab == HomeTabsLayout.yourFeeds;
      _selectedInterest = _interests
          .where((value) => HomeTabsLayout.topicId(value.id) == _selectedTab)
          .firstOrNull;
    });
    if (previous != _selectedTab ||
        (previousInterest == null && _selectedInterest != null)) {
      _resetSelection();
      _discoveryQueries = result.discoveryQueries;
      await _load();
      unawaited(_warmSubscriptions());
    }
  }

  void _layoutChanged(SettingsState settings) {
    if (_region != settings.country.code) {
      _region = settings.country.code;
      _resetConnection();
      if (_selectedTab == HomeTabsLayout.yourFeeds) {
        unawaited(_resolveTopicCatalog());
      } else {
        unawaited(_load());
        unawaited(_warmSubscriptions());
      }
    }
    final next = settings.homeTabsLayout;
    if (!mounted || next.encode() == _layout.encode()) return;
    final enabled = next.orderedIds([
      ..._availableTabIds,
      ...?next.enabledOrder?.where((id) => id.startsWith('topic:')),
    ]);
    final nextSelected =
        enabled.contains(_selectedTab) ? _selectedTab : enabled.firstOrNull;
    if (nextSelected == _selectedTab) {
      setState(() => _layout = next);
      if (next.enabledOrder?.any((id) =>
              id.startsWith('topic:') &&
              !_interests.any(
                  (interest) => HomeTabsLayout.topicId(interest.id) == id)) ??
          false) {
        unawaited(_resolveTopicCatalog());
      }
      return;
    }
    _clearImpressions();
    _revision++;
    _subscriptionRevision++;
    setState(() {
      _layout = next;
      _selectedTab = nextSelected;
      _selectedInterest = _interests
          .where((value) => HomeTabsLayout.topicId(value.id) == nextSelected)
          .firstOrNull;
      _resetSelection();
      _feedsVisited |= nextSelected == HomeTabsLayout.yourFeeds;
    });
    if (nextSelected == HomeTabsLayout.yourFeeds) {
      unawaited(_resolveTopicCatalog());
    } else {
      unawaited(_load());
      unawaited(_warmSubscriptions());
    }
  }

  void _resetSelection() {
    _videos = [];
    _interestVideos.clear();
    _loading = false;
    _discovering = false;
    _failed = false;
    _discoveryPrepared = false;
    _enteredQuery = null;
  }

  void _selectHomeTab(String id, {RecommendationInterest? interest}) {
    if (_selectedTab == id) return;
    final request = _tabRequests()[id];
    final prepared = request == null ? null : _readyTab(request);
    final lastForYou =
        id == HomeTabsLayout.forYou && _sessionCurrent ? _lastForYou : null;
    final needsCatalog = !_catalogKnown || _loading;
    _clearImpressions();
    _revision++;
    _subscriptionRevision++;
    setState(() {
      _selectedTab = id;
      _selectedInterest = interest;
      _resetSelection();
      if (prepared != null) {
        final pool = interest == null ? _discovered : _interestVideos;
        pool
          ..clear()
          ..addAll(prepared.found);
        _videos = prepared.ranked;
        _reasons = prepared.reasons;
        _available = prepared.available;
        _discoveryPrepared = true;
      } else if (lastForYou != null) {
        _videos = lastForYou.videos;
        _reasons = lastForYou.reasons;
        _available = lastForYou.available;
      }
      _feedsVisited |= id == HomeTabsLayout.yourFeeds;
    });
    if (prepared != null) return;
    if (lastForYou != null) {
      // Paint the previous cards before collecting current local candidates.
      // Impressions and newly discovered videos can change their next rank.
      final revision = _revision;
      final subscriptions = _subscriptionRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_current || _selectedTab != id) return;
        if (_revision == revision) unawaited(_load());
        if (_subscriptionRevision == subscriptions) {
          unawaited(_warmSubscriptions());
        }
      });
    } else if (id == HomeTabsLayout.yourFeeds) {
      if (needsCatalog) unawaited(_resolveTopicCatalog());
    } else if (id != HomeTabsLayout.discover) {
      unawaited(_load());
      unawaited(_warmSubscriptions());
    }
  }

  // The native catalog supplies at most four learned topics with bounded queries.
  Map<String, _TabRequest> _tabRequests() {
    if (!_catalogKnown) return {};
    final enabled = _layout.orderedIds(_availableTabIds);
    final topics = {
      for (final item in _interests) HomeTabsLayout.topicId(item.id): item
    };
    final requested = <String, _TabRequest>{};
    for (final id in enabled) {
      if (id == HomeTabsLayout.discover) {
        if (_discoveryQueries.isNotEmpty || _discoverySeed != null) {
          requested[id] = (
            tab: id,
            queries: _discoveryQueries,
            seed: _discoveryQueries.isEmpty ? _discoverySeed : null
          );
        }
      } else if (topics[id] case final item?) {
        requested[id] = (tab: id, queries: item.queries, seed: null);
      }
    }
    return requested;
  }

  _PreparedTab? _readyTab(_TabRequest request) {
    final batch = _preparedTabs[_requestKey(request)];
    if (batch == null) return null;
    final found = _engine
        .eligibleVideos(batch.found)
        .map((video) => video.videoId)
        .toSet();
    return batch.ranked.any((video) => found.contains(video.videoId))
        ? batch
        : null;
  }

  _PreparedTab _snapshot(List<Video> found, List<Video> candidates,
          RecommendationResult<Video> ranked) =>
      (
        found: found,
        ranked: ranked.available
            ? ranked.items.map((item) => item.item).toList()
            : _engine.eligibleVideos(candidates),
        reasons: {
          for (final item in ranked.items) item.item.videoId: item.reason
        },
        available: ranked.available,
      );

  bool get _coolingDown => _retryNotBefore?.isAfter(DateTime.now()) == true;

  bool _instanceRejected(Object error) {
    if (error is! InvidiousServiceError ||
        !(error.isRateLimited ||
            error.retryAfterIsInvalid ||
            (error.retryAfter ?? Duration.zero) > Duration.zero ||
            error.isAuthenticationFailure ||
            error.isGatewayAccessFailure)) {
      return false;
    }
    _preparationStopped = true;
    if (error.retryAfter case final delay? when delay > Duration.zero) {
      _retryNotBefore = DateTime.now().add(delay);
    }
    return true;
  }

  // Resolve one advertised batch at a time. Candidate lookup caches overlapping
  // queries for this instance. Empty batches stay absent until an explicit
  // refresh or a new catalog/connection supplies different inputs.
  void _prepareTabs(Map<String, _TabRequest> requests) {
    final keys = requests.values.map(_requestKey).toSet();
    _preparedTabs.removeWhere((key, _) => !keys.contains(key));
    if (!_discoveryVisible ||
        !_sessionCurrent ||
        _app.state.server == null ||
        _preparation != null ||
        _preparationStopped ||
        _coolingDown ||
        _loading ||
        _selectedTab == null) {
      return;
    }
    final next = requests.values
        .where((request) =>
            request.tab != _selectedTab &&
            !_preparedTabs.containsKey(_requestKey(request)))
        .firstOrNull;
    if (next == null) return;
    final key = _requestKey(next);
    final token = _preparation = Object();
    final generation = _engine.generation(RecommendationDomain.video);
    bool current() =>
        identical(token, _preparation) &&
        _discoveryVisible &&
        _sessionCurrent &&
        _selectedTab != next.tab &&
        _engine.generation(RecommendationDomain.video) == generation &&
        _tabRequests().values.any((entry) => _requestKey(entry) == key);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!current()) return;
        final videos = await _sources.discoverVideos(
            queries: next.queries, seed: next.seed, isCurrent: current);
        if (!current()) return;
        final found = _engine.eligibleVideos(videos);
        if (found.isEmpty) {
          _preparedTabs[key] = null;
          return;
        }
        final follows = _followedVideos;
        final candidates = next.tab == HomeTabsLayout.discover
            ? [...found, ...follows, ..._sources.localVideos()]
            : found;
        final ranked = await _engine.rankVideos(candidates,
            subscriptionChannels: _followedChannels);
        if (current() &&
            (next.tab != HomeTabsLayout.discover ||
                identical(follows, _followedVideos))) {
          _preparedTabs[key] = _snapshot(found, candidates, ranked);
        }
      } catch (error) {
        if (current() && !_instanceRejected(error)) _preparedTabs[key] = null;
      } finally {
        if (mounted && identical(token, _preparation)) {
          setState(() => _preparation = null);
        }
      }
    });
  }

  bool get _rankedViewport =>
      _lifecycle == AppLifecycleState.resumed &&
      _available &&
      _selectedInterest == null &&
      _tasteGeneration == _engine.generation(RecommendationDomain.video) &&
      _current;

  bool get _impressionsActive => _impressionSurface && _rankedViewport;

  void _setDiscoveryVisible(bool discoveryVisible) {
    if (_discoveryVisible == discoveryVisible) return;
    _discoveryVisible = discoveryVisible;
    if (!discoveryVisible) {
      _preparation = null;
    } else if (!_coolingDown) {
      _preparationStopped = false;
    }
    if (_discoveryTab) {
      if (discoveryVisible) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _discoveryVisible && _discoveryTab && !_loading) {
            unawaited(_load());
          }
        });
      } else if (_discovering) {
        _revision++;
        _discovering = false;
        _loading = false;
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted || state == _lifecycle) return;
    // Backgrounding can suspend frames before build observes the new state.
    if (state != AppLifecycleState.resumed) _setDiscoveryVisible(false);
    _clearImpressions();
    setState(() => _lifecycle = state);
  }

  void _clearImpressions() {
    _viewportGeneration++;
    _impressionFlush?.cancel();
    _impressionFlush = null;
    for (final dwell in _visibleDwell.values) {
      dwell.cancel();
    }
    _visibleDwell.clear();
    _seenInViewport.clear();
    _impressionBatch.clear();
    for (final key in _impressionKeys) {
      VisibilityDetectorController.instance.forget(key);
    }
    _impressionKeys.clear();
  }

  void _scheduleVisibilityUpdate() {
    if (_visibilityScheduled || !_impressionsActive) return;
    _visibilityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityScheduled = false;
      if (_impressionsActive) VisibilityDetectorController.instance.notifyNow();
    });
  }

  // Flow ImpressionDwell.kt and HomeFeedBody.kt: half the card's height for
  // one uninterrupted second while the ranked Home viewport is active.
  Widget _observeFeedCard(Video video, Widget child) {
    final key = ValueKey((this, video.videoId));
    final observe =
        _impressionsActive && !video.filtered && video.videoId.isNotEmpty;
    if (observe) _impressionKeys.add(key);
    return VisibilityDetector(
      key: key,
      onVisibilityChanged: observe
          ? (info) {
              final id = video.videoId;
              final halfVisible = info.size.height > 0 &&
                  info.visibleBounds.width > 0 &&
                  info.visibleBounds.height * 2 >= info.size.height;
              if (!_impressionsActive || !halfVisible) {
                _visibleDwell.remove(id)?.cancel();
                _seenInViewport.remove(id);
                _impressionBatch.remove(id);
                return;
              }
              if (_seenInViewport.contains(id)) return;
              _visibleDwell.putIfAbsent(
                  id,
                  () => Timer(const Duration(seconds: 1), () {
                        _visibleDwell.remove(id);
                        if (!_impressionsActive) return;
                        _seenInViewport.add(id);
                        _impressionBatch[id] = video;
                        _impressionFlush ??= Timer(
                            const Duration(milliseconds: 80),
                            _flushImpressions);
                      }));
            }
          : null,
      child: child,
    );
  }

  void _flushImpressions() {
    _impressionFlush = null;
    if (!_impressionsActive) return;
    VisibilityDetectorController.instance.notifyNow();
    final videos = _impressionBatch.values.toList(growable: false);
    _impressionBatch.clear();
    if (videos.isEmpty) return;
    final viewport = _viewportGeneration;
    unawaited(_engine.recordVideoImpressions(
      videos,
      expectedGeneration: _engine.generation(RecommendationDomain.video),
      isCurrent: () => _impressionsActive && viewport == _viewportGeneration,
    ));
  }

  void _retireSubscriptions() {
    _lastForYou = null;
    _subscriptionRevision++;
    _subscriptionRankWaiting = false;
    if (_followedVideos.isNotEmpty) {
      final followedIds = _followedVideos.map((video) => video.videoId).toSet();
      _videos = _videos
          .where((video) => !followedIds.contains(video.videoId))
          .toList();
    }
    _followedChannels = const {};
    _followedVideos = const [];
  }

  void _invalidateDiscoverSnapshot() {
    final request = _tabRequests()[HomeTabsLayout.discover];
    if (request != null) _preparedTabs.remove(_requestKey(request));
  }

  void _subscriptionsChanged() {
    if (!_sessionCurrent) return;
    setState(() {
      _revision++;
      _discovering = false;
      _sources.clearVideoDiscovery();
      _invalidateDiscoverSnapshot();
      _retireSubscriptions();
    });
    if (_current) {
      unawaited(_load());
      unawaited(_warmSubscriptions(forceRefresh: true));
    }
  }

  void _appChanged(AppState next) {
    final previous = _previousAppState;
    _previousAppState = next;
    if (!mounted ||
        (previous.profileId == next.profileId &&
            previous.server == next.server &&
            previous.sessionRevision == next.sessionRevision &&
            previous.globalLoading == next.globalLoading &&
            previous.sessionRecoveryRequired == next.sessionRecoveryRequired)) {
      return;
    }
    if (previous.server != next.server ||
        previous.profileId != next.profileId) {
      _preparationStopped = false;
      _retryNotBefore = null;
    }
    _resetConnection();
    if (_selectedTab == HomeTabsLayout.yourFeeds) {
      unawaited(_resolveTopicCatalog());
    }
    if (!_current) return;
    unawaited(_load());
    unawaited(_warmSubscriptions());
  }

  Future<void> _resetForProxy() async {
    if (mounted) _resetConnection();
  }

  void _resetConnection() {
    _clearImpressions();
    setState(() {
      _revision++;
      _loading = false;
      _discovering = false;
      _available = false;
      _discoveryPrepared = false;
      _enteredQuery = null;
      _failed = false;
      _selectedInterest = null;
      _interests = const [];
      _discoveryQueries = const [];
      _preparedTabs.clear();
      _catalogKnown = false;
      _discoverySeed = null;
      _preparation = null;
      _videos = [];
      _reasons = {};
      _discovered.clear();
      _interestVideos.clear();
      _sources.clearVideoDiscovery();
      _retireSubscriptions();
    });
  }

  void _rerankSubscriptions() {
    if (_discovering) {
      _subscriptionRankWaiting = true;
    } else {
      unawaited(_load());
    }
  }

  Future<void> _warmSubscriptions({bool forceRefresh = false}) async {
    if (!_current ||
        _selectedTab != HomeTabsLayout.forYou ||
        !_engine.learningEnabled(RecommendationDomain.video)) {
      return;
    }
    final revision = ++_subscriptionRevision;
    final generation = _engine.generation(RecommendationDomain.video);
    final server = _app.state.server;
    final proxy = NetworkProxy.instance.config;
    bool requestCurrent() =>
        _current &&
        revision == _subscriptionRevision &&
        generation == _engine.generation(RecommendationDomain.video) &&
        _app.state.server == server &&
        !NetworkProxy.instance.isChanging &&
        identical(proxy, NetworkProxy.instance.config);

    try {
      await for (final batch in _subscriptionSource.warm(
          server: server,
          isCurrent: requestCurrent,
          forceRefresh: forceRefresh)) {
        if (!requestCurrent()) return;
        if (mapEquals(batch.channels, _followedChannels) &&
            listEquals(batch.videos, _followedVideos)) {
          continue;
        }
        _invalidateDiscoverSnapshot();
        _lastForYou = null;
        _followedChannels = batch.channels;
        _followedVideos = batch.videos;
        _rerankSubscriptions();
      }
    } catch (_) {
      // Subscription warming is optional. Local recommendations and explicit
      // discovery stay available even when the selected instance is offline.
    }
  }

  void _changed() {
    _lastForYou = null;
    if (!_current) {
      if (_sessionCurrent) {
        // Resume-only and configured feeds still reflect local progress; they
        // do not need recommendation ranking or subscription warming.
        setState(() {});
        if (_selectedTab == HomeTabsLayout.yourFeeds) {
          unawaited(_resolveTopicCatalog());
        }
      }
      return;
    }
    final generation = _engine.generation(RecommendationDomain.video);
    if (generation != _tasteGeneration) {
      _clearImpressions();
      _tasteGeneration = generation;
      _discovering = false;
      _discoveryPrepared = false;
      _enteredQuery = null;
      _failed = false;
      _selectedInterest = null;
      _interests = const [];
      _discoveryQueries = const [];
      _preparedTabs.clear();
      _catalogKnown = false;
      _discoverySeed = null;
      _preparation = null;
      _discovered.clear();
      _interestVideos.clear();
      _sources.clearVideoDiscovery();
      _retireSubscriptions();
      unawaited(_warmSubscriptions());
    } else if (_discovering) {
      // History updates should not interrupt an intentional discovery request.
      return;
    }
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant FlowVideoHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      _clearImpressions();
      _revision++;
      _loading = false;
      _discovering = false;
      _retireSubscriptions();
      if (widget.active) {
        final generation = _tasteGeneration;
        _changed();
        if (generation == _tasteGeneration) unawaited(_warmSubscriptions());
      }
    }
  }

  bool get _discoveryTab =>
      _selectedTab == HomeTabsLayout.discover ||
      (_selectedTab?.startsWith('topic:') ?? false);

  Future<void> _load({bool refresh = false}) async {
    if (!_current || (_discoveryTab && !_discoveryVisible)) return;
    if (refresh && !_coolingDown) {
      _preparationStopped = false;
      _preparedTabs.removeWhere((_, batch) => batch == null);
    }
    final selected = _selectedInterest;
    if (selected == null && (_selectedTab?.startsWith('topic:') ?? false)) {
      await _resolveTopicCatalog();
      return;
    }
    final discover = _selectedTab == HomeTabsLayout.discover;
    if (_discovering ||
        (_failed && !refresh && (discover || selected != null))) {
      return;
    }
    final prepare =
        (discover || selected != null) && (refresh || !_discoveryPrepared);
    if (prepare && _coolingDown) {
      setState(() => _failed = true);
      return;
    }
    final revision = ++_revision;
    final generation = _engine.generation(RecommendationDomain.video);
    bool requestCurrent() =>
        _current &&
        (!prepare || _discoveryVisible) &&
        revision == _revision &&
        generation == _engine.generation(RecommendationDomain.video);
    setState(() {
      _loading = true;
      _discovering = prepare;
      _failed = false;
    });
    try {
      final local = selected == null ? _sources.localVideos() : const <Video>[];
      RecommendationResult<Video>? initialRank;
      String? preparedKey;
      if (prepare) {
        if (discover && _enteredQuery == null && _discoveryQueries.isEmpty) {
          // A restored Discover tab may be opened before For you has ranked.
          initialRank = await _engine.rankVideos(
              [..._discovered, ..._followedVideos, ...local],
              subscriptionChannels: _followedChannels);
          if (!requestCurrent()) return;
          _discoveryQueries = initialRank.discoveryQueries;
        }
        final queries = selected?.queries ?? _discoveryQueries;
        final seed =
            discover ? _engine.eligibleVideos(local).firstOrNull : null;
        if (_enteredQuery != null || queries.isNotEmpty || seed != null) {
          final found = await _sources.discoverVideos(
              query: _enteredQuery,
              queries: queries,
              seed: seed,
              isCurrent: requestCurrent);
          if (!requestCurrent()) return;
          final destination = discover ? _discovered : _interestVideos;
          destination
            ..clear()
            ..addAll(found);
          _discoveryPrepared = true;
          if (_enteredQuery == null) {
            final request = (
              tab: _selectedTab!,
              queries: queries,
              seed: queries.isEmpty ? seed : null
            );
            preparedKey = _requestKey(request);
          }
          initialRank = null;
        }
      }
      // The ranker caps the pool after admission and deduplication. Start
      // with the requested discovery so a full history cannot hide its feed.
      final candidates = selected == null
          ? [..._discovered, ..._followedVideos, ...local]
          : List<Video>.of(_interestVideos);
      _subscriptionRankWaiting = false;
      final result = initialRank ??
          await _engine.rankVideos(candidates,
              subscriptionChannels: _followedChannels);
      if (!requestCurrent()) return;
      if (_subscriptionRankWaiting) {
        // A follow changed after this rank started. Never put its old cards
        // back while the replacement rank is pending.
        _subscriptionRankWaiting = false;
        _discovering = false;
        await _load();
        return;
      }
      setState(() {
        if (preparedKey != null) {
          final found = discover ? _discovered : _interestVideos;
          _preparedTabs[preparedKey] = found.isEmpty
              ? null
              : _snapshot(List.of(found), candidates, result);
        }
        _available = result.available;
        _catalogKnown = true;
        if (selected == null) {
          _discoverySeed = _engine.eligibleVideos(local).firstOrNull;
        }
        _interests = result.interests;
        _discoveryQueries = result.discoveryQueries;
        _videos = result.available
            ? result.items.map((entry) => entry.item).toList()
            : _engine.eligibleVideos(candidates);
        _reasons = {
          for (final entry in result.items) entry.item.videoId: entry.reason,
        };
        if (_selectedTab == HomeTabsLayout.forYou) {
          _lastForYou =
              (videos: _videos, reasons: _reasons, available: _available);
        }
        _loading = false;
        _discovering = false;
      });
    } catch (error) {
      if (!requestCurrent()) return;
      if (prepare) _instanceRejected(error);
      setState(() {
        _failed = true;
        _loading = false;
        _discovering = false;
      });
    }
  }

  Future<void> _discover() async {
    final manualSearch =
        _catalogKnown && _discoveryQueries.isEmpty && _discoverySeed == null;
    _selectHomeTab(HomeTabsLayout.discover);
    if (!_current || _loading) return;
    final generation = _engine.generation(RecommendationDomain.video);
    if (!manualSearch) {
      if (!_discoveryPrepared) await _load();
      return;
    }
    final locals = AppLocalizations.of(context)!;
    var query = '';
    final result = await showDialog<String>(
      context: context,
      useRootNavigator: false,
      builder: (context) => AlertDialog(
        title: Text(locals.flowSearchTopic),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(locals.flowDiscoveryHint),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('video-discovery-query'),
            onChanged: (value) => query = value,
            autofocus: true,
            maxLength: 120,
            decoration: InputDecoration(labelText: locals.flowSearchTopic),
            textInputAction: TextInputAction.search,
            onSubmitted: (value) {
              if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
            },
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(locals.cancel)),
          TextButton(
              onPressed: () {
                if (query.trim().isNotEmpty) {
                  Navigator.pop(context, query.trim());
                }
              },
              child: Text(locals.search)),
        ],
      ),
    );
    if (_current &&
        _selectedTab == HomeTabsLayout.discover &&
        generation == _engine.generation(RecommendationDomain.video) &&
        result != null) {
      _enteredQuery = result;
      _discoveryPrepared = false;
      _failed = false;
      await _load();
    }
  }

  Future<void> _feedback(Video video, RecommendationFeedback feedback) async {
    try {
      await _engine.feedback(video, RecommendationDomain.video, feedback);
    } catch (_) {
      if (mounted && _current) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.couldntFetchVideos)));
      }
    }
  }

  @override
  void dispose() {
    _impressionSurface = false;
    _clearImpressions();
    WidgetsBinding.instance.removeObserver(this);
    _revision++;
    _subscriptionRevision++;
    unawaited(_appChanges.cancel());
    unawaited(_settingsChanges.cancel());
    _engine.changes.removeListener(_changed);
    playbackHistoryRevision.removeListener(_changed);
    communityFilters.changes.removeListener(_changed);
    recommendationSubscriptionRevision.removeListener(_subscriptionsChanged);
    NetworkProxy.instance.removeBeforeApply(_resetForProxy);
    _scroll.dispose();
    super.dispose();
  }

  Widget _discoveryChip(String label, {required bool enabled}) => ActionChip(
        key: const ValueKey('video-home-discover'),
        onPressed: _loading || !enabled ? null : _discover,
        label: Text(label),
      );

  Widget _status(BuildContext context, List<Video> videos, Widget? notice) {
    final locals = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (!_available && !_loading && videos.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(locals.flowRecommendationUnavailable, style: style),
          ),
        if (_failed)
          TextButton.icon(
            onPressed: _loading ? null : () => _load(refresh: true),
            icon: const Icon(Icons.refresh),
            label: Text(locals.couldntFetchVideos),
          ),
        if (notice != null) notice,
        if (videos.isEmpty && !_loading && !_failed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
                _selectedInterest != null || _discoveryPrepared
                    ? locals.nVideos(0)
                    : locals.flowRecommendationHint,
                style: style),
          ),
        if (_discovering)
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 8),
            child: Text(locals.flowDiscoveryHint, style: style),
          ),
      ],
    );
  }

  Future<void> _removeFromHistory(String videoId) async {
    if (!_sessionCurrent || !_historyRemovals.add(videoId)) return;
    setState(() {});
    try {
      // Flow ContinueWatchingShelf.kt's close action calls
      // HomeViewModel.removeContinueWatchingEntry to delete local history.
      await _owner.deleteLocalHistory(videoId);
      if (db.profileId == _profile) playbackHistoryRevision.value++;
    } catch (_) {
      if (mounted && _sessionCurrent) {
        final locals = AppLocalizations.of(context)!;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(locals.flowRemoveFromHistoryError)));
      }
    } finally {
      _historyRemovals.remove(videoId);
      if (mounted) setState(() {});
    }
  }

  Widget _continueWatching(List<Video> continuing) {
    final locals = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 4, 0),
            child: Row(
              children: [
                const Icon(Icons.play_circle_fill, size: 23),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(locals.flowContinueWatching,
                      style: theme.textTheme.titleMedium),
                ),
                if (!widget.television)
                  IconButton(
                    tooltip: locals.history,
                    onPressed: () => context.router.push(
                        NavigationSectionRoute(source: HomeDataSource.history)),
                    icon: const Icon(Icons.chevron_right),
                  ),
              ],
            ),
          ),
          if (widget.television)
            TvHorizontalVideoList(
              key: ValueKey(continuing.map((video) => video.videoId).join(',')),
              paginatedVideoList: FixedItemList(continuing),
              autoFocusedIndex: -1,
            )
          else
            LayoutBuilder(builder: (context, constraints) {
              final width =
                  (constraints.maxWidth - 40).clamp(180.0, 350.0).toDouble();
              final scale = MediaQuery.textScalerOf(context);
              return SizedBox(
                height: width * 9 / 16 +
                    (scale.scale(14) * 2.5 + scale.scale(12) * 1.4 + 14)
                        .clamp(58.0, double.infinity),
                child: ListView.separated(
                  key: PageStorageKey('flow-resume-$_profile'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: continuing.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final video = continuing[index];
                    return SizedBox(
                      width: width,
                      child: VideoListItem(
                        key: ValueKey('resume-${video.videoId}'),
                        video: video,
                        layout: VideoCardLayout.continueWatching,
                        showCommunityLabels: true,
                        allowModalSheet: false,
                        resumeAction: IconButton(
                          tooltip: locals.flowRemoveFromHistory,
                          visualDensity: VisualDensity.standard,
                          constraints:
                              const BoxConstraints(minWidth: 48, minHeight: 48),
                          iconSize: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                          onPressed: _historyRemovals.contains(video.videoId)
                              ? null
                              : () => _removeFromHistory(video.videoId),
                          icon: const Icon(Icons.close),
                        ),
                      ),
                    );
                  },
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _phoneCard(Video video) => _observeFeedCard(
      video,
      VideoListItem(
        key: ValueKey('flow-video-${video.videoId}'),
        video: video,
        layout: VideoCardLayout.flowFeed,
        showCommunityLabels: true,
        showVideoModalSheet: _available
            ? (menuContext, video) => VideoModalSheet.showVideoModalSheet(
                  menuContext,
                  video,
                  recommendationActions: (_) => VideoRecommendationActions(
                    video: video,
                    reason: _reasons[video.videoId] ?? '',
                    onFeedback: (feedback) => _feedback(video, feedback),
                  ),
                )
            : null,
      ));

  Widget _grid(List<Video> videos,
      {required int columns, required double width}) {
    final inset = 12.0;
    final gap = 14.0;
    final cardWidth = (width - 2 * inset - (columns - 1) * gap) / columns;
    final scale = MediaQuery.textScalerOf(context);
    final height = cardWidth * 9 / 16 +
        (widget.television
            ? scale.scale(14) * 8 + (_available ? 48 : 0)
            : scale.scale(16) * 2.45 + scale.scale(12) * 1.5 + 32);
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: inset),
      sliver: SliverGrid.builder(
        itemCount: videos.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: gap,
          mainAxisSpacing: gap,
          mainAxisExtent: height,
        ),
        itemBuilder: (context, index) {
          final video = videos[index];
          if (!widget.television) return _phoneCard(video);
          return _observeFeedCard(
              video,
              Column(
                key: ValueKey('flow-card-${video.videoId}'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: TvVideoItem(
                      video: video,
                      autoFocus: false,
                      showCommunityLabels: true,
                    ),
                  ),
                  if (_available)
                    VideoRecommendationActions(
                      video: video,
                      reason: _reasons[video.videoId] ?? '',
                      onFeedback: (feedback) => _feedback(video, feedback),
                    ),
                ],
              ));
        },
      ),
    );
  }

  Widget _phoneFeed(List<Video> videos, List<Video> continuing, double width) {
    final columns = (width / 360).floor().clamp(1, 4);
    final firstRow = videos.take(columns).toList();
    final remainder = videos.skip(columns).toList();
    return SliverMainAxisGroup(slivers: [
      if (firstRow.isNotEmpty)
        if (columns == 1)
          // List and grid children already get a repaint boundary. Give the
          // standalone card its own layer so its detector sees it leave.
          SliverToBoxAdapter(
              child: RepaintBoundary(child: _phoneCard(firstRow.single)))
        else
          _grid(firstRow, columns: columns, width: width),
      if (continuing.isNotEmpty)
        SliverToBoxAdapter(child: _continueWatching(continuing)),
      if (remainder.isNotEmpty)
        if (columns == 1)
          SliverList.builder(
            itemCount: remainder.length,
            itemBuilder: (context, index) => Padding(
              key: ValueKey(remainder[index].videoId),
              padding: const EdgeInsets.only(top: 10),
              child: _phoneCard(remainder[index]),
            ),
          )
        else
          _grid(remainder, columns: columns, width: width),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final routeVisible = ModalRoute.isCurrentOf(context) != false;
    final (playerCoversHome, floatingVideo) =
        context.select((PlayerCubit player) {
      final state = player.state;
      return (
        state.isPip || (!state.isHidden && !state.isMini),
        !state.isHidden && !state.isAudio
      );
    });
    final homeVisible = widget.active &&
        routeVisible &&
        TickerMode.of(context) &&
        !playerCoversHome;
    final discoveryVisible = homeVisible &&
        (_lifecycle == null || _lifecycle == AppLifecycleState.resumed);
    _setDiscoveryVisible(discoveryVisible);
    // A floating video can cover individual cards while Home itself is visible.
    // Read the persisted consent when Home builds. Scroll and per-card
    // visibility callbacks only need to recheck the live session/generation.
    final surface = homeVisible &&
        !floatingVideo &&
        _rankedViewport &&
        _engine.learningEnabled(RecommendationDomain.video);
    if (_impressionSurface != surface) {
      _impressionSurface = surface;
      if (!surface) _clearImpressions();
    }
    _scheduleVisibilityUpdate();
    final locals = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final continuing = _layout.continueWatching
        ? _engine.eligibleVideos(continuingVideos(_owner))
        : const <Video>[];
    final requests = _tabRequests();
    _prepareTabs(requests);
    final ready = {
      for (final request in requests.values)
        if (_readyTab(request) != null) request.tab,
    };
    final pinned = _layout.enabledOrder ?? const <String>[];
    final discoverReady = ready.contains(HomeTabsLayout.discover);
    final manualSearch =
        _catalogKnown && !requests.containsKey(HomeTabsLayout.discover);
    final onDiscover = _selectedTab == HomeTabsLayout.discover ||
        discoverReady ||
        manualSearch;
    final tabChips = <String, Widget>{
      HomeTabsLayout.forYou: ChoiceChip(
        key: const ValueKey('video-home-for-you'),
        label: Text(locals.flowForYou),
        selected: _selectedTab == HomeTabsLayout.forYou,
        onSelected: (_) => _selectHomeTab(HomeTabsLayout.forYou),
      ),
      if (widget.configuredFeed != null)
        HomeTabsLayout.yourFeeds: ChoiceChip(
          key: const ValueKey('video-home-your-feeds'),
          label: Text(locals.flowYourFeeds),
          selected: _selectedTab == HomeTabsLayout.yourFeeds,
          onSelected: (_) => _selectHomeTab(HomeTabsLayout.yourFeeds),
        ),
      if (onDiscover || pinned.contains(HomeTabsLayout.discover))
        HomeTabsLayout.discover: _discoveryChip(
            manualSearch ? locals.flowSearchTopic : locals.flowDiscoverVideos,
            enabled: onDiscover),
      for (final interest in _interests)
        if (_selectedInterest?.id == interest.id ||
            pinned.contains(HomeTabsLayout.topicId(interest.id)) ||
            ready.contains(HomeTabsLayout.topicId(interest.id)))
          HomeTabsLayout.topicId(interest.id): ChoiceChip(
            key: ValueKey('flow-interest-${interest.id}'),
            label: Text(interest.label,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            selected: _selectedTab == HomeTabsLayout.topicId(interest.id),
            onSelected:
                _loading || !ready.contains(HomeTabsLayout.topicId(interest.id))
                    ? null
                    : (_) => _selectHomeTab(HomeTabsLayout.topicId(interest.id),
                        interest: interest),
          ),
    };
    final enabledIds = _layout.orderedIds(tabChips.keys);
    final chips = [for (final id in enabledIds) tabChips[id]!];
    final editAction = widget.editAction ??
        IconButton(
          key: const ValueKey('home-tabs-edit'),
          autofocus: widget.television && enabledIds.isEmpty,
          icon: const Icon(Icons.edit, size: 20),
          tooltip: locals.homeTabs,
          onPressed: () {
            final interests =
                List<RecommendationInterest>.unmodifiable(_interests);
            if (widget.onEdit != null) {
              widget.onEdit!(interests);
            } else {
              Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => HomeTabsEditorScreen(
                      interests: interests,
                      includeYourFeeds: !widget.television)));
            }
          },
        );
    final strip = FlowHomeChipStrip(trailing: editAction, chips: [
      ...widget.leadingChips,
      ...chips,
      if (enabledIds.isNotEmpty && !widget.television)
        IconButton(
          tooltip: locals.localRecommendations,
          onPressed: () => showRecommendationSettings(context),
          icon: const Icon(Icons.tune_rounded, size: 20),
        ),
    ]);
    final feed = CommunityBrowse<Video>(
      items: _engine.eligibleVideos(_videos),
      match: videoCommunityMatches,
      builder: (context, videos, notice) => RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        child: LayoutBuilder(builder: (context, constraints) {
          // Only viewport width affects the card layout. Sliver constraints
          // also change with the scroll offset.
          final width = constraints.maxWidth;
          return CustomScrollView(
            key: const PageStorageKey('flow-video-home'),
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (widget.television)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(
                            child: Text(locals.flowForYou,
                                style: text.headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w700)),
                          ),
                          IconButton(
                            autofocus: true,
                            tooltip: locals.settings,
                            onPressed: () =>
                                showRecommendationSettings(context),
                            icon: const Icon(Icons.tune_rounded),
                          ),
                          IconButton(
                            tooltip: locals.search,
                            onPressed: () =>
                                context.router.push(TvSearchRoute()),
                            icon: const Icon(Icons.search_rounded),
                          ),
                        ]),
                        if (chips.isNotEmpty) strip,
                        if (continuing.isNotEmpty)
                          _continueWatching(continuing),
                        _status(context, videos, notice),
                      ],
                    ),
                  ),
                )
              else
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: _status(context, videos, notice),
                  ),
                ),
              if (widget.television)
                _grid(videos,
                    columns: (width / 360).floor().clamp(1, 4), width: width)
              else
                _phoneFeed(videos, continuing, width),
            ],
          );
        }),
      ),
    );
    final selected = enabledIds.contains(_selectedTab);
    final resumeOnly = continuing.isEmpty
        ? const SizedBox.expand()
        : SingleChildScrollView(child: _continueWatching(continuing));
    if (widget.television) {
      return selected
          ? feed
          : Column(children: [strip, Expanded(child: resumeOnly)]);
    }
    return Column(children: [
      strip,
      Expanded(
        child: IndexedStack(
          index: !selected
              ? 2
              : _selectedTab == HomeTabsLayout.yourFeeds
                  ? 1
                  : 0,
          children: [
            ExcludeFocus(
              excluding: !selected || _selectedTab == HomeTabsLayout.yourFeeds,
              child: TickerMode(
                enabled: selected && _selectedTab != HomeTabsLayout.yourFeeds,
                child: feed,
              ),
            ),
            ExcludeFocus(
              excluding: _selectedTab != HomeTabsLayout.yourFeeds,
              child: TickerMode(
                enabled: _selectedTab == HomeTabsLayout.yourFeeds,
                child: _feedsVisited && widget.configuredFeed != null
                    ? widget.configuredFeed!(continuing.isEmpty
                        ? null
                        : _continueWatching(continuing))
                    : const SizedBox.shrink(),
              ),
            ),
            resumeOnly,
          ],
        ),
      ),
    ]);
  }
}
