import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_album.dart';
import 'package:clipious/music/models/music_discovery.dart';
import 'package:clipious/music/models/music_playlist.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/views/components/music_catalog_cards.dart';
import 'package:clipious/router.dart';
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class MusicHomePage extends StatefulWidget {
  final VoidCallback onExplore;
  final VoidCallback onLibrary;

  const MusicHomePage(
      {super.key, required this.onExplore, required this.onLibrary});

  @override
  State<MusicHomePage> createState() => _MusicHomePageState();
}

// Keep the page's feed and scroll position when opening a mood from a shelf.
mixin _MoodNavigation<T extends StatefulWidget> on State<T> {
  MusicMoodCategory? _mood;
  final _scroll = ScrollController();
  double _browseOffset = 0;

  void _openMood(MusicMoodCategory mood) {
    _browseOffset = _scroll.offset;
    setState(() => _mood = mood);
    _restoreScroll(0);
  }

  void _closeMood() {
    setState(() => _mood = null);
    _restoreScroll(_browseOffset);
  }

  void _restoreScroll(double offset) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}

class _MusicHomePageState extends State<MusicHomePage>
    with _MoodNavigation<MusicHomePage> {
  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return PopScope(
      canPop: _mood == null || !TickerMode.of(context),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _mood != null && TickerMode.of(context)) {
          _closeMood();
        }
      },
      child: _DiscoveryScroll(
        storageKey: 'music-home',
        controller: _scroll,
        children: [
          _RetainedSection(
            offstage: _mood != null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PageHeading(
                  title: locals.home,
                  trailing: IconButton(
                    tooltip: locals.musicLibrary,
                    onPressed: widget.onLibrary,
                    icon: const Icon(Icons.library_music_outlined),
                  ),
                ),
                _SectionHeading(
                  title: locals.musicNewReleases,
                  onMore: widget.onExplore,
                ),
                _CatalogSection<List<MusicAlbum>>(
                  request: () => musicCatalogService.getNewReleases(),
                  empty: (albums) => albums.isEmpty,
                  emptyText: locals.musicNoReleases,
                  builder: (context, albums) => MusicCatalogShelf(
                    key: const ValueKey('music-home-releases'),
                    itemCount: albums.length,
                    itemBuilder: (context, index) => _album(albums[index]),
                  ),
                ),
                _SectionHeading(title: locals.musicCharts),
                _CatalogSection<MusicCharts>(
                  request: () => musicCatalogService.getCharts(),
                  empty: (charts) => charts.playlists.isEmpty,
                  emptyText: locals.musicNoCharts,
                  builder: (context, charts) => MusicCatalogShelf(
                    key: const ValueKey('music-home-charts'),
                    itemCount: charts.playlists.length,
                    itemBuilder: (context, index) =>
                        _playlist(charts.playlists[index]),
                  ),
                ),
                _SectionHeading(title: locals.musicMoodsAndGenres),
                _CatalogSection<List<MusicMoodCategory>>(
                  request: () => musicCatalogService.getMoodCategories(),
                  empty: (categories) => categories.isEmpty,
                  emptyText: locals.musicNoMoods,
                  builder: (context, categories) => _MoodChoices(
                    categories: categories.take(12).toList(),
                    onSelect: _openMood,
                  ),
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: widget.onExplore,
                  icon: const Icon(Icons.explore_outlined),
                  label: Text(locals.musicExplore),
                ),
              ],
            ),
          ),
          if (_mood case final mood?)
            _MoodDetail(
              key: ValueKey(mood.params),
              category: mood,
              onBack: _closeMood,
            ),
        ],
      ),
    );
  }
}

enum _ExploreCategory { releases, charts, moods }

class MusicExplorePage extends StatefulWidget {
  const MusicExplorePage({super.key});

  @override
  State<MusicExplorePage> createState() => _MusicExplorePageState();
}

