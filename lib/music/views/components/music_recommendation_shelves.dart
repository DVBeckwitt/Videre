import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/recommendations/candidate_sources.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/recommendations/subscription_recommendations.dart';
import 'package:clipious/recommendations/subscription_revision.dart';
import 'package:clipious/recommendations/views/recommendation_settings.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'music_catalog_cards.dart';
import 'music_library_actions.dart';
import 'music_recommendation_collection.dart';
import '../screens/music.dart';

typedef _DailyMix = ({String label, List<String> seeds});
typedef _LocalShelf = ({String id, String title, List<MusicTrack> tracks});

final _recordingId = RegExp(r'^[A-Za-z0-9_-]{11}$');

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

class _ProfileMusicShelvesState extends State<_ProfileMusicShelves> {
  late final RecommendationService _recommendations;
  late final MusicLibraryService _library;
  late final RecommendationCandidates _candidates;
  late final SubscriptionRecommendationSource _subscriptionSource;
  Map<String, String> _subscriptionChannels = const {};
  List<MusicTrack> _subscribedMusic = const [];
  bool _active = false;
  int _subscriptionLoad = 0;
  late int _tasteGeneration;
  List<RecommendedItem<MusicTrack>> _picks = const [];
  List<MusicTrack> _history = const [];
  List<MusicTrack> _onRepeat = const [];
  List<MusicTrack> _rotation = const [];
  List<MusicTrack> _rediscover = const [];
  List<_DailyMix> _dailyMixes = const [];
  Map<String, MusicTrack> _mixCovers = const {};
  Set<String> _hiddenArtists = const {};
  String? _timeBucket;
  final _expandedMixes = <String, List<MusicTrack>>{};
  ({DateTime day, int generation, Object proxy})? _mixScope;
  int _generation = 0;

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
    _recommendations = RecommendationService.forProfile(
        widget.database, widget.session.profileId);
    _library = MusicLibraryService.forProfile(
        widget.database, widget.session.profileId);
    _candidates =
        RecommendationCandidates(widget.database, isCurrent: () => _current);
    _subscriptionSource = SubscriptionRecommendationSource(widget.database);
    _tasteGeneration = _recommendations.generation(RecommendationDomain.music);
    _recommendations.changes.addListener(_recommendationsChanged);
    recommendationSubscriptionRevision.addListener(_subscriptionsChanged);
    _library.changes.addListener(_refresh);
    communityFilters.changes.addListener(_refresh);
    playbackHistoryRevision.addListener(_historyChanged);
    _refresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.of(context);
    if (active == _active) return;
    _active = active;
    if (active) {
      unawaited(_warmSubscriptions());
    } else {
      _subscriptionLoad++;
    }
  }

  @override
  void dispose() {
    _generation++;
    _subscriptionLoad++;
    _recommendations.changes.removeListener(_recommendationsChanged);
    recommendationSubscriptionRevision.removeListener(_subscriptionsChanged);
    _library.changes.removeListener(_refresh);
    communityFilters.changes.removeListener(_refresh);
    playbackHistoryRevision.removeListener(_historyChanged);
    super.dispose();
  }

  void _recommendationsChanged() {
    final generation = _recommendations.generation(RecommendationDomain.music);
    if (generation != _tasteGeneration) {
      _tasteGeneration = generation;
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

  Future<void> _refresh() async {
    final generation = ++_generation;
    if (!_current) return;
    final history =
        _recommendations.eligibleMusic(_candidates.listeningHistory(limit: 12));
    final candidates = [..._subscribedMusic, ..._candidates.localMusic()];
    setState(() {
      _history = history;
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
      _picks = ranked.available ? ranked.items.take(12).toList() : const [];
      _onRepeat = resolve(onRepeat);
      _rotation = resolve(rotation.where((id) => !repeatIds.contains(id)));
      _rediscover = resolve(rediscover.where((id) => !repeatIds.contains(id)));
      _timeBucket = summary['timeBucket'] is String
          ? summary['timeBucket'] as String
          : null;
      _hiddenArtists = hiddenArtists;
      _mixCovers = tracks;
      _dailyMixes = [
        for (final mix in dailyMixes)
          if (tracks.keys.toSet().intersection(mix.seeds.toSet()).length >= 2)
            (
              label: mix.label,
              seeds: mix.seeds.where(tracks.containsKey).toList()
            ),
      ];
    });
  }

  void _open(MusicTrack track) {
    if (_current) context.router.push(MusicRoute(videoId: track.videoId));
  }

  List<MusicTrack> _eligible(Iterable<MusicTrack> tracks) => _current
      ? _recommendations
          .eligibleMusic(tracks)
          .where((track) => !_hiddenArtists
              .contains(RecommendationCandidate.music(track).creatorKey))
          .toList()
      : const [];

  Future<void> _playShelf(List<MusicTrack> tracks, {String? from}) async {
    final songs = _eligible(tracks);
    if (songs.isEmpty) return;
    final index =
        from == null ? 0 : songs.indexWhere((track) => track.videoId == from);
    if (index < 0) return;
    try {
      await MusicScreen.playTracks(
          context, [for (final track in songs) track.toVideo()],
          startIndex: index);
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

  void _openShelf(String title, List<MusicTrack> tracks, {_DailyMix? mix}) {
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
              cover: mix == null ? null : _mixCovers[mix.seeds.first],
              isCurrent: current,
              eligible: _eligible,
              changes: Listenable.merge(
                  [_recommendations.changes, communityFilters.changes]),
              load: mix == null
                  ? null
                  : (routeCurrent) =>
                      _loadMix(mix, () => current() && routeCurrent()),
            )));
  }

  Future<List<MusicTrack>> _loadMix(
      _DailyMix mix, bool Function() current) async {
    final scope = (
      day: DateUtils.dateOnly(DateTime.now()),
      generation: _recommendations.generation(RecommendationDomain.music),
      proxy: NetworkProxy.instance.config,
    );
    if (scope != _mixScope) {
      _expandedMixes.clear();
      _mixScope = scope;
    }
    final seeds = _eligible([
      for (final id in mix.seeds)
        if (_mixCovers[id] case final track?) track,
    ]).take(3).map((track) => track.videoId).toList(growable: false);
    if (!current() || seeds.length < 2) return const [];
    final key = seeds.join(',');
    final cached = _expandedMixes[key];
    if (cached != null) {
      final eligible = _eligible(cached);
      if (eligible.length >= 4) return eligible;
      _expandedMixes.remove(key);
    }

    // Flow MusicViewModel.buildDailyMixSections: recall related lanes from
    // learned seeds, then rank in the Discover surface and dedup across mixes.
    // Videre loads just the chosen mix through the selected Invidious instance.
    final related =
        await musicCatalogService.getRelatedSongs(seeds, isCurrent: current);
    if (!current() || _mixScope != scope) return const [];
    final ranked =
        await _recommendations.rankMusic(related, surface: 'discover');
    if (!current() || _mixScope != scope || ranked.cancelled) return const [];
    if (!ranked.available) throw const MusicCatalogUnsupported();
    final used = {
      for (final mixTracks in _expandedMixes.values)
        for (final track in mixTracks) track.videoId,
    };
    final tracks = _eligible(ranked.items.map((item) => item.item))
        .where((track) => !used.contains(track.videoId))
        .take(14)
        .toList();
    if (tracks.length < 4) return const [];
    if (_expandedMixes.length >= 3) {
      _expandedMixes.remove(_expandedMixes.keys.first);
    }
    _expandedMixes[key] = tracks;
    return tracks;
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
            onPressed: () => _playShelf(shelf.tracks),
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
            thumbnails: song.thumbnails,
            showPlayIndicator: true,
            onOpen: () => _playShelf(shelf.tracks, from: song.videoId),
            onLongPress: () => MusicLibraryActions.showSongMenu(
                context, song.toVideo(),
                onPlay: () => _playShelf(shelf.tracks, from: song.videoId)),
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
    final onRepeat = _eligible(_onRepeat);
    final rediscover = _eligible(_rediscover);
    final rotation = _eligible(_rotation);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
            onOpen: _open,
            onFeedback: _feedback,
            isCurrent: () => _current,
          ),
        ],
        if (_history.isNotEmpty) ...[
          _ShelfHeading(title: locals.musicKeepListening),
          MusicCatalogShelf(
            key: const ValueKey('music-keep-listening'),
            itemCount: _history.length,
            itemBuilder: (context, index) {
              final track = _history[index];
              return MusicCatalogCard(
                key: ValueKey('music-keep-listening-${track.videoId}'),
                title: track.title,
                subtitle: [
                  if (track.artists.isNotEmpty) track.artists.join(', '),
                  if (track.durationSeconds case final seconds?
                      when seconds > 0)
                    prettyDurationCustom(Duration(seconds: seconds)),
                ].join(' • '),
                thumbnails: track.thumbnails,
                onOpen: () => _open(track),
                onLongPress: () =>
                    MusicLibraryActions.showSongMenu(context, track.toVideo()),
                showPlayIndicator: true,
              );
            },
          ),
        ],
        if (_dailyMixes.isNotEmpty) ...[
          _ShelfHeading(title: locals.musicDailyMixes),
          MusicCatalogShelf(
            key: const ValueKey('music-daily-mixes'),
            itemCount: _dailyMixes.length,
            itemBuilder: (_, index) {
              final mix = _dailyMixes[index];
              final title = locals.musicDailyMixTitle(mix.label);
              return MusicCatalogCard(
                key: ValueKey('music-daily-mix-$index'),
                title: title,
                thumbnails: _mixCovers[mix.seeds.first]?.thumbnails ?? const [],
                onOpen: () => _openShelf(title, const [], mix: mix),
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

class _QuickPickRows extends StatelessWidget {
  final List<RecommendedItem<MusicTrack>> picks;
  final ValueChanged<MusicTrack> onOpen;
  final void Function(MusicTrack, RecommendationFeedback) onFeedback;
  final bool Function() isCurrent;

  const _QuickPickRows(
      {required this.picks,
      required this.onOpen,
      required this.onFeedback,
      required this.isCurrent});

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final rowHeight = math.max(64.0, 20 + scaler.scale(14) * 1.4 * 2);
    final rows = math.min(4, picks.length);
    return LayoutBuilder(
        builder: (context, bounds) => SizedBox(
              height: rows * rowHeight,
              child: ListView.separated(
                key: const ValueKey('music-quick-picks'),
                primary: false,
                scrollDirection: Axis.horizontal,
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: (picks.length / rows).ceil(),
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, lane) => SizedBox(
                  width: math.min(
                      420.0, bounds.maxWidth * (picks.length > rows ? 0.9 : 1)),
                  child: Column(children: [
                    for (final pick in picks.skip(lane * rows).take(rows))
                      SizedBox(
                          height: rowHeight,
                          child: _QuickPickRow(
                            key: ValueKey(
                                'music-quick-pick-${pick.item.videoId}'),
                            pick: pick,
                            onOpen: () => onOpen(pick.item),
                            onFeedback: (feedback) =>
                                onFeedback(pick.item, feedback),
                            isCurrent: isCurrent,
                          )),
                  ]),
                ),
              ),
            ));
  }
}

class _QuickPickRow extends StatelessWidget {
  final RecommendedItem<MusicTrack> pick;
  final VoidCallback onOpen;
  final ValueChanged<RecommendationFeedback> onFeedback;
  final bool Function() isCurrent;
  const _QuickPickRow(
      {super.key,
      required this.pick,
      required this.onOpen,
      required this.onFeedback,
      required this.isCurrent});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: const EdgeInsetsDirectional.only(start: 2, end: 4),
      horizontalTitleGap: 12,
      minLeadingWidth: 0,
      visualDensity: VisualDensity.compact,
      onTap: onOpen,
      onLongPress: () =>
          MusicLibraryActions.showSongMenu(context, pick.item.toVideo()),
      onFocusChange: (focused) {
        if (focused) Scrollable.ensureVisible(context, alignment: 0.5);
      },
      leading: SizedBox.square(
          dimension: 48,
          child: pick.item.thumbnails.isEmpty
              ? DecoratedBox(
                  decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(6)),
                  child: const Icon(Icons.music_note_rounded),
                )
              : Thumbnail(
                  images: pick.item.thumbnails,
                  decoration:
                      BoxDecoration(borderRadius: BorderRadius.circular(6)))),
      title: Text(pick.item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w700)),
      subtitle: Text(pick.item.artists.join(', '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      trailing: MusicRecommendationActions(
          reason: pick.reason, onFeedback: onFeedback, isCurrent: isCurrent),
    );
  }
}

