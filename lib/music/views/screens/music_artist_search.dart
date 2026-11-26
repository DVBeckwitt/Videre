import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/music_collection.dart';
import 'package:clipious/music/models/music_search_text.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/views/components/music_offline_recovery.dart';
import 'package:clipious/music/views/components/music_screen_privacy.dart';
import 'package:clipious/music/views/components/music_track_results.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils.dart' show selectKeys;
import 'package:clipious/utils/views/tv/components/tv_overscan.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

bool artistSearchMatches(List<String> terms, Iterable<String?> fields) {
  final text = normalizeMusicSearchText(fields.nonNulls.join(' '));
  return terms.every(text.contains);
}

class MusicArtistSearchScaffold extends StatefulWidget {
  const MusicArtistSearchScaffold({
    super.key,
    required this.artistName,
    required this.results,
    this.isAvailable = true,
    this.onQueryChanged,
    this.onSearch,
  });

  final String artistName;
  final Widget Function(BuildContext, String) results;
  final bool isAvailable;
  final ValueChanged<String>? onQueryChanged;
  final ValueChanged<String>? onSearch;

  @override
  State<MusicArtistSearchScaffold> createState() =>
      _MusicArtistSearchScaffoldState();
}

class _MusicArtistSearchScaffoldState extends State<MusicArtistSearchScaffold> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _submit() {
    FocusScope.of(context).unfocus();
    widget.onSearch?.call(_query.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final online = widget.onSearch != null;
    final page = Scaffold(
      appBar: AppBar(title: Text(widget.artistName)),
      body: SafeArea(
        child: !widget.isAvailable
            ? Center(child: Text(locals.musicSourceUnavailable))
            : Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Row(children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('music-artist-search-query'),
                        controller: _query,
                        autofocus: true,
                        enableIMEPersonalizedLearning: online,
                        textInputAction: TextInputAction.search,
                        maxLength: online ? 200 : null,
                        onChanged: (query) {
                          setState(() {});
                          widget.onQueryChanged?.call(query.trim());
                        },
                        onSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          labelText: locals.musicSearchArtistCatalog,
                          prefixIcon: online ? null : const Icon(Icons.search),
                          counterText: '',
                          suffixIcon: _query.text.isEmpty
                              ? null
                              : IconButton(
                                  key: const ValueKey(
                                      'music-artist-search-clear'),
                                  tooltip: MaterialLocalizations.of(context)
                                      .clearButtonTooltip,
                                  icon: const Icon(Icons.clear),
                                  onPressed: () =>
                                      Navigator.of(context).maybePop(),
                                ),
                        ),
                      ),
                    ),
                    if (online)
                      IconButton(
                        key: const ValueKey('music-artist-search-submit'),
                        tooltip: locals.search,
                        onPressed: _query.text.trim().isEmpty ? null : _submit,
                        icon: const Icon(Icons.search),
                      ),
                  ]),
                ),
                Expanded(child: widget.results(context, _query.text.trim())),
              ]),
      ),
    );
    return MusicScreenPrivacySurface(
      child: Shortcuts(
        shortcuts: {
          for (final key in selectKeys)
            SingleActivator(key): const ActivateIntent(),
        },
        child: isTv ? TvOverscan(child: page) : page,
      ),
    );
  }
}

class MusicCatalogArtistSearch extends StatefulWidget {
  const MusicCatalogArtistSearch({
    super.key,
    required this.artistId,
    required this.artistName,
    required this.server,
    required this.isSourceCurrent,
    required this.cachedSongs,
    required this.cachedReleases,
    required this.releaseContinuation,
    required this.needsFirstReleasePage,
    required this.onPlay,
    required this.onOpenRelease,
  });

  final String artistId;
  final String artistName;
  final Server? server;
  final bool Function() isSourceCurrent;
  final List<MusicTrack> cachedSongs;
  final List<MusicCollection> cachedReleases;
  final String? releaseContinuation;
  final bool needsFirstReleasePage;
  final Future<void> Function(
      BuildContext, List<MusicTrack>, int, bool Function()) onPlay;
  final Future<void> Function(BuildContext, String) onOpenRelease;

