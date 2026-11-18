import 'dart:convert';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/content_filter/community_filter_widgets.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/views/components/music_catalog_cards.dart';
import 'package:clipious/music/views/components/community_music_artwork.dart';
import 'package:clipious/music/views/components/music_chart_picker.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/components/music_recommendation_shelves.dart';
import 'package:clipious/music/views/components/music_track_results.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/recommendations/views/recommendation_settings.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
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
    final locals = AppLocalizations.of(context)!;
    return _DiscoveryScroll(
      storageKey: 'music-home',
      controller: _scroll,
      children: [
        _MusicHomeShortcuts(
          onSearch: widget.showSearchShortcut ? widget.onSearch : null,
          onLibrary: widget.onLibrary,
          onDiscover: _showDiscovery,
        ),
        const MusicRecommendationShelves(),
        _SavedSongs(onLibrary: widget.onLibrary),
        const _SavedMusicSuggestions(),
        _SectionHeading(title: locals.musicExplore),
        const _MusicExplore(),
        _DiscoverySongs(key: _discovery),
      ],
    );
  }
}

class _MusicHomeShortcuts extends StatelessWidget {
  final VoidCallback? onSearch;
  final VoidCallback onLibrary;
  final VoidCallback onDiscover;

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
    final shortcuts = <(String, String, VoidCallback)>[
      if (onSearch case final search?) ('search', locals.search, search),
      ('library', locals.musicLibrary, onLibrary),
      ('charts', locals.musicTopCharts, () => _openCharts(context)),
      ('discover', locals.musicDiscover, onDiscover),
      (
        'recommendations',
        locals.localRecommendations,
        () => showRecommendationSettings(context)
      ),
    ];
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
          for (final (id, label, action) in shortcuts)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: Builder(
                builder: (buttonContext) => TextButton(
                  key: ValueKey('music-home-$id'),
                  onPressed: action,
                  onFocusChange: (focused) {
                    if (focused) Scrollable.ensureVisible(buttonContext);
                  },
                  style: style,
                  child: Text(label),
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
          return ListenableBuilder(
            listenable: library.changes,
            builder: (context, _) {
              final songs = library.entries
                  .where((entry) => entry.kind == MusicLibraryKind.song)
                  .take(12)
                  .toList();
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
                    _SavedSongRows(songs: songs, session: session),
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
  final AppState session;

  const _SavedSongRows({required this.songs, required this.session});

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
                      onOpen: () => _openSong(
                          context, session, song.id, song.artistCredits),
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
  final VoidCallback onOpen;

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
        onLongPress: () =>
            MusicLibraryActions.showSongMenu(context, song.toVideo()),
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
              MusicLibraryActions(videos: [song.toVideo()]),
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

/// Suggestions come only from this profile's saved music. Choosing one opens
/// an ordinary Invidious search; merely showing Home makes no catalog request.
class _SavedMusicSuggestions extends StatelessWidget {
  const _SavedMusicSuggestions();

  @override
  Widget build(BuildContext context) => BlocBuilder<AppCubit, AppState>(
        buildWhen: _sessionChanged,
        builder: (context, session) {
          if (!_sameSession(session, session)) return const SizedBox.shrink();
          final library = MusicLibraryService.forProfile(db, session.profileId);
          return ListenableBuilder(
            listenable: library.changes,
            builder: (context, _) {
              final artists = _savedArtistNames(library);
              if (artists.isEmpty) return const SizedBox.shrink();
              return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SectionHeading(
                        title: AppLocalizations.of(context)!
                            .musicSearchSuggestions),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (var index = 0; index < artists.length; index++)
                          ActionChip(
                            key: ValueKey('music-suggestion-$index'),
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHigh,
                            side: BorderSide.none,
                            shape: const StadiumBorder(),
                            label: Text(artists[index],
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            onPressed: () {
                              if (_sameSession(
                                  session, context.read<AppCubit>().state)) {
                                context.router.push(MusicRoute(
                                    initialQuery: '${artists[index]} music'));
                              }
                            },
                          ),
                      ],
                    ),
                  ]);
            },
          );
        },
      );
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

  bool matches(_DiscoverySession other) =>
      identical(database, other.database) &&
      !_sessionChanged(app, other.app) &&
      identical(proxy, other.proxy) &&
      country == other.country &&
      filters == other.filters;

  bool get eligible =>
      app.server != null &&
      _sameSession(app, app) &&
      !NetworkProxy.instance.isChanging;
}

class _DiscoverySongs extends StatefulWidget {
  const _DiscoverySongs({super.key});

  @override
  State<_DiscoverySongs> createState() => _DiscoverySongsState();
}

class _DiscoverySongsState extends State<_DiscoverySongs> {
  _DiscoverySession? _session;
  String? _artist;
  List<MusicTrack> _songs = const [];
  Map<String, String> _reasons = const {};
  int _generation = 0;
  bool _attempted = false;
  bool _loading = false;
  bool _failed = false;
  bool _visible = false;
  bool _showCommunityHidden = false;

  @override
  void initState() {
    super.initState();
    NetworkProxy.instance.addBeforeApply(_beforeProxyChange);
  }

  @override
  void dispose() {
    _generation++;
    NetworkProxy.instance.removeBeforeApply(_beforeProxyChange);
    super.dispose();
  }

  void _reset() {
    _generation++;
    _artist = null;
    _songs = const [];
    _reasons = const {};
    _attempted = false;
    _loading = false;
    _failed = false;
    _showCommunityHidden = false;
  }

  Future<void> _beforeProxyChange() async {
    if (!mounted) return;
    setState(() {
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
      TickerMode.of(context) &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  bool _current(int generation, _DiscoverySession session) =>
      generation == _generation && _sameConnection(session) && _pageVisible;

  Future<void> _load(_DiscoverySession session, String? artist) async {
    if (_loading || !_current(_generation, session)) return;
    if (artist != null &&
        !_savedArtistNames(MusicLibraryService.forProfile(
                session.database, session.app.profileId))
            .contains(artist)) {
      return;
    }
    if (_session?.matches(session) != true || _artist != artist) _reset();
    _session = session;
    _artist = artist;
    final generation = ++_generation;
    setState(() {
      _attempted = true;
      _loading = true;
      _failed = false;
    });
    try {
      final songs = await musicCatalogService.getDiscoverySongs(
          artist: artist, isCurrent: () => _current(generation, session));
      if (!_current(generation, session)) return;
      final recommendations = RecommendationService.forProfile(
          session.database, session.app.profileId);
      final ranked =
          await recommendations.rankMusic(songs, surface: 'discover');
      if (_current(generation, session)) {
        setState(() {
          _songs = _rankedSelection(recommendations, songs, ranked);
          _reasons = {
            if (ranked.available)
              for (final entry in ranked.items)
                entry.item.videoId: entry.reason,
          };
        });
      }
    } catch (_) {
      if (_current(generation, session)) {
        setState(() => _failed = true);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          // A country/proxy change can precede its UI notification. Never keep
          // the old selection or let an abandoned request leave a spinner.
          if (!_sameConnection(session)) {
            _reset();
            _session = null;
          } else if (!_pageVisible) {
            _attempted = _songs.isNotEmpty;
            _failed = false;
          }
        });
      }
    }
  }

  List<MusicTrack> _rankedSelection(RecommendationService recommendations,
      List<MusicTrack> songs, RecommendationResult<MusicTrack> ranked) {
    // Keep explicitly loaded metadata for temporary community-filter reveal.
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

  Future<void> _feedback(int generation, _DiscoverySession session,
      MusicTrack song, RecommendationFeedback feedback) async {
    if (!_current(generation, session)) return;
    final recommendations = RecommendationService.forProfile(
        session.database, session.app.profileId);
    try {
      await recommendations.feedback(
          song.toVideo(), RecommendationDomain.music, feedback);
      if (!_current(generation, session)) return;
      final ranked =
          await recommendations.rankMusic(_songs, surface: 'discover');
      if (!_current(generation, session)) return;
      setState(() {
        _songs = _rankedSelection(recommendations, _songs, ranked);
        _reasons = {
          if (ranked.available)
            for (final entry in ranked.items) entry.item.videoId: entry.reason,
        };
      });
    } catch (_) {
      if (mounted && _current(generation, session)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.recommendationError)));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: communityFilters.changes,
        builder: (context, _) => _buildDiscovery(context),
      );

  Widget _buildDiscovery(BuildContext context) {
    // The optional dependency also invalidates on country changes while Home
    // remains mounted under the settings route. Small isolated hosts need only
    // AppCubit; the source of truth for the snapshot is still the database.
    context.watch<SettingsCubit?>();
    final session = _DiscoverySession(context.watch<AppCubit>().state);
    final visible = _pageVisible;
    if (_session?.matches(session) != true) {
      _reset();
      _session = session;
    }
    if (_visible && !visible && _loading) {
      // Cancel the rest of the bounded batch, but retain display metadata that
      // was loaded successfully before this request. Loading or refreshing
      // always needs another explicit action, including after reopening Home.
      _generation++;
      _loading = false;
      _attempted = _songs.isNotEmpty;
      _failed = false;
    }
    _visible = visible;
    if (!session.eligible) return const SizedBox.shrink();
    final library =
        MusicLibraryService.forProfile(session.database, session.app.profileId);
    final recommendations = RecommendationService.forProfile(
        session.database, session.app.profileId);
    return ListenableBuilder(
      listenable: library.changes,
      builder: (context, _) => ListenableBuilder(
        listenable: recommendations.changes,
        builder: (context, _) =>
            _buildSelection(context, session, _savedArtistNames(library)),
      ),
    );
  }

  Widget _buildSelection(
      BuildContext context, _DiscoverySession session, List<String> artists) {
    if (_artist != null && !artists.contains(_artist)) _reset();
    final artist = _artist;
    final selection = _songs;
    final locals = AppLocalizations.of(context)!;
    final recommendations = RecommendationService.forProfile(
        session.database, session.app.profileId);
    final admitted =
        recommendations.eligibleMusic(_songs, includeCommunityHidden: true);
    final results =
        musicTrackResults(admitted, showHidden: _showCommunityHidden);
    return Column(
      key: const ValueKey('music-discovery'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeading(
          title: locals.musicDiscover,
          action: _attempted
              ? IconButton(
                  key: const ValueKey('music-discovery-refresh'),
                  tooltip: locals.refresh,
                  onPressed: _loading ? null : () => _load(session, artist),
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
        if (artists.isNotEmpty) ...[
          Text(locals.musicDiscoverByArtist),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final seed in <String?>[null, ...artists])
                  ChoiceChip(
                    label: Text(seed ?? locals.musicDiscoverAllMusic,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    selected: seed == artist,
                    onSelected: _loading
                        ? null
                        : (selected) {
                            if (selected) _load(session, seed);
                          },
                  ),
              ],
            ),
          ),
        ],
        if (_loading)
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
        if (_failed)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _songs.isEmpty
                  ? locals.musicLoadError
                  : locals.musicDiscoverRefreshFailed,
              key: const ValueKey('music-discovery-failure'),
            ),
          ),
        if (results.hidden > 0)
          CommunityHiddenNotice(
            count: results.hidden,
            showing: _showCommunityHidden,
            onToggle: () =>
                setState(() => _showCommunityHidden = !_showCommunityHidden),
          ),
        if (results.visible.isNotEmpty)
          MusicCatalogShelf(
            key: const ValueKey('music-discovery-songs'),
            itemCount: results.visible.length,
            itemBuilder: (context, index) {
              final (song, matches) = results.visible[index];
              final reason = _reasons[song.videoId];
              // Opening a menu can cancel a pending refresh. Its actions still
              // belong to this displayed list until the selection changes.
              bool currentSong() =>
                  identical(_songs, selection) &&
                  _sameConnection(session) &&
                  _pageVisible &&
                  recommendations.eligibleMusic([song],
                      includeCommunityHidden: _showCommunityHidden).isNotEmpty;
              final recommendation = reason == null
                  ? null
                  : MusicSongRecommendation(
                      reason: reason,
                      isCurrent: currentSong,
                      onFeedback: (feedback) =>
                          _feedback(_generation, session, song, feedback));
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
                      videos: [song.toVideo()], recommendation: recommendation),
                ]),
                onLongPress: () => MusicLibraryActions.showSongMenu(
                    context, song.toVideo(),
                    recommendation: recommendation),
                onOpen: () {
                  if (currentSong()) {
                    _openSong(
                        context, session.app, song.videoId, song.artistCredits);
                  }
                },
              );
            },
          )
        else if (!_loading && results.hidden == 0) ...[
          if (!_attempted || !_failed)
            Text(
                _attempted
                    ? locals.musicDiscoverEmpty
                    : locals.musicDiscoverManualHint,
                key: const ValueKey('music-discovery-empty')),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              key: const ValueKey('music-discovery-load'),
              onPressed: () => _load(session, artist),
              icon: Icon(_attempted ? Icons.refresh : Icons.explore_outlined),
              label: Text(_attempted ? locals.retry : locals.musicDiscoverLoad),
            ),
          ),
        ],
      ],
    );
  }
}

