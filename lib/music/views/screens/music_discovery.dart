import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/content_filter/community_filter_widgets.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_charts.dart';
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_layout.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/views/components/music_catalog_cards.dart';
import 'package:clipious/music/views/components/community_music_artwork.dart';
import 'package:clipious/music/views/components/music_chart_picker.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/components/music_recommendation_collection.dart';
import 'package:clipious/music/views/components/music_recommendation_shelves.dart';
import 'package:clipious/music/views/components/music_track_results.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/player/states/player.dart' show PlayerCubit;
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/recommendations/views/recommendation_settings.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class MusicHomePage extends StatefulWidget {
  final VoidCallback onSearch;
  final VoidCallback onLibrary;
  final bool showSearchShortcut;

  const MusicHomePage({
    super.key,
    required this.onSearch,
    required this.onLibrary,
    this.showSearchShortcut = true,
  });

  @override
  State<MusicHomePage> createState() => _MusicHomePageState();
}

/// Local bookmarks and a bounded, category-checked Invidious selection. The
/// upstream trending endpoint no longer provides a Music category.
class _MusicHomePageState extends State<MusicHomePage> {
  final _scroll = ScrollController();
  final _discovery = GlobalKey();

  void _showDiscovery() {
    final target = _discovery.currentContext;
    if (target != null) Scrollable.ensureVisible(target);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The expanded phone player sits above the Navigator. Home can still be
    // the current route while the player covers its recommendation shelves.
    final covered = context.select((PlayerCubit? player) {
      final state = player?.state;
      return state != null &&
          (state.isPip || (!state.isHidden && !state.isMini));
    });
    return TickerMode(
      enabled: !covered,
      child: _DiscoverySongs(
          builder: (canDiscover, freshShelves, songs) => _DiscoveryScroll(
                storageKey: 'music-home',
                controller: _scroll,
                children: [
                  _MusicHomeShortcuts(
                    onSearch:
                        widget.showSearchShortcut ? widget.onSearch : null,
                    onLibrary: widget.onLibrary,
                    onDiscover: canDiscover == null
                        ? null
                        : () {
                            if (canDiscover()) _showDiscovery();
                          },
                  ),
                  const MusicRecommendationShelves(),
                  _SavedSongs(onLibrary: widget.onLibrary),
                  freshShelves,
                  const _MusicExplore(),
                  KeyedSubtree(key: _discovery, child: songs),
                ],
              )),
    );
  }
}

class _MusicHomeShortcuts extends StatelessWidget {
  final VoidCallback? onSearch;
  final VoidCallback onLibrary;
  final VoidCallback? onDiscover;

  const _MusicHomeShortcuts({
    required this.onSearch,
    required this.onLibrary,
    required this.onDiscover,
  });

