import 'dart:async';

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
  final Widget? configuredFeed;
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
  bool _discoveryStarted = false;
  late final int _session = _app.state.sessionRevision;
  late final RecommendationCandidates _sources =
      RecommendationCandidates(db, isCurrent: () => _current);
  late final _subscriptionSource = SubscriptionRecommendationSource(db);
  final ScrollController _scroll = ScrollController();
  final Set<Key> _impressionKeys = {};
  final Map<String, Timer> _visibleDwell = {};
  final Set<String> _seenInViewport = {};
  final Map<String, Video> _impressionBatch = {};
  Timer? _impressionFlush;
  bool _impressionSurface = false;
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
      _selectedTab != HomeTabsLayout.yourFeeds &&
      (_selectedTab != HomeTabsLayout.discover || _discoveryStarted);

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
    if (_selectedTab == HomeTabsLayout.yourFeeds ||
        (_selectedTab?.startsWith('topic:') ?? false)) {
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
        (order != null && !order.any((id) => id.startsWith('topic:')))) {
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
    final result = await _engine.rankVideos(local.localVideos());
    if (!valid()) return;
    setState(() {
      _interests = result.interests;
      final enabled = _layout.orderedIds(_availableTabIds);
      if (!enabled.contains(_selectedTab)) _selectedTab = enabled.firstOrNull;
      _feedsVisited |= _selectedTab == HomeTabsLayout.yourFeeds;
      _selectedInterest = _interests
          .where((value) => HomeTabsLayout.topicId(value.id) == _selectedTab)
          .firstOrNull;
      _videos = [];
      _loading = false;
      _discovering = false;
    });
    if (_selectedTab == HomeTabsLayout.forYou) {
      await _load();
      unawaited(_warmSubscriptions());
    }
  }

  void _layoutChanged(SettingsState settings) {
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
    final selected = _selectedTab;
    setState(() {
      _layout = next;
      _selectedTab = nextSelected;
      _selectedInterest = null;
      _videos = [];
      _feedsVisited |= _selectedTab == HomeTabsLayout.yourFeeds;
      _loading = false;
      _discovering = false;
    });
    if (selected != _selectedTab && _current) {
      final interest = _interests
          .where((value) => HomeTabsLayout.topicId(value.id) == _selectedTab)
          .firstOrNull;
      if (interest != null) {
        setState(() => _selectedInterest = interest);
      } else if (_selectedTab?.startsWith('topic:') ?? false) {
        unawaited(_resolveTopicCatalog());
      } else {
        unawaited(_load());
        unawaited(_warmSubscriptions());
      }
    } else if (_selectedTab == HomeTabsLayout.yourFeeds) {
      unawaited(_resolveTopicCatalog());
    }
  }

  void _selectHomeTab(String id) {
    _clearImpressions();
    _revision++;
    _subscriptionRevision++;
    setState(() {
      _selectedTab = id;
      _selectedInterest = null;
      if (id == HomeTabsLayout.discover) _videos = [];
      _loading = false;
      _discovering = false;
      _feedsVisited |= id == HomeTabsLayout.yourFeeds;
    });
    if (id == HomeTabsLayout.forYou) {
      unawaited(_load());
      unawaited(_warmSubscriptions());
    } else if (id == HomeTabsLayout.yourFeeds && _interests.isEmpty) {
      unawaited(_resolveTopicCatalog());
    }
  }

  bool get _impressionsActive =>
      _impressionSurface &&
      _current &&
      _lifecycle == AppLifecycleState.resumed &&
      _available &&
      _selectedInterest == null &&
      _engine.learningEnabled(RecommendationDomain.video);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted || state == _lifecycle) return;
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

  void _subscriptionsChanged() {
    if (!_current) return;
    setState(() {
      _revision++;
      _discovering = false;
      _sources.clearVideoDiscovery();
      _retireSubscriptions();
    });
    unawaited(_load());
    unawaited(_warmSubscriptions(forceRefresh: true));
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
    _resetConnection();
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
      _failed = false;
      _available = false;
      _selectedInterest = null;
      _interests = const [];
      _discoveryQueries = const [];
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
      _selectedInterest = null;
      _interests = const [];
      _discoveryQueries = const [];
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

  Future<void> _load({
    String? query,
    List<String> queries = const [],
    Video? seed,
  }) async {
    if (!_current) return;
    final revision = ++_revision;
    final generation = _engine.generation(RecommendationDomain.video);
    bool requestCurrent() =>
        _current &&
        revision == _revision &&
        generation == _engine.generation(RecommendationDomain.video);
    setState(() {
      _loading = true;
      _discovering = query != null || queries.isNotEmpty || seed != null;
      _failed = false;
    });
    try {
      final selected = _selectedInterest;
      if (_discovering) {
        final found = await _sources.discoverVideos(
            query: query,
            queries: queries,
            seed: seed,
            isCurrent: requestCurrent);
        if (!requestCurrent()) return;
        final destination = selected == null ? _discovered : _interestVideos;
        destination
          ..clear()
          ..addAll(found);
      }
      // The ranker caps the pool after admission and deduplication. Start
      // with the requested discovery so a full history cannot hide its feed.
      final candidates = selected == null
          ? [..._discovered, ..._followedVideos, ..._sources.localVideos()]
          : List<Video>.of(_interestVideos);
      _subscriptionRankWaiting = false;
      final result = await _engine.rankVideos(candidates,
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
        _available = result.available;
        _interests = result.interests;
        _discoveryQueries = result.discoveryQueries;
        _videos = result.available
            ? result.items.map((entry) => entry.item).toList()
            : _engine.eligibleVideos(candidates);
        _reasons = {
          for (final entry in result.items) entry.item.videoId: entry.reason,
        };
        _loading = false;
        _discovering = false;
      });
      // Recover topic selection from a local rank without making an implicit
      // discovery request. Clicking the topic remains the explicit fetch.
      if (selected == null && (_selectedTab?.startsWith('topic:') ?? false)) {
        final interest = _interests
            .where((value) => HomeTabsLayout.topicId(value.id) == _selectedTab)
            .firstOrNull;
        if (interest != null) {
          setState(() {
            _selectedInterest = interest;
            _videos = [];
          });
        } else if (mounted) {
          setState(() {
            _selectedTab = _layout.orderedIds(_availableTabIds).firstOrNull;
            _feedsVisited |= _selectedTab == HomeTabsLayout.yourFeeds;
            if (_selectedTab != HomeTabsLayout.forYou) _videos = [];
          });
        }
      }
    } catch (_) {
      if (!requestCurrent()) return;
      setState(() {
        _failed = true;
        _loading = false;
        _discovering = false;
      });
    }
  }

  Future<void> _discover() async {
    _selectHomeTab(HomeTabsLayout.discover);
    _discoveryStarted = true;
    if (!_current || _loading) return;
    _selectedInterest = null;
    final generation = _engine.generation(RecommendationDomain.video);
    final seed =
        _engine.eligibleVideos(_sources.localVideos(limit: 80)).firstOrNull;
    if (!mounted ||
        !_current ||
        generation != _engine.generation(RecommendationDomain.video)) {
      return;
    }
    if (_discoveryQueries.isNotEmpty || seed != null) {
      await _load(queries: _discoveryQueries, seed: seed);
      return;
    }
    final locals = AppLocalizations.of(context)!;
    var query = '';
    final result = await showDialog<String>(
      context: context,
      useRootNavigator: false,
      builder: (context) => AlertDialog(
        title: Text(locals.flowDiscoverVideos),
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
        generation == _engine.generation(RecommendationDomain.video) &&
        result != null) {
      await _load(query: result);
    }
  }

  Future<void> _selectInterest(RecommendationInterest interest) async {
    _selectHomeTab(HomeTabsLayout.topicId(interest.id));
    if (!_current) return;
    _clearImpressions();
    _selectedInterest = interest;
    _interestVideos.clear();
    _videos = [];
    await _load(queries: interest.queries);
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

  Widget _discoveryChip(AppLocalizations locals) => ActionChip(
        key: const ValueKey('video-home-discover'),
        onPressed: _loading ? null : _discover,
        label: Text(locals.flowDiscoverVideos),
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
            onPressed: _loading ? null : () => _load(),
            icon: const Icon(Icons.refresh),
            label: Text(locals.couldntFetchVideos),
          ),
        if (notice != null) notice,
        if (videos.isEmpty && !_loading && _selectedInterest != null)
          TextButton.icon(
            onPressed: () => _selectInterest(_selectedInterest!),
            icon: const Icon(Icons.search),
            label: Text(locals.flowDiscoverVideos),
          ),
        if (videos.isEmpty && !_loading && _selectedInterest == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(locals.flowRecommendationHint, style: style),
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

  Widget _phoneFeed(List<Video> videos, List<Video> continuing) {
    return SliverLayoutBuilder(builder: (context, constraints) {
      final width = constraints.crossAxisExtent;
      final columns = (width / 360).floor().clamp(1, 4);
      final firstRow = videos.take(columns).toList();
      final remainder = videos.skip(columns).toList();
      return SliverMainAxisGroup(slivers: [
        if (firstRow.isNotEmpty)
          if (columns == 1)
            SliverToBoxAdapter(child: _phoneCard(firstRow.single))
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
    });
  }

  @override
  Widget build(BuildContext context) {
    final routeVisible = ModalRoute.isCurrentOf(context) != false;
    final overlay = context.select((PlayerCubit player) {
      final state = player.state;
      // A floating video can cover parts of a card without changing its clip.
      return state.isPip ||
          (!state.isHidden && (!state.isMini || !state.isAudio));
    });
    final surface = routeVisible && !overlay && TickerMode.of(context);
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
      HomeTabsLayout.discover: _discoveryChip(locals),
      for (final interest in _interests)
        HomeTabsLayout.topicId(interest.id): ChoiceChip(
          key: ValueKey('flow-interest-${interest.id}'),
          label: Text(interest.label,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          selected: _selectedTab == HomeTabsLayout.topicId(interest.id),
          onSelected: _loading ? null : (_) => _selectInterest(interest),
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
        onRefresh: _load,
        child: CustomScrollView(
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
                          onPressed: () => showRecommendationSettings(context),
                          icon: const Icon(Icons.tune_rounded),
                        ),
                        IconButton(
                          tooltip: locals.search,
                          onPressed: () => context.router.push(TvSearchRoute()),
                          icon: const Icon(Icons.search_rounded),
                        ),
                      ]),
                      if (chips.isNotEmpty) strip,
                      if (continuing.isNotEmpty) _continueWatching(continuing),
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
              SliverLayoutBuilder(builder: (context, constraints) {
                final width = constraints.crossAxisExtent;
                return _grid(videos,
                    columns: (width / 360).floor().clamp(1, 4), width: width);
              })
            else
              _phoneFeed(videos, continuing),
          ],
        ),
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
                    ? LayoutBuilder(
                        builder: (context, constraints) => Column(children: [
                          if (continuing.isNotEmpty)
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                  maxHeight: constraints.maxHeight * 0.5),
                              child: SingleChildScrollView(
                                  child: _continueWatching(continuing)),
                            ),
                          Expanded(child: widget.configuredFeed!),
                        ]),
                      )
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