class _MusicExplorePageState extends State<MusicExplorePage>
    with _MoodNavigation<MusicExplorePage> {
  _ExploreCategory _selected = _ExploreCategory.releases;
  final _visited = {_ExploreCategory.releases};

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return PopScope(
      canPop: _mood == null || !TickerMode.of(context),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _mood != null && TickerMode.of(context)) {
          _closeMood();
        }
      },
      child: _DiscoveryScroll(
        storageKey: 'music-explore',
        controller: _scroll,
        children: [
          _PageHeading(title: locals.musicExplore),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final category in _ExploreCategory.values)
                ChoiceChip(
                  key: ValueKey('music-explore-${category.name}'),
                  label: Text(switch (category) {
                    _ExploreCategory.releases => locals.musicNewReleases,
                    _ExploreCategory.charts => locals.musicCharts,
                    _ExploreCategory.moods => locals.musicMoodsAndGenres,
                  }),
                  selected: _selected == category,
                  onSelected: (_) => setState(() {
                    _selected = category;
                    _visited.add(category);
                    _mood = null;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 24),
          for (final category in _ExploreCategory.values)
            if (_visited.contains(category))
              _RetainedSection(
                key: ValueKey(category),
                offstage: _selected != category,
                child: switch (category) {
                  _ExploreCategory.releases =>
                    _CatalogSection<List<MusicAlbum>>(
                      request: () => musicCatalogService.getNewReleases(),
                      empty: (albums) => albums.isEmpty,
                      emptyText: locals.musicNoReleases,
                      builder: (context, albums) => MusicCatalogGrid(
                        itemCount: albums.length,
                        itemBuilder: (context, index) => _album(albums[index]),
                      ),
                    ),
                  _ExploreCategory.charts => const _Charts(),
                  _ExploreCategory.moods => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _RetainedSection(
                          offstage: _mood != null,
                          child: _CatalogSection<List<MusicMoodCategory>>(
                            request: () =>
                                musicCatalogService.getMoodCategories(),
                            empty: (categories) => categories.isEmpty,
                            emptyText: locals.musicNoMoods,
                            builder: (context, categories) =>
                                _GroupedMoodChoices(
                              categories: categories,
                              onSelect: _openMood,
                            ),
                          ),
                        ),
                        if (_mood case final mood?)
                          _MoodDetail(
                            key: ValueKey(mood.params),
                            category: mood,
                            onBack: _closeMood,
                          ),
                      ],
                    ),
                },
              ),
        ],
      ),
    );
  }
}

class _Charts extends StatefulWidget {
  const _Charts();

  @override
  State<_Charts> createState() => _ChartsState();
}

class _ChartsState extends State<_Charts> {
  String _country = 'ZZ';
  List<MusicCountry> _countries = [];
  int _generation = 0;