  Future<void> _openCharts(BuildContext context) async {
    final app = context.read<AppCubit>();
    final session = app.state;
    final database = db;
    final route = ModalRoute.of(context);
    if (session.server == null || !_sameSession(session, session)) return;

    final playlistId = await showMusicChartPicker(context,
        browsingCountry: database.getSettings(browsingCountry)?.value ?? 'US');
    if (playlistId != null &&
        context.mounted &&
        identical(database, db) &&
        (route?.isCurrent ?? true) &&
        _sameSession(session, app.state)) {
      context.router.push(MusicRoute(playlistId: playlistId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final locals = AppLocalizations.of(context)!;
    final order = context.select((SettingsCubit? settings) =>
        settings?.state.musicLayout.shortcuts ?? MusicShortcut.values);
    final actions = <MusicShortcut, VoidCallback>{
      if (onSearch case final search?) MusicShortcut.search: search,
      MusicShortcut.library: onLibrary,
      MusicShortcut.charts: () => _openCharts(context),
      if (onDiscover case final discover?) MusicShortcut.discover: discover,
      MusicShortcut.recommendations: () => showRecommendationSettings(context),
    };
    final shortcuts = order.where(actions.containsKey);
    if (shortcuts.isEmpty) return const SizedBox.shrink();
    final style = TextButton.styleFrom(
      backgroundColor: colors.surfaceContainerHigh,
      foregroundColor: colors.onSurfaceVariant,
      minimumSize: const Size(0, 32),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      shape: const StadiumBorder(),
    );
    return SingleChildScrollView(
      key: const ValueKey('music-home-shortcuts'),
      scrollDirection: Axis.horizontal,
      physics: const AlwaysScrollableScrollPhysics(),
      child: Row(
        children: [
          for (final shortcut in shortcuts)
            Padding(
              key: ValueKey(shortcut),
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: Builder(
                builder: (buttonContext) => TextButton(
                  key: ValueKey('music-home-${shortcut.name}'),
                  onPressed: actions[shortcut],
                  onFocusChange: (focused) {
                    if (focused) Scrollable.ensureVisible(buttonContext);
                  },
                  style: style,
                  child: Text(shortcut.label(locals)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Local bookmarks refresh without a catalog call and never cross profiles.
class _SavedSongs extends StatelessWidget {
  final VoidCallback onLibrary;

  const _SavedSongs({required this.onLibrary});

  @override
  Widget build(BuildContext context) => BlocBuilder<AppCubit, AppState>(
        buildWhen: _sessionChanged,
        builder: (context, session) {
          if (!_sameSession(session, session) ||
              db.profileId != session.profileId) {
            return const SizedBox.shrink();
          }
          final library = MusicLibraryService.forProfile(db, session.profileId);
          Iterable<MusicLibraryEntry> preview() => library.entries
              .where((entry) => entry.kind == MusicLibraryKind.song)
              .take(12);
          return ListenableBuilder(
            listenable: library.changes,
            builder: (context, _) {
              final songs = preview().toList();
              final locals = AppLocalizations.of(context)!;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SectionHeading(
                    title: locals.musicSavedSongs,
                    action: IconButton(
                      key: const ValueKey('music-home-saved-library'),
                      tooltip: locals.musicBrowseLibrary,
                      onPressed: onLibrary,
                      icon: const Icon(Icons.arrow_forward_rounded),
                    ),
                  ),
                  if (songs.isEmpty)
                    Container(
                      key: const ValueKey('music-home-saved-empty'),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        color:
                            Theme.of(context).colorScheme.surfaceContainerLow,
                      ),
                      child: Row(children: [
                        Icon(Icons.favorite_border_rounded,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 12),
                        Expanded(child: Text(locals.musicHomeEmpty)),
                      ]),
                    )
                  else
                    _SavedSongRows(
                        songs: songs,
                        onOpen: (song) async {
                          if (!context.mounted ||
                              !_sameSession(
                                  session, context.read<AppCubit>().state)) {
                            return;
                          }
                          await _openSong(context, song.id,
                              preview().map((entry) => entry.toVideo()));
                        }),
                ],
              );
            },
          );
        },
      );
}

/// Four compact rows per lane keep the most recently saved music close at hand.
/// A nested horizontal list owns its drags instead of switching the Home tab.
class _SavedSongRows extends StatelessWidget {
  final List<MusicLibraryEntry> songs;
  final Future<void> Function(MusicLibraryEntry) onOpen;

  const _SavedSongRows({required this.songs, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    final title = textTheme.titleSmall!;
    final subtitle = textTheme.bodySmall!;
    final rowHeight = math.max(
        64.0,
        20 +
            (scaler.scale(title.fontSize!) * (title.height ?? 1.3))
                .ceilToDouble() +
            (scaler.scale(subtitle.fontSize!) * (subtitle.height ?? 1.3))
                .ceilToDouble());
    final rows = math.min(4, songs.length);
    return LayoutBuilder(builder: (context, constraints) {
      final laneWidth = math.min(
          420.0, constraints.maxWidth - (songs.length > rows ? 24 : 0));
      return SizedBox(
        height: rowHeight * rows,
        child: ListView.separated(
          key: const ValueKey('music-home-saved'),
          primary: false,
          scrollDirection: Axis.horizontal,
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: (songs.length / rows).ceil(),
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (context, lane) => SizedBox(
            width: laneWidth,
            child: Column(
              children: [
                for (final song in songs.skip(lane * rows).take(rows))
                  SizedBox(
                    height: rowHeight,
                    child: _SavedSongRow(
                      key: ValueKey('music-home-saved-${song.id}'),
                      song: song,
                      onOpen: () => onOpen(song),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

class _SavedSongRow extends StatelessWidget {
  final MusicLibraryEntry song;
  final Future<void> Function() onOpen;

  const _SavedSongRow({super.key, required this.song, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final covers = song.displayThumbnails;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onOpen,
        onLongPress: () => MusicLibraryActions.showSongMenu(
            context, song.toVideo(),
            onPlay: onOpen),
        borderRadius: BorderRadius.circular(12),
        onFocusChange: (focused) {
          if (focused) Scrollable.ensureVisible(context, alignment: 0.5);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: Row(
            children: [
              ExcludeSemantics(
                child: SizedBox.square(
                  dimension: 48,
                  child: CommunityMusicArtwork(
                      videoId: song.id,
                      music: song.toVideo().musicMetadata!,
                      durationSeconds: song.durationSeconds,
                      fallback: covers.isEmpty
                          ? DecoratedBox(
                              decoration: BoxDecoration(
                                color: colors.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Icon(Icons.music_note_rounded,
                                  color: colors.onSurfaceVariant),
                            )
                          : Thumbnail(
                              images: covers,
                              decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(6)),
                            )),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    if (song.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(song.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant)),
                    ],
                  ],
                ),
              ),
              MusicLibraryActions(videos: [song.toVideo()], onPlay: onOpen),
            ],
          ),
        ),
      ),
    );
  }
}

List<String> _savedArtistNames(MusicLibraryService library) {
  final artists = <String>[];
  final seen = <String>{};
  for (final entry in library.entries) {
    final artist = switch (entry.kind) {
      MusicLibraryKind.song => entry.subtitle.trim(),
      MusicLibraryKind.artist => entry.title.trim(),
      _ => '',
    };
    if (artist.isNotEmpty && seen.add(artist.toLowerCase())) {
      artists.add(artist);
      if (artists.length == 3) break;
    }
  }
  return artists;
}

/// Admission snapshot for a page-local selection. The song cache contains only
/// display metadata, never playback responses.
class _DiscoverySession {
  final AppState app;
  final IDbClient database;
  final SocksProxyConfig proxy;
  final String country;
  final String filters;

  _DiscoverySession(this.app)
      : database = db,
        proxy = NetworkProxy.instance.config,
        country = db.getSettings(browsingCountry)?.value ?? 'US',
        filters = jsonEncode([
          for (final filter in db.getAllFilters())
            [filter.uuid, filter.toJson()],
        ]);

  bool sameConnection(_DiscoverySession other) =>
      identical(database, other.database) &&
      !_sessionChanged(app, other.app) &&
      identical(proxy, other.proxy);

  bool matches(_DiscoverySession other) =>
      sameConnection(other) &&
      country == other.country &&
      filters == other.filters;

  bool get eligible =>
      app.server != null &&
      _sameSession(app, app) &&
      !NetworkProxy.instance.isChanging;
}

typedef _DiscoveryBatch = ({
  List<MusicTrack> songs,
  Map<String, String> reasons
});

class _DiscoverySongs extends StatefulWidget {
  final Widget Function(
      bool Function()? canDiscover, Widget freshShelves, Widget songs) builder;
  const _DiscoverySongs({required this.builder});

  @override
  State<_DiscoverySongs> createState() => _DiscoverySongsState();
}

class _DiscoverySongsState extends State<_DiscoverySongs>
    with WidgetsBindingObserver {
  _DiscoverySession? _session;
  final _batches = <String?, _DiscoveryBatch>{};
  final _failures = <String?>{};
  String? _artist;
  String? _loadingArtist;
  int _generation = 0;
  bool _loading = false;
  bool _paused = false;
  Timer? _cooldown;
  bool _visible = false;
  late bool _foreground;
  bool _showCommunityHidden = false;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    NetworkProxy.instance.addBeforeApply(_beforeProxyChange);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    setState(() {
      _foreground = foreground;
      if (!foreground) _cancelLoading();
    });
  }

  @override
  void dispose() {
    _generation++;
    _cooldown?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    NetworkProxy.instance.removeBeforeApply(_beforeProxyChange);
    super.dispose();
  }

  void _reset() {
    _generation++;
    _artist = null;
    _batches.clear();
    _failures.clear();
    _loading = false;
    _showCommunityHidden = false;
  }

  void _cancelLoading() {
    if (!_loading) return;
    _generation++;
    _loading = false;
  }

  void _clearPause() {
    _cooldown?.cancel();
    _cooldown = null;
    _paused = false;
  }

  void _pause(InvidiousServiceError error) {
    _paused = true;
    final delay = error.retryAfter;
    if (delay == null || delay <= Duration.zero) return;
    _cooldown?.cancel();
    _cooldown = Timer(delay, () {
      if (mounted) setState(() => _cooldown = null);
    });
  }

  Future<void> _beforeProxyChange() async {
    if (!mounted) return;
    setState(() {
      _clearPause();
      _reset();
      _session = null;
    });
  }

  bool _sameConnection(_DiscoverySession session) =>
      mounted &&
      session.eligible &&
      session.matches(_DiscoverySession(context.read<AppCubit>().state));

  bool get _pageVisible =>
      mounted &&
      _foreground &&
      TickerMode.of(context) &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  bool _current(_DiscoverySession session, String? artist) =>
      _pageVisible &&
      _sameConnection(session) &&
      (artist == null ||
          _savedArtistNames(MusicLibraryService.forProfile(
                  session.database, session.app.profileId))
              .contains(artist));

  Future<void> _load(_DiscoverySession session, String? artist) async {
    if (_loading || _paused || !_current(session, artist)) return;
    final generation = _generation;
    bool current() => generation == _generation && _current(session, artist);
    setState(() {
      _loadingArtist = artist;
      _loading = true;
      _failures.remove(artist);
    });
    try {
      final songs = await musicCatalogService.getDiscoverySongs(
          artist: artist,
          isCurrent: current,
          onInstanceFailure: (error) {
            if (current()) _pause(error);
          });
      if (!current()) return;
      final recommendations = RecommendationService.forProfile(
          session.database, session.app.profileId);
      final batch = await _rank(recommendations, songs);
      if (current()) _batches[artist] = batch;
    } catch (error) {
      if (current()) {
        _failures.add(artist);
        if (error is InvidiousServiceError && musicDiscoveryMustStop(error)) {
          _pause(error);
        }
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          if (!_sameConnection(session)) {
            _reset();
          }
        });
      }
    }
  }

  Future<_DiscoveryBatch> _rank(
      RecommendationService recommendations, List<MusicTrack> songs) async {
    final ranked = await recommendations.rankMusic(songs, surface: 'discover');
    return (
      songs: _rankedSelection(recommendations, songs, ranked),
      reasons: {
        if (ranked.available)
          for (final entry in ranked.items) entry.item.videoId: entry.reason,
      }
    );
  }

  List<MusicTrack> _rankedSelection(RecommendationService recommendations,
      List<MusicTrack> songs, RecommendationResult<MusicTrack> ranked) {
    // Keep loaded metadata for temporary community-filter reveal.
    // Such hidden entries do not enter the ranker or get an invented reason.
    // Personal exclusions and manual filters still remove them permanently.
    final admitted =
        recommendations.eligibleMusic(songs, includeCommunityHidden: true);
    if (!ranked.available) return admitted;
    final admittedIds = admitted.map((track) => track.videoId).toSet();
    final rankedIds = ranked.items.map((entry) => entry.item.videoId).toSet();
    return [
      ...ranked.items
          .map((entry) => entry.item)
          .where((track) => admittedIds.contains(track.videoId)),
      ...admitted.where((track) => !rankedIds.contains(track.videoId)),
    ];
  }

  Future<void> _feedback(
      _DiscoverySession session,
      String? artist,
      _DiscoveryBatch batch,
      MusicTrack song,
      RecommendationFeedback feedback) async {
    bool current() =>
        _current(session, artist) &&
        _artist == artist &&
        identical(_batches[artist]?.songs, batch.songs);
    if (!current()) return;
    final recommendations = RecommendationService.forProfile(
        session.database, session.app.profileId);
    try {
      await recommendations.feedback(
          song.toVideo(), RecommendationDomain.music, feedback);
      if (!current()) return;
      final ranked = await _rank(recommendations, batch.songs);
      if (current()) setState(() => _batches[artist] = ranked);
    } catch (_) {
      if (mounted && current()) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.recommendationError)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<SettingsCubit?>();
    final session = _DiscoverySession(context.watch<AppCubit>().state);
    if (_session?.matches(session) != true) {
      if (_session?.app.server != session.app.server ||
          !identical(_session?.proxy, session.proxy) ||
          _session?.app.profileId != session.app.profileId) {
        _clearPause();
      }
      _reset();
      _session = session;
    }
    final visible = _pageVisible;
    if (_visible && !visible) _cancelLoading();
    _visible = visible;
    final library = session.eligible
        ? MusicLibraryService.forProfile(
            session.database, session.app.profileId)
        : null;
    final recommendations = session.eligible
        ? RecommendationService.forProfile(
            session.database, session.app.profileId)
        : null;
    return ListenableBuilder(
      listenable: Listenable.merge([
        communityFilters.changes,
        library?.changes,
        recommendations?.changes
      ]),
      builder: (context, _) => library == null || recommendations == null
          ? widget.builder(
              null, const SizedBox.shrink(), const SizedBox.shrink())
          : _buildSelection(context, session, library, recommendations),
    );
  }

  Widget _buildSelection(BuildContext context, _DiscoverySession session,
      MusicLibraryService library, RecommendationService recommendations) {
    final seeds = <String?>[null, ..._savedArtistNames(library)];
    final savedSongs = {
      for (final entry in library.entries)
        if (entry.kind == MusicLibraryKind.song) entry.id,
    };
    _batches.removeWhere((seed, _) => !seeds.contains(seed));
    _failures.removeWhere((seed) => !seeds.contains(seed));
    if (_loading && !seeds.contains(_loadingArtist)) _cancelLoading();
    final pending = seeds.where(
        (seed) => !_batches.containsKey(seed) && !_failures.contains(seed));
    if (_visible && !_loading && !_paused && pending.isNotEmpty) {
      final next = pending.first;
      final generation = _generation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (generation == _generation &&
            !_batches.containsKey(next) &&
            !_failures.contains(next)) {
          _load(session, next);
        }
      });
    }
    final choices = {
      for (final seed in seeds)
        if (_batches[seed] case final batch?)
          seed: musicTrackResults(
              recommendations.eligibleMusic(
                  seed == null
                      ? batch.songs
                      : batch.songs
                          .where((song) => !savedSongs.contains(song.videoId)),
                  includeCommunityHidden: true),
              showHidden: _showCommunityHidden),
    };
    final ready = choices.keys
        .where((seed) => choices[seed]!.visible.isNotEmpty)
        .toList();
    if (!ready.contains(_artist)) _artist = ready.firstOrNull;
    final artist = _artist;
    final batch = _batches[artist];
    final results = choices[artist];
    final songs = results?.visible ?? const <MusicTrackResult>[];
    final hidden = choices.values.fold(0, (sum, result) => sum + result.hidden);
    final locals = AppLocalizations.of(context)!;
    final refreshing = _loading && _loadingArtist == artist;
    final failed = _failures.contains(artist);
    final missing = _failures
        .where((seed) => _batches[seed]?.songs.isNotEmpty != true)
        .toList();
    List<MusicTrack> playable(String? seed, Iterable<MusicTrack> tracks) =>
        recommendations.eligibleMusic(
            seed == null
                ? tracks
                : tracks.where((song) =>
                    !library.contains(MusicLibraryKind.song, song.videoId)),
            includeCommunityHidden: _showCommunityHidden);
    bool readyNow(String? seed) {
      final saved = _batches[seed];
      return saved != null &&
          _current(session, seed) &&
          playable(seed, saved.songs).isNotEmpty;
    }

    return widget.builder(
        ready.isEmpty ? null : () => ready.any(readyNow),
        _FreshSelection(
          session: session,
          artists: [
            for (final entry in library.entries
                .where((entry) => entry.kind == MusicLibraryKind.artist)
                .take(3))
              entry.id,
          ],
        ),
        Column(
          key: const ValueKey('music-discovery'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SectionHeading(
              title: locals.musicDiscover,
              action: songs.isNotEmpty
                  ? IconButton(
                      key: const ValueKey('music-discovery-refresh'),
                      tooltip: locals.refresh,
                      onPressed: _loading || _paused
                          ? null
                          : () => _load(session, artist),
                      icon: const Icon(Icons.refresh_rounded),
                    )
                  : null,
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(locals.musicDiscoverHint,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
            if (ready.any((seed) => seed != null)) ...[
              Text(locals.musicDiscoverByArtist),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final seed in ready)
                      ChoiceChip(
                        label: Text(seed ?? locals.musicDiscoverAllMusic,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        selected: seed == artist,
                        onSelected: (selected) {
                          if (selected && seed != artist && readyNow(seed)) {
                            setState(() => _artist = seed);
                          }
                        },
                      ),
                  ],
                ),
              ),
            ],
            if (_loading && (ready.isEmpty || refreshing))
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(locals.musicDiscoverLoading),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      key: const ValueKey('music-discovery-loading'),
                      semanticsLabel: locals.musicDiscoverLoading,
                    ),
                  ],
                ),
              ),
            if (missing.isNotEmpty || failed || _paused)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  failed && songs.isNotEmpty
                      ? locals.musicDiscoverRefreshFailed
                      : locals.musicLoadError,
                  key: const ValueKey('music-discovery-failure'),
                ),
              ),
            if (hidden > 0)
              CommunityHiddenNotice(
                count: hidden,
                showing: _showCommunityHidden,
                onToggle: () => setState(
                    () => _showCommunityHidden = !_showCommunityHidden),
              ),
            if (batch != null && songs.isNotEmpty)
              MusicCatalogShelf(
                key: const ValueKey('music-discovery-songs'),
                itemCount: songs.length,
                itemBuilder: (context, index) {
                  final (song, matches) = songs[index];
                  final reason = batch.reasons[song.videoId];
                  // Opening a menu can cancel a pending refresh. Its actions still
                  // belong to this displayed list until the selection changes.
                  bool currentSong() =>
                      _artist == artist &&
                      identical(_batches[artist]?.songs, batch.songs) &&
                      _current(session, artist) &&
                      playable(artist, [song]).isNotEmpty;
                  Future<void> open() async {
                    if (context.mounted && currentSong()) {
                      await _openSong(
                          context,
                          song.videoId,
                          playable(artist, batch.songs)
                              .map((track) => track.toVideo()));
                    }
                  }

                  final recommendation = reason == null
                      ? null
                      : MusicSongRecommendation(
                          reason: reason,
                          isCurrent: currentSong,
                          onFeedback: (feedback) => _feedback(
                              session, artist, batch, song, feedback));
                  return MusicCatalogCard(
                    key: ValueKey('music-discovery-${song.videoId}'),
                    title: song.title,
                    subtitle: song.artists.join(', '),
                    song: song,
                    showPlayIndicator: true,
                    badge: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (matches.isNotEmpty)
                        Flexible(
                            child: CommunityMatchLabels(
                                matches: matches, compact: true)),
                      MusicLibraryActions(
                          videos: [song.toVideo()],
                          onPlay: open,
                          recommendation: recommendation),
                    ]),
                    onLongPress: () => MusicLibraryActions.showSongMenu(
                        context, song.toVideo(),
                        onPlay: open, recommendation: recommendation),
                    onOpen: open,
                  );
                },
              )
            else if (pending.isEmpty &&
                !_loading &&
                missing.isEmpty &&
                hidden == 0)
              Text(locals.musicDiscoverEmpty,
                  key: const ValueKey('music-discovery-empty')),
            if (missing.isNotEmpty || _paused)
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  key: const ValueKey('music-discovery-retry'),
                  onPressed: _loading || _cooldown != null
                      ? null
                      : () {
                          if (!_sameConnection(session) || !_pageVisible) {
                            return;
                          }
                          final refreshPartial =
                              _paused && pending.isEmpty && missing.isEmpty;
                          setState(() {
                            _clearPause();
                            for (final seed in missing) {
                              _failures.remove(seed);
                              _batches.remove(seed);
                            }
                          });
                          if (refreshPartial) _load(session, artist);
                        },
                  icon: const Icon(Icons.refresh),
                  label: Text(locals.retry),
                ),
              ),
          ],
        ));
  }
}

class _MusicExplore extends StatefulWidget {
  const _MusicExplore();

  @override
  State<_MusicExplore> createState() => _MusicExploreState();
}

class _MusicExploreState extends State<_MusicExplore>
    with WidgetsBindingObserver {
  // A null result can be retried on a later visit. An empty verified selection
  // stays hidden without repeating the same search.
  final _recordings = <String, List<MusicTrack>?>{};
  _DiscoverySession? _session;
  DateTime? _retryAfter;
  late bool _foreground;
  bool _active = false;
  bool _preparing = false;
  int _visit = 0;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    NetworkProxy.instance.addBeforeApply(_proxyChanging);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    setState(() {
      _foreground = foreground;
      _visit++;
    });
  }

  Future<void> _proxyChanging() async {
    if (mounted) setState(() => _session = null);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NetworkProxy.instance.removeBeforeApply(_proxyChanging);
    super.dispose();
  }

  bool get _visible =>
      mounted &&
      _foreground &&
      TickerMode.of(context) &&
      (ModalRoute.isCurrentOf(context) ?? true);

  bool _same(_DiscoverySession session) =>
      mounted &&
      identical(session, _session) &&
      session.eligible &&
      session.matches(_DiscoverySession(context.read<AppCubit>().state));

  void _prepare(_DiscoverySession session) {
    if (!_active ||
        _preparing ||
        _retryAfter?.isAfter(DateTime.now()) == true) {
      return;
    }
    final genre = musicExploreGenres
        .where((genre) => !_recordings.containsKey(genre))
        .firstOrNull;
    if (genre == null) return;
    final visit = _visit;
    bool current() => visit == _visit && _same(session) && _visible;
    void stopBatch(InvidiousServiceError error) {
      if (!current() || !musicDiscoveryMustStop(error)) return;
      if (error.retryAfter case final delay? when delay > Duration.zero) {
        _retryAfter = DateTime.now().add(delay);
      }
      for (final remaining in musicExploreGenres) {
        _recordings.putIfAbsent(remaining, () => null);
      }
    }

    _preparing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!current()) return;
        final songs = await musicCatalogService.getGenreSongs(genre,
            isCurrent: current, onInstanceFailure: stopBatch);
        if (current()) _recordings[genre] = songs;
      } catch (error) {
        if (!current()) return;
        _recordings[genre] = null;
        if (error is InvidiousServiceError) stopBatch(error);
      } finally {
        _preparing = false;
        if (mounted) setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    context.watch<SettingsCubit?>();
    final snapshot = _DiscoverySession(context.watch<AppCubit>().state);
    if (_session?.matches(snapshot) != true) {
      _visit++;
      _session = snapshot;
      _recordings.clear();
      _retryAfter = null;
    }
    final session = _session!;
    final active = session.eligible && _visible;
    if (active != _active) {
      _visit++;
      _active = active;
      if (active && _retryAfter?.isAfter(DateTime.now()) != true) {
        _recordings.removeWhere((_, tracks) => tracks == null);
      }
    }
    if (!session.eligible) return const SizedBox.shrink();
    _prepare(session);
    final recommendations = RecommendationService.forProfile(
        session.database, session.app.profileId);
    return ListenableBuilder(
        listenable: Listenable.merge(
            [communityFilters.changes, recommendations.changes]),
        builder: (context, _) => _tiles(context, session, recommendations));
  }