/// Shared local feedback for Quick Picks and explicitly loaded discovery.
class MusicRecommendationActions extends StatelessWidget {
  final String reason;
  final ValueChanged<RecommendationFeedback> onFeedback;
  final bool Function()? isCurrent;

  const MusicRecommendationActions(
      {super.key,
      required this.reason,
      required this.onFeedback,
      this.isCurrent});

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return PopupMenuButton<int>(
      tooltip: locals.musicLibraryActions,
      onSelected: (value) {
        if (isCurrent?.call() == false) return;
        if (value == 0) {
          showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                    title: Text(locals.recommendationWhy),
                    content: Text(reason),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text(MaterialLocalizations.of(context)
                              .closeButtonLabel))
                    ],
                  ));
        } else {
          onFeedback(switch (value) {
            1 => RecommendationFeedback.like,
            3 => RecommendationFeedback.block,
            _ => RecommendationFeedback.notInterested,
          });
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(value: 0, child: Text(locals.recommendationWhy)),
        PopupMenuItem(value: 1, child: Text(locals.recommendationMoreLikeThis)),
        PopupMenuItem(
            value: 2, child: Text(locals.recommendationNotInterested)),
        PopupMenuItem(value: 3, child: Text(locals.recommendationBlockCreator)),
      ],
    );
  }
}
