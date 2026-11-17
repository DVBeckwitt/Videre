import 'dart:convert';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/content_filter/community_filter_widgets.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/views/components/music_catalog_cards.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/components/music_track_results.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
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

  const MusicHomePage(
      {super.key, required this.onSearch, required this.onLibrary});

  @override
  State<MusicHomePage> createState() => _MusicHomePageState();
}

/// Local bookmarks and a bounded, category-checked Invidious selection. The
/// upstream trending endpoint no longer provides a Music category.
class _MusicHomePageState extends State<MusicHomePage> {
  final _scroll = ScrollController();

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
        _MusicWelcome(onSearch: widget.onSearch, onLibrary: widget.onLibrary),
        _SavedSongs(onLibrary: widget.onLibrary),
        _SectionHeading(title: locals.musicSearchSuggestions),
        const _SavedMusicSuggestions(),
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(locals.musicExploreHint,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
        const _MusicExplore(),
        const _DiscoverySongs(),
      ],
    );
  }
}

class _MusicWelcome extends StatelessWidget {
  final VoidCallback onSearch;
  final VoidCallback onLibrary;

  const _MusicWelcome({required this.onSearch, required this.onLibrary});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final locals = AppLocalizations.of(context)!;
    return Column(
      key: const ValueKey('music-home-welcome'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(locals.music,
              style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700, color: colors.onSurface)),
        ),
        const SizedBox(height: 4),
        Text(locals.musicHomeSubtitle,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant)),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              key: const ValueKey('music-home-search'),
              onPressed: onSearch,
              icon: const Icon(Icons.search_rounded),
              label: Text(locals.search),
            ),
            FilledButton.tonalIcon(
              key: const ValueKey('music-home-library'),
              onPressed: onLibrary,
              icon: const Icon(Icons.library_music_outlined),
              label: Text(locals.musicLibrary),
            ),
          ],
        ),
      ],
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
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color:
                            Theme.of(context).colorScheme.surfaceContainerLow,
                      ),
                      child: Row(children: [
                        Icon(Icons.favorite_border_rounded,
                            color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 16),
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
        72.0,
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
                      onOpen: () => _openSong(context, session, song.id),
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
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(12),
        onFocusChange: (focused) {
          if (focused) Scrollable.ensureVisible(context, alignment: 0.5);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
          child: Row(
            children: [
              ExcludeSemantics(
                child: SizedBox.square(
                  dimension: 56,
                  child: song.thumbnails.isEmpty
                      ? DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(Icons.music_note_rounded,
                              color: colors.onSurfaceVariant),
                        )
                      : Thumbnail(
                          images: song.thumbnails,
                          decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10)),
                        ),
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
              if (artists.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var index = 0; index < artists.length; index++)
                      ActionChip(
                        key: ValueKey('music-suggestion-$index'),
                        avatar: const Icon(Icons.search, size: 18),
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
              );
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
  const _DiscoverySongs();

  @override
  State<_DiscoverySongs> createState() => _DiscoverySongsState();
}

class _DiscoverySongsState extends State<_DiscoverySongs> {
  _DiscoverySession? _session;
  List<MusicTrack> _songs = const [];
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
    _songs = const [];
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

  bool _sameConnection(int generation, _DiscoverySession session) =>
      mounted &&
      generation == _generation &&
      session.eligible &&
      session.matches(_DiscoverySession(context.read<AppCubit>().state));

  bool get _pageVisible =>
      mounted &&
      TickerMode.of(context) &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  bool _current(int generation, _DiscoverySession session) =>
      _sameConnection(generation, session) && _pageVisible;

  Future<void> _load() async {
    if (_loading || !_pageVisible) return;
    final session = _DiscoverySession(context.read<AppCubit>().state);
    if (!session.eligible) return;
    if (_session?.matches(session) != true) _reset();
    _session = session;
    final generation = ++_generation;
    setState(() {
      _attempted = true;
      _loading = true;
      _failed = false;
    });
    try {
      final songs = await musicCatalogService.getDiscoverySongs(
          isCurrent: () => _current(generation, session));
      if (_current(generation, session)) {
        setState(() => _songs = songs);
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
          if (!_sameConnection(generation, session)) {
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
    final locals = AppLocalizations.of(context)!;
    final results = musicTrackResults(_songs, showHidden: _showCommunityHidden);
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
                  onPressed: _loading ? null : _load,
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
              return MusicCatalogCard(
                key: ValueKey('music-discovery-${song.videoId}'),
                title: song.title,
                subtitle: song.artists.join(', '),
                thumbnails: song.thumbnails,
                badge: matches.isEmpty
                    ? null
                    : CommunityMatchLabels(matches: matches, compact: true),
                onOpen: () {
                  if (_current(_generation, session)) {
                    _openSong(context, session.app, song.videoId);
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
              onPressed: _load,
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
      (locals.musicGenrePop, 'pop music', Icons.mic_external_on_rounded),
      (locals.musicGenreJazz, 'jazz music', Icons.piano_rounded),
      (locals.musicGenreClassical, 'classical music', Icons.music_note_rounded),
      (
        locals.musicGenreElectronic,
        'electronic music',
        Icons.graphic_eq_rounded
      ),
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
                        color: index.isEven
                            ? colors.secondaryContainer
                            : colors.tertiaryContainer,
                        borderRadius: BorderRadius.circular(20),
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
                          child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ExcludeSemantics(
                                    child: Icon(genres[index].$3,
                                        color: index.isEven
                                            ? colors.onSecondaryContainer
                                            : colors.onTertiaryContainer,
                                        size: 28)),
                                const SizedBox(height: 18),
                                Text(genres[index].$1,
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                            color: index.isEven
                                                ? colors.onSecondaryContainer
                                                : colors.onTertiaryContainer)),
                              ],
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

void _openSong(BuildContext context, AppState session, String videoId) {
  if (_sameSession(session, context.read<AppCubit>().state)) {
    context.router.push(MusicRoute(videoId: videoId));
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
              MediaQuery.sizeOf(context).width < 600 ? 16 : 28,
              16,
              MediaQuery.sizeOf(context).width < 600 ? 16 : 28,
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