  Widget _tiles(BuildContext context, _DiscoverySession session,
      RecommendationService recommendations) {
    final locals = AppLocalizations.of(context)!;
    final labels = [
      locals.musicGenrePop,
      locals.musicGenreJazz,
      locals.musicGenreClassical,
      locals.musicGenreElectronic,
    ];
    final ready = [
      for (final (index, genre) in musicExploreGenres.indexed)
        if (_recordings[genre] case final recordings?)
          if (recommendations.eligibleMusic(recordings) case final tracks
              when tracks.isNotEmpty)
            (index: index, tracks: tracks),
    ];
    if (ready.isEmpty) return const SizedBox.shrink();
    final token = recommendations.generation(RecommendationDomain.music);
    bool current() =>
        _same(session) &&
        token == recommendations.generation(RecommendationDomain.music);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _SectionHeading(title: locals.musicExplore),
      LayoutBuilder(builder: (context, constraints) {
        final columns = constraints.maxWidth >= 760 ? 4 : 2;
        const gap = 12.0;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final (:index, :tracks) in ready)
              Builder(
                  builder: (tileContext) => SizedBox(
                        width: width,
                        child: Material(
                          color: colors.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(6),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            key: ValueKey('music-explore-$index'),
                            onFocusChange: (focused) {
                              if (focused) {
                                Scrollable.ensureVisible(tileContext,
                                    alignment: 0.5);
                              }
                            },
                            onTap: () {
                              if (!current() ||
                                  !_visible ||
                                  recommendations
                                      .eligibleMusic(tracks)
                                      .isEmpty) {
                                return;
                              }
                              Navigator.of(context).push<void>(
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          MusicRecommendationCollection(
                                              title: labels[index],
                                              tracks: tracks,
                                              isCurrent: current,
                                              eligible:
                                                  recommendations.eligibleMusic,
                                              changes: Listenable.merge([
                                                communityFilters.changes,
                                                recommendations.changes,
                                              ]))));
                            },
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 48),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                                child: Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: Text(labels[index],
                                      style: theme.textTheme.titleSmall),
                                ),
                              ),
                            ),
                          ),
                        ),
                      )),
          ],
        );
      }),
    ]);
  }
}