  Future<MusicCharts> _load() async {
    final generation = ++_generation;
    final requestedCountry = _country;
    final session = context.read<AppCubit>().state;
    final charts = await musicCatalogService.getCharts(country: _country);
    if (mounted &&
        generation == _generation &&
        _country == requestedCountry &&
        _sameSession(session, context.read<AppCubit>().state)) {
      setState(() {
        _country = charts.country;
        _countries = charts.countries;
      });
    }
    return charts;
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return BlocListener<AppCubit, AppState>(
      listenWhen: _sessionChanged,
      listener: (context, state) => setState(() {
        _generation++;
        _country = 'ZZ';
        _countries = [];
      }),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_countries.isNotEmpty) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: DropdownButtonFormField<String>(
                key: const ValueKey('music-chart-country'),
                initialValue: _countries.any((item) => item.code == _country)
                    ? _country
                    : null,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: locals.musicCountry,
                  prefixIcon: const Icon(Icons.public),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (final country in _countries)
                    DropdownMenuItem(
                      value: country.code,
                      child: Text(
                        country.code == 'ZZ'
                            ? locals.musicGlobal
                            : country.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (country) {
                  if (country != null && country != _country) {
                    setState(() => _country = country);
                  }
                },
              ),
            ),
            const SizedBox(height: 24),
          ],
          _CatalogSection<MusicCharts>(
            requestKey: _country,
            request: _load,
            empty: (charts) =>
                charts.playlists.isEmpty && charts.artists.isEmpty,
            emptyText: locals.musicNoCharts,
            builder: (context, charts) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (charts.playlists.isNotEmpty)
                  MusicCatalogGrid(
                    itemCount: charts.playlists.length,
                    itemBuilder: (context, index) =>
                        _playlist(charts.playlists[index]),
                  ),
                if (charts.artists.isNotEmpty) ...[
                  _SectionHeading(title: locals.musicPopularArtists),
                  MusicCatalogShelf(
                    itemCount: charts.artists.length,
                    itemBuilder: (context, index) {
                      final artist = charts.artists[index];
                      final session = context.read<AppCubit>().state;
                      return MusicCatalogCard(
                        key: ValueKey('music-artist-${artist.id}'),
                        title: artist.name,
                        thumbnails: artist.thumbnails,
                        artist: true,
                        onOpen: () => _openRoute(
                            context, session, MusicRoute(artistId: artist.id)),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

void _openRoute(BuildContext context, AppState session, MusicRoute route) {
  if (_sameSession(session, context.read<AppCubit>().state)) {
    context.router.push(route);
  }
}

Widget _album(MusicAlbum album) => Builder(builder: (context) {
      final session = context.read<AppCubit>().state;
      return MusicCatalogCard(
        key: ValueKey('music-album-${album.id}'),
        title: album.title,
        subtitle: album.artists.join(', '),
        thumbnails: album.thumbnails,
        onOpen: () =>
            _openRoute(context, session, MusicRoute(albumId: album.id)),
      );
    });

Widget _playlist(MusicPlaylist playlist) => Builder(builder: (context) {
      final session = context.read<AppCubit>().state;
      return MusicCatalogCard(
        key: ValueKey('music-playlist-${playlist.id}'),
        title: playlist.title,
        subtitle: playlist.author,
        thumbnails: playlist.thumbnails,
        onOpen: () =>
            _openRoute(context, session, MusicRoute(playlistId: playlist.id)),
      );
    });

class _MoodDetail extends StatelessWidget {
  final MusicMoodCategory category;
  final VoidCallback onBack;

  const _MoodDetail({super.key, required this.category, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            BackButton(onPressed: onBack),
            const SizedBox(width: 8),
            Expanded(
              child: Text(category.title,
                  style: Theme.of(context).textTheme.headlineSmall),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _CatalogSection<List<MusicPlaylist>>(
          request: () => musicCatalogService.getMoodPlaylists(category.params),
          empty: (playlists) => playlists.isEmpty,
          emptyText: AppLocalizations.of(context)!.musicNoPlaylists,
          builder: (context, playlists) => MusicCatalogGrid(
            itemCount: playlists.length,
            itemBuilder: (context, index) => _playlist(playlists[index]),
          ),
        ),
      ],
    );
  }
}

class _MoodChoices extends StatelessWidget {
  final List<MusicMoodCategory> categories;
  final ValueChanged<MusicMoodCategory> onSelect;

  const _MoodChoices({required this.categories, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final session = context.read<AppCubit>().state;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final category in categories)
          ActionChip(
            key: ValueKey('music-mood-${category.params}'),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(category.title,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            onPressed: () {
              if (_sameSession(session, context.read<AppCubit>().state)) {
                onSelect(category);
              }
            },
          ),
      ],
    );
  }
}

class _GroupedMoodChoices extends StatelessWidget {
  final List<MusicMoodCategory> categories;
  final ValueChanged<MusicMoodCategory> onSelect;

  const _GroupedMoodChoices({required this.categories, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<MusicMoodCategory>>{};
    for (final category in categories) {
      groups.putIfAbsent(category.group, () => []).add(category);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in groups.entries) ...[
          if (entry.key.isNotEmpty) _SectionHeading(title: entry.key),
          _MoodChoices(categories: entry.value, onSelect: onSelect),
          const SizedBox(height: 20),
        ],
      ],
    );
  }
}

class _RetainedSection extends StatelessWidget {
  final bool offstage;
  final Widget child;

  const _RetainedSection(
      {super.key, required this.offstage, required this.child});

  @override
  Widget build(BuildContext context) => Offstage(
        offstage: offstage,
        child: TickerMode(
          enabled: !offstage,
          child: ExcludeFocus(excluding: offstage, child: child),
        ),
      );
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

class _PageHeading extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const _PageHeading({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      );
}

class _SectionHeading extends StatelessWidget {
  final String title;
  final VoidCallback? onMore;

  const _SectionHeading({required this.title, this.onMore});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 12),
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
            if (onMore != null)
              IconButton(
                tooltip: AppLocalizations.of(context)!.musicBrowseAll,
                onPressed: onMore,
                icon: const Icon(Icons.arrow_forward_rounded),
              ),
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
    initial.profileId == current.profileId &&
    initial.sessionRevision == current.sessionRevision &&
    initial.server == current.server;

/// Each shelf owns its loading/error state and invalidates asynchronous results
/// on profile/server transitions. Rebuilding or hiding a shelf does not refetch.
class _CatalogSection<T> extends StatefulWidget {
  final Object? requestKey;
  final Future<T> Function() request;
  final bool Function(T) empty;
  final String emptyText;
  final Widget Function(BuildContext, T) builder;

  const _CatalogSection({
    this.requestKey,
    required this.request,
    required this.empty,
    required this.emptyText,
    required this.builder,
  });

  @override
  State<_CatalogSection<T>> createState() => _CatalogSectionState<T>();
}

class _CatalogSectionState<T> extends State<_CatalogSection<T>> {
  T? _data;
  bool _loading = true;
  bool _failed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void didUpdateWidget(covariant _CatalogSection<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.requestKey != oldWidget.requestKey) _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final session = context.read<AppCubit>().state;
    setState(() {
      _loading = true;
      _failed = false;
      _data = null;
    });
    if (!_sameSession(session, session)) return;
    try {
      final data = await widget.request();
      if (_active(generation, session)) {
        setState(() {
          _data = data;
          _loading = false;
        });
      }
    } catch (_) {
      if (_active(generation, session)) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  bool _active(int generation, AppState session) =>
      mounted &&
      generation == _generation &&
      _sameSession(session, context.read<AppCubit>().state);

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return BlocListener<AppCubit, AppState>(
      listenWhen: _sessionChanged,
      listener: (_, __) => _load(),
      child: _loading
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: SizedBox.square(
                  dimension: 28,
                  child: MotionLoadingIndicator(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            )
          : _failed
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(locals.musicLoadError),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh_rounded),
                        label: Text(locals.retry),
                      ),
                    ],
                  ),
                )
              : _data == null || widget.empty(_data as T)
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(widget.emptyText,
                          style: Theme.of(context).textTheme.bodyMedium),
                    )
                  : widget.builder(context, _data as T),
    );
  }
}
