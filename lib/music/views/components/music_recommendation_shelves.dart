import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_starter_artists.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/recommendations/candidate_sources.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/recommendations/subscription_recommendations.dart';
import 'package:clipious/recommendations/subscription_revision.dart';
import 'package:clipious/recommendations/views/recommendation_settings.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'music_catalog_cards.dart';
import 'community_music_artwork.dart';
import 'music_library_actions.dart';
import 'music_recommendation_collection.dart';
import '../screens/music.dart';

typedef _DailyMix = ({String label, List<String> seeds});
typedef _MixScope = ({DateTime day, int generation, Object proxy});
typedef _LocalShelf = ({String id, String title, List<MusicTrack> tracks});

final _recordingId = RegExp(r'^[A-Za-z0-9_-]{11}$');
const _maxQuickPicks = 12;
const _maxSpeedDialTracks = 6;

List<String> _trackIds(Object? value, int limit) => value is List
    ? value
        .take(limit)
        .whereType<String>()
        .where(_recordingId.hasMatch)
        .toSet()
        .toList(growable: false)
    : const [];

Iterable<_DailyMix> _mixSeeds(Object? value) sync* {
  if (value is! List) return;
  for (final candidate in value.take(3).whereType<Map<Object?, Object?>>()) {
    final label = candidate['label'];
    final seeds = _trackIds(candidate['seedTrackIds'], 4);
    if (label is! String || label.trim().isEmpty || seeds.length < 2) continue;
    yield (
      label: String.fromCharCodes(label.trim().runes.take(80)),
      seeds: seeds
    );
  }
}

/// Muzza's compact picks and listening shelves, supplied by local Videre data.
/// Native Flow music ranking supplies Quick Picks. Existing subscriptions can
/// contribute an independently verified Music pool on the first visible Home.
class MusicRecommendationShelves extends StatelessWidget {
  const MusicRecommendationShelves({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppCubit>().state;
    context.watch<SettingsCubit?>();
    if (session.globalLoading ||
        session.sessionRecoveryRequired ||
        session.profileId != db.profileId) {
      return const SizedBox.shrink();
    }
    final filters = jsonEncode([
      for (final filter in db.getAllFilters()) [filter.uuid, filter.toJson()]
    ]);
    return _ProfileMusicShelves(
      key: ValueKey((
        db,
        session.profileId,
        session.sessionRevision,
        session.server,
        filters
      )),
      database: db,
      session: session,
    );
  }
}

class _ProfileMusicShelves extends StatefulWidget {
  final IDbClient database;
  final AppState session;

  const _ProfileMusicShelves(
      {super.key, required this.database, required this.session});