Future<void> _openSong(
    BuildContext context, String videoId, Iterable<Video> songs) async {
  final queue = songs.toList(growable: false);
  final index = queue.indexWhere((video) => video.videoId == videoId);
  if (index < 0) return;
  await context.router.push(MusicRoute(
      videoId: videoId,
      artistCredits: queue[index].musicMetadata?.artistCredits ?? const [],
      queue: queue,
      startIndex: index));
}

class _DiscoveryScroll extends StatelessWidget {
  final String storageKey;
  final ScrollController controller;
  final List<Widget> children;

  const _DiscoveryScroll(
      {required this.storageKey,
      required this.controller,
      required this.children});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1440),
        child: SingleChildScrollView(
          key: PageStorageKey(storageKey),
          controller: controller,
          primary: false,
          padding: EdgeInsets.fromLTRB(
              MediaQuery.sizeOf(context).width < 600 ? 12 : 24,
              8,
              MediaQuery.sizeOf(context).width < 600 ? 12 : 24,
              32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  final String title;
  final Widget? action;
  const _SectionHeading({required this.title, this.action});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 12),
        child: Row(
          children: [
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
          ],
        ),
      );
}

bool _sessionChanged(AppState before, AppState after) =>
    before.profileId != after.profileId ||
    before.sessionRevision != after.sessionRevision ||
    before.server != after.server ||
    before.globalLoading != after.globalLoading ||
    before.sessionRecoveryRequired != after.sessionRecoveryRequired;