  @override
  State<MusicCatalogArtistSearch> createState() =>
      _MusicCatalogArtistSearchState();
}

class _MusicCatalogArtistSearchState extends State<MusicCatalogArtistSearch> {
  final _catalog = musicCatalogService;
  final _proxy = NetworkProxy.instance;
  final _remoteSongs = <String, MusicTrack>{};
  final _releaseTokens = <String>{};
  late final _releases = {
    for (final release in widget.cachedReleases) release.id: release,
  };
  late var _needsFirstReleasePage = widget.needsFirstReleasePage;
  late var _releaseContinuation = widget.releaseContinuation;
  String _query = '';
  int _revision = 0;
  int _songPage = 1;
  bool _songsLoading = false;
  bool _moreSongs = false;
  Object? _songsFailure;
  bool _releasesLoading = false;
  Object? _releaseFailure;
  bool _sourceRetired = false;

  bool get _available =>
      !_sourceRetired &&
      identical(_catalog, musicCatalogService) &&
      widget.isSourceCurrent();

  bool get _hasReleasePage =>
      _needsFirstReleasePage || _releaseContinuation != null;

  bool _current(int revision) =>
      mounted &&
      revision == _revision &&
      _available &&
      ModalRoute.of(context)?.isActive != false;

  @override
  void initState() {
    super.initState();
    _proxy.addBeforeApply(_retireSource);
  }

  Future<void> _retireSource() async {
    if (mounted) setState(() => _sourceRetired = true);
  }

  @override
  void dispose() {
    _proxy.removeBeforeApply(_retireSource);
    super.dispose();
  }

  void _reviseQuery(String query) {
    _revision++;
    _query = query;
    _remoteSongs.clear();
    _songPage = 1;
    _songsLoading = false;
    _songsFailure = null;
    _moreSongs = false;
    _releasesLoading = false;
    _releaseFailure = null;
  }

  void _edit(String query) {
    if (query != _query) setState(() => _reviseQuery(''));
  }

  void _search(String query) {
    if (!_available || query.isEmpty) return;
    setState(() => _reviseQuery(query));
    unawaited(_loadSongs());
    if (_needsFirstReleasePage) unawaited(_loadReleases());
  }

  Future<void> _loadSongs() async {
    if (_songsLoading || _query.isEmpty) return;
    final revision = _revision;
    bool current() => _current(revision);
    if (!current()) return;
    setState(() {
      _songsLoading = true;
      _songsFailure = null;
    });
    try {
      final page = await _catalog.searchArtistSongs(
        widget.artistId,
        _query,
        _songPage,
        expectedServer: widget.server,
        isCurrent: current,
      );
      if (!current()) return;
      setState(() {
        for (final song in page.songs) {
          _remoteSongs.putIfAbsent(song.videoId, () => song);
        }
        _songPage++;
        _moreSongs = page.hasMore;
        _songsLoading = false;
      });
    } on MusicCatalogUnsupported {
      if (current()) {
        setState(() {
          _moreSongs = false;
          _songsLoading = false;
        });
      }
    } catch (error) {
      if (current()) {
        setState(() {
          _songsFailure = error;
          _songsLoading = false;
        });
      }
    }
  }