  @override
  State<_ProfileMusicShelves> createState() => _ProfileMusicShelvesState();
}

class _ProfileMusicShelvesState extends State<_ProfileMusicShelves>
    with WidgetsBindingObserver {
  late final RecommendationService _recommendations;
  late final MusicLibraryService _library;
  late final RecommendationCandidates _candidates;
  late final MusicStarterArtists _starterArtists;
  late final SubscriptionRecommendationSource _subscriptionSource;
  Map<String, String> _subscriptionChannels = const {};
  List<MusicTrack> _subscribedMusic = const [];
  bool _active = false;
  bool _pageVisible = false;
  bool _openingSpeedDial = false;
  int _subscriptionLoad = 0;
  late int _tasteGeneration;
  List<RecommendedItem<MusicTrack>> _picks = const [];
  List<MusicTrack> _localTracks = const [];
  List<MusicTrack> _history = const [];
  List<MusicTrack> _onRepeat = const [];
  List<MusicTrack> _rotation = const [];
  List<MusicTrack> _rediscover = const [];
  List<_DailyMix> _dailyMixes = const [];
  Map<String, MusicTrack> _mixCovers = const {};
  Set<String> _hiddenArtists = const {};
  String? _timeBucket;
  // An empty list is a completed search below the display minimum. A null
  // entry is a failed request that can be retried on a later visit.
  final _preparedMixes = <String, List<MusicTrack>?>{};
  _MixScope? _mixScope;
  DateTime? _mixRetryAfter;
  int _mixVisit = 0;
  bool _preparingMix = false;
  int _generation = 0;
  late Future<void> _ranking;
  final _pickFocus = <int, FocusNode>{};
  final _random = math.Random();

  bool get _current {
    if (!mounted || !identical(widget.database, db)) return false;
    final current = context.read<AppCubit>().state;
    return !current.globalLoading &&
        !current.sessionRecoveryRequired &&
        current.profileId == widget.session.profileId &&
        db.profileId == widget.session.profileId &&
        current.sessionRevision == widget.session.sessionRevision &&
        current.server == widget.session.server &&
        !NetworkProxy.instance.isChanging;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NetworkProxy.instance.addBeforeApply(_proxyChanging);
    _recommendations = RecommendationService.forProfile(
        widget.database, widget.session.profileId);
    _library = MusicLibraryService.forProfile(
        widget.database, widget.session.profileId);
    _candidates =
        RecommendationCandidates(widget.database, isCurrent: () => _current);
    _starterArtists =
        MusicStarterArtists(widget.database, widget.session.profileId);
    _subscriptionSource = SubscriptionRecommendationSource(widget.database);
    _tasteGeneration = _recommendations.generation(RecommendationDomain.music);
    _recommendations.changes.addListener(_recommendationsChanged);
    recommendationSubscriptionRevision.addListener(_subscriptionsChanged);
    _library.changes.addListener(_refresh);
    _starterArtists.changes.addListener(_starterArtistsChanged);
    communityFilters.changes.addListener(_refresh);
    playbackHistoryRevision.addListener(_historyChanged);
    _refresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pageVisible =
        TickerMode.of(context) && (ModalRoute.isCurrentOf(context) ?? true);
    _updateActivity(WidgetsBinding.instance.lifecycleState);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _updateActivity(state);

  void _updateActivity(AppLifecycleState? lifecycle) {
    final active = _pageVisible &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
    if (active == _active) return;
    _active = active;
    _mixVisit++;
    if (active) {
      if (_mixRetryAfter?.isAfter(DateTime.now()) != true) {
        _preparedMixes.removeWhere((_, tracks) => tracks == null);
      }
      unawaited(_prepareNextMix());
      unawaited(_warmSubscriptions());
    } else {
      _subscriptionLoad++;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NetworkProxy.instance.removeBeforeApply(_proxyChanging);
    _generation++;
    _subscriptionLoad++;
    _recommendations.changes.removeListener(_recommendationsChanged);
    recommendationSubscriptionRevision.removeListener(_subscriptionsChanged);
    _library.changes.removeListener(_refresh);
    _starterArtists.changes.removeListener(_starterArtistsChanged);
    communityFilters.changes.removeListener(_refresh);
    playbackHistoryRevision.removeListener(_historyChanged);
    for (final node in _pickFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _recommendationsChanged() {
    final generation = _recommendations.generation(RecommendationDomain.music);
    if (generation != _tasteGeneration) {
      _tasteGeneration = generation;
      _dailyMixes = const [];
      _preparedMixes.clear();
      _subscriptionLoad++;
      _subscriptionChannels = const {};
      _subscribedMusic = const [];
      if (_active) unawaited(_warmSubscriptions());
    }
    unawaited(_refresh());
  }

  void _subscriptionsChanged() {
    _subscriptionLoad++;
    _subscriptionChannels = const {};
    _subscribedMusic = const [];
    unawaited(_refresh());
    if (_active) {
      unawaited(_warmSubscriptions(forceRefresh: true));
    }
  }

  Future<void> _warmSubscriptions({bool forceRefresh = false}) async {
    final load = ++_subscriptionLoad;
    bool current() =>
        _active &&
        _current &&
        load == _subscriptionLoad &&
        _recommendations.learningEnabled(RecommendationDomain.music);
    if (!current()) return;
    try {
      await for (final batch in _subscriptionSource.warm(
          server: widget.session.server,
          isCurrent: current,
          music: true,
          forceRefresh: forceRefresh,
          localMusic:
              _recommendations.eligibleMusic(_candidates.localMusic()))) {
        if (!current()) return;
        _subscriptionChannels = batch.channels;
        if (batch.music.isNotEmpty) _subscribedMusic = batch.music;
        await _refresh();
      }
    } on Exception {
      // A follow source can be unavailable while the local shelf works.
    }
  }

  void _historyChanged() {
    if (!_current) return;
    final current =
        _recommendations.eligibleMusic(_candidates.listeningHistory(limit: 12));
    // Progress ticks often update history without changing the displayed pool.
    // Do not rerank eighty candidates on every position notification.
    if (listEquals(
        current.map((t) => (t.videoId, t.title, t.artists.join(', '))).toList(),
        _history
            .map((t) => (t.videoId, t.title, t.artists.join(', ')))
            .toList())) {
      return;
    }
    _refresh();
  }

  void _starterArtistsChanged() {
    if (_current) setState(() {});
  }

  Future<void> _refresh() => _ranking = _refreshShelves();

  Future<void> _refreshShelves() async {
    final generation = ++_generation;
    if (!_current) return;
    final history =
        _recommendations.eligibleMusic(_candidates.listeningHistory(limit: 12));
    final localTracks = _candidates.localMusic();
    final candidates = [..._subscribedMusic, ...localTracks];
    setState(() {
      _history = history;
      _localTracks = localTracks;
      _picks = const [];
    });
    final ranked = await _recommendations.rankMusic(candidates,
        subscriptionChannels: _subscriptionChannels);
    if (!_current || generation != _generation) return;
    final summary =
        ranked.available ? ranked.summary : const <String, dynamic>{};
    final onRepeat = _trackIds(summary['onRepeat'], 16);
    final rotation = _trackIds(summary['timeOfDay'], 12);
    final rediscover = _trackIds(summary['rediscover'], 12);
    final dailyMixes = _mixSeeds(summary['dailyMixes']).toList();
    final ids = {
      ...onRepeat,
      ...rotation,
      ...rediscover,
      for (final mix in dailyMixes) ...mix.seeds,
    };
    final hidden = summary['hiddenArtists'];
    final hiddenArtists = hidden is List
        ? hidden.take(2000).whereType<String>().toSet()
        : const <String>{};
    final tracks = {
      for (final track
          in _recommendations.eligibleMusic(_candidates.localMusic(ids: ids)))
        if (!hiddenArtists
            .contains(RecommendationCandidate.music(track).creatorKey))
          track.videoId: track,
    };
    final repeatIds = onRepeat.toSet();
    // Flow MusicViewModel.refreshLocalShelves omits repeat tracks from time
    // rotation and rediscovery and hides shelves below their useful minimum.
    List<MusicTrack> resolve(Iterable<String> ordered) => [
          for (final id in ordered)
            if (tracks[id] case final track?) track,
        ];
    setState(() {
      // An unavailable native ranker is not replaced with an invented score.
      _picks = ranked.available
          ? ranked.items.take(_maxQuickPicks).toList()
          : const [];
      _onRepeat = resolve(onRepeat);
      _rotation = resolve(rotation.where((id) => !repeatIds.contains(id)));
      _rediscover = resolve(rediscover.where((id) => !repeatIds.contains(id)));
      _timeBucket = summary['timeBucket'] is String
          ? summary['timeBucket'] as String
          : null;
      _hiddenArtists = hiddenArtists;
      _mixCovers = tracks;
      _dailyMixes = dailyMixes
          .map((mix) => (
                label: mix.label,
                seeds: mix.seeds.where(tracks.containsKey).take(3).toList()
              ))
          .where((mix) => mix.seeds.length >= 2)
          .toList();
      final keys = _dailyMixes.map(_mixKey).toSet();
      _preparedMixes.removeWhere((key, _) => !keys.contains(key));
    });
    unawaited(_prepareNextMix());
  }

  Future<void> _open(
      MusicTrack track, Iterable<MusicTrack> tracks, String queueTitle) async {
    if (!_current) return;
    final songs = _recommendations.eligibleMusic(tracks);
    final index = songs.indexWhere((song) => song.videoId == track.videoId);
    if (index < 0) return;
    await context.router.push(MusicRoute(
        videoId: track.videoId,
        artistCredits: songs[index].artistCredits,
        queue: [for (final song in songs) song.toVideo()],
        queueTitle: queueTitle,
        startIndex: index));
  }

  Future<void> _openQuickPick(MusicTrack track) async {
    final tracks = _picks.map((pick) => pick.item);
    final title = AppLocalizations.of(context)!.musicQuickPicks;
    if (!isTv || !_current) return _open(track, tracks, title);
    final origin = ModalRoute.of(context);
    final slot =
        _picks.indexWhere((pick) => pick.item.videoId == track.videoId);
    if (slot < 0) return;
    await _open(track, tracks, title);
    await WidgetsBinding.instance.endOfFrame;
    // Playback can change the order or remove the played song while this
    // route is covered. Wait for the active ranking and its rows to mount.
    final restoredFocus = FocusManager.instance.primaryFocus;
    bool canRestore() =>
        _current &&
        _active &&
        origin?.isCurrent == true &&
        FocusManager.instance.primaryFocus == restoredFocus;
    Future<void> ranking;
    do {
      if (!canRestore()) return;
      ranking = _ranking;
      await ranking;
      await WidgetsBinding.instance.endOfFrame;
    } while (!identical(ranking, _ranking));
    if (!canRestore() || _picks.isEmpty) return;
    final index =
        _picks.indexWhere((pick) => pick.item.videoId == track.videoId);
    _pickFocus[index >= 0 ? index : math.min(slot, _picks.length - 1)]
        ?.requestFocus();
  }

  List<MusicTrack> _eligible(Iterable<MusicTrack> tracks) => _current
      ? _recommendations
          .eligibleMusic(tracks)
          .where((track) => !_hiddenArtists
              .contains(RecommendationCandidate.music(track).creatorKey))
          .toList()
      : const [];

  Future<void> _openSpeedDial({String? videoId}) async {
    if (!_active || !_current || _openingSpeedDial) return;
    // Resolve the recording from the current profile's pool at activation.
    final tracks = _eligible(_candidates.localMusic());
    if (tracks.isEmpty) return;
    final random = videoId == null;
    final queue = random
        ? [tracks[_random.nextInt(tracks.length)]]
        : tracks.take(_maxSpeedDialTracks).toList();
    final track = random
        ? queue.single
        : queue.where((track) => track.videoId == videoId).firstOrNull;
    if (track == null) return;
    final locals = AppLocalizations.of(context)!;
    _openingSpeedDial = true;
    try {
      await _open(track, queue,
          random ? locals.musicRandomPick : locals.musicSpeedDial);
    } finally {
      _openingSpeedDial = false;
    }
  }

  Future<void> _playShelf(_LocalShelf shelf,
      {String? from, bool songTap = false}) async {
    final songs = _eligible(shelf.tracks);
    if (songs.isEmpty) return;
    final index =
        from == null ? 0 : songs.indexWhere((track) => track.videoId == from);
    if (index < 0) return;
    try {
      await MusicScreen.playTracks(
          context, [for (final track in songs) track.toVideo()],
          queueTitle: shelf.title, startIndex: index, songTap: songTap);
    } catch (_) {
      if (mounted && _current) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.musicPlaybackError)));
      }
    }
  }

  String? _rotationLabel(AppLocalizations locals) => switch (_timeBucket) {
        'WeekdayMorning' || 'WeekendMorning' => locals.musicRotationMorning,
        'WeekdayAfternoon' ||
        'WeekendAfternoon' =>
          locals.musicRotationAfternoon,
        'WeekdayEvening' || 'WeekendEvening' => locals.musicRotationEvening,
        'WeekdayNight' || 'WeekendNight' => locals.musicRotationNight,
        _ => null,
      };

  void _openShelf(String title, List<MusicTrack> tracks) {
    if (!_current) return;
    final proxy = NetworkProxy.instance.config;
    final token = _recommendations.generation(RecommendationDomain.music);
    bool current() =>
        _current &&
        identical(proxy, NetworkProxy.instance.config) &&
        token == _recommendations.generation(RecommendationDomain.music);
    Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => MusicRecommendationCollection(
              title: title,
              tracks: tracks,
              isCurrent: current,
              eligible: _eligible,
              changes: Listenable.merge(
                  [_recommendations.changes, communityFilters.changes]),
            )));
  }

  _MixScope get _currentMixScope => (
        day: DateUtils.dateOnly(DateTime.now()),
        generation: _recommendations.generation(RecommendationDomain.music),
        proxy: NetworkProxy.instance.config,
      );

  String _mixKey(_DailyMix mix) => (mix.seeds.toList()..sort()).join(',');

  Future<void> _proxyChanging() async {
    setState(() {
      _mixVisit++;
      _preparedMixes.clear();
      _mixScope = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_prepareNextMix());
    });
  }

  Future<void> _prepareNextMix() async {
    if (!_active ||
        !_current ||
        _preparingMix ||
        widget.session.server == null) {
      return;
    }
    final scope = _currentMixScope;
    if (scope != _mixScope) {
      _preparedMixes.clear();
      _mixScope = scope;
      _mixRetryAfter = null;
    }
    if (_mixRetryAfter?.isAfter(DateTime.now()) == true) return;
    final mix = _dailyMixes
        .where((mix) => !_preparedMixes.containsKey(_mixKey(mix)))
        .firstOrNull;
    if (mix == null) return;
    final key = _mixKey(mix);
    final visit = _mixVisit;
    bool current() =>
        _current &&
        _active &&
        visit == _mixVisit &&
        scope == _currentMixScope &&
        _dailyMixes.any((mix) => _mixKey(mix) == key);

    // Prepare one group at a time, even if history changes during a request.
    // The selected instance verifies the recordings before they enter a mix.
    _preparingMix = true;
    try {
      final related = await musicCatalogService.getRelatedSongs(mix.seeds,
          isCurrent: current);
      if (!current()) return;
      final ranked =
          await _recommendations.rankMusic(related, surface: 'discover');
      if (!current()) return;
      if (!ranked.available) {
        _preparedMixes[key] = null;
        return;
      }
      final used = _preparedMixes.values.nonNulls
          .expand((tracks) => tracks)
          .map((track) => track.videoId)
          .toSet();
      final tracks = _eligible(ranked.items.map((item) => item.item))
          .where((track) => used.add(track.videoId))
          .take(14)
          .toList();
      setState(
          () => _preparedMixes[key] = tracks.length >= 4 ? tracks : const []);
    } catch (error) {
      if (!current()) return;
      _preparedMixes[key] = null;
      // An instance-wide rejection applies to the remaining groups as well.
      if (error is InvidiousServiceError &&
          (error.isRateLimited ||
              error.retryAfterIsInvalid ||
              (error.retryAfter ?? Duration.zero) > Duration.zero ||
              error.isAuthenticationFailure ||
              error.isGatewayAccessFailure)) {
        if (error.retryAfter case final delay? when delay > Duration.zero) {
          _mixRetryAfter = DateTime.now().add(delay);
        }
        for (final pending in _dailyMixes) {
          _preparedMixes.putIfAbsent(_mixKey(pending), () => null);
        }
      }
    } finally {
      _preparingMix = false;
      if (mounted) unawaited(_prepareNextMix());
    }
  }

  Widget _shelf(BuildContext context, _LocalShelf shelf) {
    final locals = AppLocalizations.of(context)!;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _ShelfHeading(
        title: shelf.title,
        action: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            key: ValueKey('music-${shelf.id}-play'),
            tooltip: locals.musicPlayAll,
            icon: const Icon(Icons.play_arrow_rounded),
            onPressed: () => _playShelf(shelf),
          ),
          IconButton(
            key: ValueKey('music-${shelf.id}-view'),
            tooltip: shelf.title,
            icon: const Icon(Icons.arrow_forward_rounded),
            onPressed: () => _openShelf(shelf.title, shelf.tracks),
          ),
        ]),
      ),
      MusicCatalogShelf(
        key: ValueKey('music-${shelf.id}'),
        itemCount: shelf.tracks.length,
        itemBuilder: (_, index) {
          final song = shelf.tracks[index];
          return MusicCatalogCard(
            key: ValueKey('music-${shelf.id}-${song.videoId}'),
            title: song.title,
            subtitle: song.artists.join(', '),
            song: song,
            showPlayIndicator: true,
            badge: MusicLibraryActions(
                videos: [song.toVideo()],
                onPlay: () => _playShelf(shelf, from: song.videoId)),
            onOpen: () => _playShelf(shelf, from: song.videoId, songTap: true),
            onLongPress: () => MusicLibraryActions.showSongMenu(
                context, song.toVideo(),
                onPlay: () => _playShelf(shelf, from: song.videoId)),
          );
        },
      ),
    ]);
  }

  Future<void> _feedback(
      MusicTrack track, RecommendationFeedback feedback) async {
    if (!_current) return;
    try {
      await _recommendations.feedback(
          track.toVideo(), RecommendationDomain.music, feedback);
    } catch (_) {
      if (mounted && _current) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.recommendationError)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final starterKeys =
        _starterArtists.picks?.map(MusicStarterArtists.artistKey).toSet();
    final starterMatches = starterKeys == null || starterKeys.isEmpty
        ? const <MusicTrack>[]
        : _eligible(_localTracks.where(
                (track) => MusicStarterArtists.matches(track, starterKeys)))
            .take(_maxQuickPicks)
            .toList();
    final speedDial =
        _eligible(_localTracks).take(_maxSpeedDialTracks).toList();
    final showRecentActivity = context.select((SettingsCubit? settings) =>
        settings?.state.musicLayout.showRecentActivity ?? true);
    final onRepeat = _eligible(_onRepeat);
    final rediscover = _eligible(_rediscover);
    final rotation = _eligible(_rotation);
    final mixes = [
      if (_mixScope == _currentMixScope)
        for (final mix in _dailyMixes)
          if (_preparedMixes[_mixKey(mix)] case final prepared?)
            if (_eligible(prepared) case final tracks when tracks.length >= 4)
              (mix: mix, tracks: tracks),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (starterMatches.isNotEmpty)
          _shelf(context, (
            id: 'starter-artist-matches',
            title: locals.musicStarterArtistMatches,
            tracks: starterMatches,
          )),
        if (_picks.isNotEmpty) ...[
          _ShelfHeading(
            title: locals.musicQuickPicks,
            action: IconButton(
              key: const ValueKey('music-recommendation-settings'),
              tooltip: locals.settings,
              icon: const Icon(Icons.tune_rounded),
              onPressed: () => showRecommendationSettings(context),
            ),
          ),
          _QuickPickRows(
            picks: _picks,
            focusForSlot: isTv
                ? (slot) => _pickFocus.putIfAbsent(slot, FocusNode.new)
                : null,
            onOpen: _openQuickPick,
            onFeedback: _feedback,
            isCurrent: () => _current,
          ),
        ],
        if (_current) ...[
          _ShelfHeading(
            title: locals.musicSpeedDial,
            action: speedDial.isEmpty
                ? null
                : Flexible(
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton.icon(
                        key: const ValueKey('music-random-pick'),
                        icon: const Icon(Icons.casino_outlined),
                        label: Text(locals.musicRandomPick),
                        onPressed: _openSpeedDial,
                      ),
                    ),
                  ),
          ),
          if (speedDial.isEmpty)
            Text(locals.musicSpeedDialEmpty)
          else
            MusicCatalogShelf(
              key: const ValueKey('music-speed-dial'),
              itemCount: speedDial.length,
              itemBuilder: (_, index) {
                final track = speedDial[index];
                return MusicCatalogCard(
                  key: ValueKey('music-speed-dial-${track.videoId}'),
                  title: track.title,
                  subtitle: track.artists.join(', '),
                  song: track,
                  showPlayIndicator: true,
                  onOpen: () => _openSpeedDial(videoId: track.videoId),
                );
              },
            ),
        ],
        if (showRecentActivity && _history.isNotEmpty) ...[
          _ShelfHeading(title: locals.musicKeepListening),
          MusicCatalogShelf(
            key: const ValueKey('music-keep-listening'),
            itemCount: _history.length,
            itemBuilder: (context, index) {
              final track = _history[index];
              Future<void> open() =>
                  _open(track, _history, locals.musicKeepListening);
              return MusicCatalogCard(
                key: ValueKey('music-keep-listening-${track.videoId}'),
                title: track.title,
                subtitle: [
                  if (track.artists.isNotEmpty) track.artists.join(', '),
                  if (track.durationSeconds case final seconds?
                      when seconds > 0)
                    prettyDurationCustom(Duration(seconds: seconds)),
                ].join(' • '),
                song: track,
                badge: MusicLibraryActions(
                    videos: [track.toVideo()], onPlay: open),
                onOpen: open,
                onLongPress: () => MusicLibraryActions.showSongMenu(
                    context, track.toVideo(),
                    onPlay: open),
                showPlayIndicator: true,
              );
            },
          ),
        ],
        if (mixes.isNotEmpty) ...[
          _ShelfHeading(title: locals.musicDailyMixes),
          MusicCatalogShelf(
            key: const ValueKey('music-daily-mixes'),
            itemCount: mixes.length,
            itemBuilder: (_, index) {
              final (:mix, :tracks) = mixes[index];
              final title = locals.musicDailyMixTitle(mix.label);
              return MusicCatalogCard(
                key: ValueKey('music-daily-mix-$index'),
                title: title,
                thumbnails:
                    _mixCovers[mix.seeds.first]?.displayThumbnails ?? const [],
                onOpen: () => _openShelf(title, tracks),
              );
            },
          ),
        ],
        if (onRepeat.length >= 2)
          _shelf(context,
              (id: 'on-repeat', title: locals.musicOnRepeat, tracks: onRepeat)),
        if (_rotationLabel(locals) case final title? when rotation.length >= 3)
          _shelf(context, (id: 'rotation', title: title, tracks: rotation)),
        if (rediscover.length >= 3)
          _shelf(context, (
            id: 'rediscover',
            title: locals.musicRediscover,
            tracks: rediscover
          )),
      ],
    );
  }
}

