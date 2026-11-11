import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/views/components/music_catalog_cards.dart';
import 'package:clipious/router.dart';
import 'package:clipious/utils/motion.dart';
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

/// Browse the selected Invidious instance's music feed. Search and the local
/// library remain available even when the instance cannot provide trending.
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
        _PageHeading(title: locals.home),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const ValueKey('music-home-search'),
              onPressed: widget.onSearch,
              icon: const Icon(Icons.search),
              label: Text(locals.search),
            ),
            OutlinedButton.icon(
              key: const ValueKey('music-home-library'),
              onPressed: widget.onLibrary,
              icon: const Icon(Icons.library_music_outlined),
              label: Text(locals.musicLibrary),
            ),
          ],
        ),
        _SectionHeading(title: locals.musicTrending),
        _CatalogSection<List<MusicTrack>>(
          request: () => musicCatalogService.getTrendingSongs(),
          empty: (songs) => songs.isEmpty,
          emptyText: locals.musicNoTrending,
          builder: (context, songs) => MusicCatalogGrid(
            key: const ValueKey('music-home-trending'),
            itemCount: songs.length,
            itemBuilder: (context, index) {
              final song = songs[index];
              final session = context.read<AppCubit>().state;
              return MusicCatalogCard(
                key: ValueKey('music-trending-${song.videoId}'),
                title: song.title,
                subtitle: song.artists.join(', '),
                thumbnails: song.thumbnails,
                onOpen: () => _openSong(context, session, song.videoId),
              );
            },
          ),
        ),
      ],
    );
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

class _PageHeading extends StatelessWidget {
  final String title;
  const _PageHeading({required this.title});

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
          ],
        ),
      );
}

class _SectionHeading extends StatelessWidget {
  final String title;
  const _SectionHeading({required this.title});

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
  final Future<T> Function() request;
  final bool Function(T) empty;
  final String emptyText;
  final Widget Function(BuildContext, T) builder;

  const _CatalogSection({
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
  Object? _failure;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final session = context.read<AppCubit>().state;
    setState(() {
      _loading = true;
      _failure = null;
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
    } catch (error) {
      if (_active(generation, session)) {
        setState(() {
          _failure = error;
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
          : _failure != null
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