/// These are search shortcuts, not curated albums or a separate music API.
class _MusicExplore extends StatelessWidget {
  const _MusicExplore();

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final session = context.watch<AppCubit>().state;
    final genres = [
      (locals.musicGenrePop, 'pop music'),
      (locals.musicGenreJazz, 'jazz music'),
      (locals.musicGenreClassical, 'classical music'),
      (locals.musicGenreElectronic, 'electronic music'),
    ];
    return LayoutBuilder(builder: (context, constraints) {
      final columns = constraints.maxWidth >= 760 ? 4 : 2;
      const gap = 12.0;
      final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (var index = 0; index < genres.length; index++)
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
                            if (_sameSession(
                                session, context.read<AppCubit>().state)) {
                              context.router.push(
                                  MusicRoute(initialQuery: genres[index].$2));
                            }
                          },
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 48),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              child: Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: Text(genres[index].$1,
                                    style: theme.textTheme.titleSmall),
                              ),
                            ),
                          ),
                        ),
                      ),
                    )),
        ],
      );
    });
  }
}

void _openSong(BuildContext context, AppState session, String videoId,
    List<MusicArtistCredit> artistCredits) {
  if (_sameSession(session, context.read<AppCubit>().state)) {
    context.router
        .push(MusicRoute(videoId: videoId, artistCredits: artistCredits));
  }
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