class _ShelfHeading extends StatelessWidget {
  final String title;
  final Widget? action;
  const _ShelfHeading({required this.title, this.action});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 12),
        child: Row(children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
          ),
          if (action != null) action!,
        ]),
      );
}

const _quickPickGap = 12.0;

double _quickPickStride(double viewport) =>
    math.min(420.0, viewport * 0.9) + _quickPickGap;

/// The scrollable keeps its full width so multiple columns can be visible on
/// tablets. Each page of a swipe is one column, including the gap after it.
class _QuickPickScrollPhysics extends PageScrollPhysics {
  final int Function() dragColumn;

  const _QuickPickScrollPhysics(this.dragColumn, {super.parent});

  @override
  _QuickPickScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _QuickPickScrollPhysics(dragColumn, parent: buildParent(ancestor));

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    final delta = super.applyPhysicsToUserOffset(position, offset);
    final step = _quickPickStride(position.viewportDimension);
    final origin = dragColumn();
    final next = (position.pixels - delta)
        .clamp((origin - 1) * step, (origin + 1) * step);
    return position.pixels - next;
  }

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    final step = _quickPickStride(position.viewportDimension);
    final column = position.pixels / step;
    // A long drag can reach the next anchor before release. Discard its
    // remaining fling velocity there so it cannot advance a second column.
    final onAnchor = (position.pixels - column.round() * step).abs() < 0.001;
    return super.createBallisticSimulation(
        position.copyWith(viewportDimension: step), onAnchor ? 0 : velocity);
  }

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    if (!isScrolling &&
        oldPosition.viewportDimension != newPosition.viewportDimension) {
      final column =
          (oldPosition.pixels / _quickPickStride(oldPosition.viewportDimension))
              .round();
      return (column * _quickPickStride(newPosition.viewportDimension))
          .clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent);
    }
    return super.adjustPositionForNewDimensions(
        oldPosition: oldPosition,
        newPosition: newPosition,
        isScrolling: isScrolling,
        velocity: velocity);
  }

  @override
  bool get allowImplicitScrolling => true;
}