  Future<void> _loadReleases() async {
    if (_releasesLoading || !_hasReleasePage) return;
    final revision = _revision;
    final token = _releaseContinuation;
    bool current() => _current(revision);
    if (!current()) return;
    setState(() {
      _releasesLoading = true;
      _releaseFailure = null;
    });
    try {
      final page = await _catalog.getArtistReleases(
        widget.artistId,
        continuation: token,
        expectedServer: widget.server,
        isCurrent: current,
      );
      if (!current()) return;
      setState(() {
        for (final release in page.releases) {
          _releases.putIfAbsent(release.id, () => release);
        }
        if (token != null) _releaseTokens.add(token);
        _releaseContinuation = _releaseTokens.contains(page.continuation)
            ? null
            : page.continuation;
        _needsFirstReleasePage = false;
        _releasesLoading = false;
      });
    } on MusicCatalogUnsupported {
      if (current()) {
        setState(() {
          _releaseContinuation = null;
          _needsFirstReleasePage = false;
          _releasesLoading = false;
        });
      }
    } catch (error) {
      if (current()) {
        setState(() {
          _releaseFailure = error;
          _releasesLoading = false;
        });
      }
    }
  }

  Widget _sectionStatus({
    required String section,
    required bool loading,
    required bool more,
    required Object? error,
    required VoidCallback load,
  }) {
    final locals = AppLocalizations.of(context)!;
    if (loading) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: LinearProgressIndicator(semanticsLabel: section),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(locals.musicCatalogError),
          ),
        if (more || error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextButton(
              onPressed: load,
              child: Text(error != null ? locals.retry : locals.loadMore),
            ),
          ),
        if (isMusicBrowseConnectionFailure(error))
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: BrowseOfflineMusicButton(),
          ),
      ],
    );
  }

  Widget _results(BuildContext context, String draft) {
    if (_query.isEmpty || draft != _query) return const SizedBox.shrink();
    final locals = AppLocalizations.of(context)!;
    final terms = musicSearchTerms(_query);
    final songs = {
      ..._remoteSongs,
      for (final song in widget.cachedSongs)
        if (!_remoteSongs.containsKey(song.videoId) &&
            artistSearchMatches(terms, [song.title, song.albumTitle]))
          song.videoId: song,
    };
    final queue = musicTrackResults(songs.values.toList(), showHidden: false)
        .visible
        .map((result) => result.$1)
        .toList();
    final releases = _releases.values
        .where((release) => artistSearchMatches(terms, [release.title]));
    final showSongs = queue.isNotEmpty ||
        _songsLoading ||
        _moreSongs ||
        _songsFailure != null;
    final showReleases = releases.isNotEmpty ||
        _releasesLoading ||
        _hasReleasePage ||
        _releaseFailure != null;
    if (!showSongs && !showReleases) {
      return Center(child: Text(locals.musicNoResults));
    }
    final revision = _revision;
    return ListView(
      key: ValueKey(_query),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        if (showSongs) ...[
          ListTile(title: Text(locals.musicSongs)),
          for (final (index, song) in queue.indexed)
            ListTile(
              key: ValueKey('music-artist-search-song-${song.videoId}'),
              leading: const Icon(Icons.audiotrack_outlined),
              title: Text(song.title),
              subtitle: song.albumTitle == null ? null : Text(song.albumTitle!),
              onTap: () {
                if (_current(revision)) {
                  unawaited(widget.onPlay(
                      context, queue, index, () => _current(revision)));
                }
              },
            ),
          _sectionStatus(
            section: locals.musicSongs,
            loading: _songsLoading,
            more: _moreSongs,
            error: _songsFailure,
            load: _loadSongs,
          ),
        ],
        if (showReleases) ...[
          ListTile(title: Text(locals.musicArtistReleases)),
          for (final release in releases)
            ListTile(
              key: ValueKey('music-artist-search-release-${release.id}'),
              leading: const Icon(Icons.album_outlined),
              title: Text(release.title),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                if (_current(revision)) {
                  unawaited(widget.onOpenRelease(context, release.id));
                }
              },
            ),
          _sectionStatus(
            section: locals.musicArtistReleases,
            loading: _releasesLoading,
            more: _hasReleasePage,
            error: _releaseFailure,
            load: _loadReleases,
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppCubit>();
    return MusicArtistSearchScaffold(
      artistName: widget.artistName,
      isAvailable: _available,
      onQueryChanged: _edit,
      onSearch: _search,
      results: _results,
    );
  }
}