bool _sameSession(AppState initial, AppState current) =>
    !current.globalLoading &&
    !current.sessionRecoveryRequired &&
    initial.profileId == db.profileId &&
    initial.profileId == current.profileId &&
    initial.sessionRevision == current.sessionRevision &&
    initial.server == current.server;

class _FreshSelection extends StatefulWidget {
  final _DiscoverySession session;
  final List<String> artists;

  const _FreshSelection({required this.session, required this.artists});

  @override
  State<_FreshSelection> createState() => _FreshSelectionState();
}

class _FreshSelectionState extends State<_FreshSelection>
    with WidgetsBindingObserver {
  static const _shelfSize = 6;
  final _releases = <String, List<MusicCollection>>{};
  final _recentTracks = <String>{};
  List<MusicTrack> _chartTracks = const [];
  bool _scheduled = false;
  bool _loading = false;
  bool _prepared = false;
  bool _chartPrepared = false;
  bool _failed = false;
  int _generation = 0;
  Timer? _cooldown;
  late bool _foreground;

  bool get _visible =>
      mounted &&
      _foreground &&
      TickerMode.of(context) &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(_FreshSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.session.matches(oldWidget.session)) {
      _cancel();
      _releases.clear();
      _recentTracks.clear();
      _chartTracks = const [];
      _chartPrepared = false;
      _failed = false;
      if (!widget.session.sameConnection(oldWidget.session)) {
        _cooldown?.cancel();
        _cooldown = null;
      }
    } else if (!listEquals(widget.artists, oldWidget.artists)) {
      _cancel();
      _releases.removeWhere((id, _) => !widget.artists.contains(id));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    setState(() {
      _foreground = foreground;
      if (!foreground && _loading) _cancel();
    });
  }

  @override
  void dispose() {
    _cooldown?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _cancel() {
    _generation++;
    _scheduled = false;
    _loading = false;
    _prepared = false;
  }

  bool _current(_DiscoverySession session) =>
      _visible &&
      session.eligible &&
      session.matches(_DiscoverySession(context.read<AppCubit>().state));

  void _chooseChartTracks(List<MusicTrack> tracks) {
    final unique = <String, MusicTrack>{};
    for (final track in tracks) {
      unique.putIfAbsent(track.videoId, () => track);
    }
    _chartTracks = [
      ...unique.keys.where((id) => !_recentTracks.contains(id)),
      ..._recentTracks.where(unique.containsKey),
    ].map((id) => unique[id]!).toList();
  }

  void _rememberChartTracks(List<MusicTrack> tracks) {
    for (final track in tracks) {
      _recentTracks
        ..remove(track.videoId)
        ..add(track.videoId);
    }
    while (_recentTracks.length > _shelfSize * 3) {
      _recentTracks.remove(_recentTracks.first);
    }
  }

  Future<void> _load(MusicChart chart, {bool refresh = false}) async {
    final session = widget.session;
    final generation = _generation;
    final artists = widget.artists;
    bool current() => generation == _generation && _current(session);
    if (_loading || _cooldown != null || !current()) return;
    setState(() {
      _loading = true;
      _failed = false;
    });

    Future<bool> tryLoad(Future<void> Function() load) async {
      try {
        await load();
      } on MusicCatalogUnsupported {
        return current();
      } catch (error) {
        if (!current()) return false;
        _failed = true;
        if (error is InvidiousServiceError && musicDiscoveryMustStop(error)) {
          final delay = error.retryAfter;
          if (delay != null && delay > Duration.zero) {
            _cooldown?.cancel();
            _cooldown = Timer(delay, () {
              if (mounted) setState(() => _cooldown = null);
            });
          }
          return false;
        }
      }
      return current();
    }

    try {
      if (refresh || !_chartPrepared) {
        final proceed = await tryLoad(() async {
          final tracks = await musicCatalogService
              .getChartSongs(chart.playlistId, isCurrent: current);
          if (current()) setState(() => _chooseChartTracks(tracks));
        });
        if (!proceed) return;
        _chartPrepared = true;
      }
      for (final id in artists) {
        if (!refresh && _releases.containsKey(id)) continue;
        final proceed = await tryLoad(() async {
          final page = await musicCatalogService.getArtistReleases(id,
              isCurrent: current);
          if (current()) {
            setState(
                () => _releases[id] = page.releases.take(_shelfSize).toList());
          }
        });
        if (!proceed) return;
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          // A hidden Home can retry incomplete work when it becomes visible.
          _prepared = current();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final chart = musicCharts
            .where((chart) => chart.countryCode == session.country)
            .firstOrNull ??
        musicCharts.first;
    final visible = _visible;
    if (!visible && _loading) _cancel();
    if (visible &&
        !_prepared &&
        !_scheduled &&
        !_loading &&
        _cooldown == null) {
      _scheduled = true;
      final generation = _generation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _generation) return;
        _scheduled = false;
        _load(chart);
      });
    }
    final releaseIds = <String>{};
    final releases = [
      for (var index = 0; index < _shelfSize; index++)
        for (final id in widget.artists)
          if (_releases[id]?.elementAtOrNull(index) case final release?
              when releaseIds.add(release.id))
            release,
    ].take(_shelfSize).toList();
    final recommendations = RecommendationService.forProfile(
        session.database, session.app.profileId);
    // Refill the shelf from its fetched rows when filtering changes.
    final tracks =
        recommendations.eligibleMusic(_chartTracks).take(_shelfSize).toList();
    if (visible) _rememberChartTracks(tracks);
    final locals = AppLocalizations.of(context)!;
    final refreshSelection = _loading || _cooldown != null
        ? null
        : () => _load(chart, refresh: true);
    if (releases.isEmpty && tracks.isEmpty) {
      if (!_failed && !(_prepared && _loading)) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_loading ? locals.musicDiscoverLoading : locals.musicLoadError),
          TextButton(
            key: const ValueKey('music-home-fresh-retry'),
            onPressed: refreshSelection,
            child: Text(locals.retry),
          ),
        ],
      );
    }

    bool current() => _current(session);
    final refresh = IconButton(
      key: const ValueKey('music-home-fresh-refresh'),
      tooltip: locals.refresh,
      onPressed: refreshSelection,
      icon: const Icon(Icons.refresh_rounded),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (releases.isNotEmpty) ...[
          _SectionHeading(
              title: locals.musicSavedArtistReleases,
              action: tracks.isEmpty ? refresh : null),
          MusicCatalogShelf(
            key: const ValueKey('music-home-releases'),
            itemCount: releases.length,
            itemBuilder: (context, index) {
              final release = releases[index];
              return MusicCatalogCard(
                title: release.title,
                subtitle: release.artists.join(', '),
                thumbnails: release.thumbnails,
                onOpen: () {
                  if (current() &&
                      _releases.values
                          .any((items) => items.contains(release))) {
                    context.router.push(MusicRoute(playlistId: release.id));
                  }
                },
              );
            },
          ),
        ],
        if (tracks.isNotEmpty) ...[
          _SectionHeading(
              title: chart.countryCode == null
                  ? locals.musicWorldwideChart
                  : locals.musicRegionalChart,
              action: refresh),
          MusicCatalogShelf(
            key: const ValueKey('music-home-chart'),
            itemCount: tracks.length,
            itemBuilder: (context, index) {
              final track = tracks[index];
              return MusicCatalogCard(
                title: track.title,
                subtitle: track.artists.join(', '),
                song: track,
                showPlayIndicator: true,
                onOpen: () {
                  if (!current()) return;
                  final playable = recommendations.eligibleMusic(tracks);
                  _openSong(context, track.videoId,
                      playable.map((track) => track.toVideo()));
                },
              );
            },
          ),
        ],
        if (_failed && !_loading) Text(locals.musicDiscoverRefreshFailed),
      ],
    );
  }
}