class _QuickPickRows extends StatefulWidget {
  final List<RecommendedItem<MusicTrack>> picks;
  final FocusNode Function(int)? focusForSlot;
  final Future<void> Function(MusicTrack) onOpen;
  final void Function(MusicTrack, RecommendationFeedback) onFeedback;
  final bool Function() isCurrent;

  const _QuickPickRows(
      {required this.picks,
      required this.focusForSlot,
      required this.onOpen,
      required this.onFeedback,
      required this.isCurrent});

  @override
  State<_QuickPickRows> createState() => _QuickPickRowsState();
}

class _QuickPickRowsState extends State<_QuickPickRows> {
  int _dragColumn = 0;

  @override
  Widget build(BuildContext context) {
    final (compact, titleLines) = context.select((SettingsCubit? settings) {
      final layout = settings?.state.musicLayout;
      return (layout?.compactRows ?? false, layout?.titleLines(1) ?? 1);
    });
    final textTheme = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    final title = textTheme.titleSmall!;
    final subtitle = textTheme.bodyMedium!;
    final rowHeight = math.max(
        compact ? 52.0 : 64.0,
        (compact ? 16 : 20) +
            titleLines * scaler.scale(title.fontSize!) * (title.height ?? 1.4) +
            scaler.scale(subtitle.fontSize!) * (subtitle.height ?? 1.4));
    final picks = widget.picks;
    final rows = math.min(4, picks.length);
    final columns = (picks.length / rows).ceil();
    return LayoutBuilder(builder: (context, bounds) {
      final width = bounds.maxWidth;
      final step = _quickPickStride(width);
      final visibleColumns =
          ((width + _quickPickGap) / step).floor().clamp(1, columns);
      // Align the last column on phones, or the last group of columns on
      // larger screens, to the same leading edge as the first.
      final endPadding = columns > visibleColumns
          ? math.max(0.0, width - (visibleColumns * step - _quickPickGap))
          : 0.0;
      return NotificationListener<ScrollStartNotification>(
          onNotification: (notice) {
            if (notice.depth == 0 && notice.dragDetails != null) {
              _dragColumn = (notice.metrics.pixels / step).round();
            }
            return false;
          },
          child: SizedBox(
            height: rows * rowHeight,
            child: ListView.separated(
              key: const ValueKey('music-quick-picks'),
              primary: false,
              scrollDirection: Axis.horizontal,
              padding: EdgeInsetsDirectional.only(end: endPadding),
              // All three TV lanes can receive returning remote focus,
              // including a song that moved outside the viewport.
              cacheExtent: widget.focusForSlot == null ? null : columns * step,
              physics: _QuickPickScrollPhysics(() => _dragColumn),
              itemCount: columns,
              separatorBuilder: (_, __) => const SizedBox(width: _quickPickGap),
              itemBuilder: (context, lane) => SizedBox(
                width:
                    columns > 1 ? step - _quickPickGap : math.min(420.0, width),
                child: Column(children: [
                  for (final (slot, pick)
                      in picks.indexed.skip(lane * rows).take(rows))
                    SizedBox(
                        height: rowHeight,
                        child: _QuickPickRow(
                          key:
                              ValueKey('music-quick-pick-${pick.item.videoId}'),
                          pick: pick,
                          compact: compact,
                          titleLines: titleLines,
                          focusNode: widget.focusForSlot?.call(slot),
                          onOpen: () => widget.onOpen(pick.item),
                          onFeedback: (feedback) =>
                              widget.onFeedback(pick.item, feedback),
                          isCurrent: widget.isCurrent,
                        )),
                ]),
              ),
            ),
          ));
    });
  }
}

class _QuickPickRow extends StatelessWidget {
  final RecommendedItem<MusicTrack> pick;
  final bool compact;
  final int titleLines;
  final FocusNode? focusNode;
  final Future<void> Function() onOpen;
  final ValueChanged<RecommendationFeedback> onFeedback;
  final bool Function() isCurrent;
  const _QuickPickRow(
      {super.key,
      required this.pick,
      required this.compact,
      required this.titleLines,
      required this.focusNode,
      required this.onOpen,
      required this.onFeedback,
      required this.isCurrent});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final track = pick.item;
    final images = track.displayThumbnails;
    final recommendation = MusicSongRecommendation(
        reason: pick.reason, onFeedback: onFeedback, isCurrent: isCurrent);
    return ListTile(
      focusNode: focusNode,
      contentPadding: const EdgeInsetsDirectional.only(start: 2, end: 4),
      horizontalTitleGap: 12,
      minLeadingWidth: 0,
      visualDensity: VisualDensity.compact,
      onTap: onOpen,
      onLongPress: () => MusicLibraryActions.showSongMenu(
          context, track.toVideo(),
          onPlay: onOpen, recommendation: recommendation),
      onFocusChange: (focused) {
        if (focused) Scrollable.ensureVisible(context, alignment: 0.5);
      },
      leading: SizedBox.square(
          dimension: compact ? 40 : 48,
          child: CommunityMusicArtwork(
              videoId: track.videoId,
              music: track.musicMetadata,
              durationSeconds: track.durationSeconds,
              fallback: images.isEmpty
                  ? DecoratedBox(
                      decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(6)),
                      child: const Icon(Icons.music_note_rounded),
                    )
                  : Thumbnail(
                      musicArtwork: true,
                      images: images,
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6))))),
      title: Text(pick.item.title,
          maxLines: titleLines,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w700)),
      subtitle: Text(pick.item.artists.join(', '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      trailing: MusicLibraryActions(
          videos: [track.toVideo()],
          onPlay: onOpen,
          recommendation: recommendation),
    );
  }
}
