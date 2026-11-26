import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals, setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../downloads/models/downloaded_video.dart';
import '../../../downloads/services/explicit_music_download.dart';
import '../../../downloads/states/download_manager.dart';
import '../../../globals.dart' show db;
import '../../../l10n/generated/app_localizations.dart';
import '../../../playlists/models/playlist.dart';
import '../../../playlists/models/playlist_reference.dart';
import '../../../settings/models/db/server.dart';
import '../../../utils/interfaces/db.dart';
import '../../../videos/models/video.dart';
import '../../models/device_playlist_track.dart';
import '../../models/local_music_track.dart';
import '../../models/music_library_entry.dart';
import '../../models/music_song_selection.dart';
import '../../models/on_device_music_entry.dart';
import '../../services/local_music_library.dart';
import '../../services/music_library_search.dart';
import '../../services/music_library_service.dart';
import '../../services/music_playlist_covers.dart';
import '../screens/music.dart';
import '../screens/music_device_album.dart';
import '../screens/music_device_artist.dart';
import '../screens/music_device_collections.dart';
import '../screens/music_library.dart';
import 'music_download_removal.dart';
import 'music_playlist_cover.dart';
import 'music_saved_song_removal.dart';
import 'music_song_selection_bar.dart';
import 'music_status_title.dart';

typedef _SearchOwner = ({
  IDbClient database,
  String profileId,
  int sessionRevision,
  Server? server,
});

typedef _LyricScope = ({_SearchOwner owner, String query});
typedef _DeviceLyricMatch = ({LocalMusicTrack track, String line});

/// Results from the current profile's saved library and verified audio files.
class MusicLibrarySearchResults extends StatefulWidget {
  const MusicLibrarySearchResults({
    super.key,
    required this.query,
    required this.active,
    required this.songSelection,
    required this.selectionRevision,
    this.selectionCloseFocus,
    required this.changeSelection,
    this.types = MusicLibrarySearchType.categories,
    this.controller,
    this.scrollKey,
    this.searchFocusNode,
    this.isCurrent,
    this.isSessionCurrent,
  });

  final String query;
  final bool active;
  final MusicSongSelection<Object> songSelection;
  final int selectionRevision;
  final FocusNode? selectionCloseFocus;
  final ValueChanged<VoidCallback> changeSelection;
  final Set<MusicLibrarySearchType> types;
  final ScrollController? controller;
  final Key? scrollKey;
  final FocusNode? searchFocusNode;

  /// Whether the caller still owns this Library search, query, and type.
  final bool Function()? isCurrent;

  /// Whether this view still owns local file reads, regardless of its query.
  final bool Function()? isSessionCurrent;

  @override
  State<MusicLibrarySearchResults> createState() =>
      _MusicLibrarySearchResultsState();
}

class _MusicLibrarySearchResultsState extends State<MusicLibrarySearchResults>
    with WidgetsBindingObserver {
  static const _lyricSearchDelay = Duration(milliseconds: 250);
  final _device = LocalMusicLibrary.instance;
  late final _search = MusicLibrarySearch(deviceLibrary: _device);
  late final _fileChanges = _search.fileChanges;
  _SearchOwner? _visibleOwner;
  bool Function()? _visibleSource;
  List<DownloadedVideo> _lastFiles = const [];
  int _fileEpoch = 0;
  int _activationRevision = 0;
  late bool _foreground;
  bool _scheduled = false;
  bool _force = false;
  bool _checkingFiles = false;
  _LyricScope? _lyricScope;
  int _lyricRevision = 0;
  bool _checkingLyrics = false;
  Timer? _lyricDelay;
  StreamSubscription<_DeviceLyricMatch>? _deviceLyrics;
  StreamSubscription<void>? _savedLyrics;
  final _deviceLyricMatches = <LocalMusicTrack, String>{};

  bool get _lyricsMode => widget.types.contains(MusicLibrarySearchType.lyrics);

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _device.addListener(_resetDeviceLyrics);
    _fileChanges.addListener(_scheduleFileRefresh);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _device.removeListener(_resetDeviceLyrics);
    _fileChanges.removeListener(_scheduleFileRefresh);
    _resetDeviceLyrics();
    unawaited(_savedLyrics?.cancel());
    _search.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (resumed == _foreground) return;
    _foreground = resumed;
    _fileEpoch++;
    if (!resumed && _lyricScope != null) {
      setState(() => _setLyricScope(null));
    }
    if (!resumed || !widget.active) return;
    if (_visibleOwner == null || _lyricsMode) {
      setState(() {});
    }
    _scheduleFileRefresh(force: true);
  }

  _SearchOwner? _owner(AppState state) {
    final database = db;
    if (state.globalLoading ||
        state.sessionRecoveryRequired ||
        state.profileId != database.profileId) {
      return null;
    }
    return (
      database: database,
      profileId: state.profileId,
      sessionRevision: state.sessionRevision,
      server: state.server,
    );
  }

  bool _sessionCurrent(_SearchOwner owner) =>
      mounted &&
      _owner(context.read<AppCubit>().state) == owner &&
      (widget.isSessionCurrent?.call() ?? true);

  bool _current(_SearchOwner owner) =>
      _sessionCurrent(owner) && (widget.isCurrent?.call() ?? true);

  bool get _visible =>
      _foreground &&
      widget.active &&
      TickerMode.of(context) &&
      (ModalRoute.isCurrentOf(context) ?? true);

  static List<DownloadedVideo> _completedFiles(DownloadManagerCubit? manager) =>
      [
        for (final file in manager?.state.videos ?? const <DownloadedVideo>[])
          if (file.profileId == db.profileId &&
              file.audioOnly &&
              file.musicMetadata != null &&
              file.downloadComplete &&
              !file.downloadFailed &&
              !file.storageFailed &&
              !file.authenticationRequired)
            file,
      ];

  void _resetDeviceLyrics() {
    _lyricRevision++;
    _lyricDelay?.cancel();
    _lyricDelay = null;
    unawaited(_deviceLyrics?.cancel());
    _deviceLyrics = null;
    _deviceLyricMatches.clear();
    _checkingLyrics = _lyricScope != null;
  }

  void _setLyricScope(_LyricScope? scope) {
    final previous = _lyricScope;
    if (previous == scope) return;
    _lyricScope = scope;
    _resetDeviceLyrics();
    if (previous?.owner != scope?.owner) {
      unawaited(_savedLyrics?.cancel());
      _savedLyrics = null;
      if (scope case (owner: final owner, query: _)) {
        _savedLyrics = _search
            .watchSavedLyrics(owner.database, owner.profileId)
            .listen((_) {
          if (_lyricScope?.owner == owner && _current(owner) && _visible) {
            setState(() {});
          }
        }, onError: (Object _) {});
      }
    }
    if (scope != null) _scheduleFileRefresh();
  }

  void _scheduleDeviceLyrics() {
    final scope = _lyricScope;
    if (scope == null ||
        !_checkingLyrics ||
        _lyricDelay != null ||
        _deviceLyrics != null) {
      return;
    }
    final (owner: owner, query: query) = scope;
    final revision = _lyricRevision;
    bool current() =>
        revision == _lyricRevision &&
        _current(owner) &&
        _visible &&
        _lyricsMode &&
        widget.query == query;
    void finish() {
      if (!current()) return;
      setState(() {
        _deviceLyrics = null;
        _checkingLyrics = false;
      });
    }

    _lyricDelay = Timer(_lyricSearchDelay, () {
      _lyricDelay = null;
      if (!current()) return;
      _deviceLyrics = _search
          .findDeviceLyricMatches(query,
              database: owner.database,
              profileId: owner.profileId,
              isCurrent: current)
          .listen((match) {
        if (current()) {
          setState(() => _deviceLyricMatches[match.track] = match.line);
        }
      }, onDone: finish, onError: (Object _) => finish(), cancelOnError: true);
    });
  }

  void _scheduleFileRefresh({bool force = false}) {
    if (!mounted || _visibleOwner == null) return;
    _force |= force;
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      final owner = _visibleOwner;
      final force = _force;
      _force = false;
      if (owner != null && _sessionCurrent(owner) && _visible) {
        unawaited(_refreshFiles(owner, force: force));
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _refreshFiles(_SearchOwner owner, {required bool force}) async {
    final epoch = _fileEpoch;
    final source = widget.isSessionCurrent;
    bool current() =>
        epoch == _fileEpoch &&
        (source?.call() ?? true) &&
        _sessionCurrent(owner) &&
        _visible &&
        _visibleOwner == owner;
    try {
      await _search.refreshFiles(
          database: owner.database,
          profileId: owner.profileId,
          downloads: _completedFiles(context.read<DownloadManagerCubit?>()),
          force: force,
          isCurrent: current);
    } catch (_) {
      // A file probe may fail after access changes. Saved metadata is still searchable.
    } finally {
      if (current()) {
        if (_checkingFiles) setState(() => _checkingFiles = false);
        _scheduleDeviceLyrics();
      }
    }
  }

  List<MusicLibrarySearchHit> _hits(_SearchOwner owner) =>
      _search.search(widget.query,
          database: owner.database,
          profileId: owner.profileId,
          types: widget.types,
          deviceLyricMatches: _deviceLyricMatches);

  Future<void> _activate(
    _SearchOwner owner,
    String query,
    Set<MusicLibrarySearchType> types,
    MusicLibrarySearchHit requested,
    bool Function()? ownsSearch,
  ) async {
    final activation = ++_activationRevision;
    bool current() =>
        _current(owner) &&
        activation == _activationRevision &&
        widget.query == query &&
        setEquals(widget.types, types) &&
        (ownsSearch?.call() ?? true);
    if (!current() || !_visible) return;
    final hits = _hits(owner);
    final hit = hits.where((item) => item.key == requested.key).firstOrNull;
    if (hit == null) return;
    final locals = AppLocalizations.of(context)!;
    final searchFocus = widget.searchFocusNode;
    try {
      switch (hit) {
        case MusicLibrarySearchBookmark(
                entry: MusicLibraryEntry(kind: MusicLibraryKind.song)
              ) ||
              MusicLibrarySearchRecording():
          final songs = <Video>[];
          var index = -1;
          for (final result in hits) {
            final song = switch (result) {
              MusicLibrarySearchBookmark(:final entry)
                  when entry.kind == MusicLibraryKind.song =>
                entry.toVideo(),
              MusicLibrarySearchRecording(:final video) => video,
              _ => null,
            };
            if (song == null) continue;
            if (result.key == hit.key) index = songs.length;
            songs.add(song);
          }
          if (index < 0) return;
          searchFocus?.unfocus();
          await MusicScreen.playTracks(context, songs,
              startIndex: index,
              queueTitle:
                  _lyricsMode ? locals.musicLyrics : locals.musicSavedSongs,
              songTap: true);
        case MusicLibrarySearchBookmark(:final entry):
          searchFocus?.unfocus();
          await Navigator.of(context).push<void>(MaterialPageRoute(
              builder: (_) => MusicScreen(
                    artistId:
                        entry.kind == MusicLibraryKind.artist ? entry.id : null,
                    artistName: entry.kind == MusicLibraryKind.artist
                        ? entry.title
                        : null,
                    playlistId:
                        entry.kind == MusicLibraryKind.artist ? null : entry.id,
                  )));
        case MusicLibrarySearchPlaylist(:final playlist):
          final source = PlaylistReference.forPlaylist(
              playlist, owner.database.forProfile(owner.profileId));
          searchFocus?.unfocus();
          await Navigator.of(context).push<void>(MaterialPageRoute(
              builder: (_) => MusicLibraryPage(source: source)));
        case MusicLibrarySearchAlbum(:final album):
          searchFocus?.unfocus();
          await MusicScreen.openDeviceCollection(
              context,
              MusicDeviceAlbumPage(
                  selectionId: _device.selectionId, albumKey: album.key));
        case MusicLibrarySearchArtist(:final artist):
          searchFocus?.unfocus();
          await MusicScreen.openDeviceCollection(
              context,
              MusicDeviceArtistPage(
                  selectionId: _device.selectionId, artistKey: artist.key));
        case MusicLibrarySearchGenre(:final genreKey):
          searchFocus?.unfocus();
          await openMusicDeviceCollections(
              context, _device, MusicDeviceCollection.genres,
              collectionKey: genreKey);
        case MusicLibrarySearchFile(:final entry):
          final track = _lyricsMode ? entry.deviceTrack : null;
          var currentHits = hits;
          if (track != null) {
            final revision = _lyricRevision;
            bool canRecheck() =>
                current() && _visible && revision == _lyricRevision;
            final line = await _search.recheckDeviceLyric(query, track,
                database: owner.database,
                profileId: owner.profileId,
                isCurrent: canRecheck);
            if (!canRecheck()) return;
            setState(() {
              if (line == null) {
                _deviceLyricMatches.remove(track);
              } else {
                _deviceLyricMatches[track] = line;
              }
            });
            if (line == null) return;
            currentHits = _hits(owner);
          }
          if (!mounted) return;
          bool present(MusicLibrarySearchFile file) =>
              file.entry.download == null ||
              _completedFiles(context.read<DownloadManagerCubit?>())
                  .contains(file.entry.download);
          final files = currentHits
              .whereType<MusicLibrarySearchFile>()
              .where(present)
              .toList();
          final index = files.indexWhere((file) => file.entry.id == entry.id);
          if (index < 0) return;
          searchFocus?.unfocus();
          await MusicScreen.playOnDeviceTracks(
              context, [for (final file in files) file.entry],
              startIndex: index,
              queueTitle: locals.onDevice,
              songTap: true,
              isCurrent: () =>
                  current() &&
                  (track != null
                      // TV playback opens a route over search and needs the
                      // selected file to stay valid after the snippets clear.
                      ? _device.enabled &&
                          !_device.unavailable &&
                          identical(
                              _device.visibleTrackById(track.playbackId), track)
                      : _hits(owner).whereType<MusicLibrarySearchFile>().any(
                          (file) => file.key == hit.key && present(file))));
      }
    } catch (_) {
      if (mounted && current() && _visible) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(locals.musicPlaybackError)));
      }
    }
  }

  bool _isSong(MusicLibrarySearchHit hit) => switch (hit) {
        MusicLibrarySearchBookmark(
          entry: MusicLibraryEntry(kind: MusicLibraryKind.song)
        ) ||
        MusicLibrarySearchRecording() ||
        MusicLibrarySearchFile() =>
          true,
        _ => false,
      };

  Video? _selectionVideo(MusicLibrarySearchHit hit) => switch (hit) {
        MusicLibrarySearchBookmark(:final entry) => entry.toVideo(),
        MusicLibrarySearchRecording(:final video) => video,
        MusicLibrarySearchFile(
          entry: OnDeviceMusicEntry(deviceTrack: final track?)
        ) =>
          devicePlaylistVideo(track),
        MusicLibrarySearchFile(
          entry: OnDeviceMusicEntry(
            download: final file?,
            downloadFileProof: final proof?
          )
        ) =>
          _downloadVideo(file, proof),
        _ => null,
      };

  Video? _downloadVideo(DownloadedVideo file, String proof) {
    final fingerprint = musicDownloadFileFingerprint(file, proof);
    if (file.musicMetadata == null || fingerprint == null) return null;
    return musicDownloadSelectionEntry(file, fingerprint: fingerprint);
  }

  Widget _selectionBar(_SearchOwner owner, List<MusicLibrarySearchHit> hits,
      AppLocalizations locals) {
    final selection = widget.songSelection;
    final songHits = hits.where(_isSong).toList();
    final ids = songHits.map((hit) => hit.key).toList();
    selection.retain(ids);
    final rows = selection.selectedRows(songHits, (hit) => hit.key);
    final selectedIds = [for (final hit in rows) hit.key];
    final revision = widget.selectionRevision;
    bool current() =>
        _current(owner) &&
        widget.active &&
        revision == widget.selectionRevision &&
        selection.active &&
        listEquals(selectedIds, [
          for (final hit in _hits(owner))
            if (_isSong(hit) && selection.contains(hit.key)) hit.key,
        ]);
    List<OnDeviceMusicEntry>? resolveFiles() {
      if (!current()) return null;
      final completed = _completedFiles(context.read<DownloadManagerCubit?>());
      final files = [
        for (final hit in _hits(owner).whereType<MusicLibrarySearchFile>())
          if (selection.contains(hit.key) &&
              (hit.entry.download == null ||
                  completed.contains(hit.entry.download)))
            hit.entry,
      ];
      return files.length == rows.length ? files : null;
    }

    final videos = [
      for (final hit in rows)
        if (_selectionVideo(hit) case final video?) video,
    ];
    final includesFiles = rows.any((hit) => hit is MusicLibrarySearchFile);
    final onlySaved = rows.isNotEmpty &&
        rows.every((hit) => hit is MusicLibrarySearchBookmark);
    return MusicSongSelectionBar(
      selected: videos,
      selectedCount: rows.length,
      allSelected: selection.allSelected(ids),
      onToggleAll: ids.isEmpty
          ? null
          : () => widget.changeSelection(() => selection.toggleAll(ids)),
      onClose: () => widget.changeSelection(selection.clear),
      closeFocus: widget.selectionCloseFocus,
      isCurrent: current,
      resolveOnDevice: includesFiles ? resolveFiles : null,
      onPlay: !includesFiles
          ? (tracks) => MusicScreen.playTracks(context, tracks,
              queueTitle: _lyricsMode ? locals.musicLyrics : locals.search)
          : null,
      removal: onlySaved
          ? (
              label: locals.musicRemoveSelectedSavedSongs,
              run: () async {
                final ids = [
                  for (final hit in rows.cast<MusicLibrarySearchBookmark>())
                    hit.entry.id,
                ];
                final library = MusicLibraryService.forProfile(
                    owner.database, owner.profileId);
                if (await confirmMusicSavedSongRemoval(context, library, ids,
                        isCurrent: current) &&
                    _current(owner) &&
                    widget.selectionRevision == revision) {
                  widget.changeSelection(selection.clear);
                }
              },
            )
          : null,
    );
  }

  Widget _row(
      _SearchOwner owner,
      String query,
      Set<MusicLibrarySearchType> types,
      MusicLibrarySearchHit hit,
      AppLocalizations locals) {
    final ownsSearch = widget.isCurrent;
    final (title, kind, icon, plays) = switch (hit) {
      MusicLibrarySearchBookmark(:final resultKind) => (
          hit.title,
          switch (resultKind) {
            MusicLibraryKind.song => locals.musicSavedSongs,
            MusicLibraryKind.artist => locals.musicLyricsArtist,
            MusicLibraryKind.album => locals.musicOpenAlbum,
            MusicLibraryKind.playlist => locals.musicPlaylists,
          },
          switch (resultKind) {
            MusicLibraryKind.song => Icons.music_note_outlined,
            MusicLibraryKind.artist => Icons.person_outline,
            MusicLibraryKind.album => Icons.album_outlined,
            MusicLibraryKind.playlist => Icons.playlist_play,
          },
          resultKind == MusicLibraryKind.song,
        ),
      MusicLibrarySearchPlaylist(:final playlist) => (
          playlist.playlistId == localWatchLaterId
              ? locals.watchLater
              : hit.title,
          locals.musicPlaylists,
          Icons.playlist_play,
          false,
        ),
      MusicLibrarySearchAlbum() => (
          hit.title,
          locals.localMusicBrowseAlbums,
          Icons.album_outlined,
          false,
        ),
      MusicLibrarySearchArtist() => (
          hit.title,
          locals.localMusicBrowseArtists,
          Icons.person_outline,
          false,
        ),
      MusicLibrarySearchGenre() => (
          hit.title,
          locals.localMusicGenres,
          Icons.category_outlined,
          false,
        ),
      MusicLibrarySearchRecording() => (
          hit.title,
          locals.musicLyrics,
          Icons.music_note_outlined,
          true,
        ),
      MusicLibrarySearchFile() => (
          hit.title,
          locals.onDevice,
          Icons.audio_file_outlined,
          true
        ),
    };
    final subtitle = hit.subtitle?.trim();
    final detail =
        subtitle == null || subtitle.isEmpty ? kind : '$kind · $subtitle';
    final lyricLine = hit.lyricLine;
    final titleLabel = Text(title);
    final selection = widget.songSelection;
    final selected = selection.contains(hit.key);
    void select() {
      if (!_current(owner)) return;
      widget.searchFocusNode?.unfocus();
      widget.changeSelection(() => selection.start(hit.key));
    }

    void toggleSelection() =>
        widget.changeSelection(() => selection.toggle(hit.key));
    return ListTile(
      key: ValueKey(('music-library-search-hit', hit.key)),
      selected: selected,
      leading: hit is MusicLibrarySearchPlaylist
          ? MusicPlaylistCoverImage(
              encoded: MusicPlaylistCovers.forProfile(
                      owner.database, owner.profileId)
                  .encodedCover(hit.playlist.playlistId),
              fallback: Icon(icon),
              size: 40,
            )
          : Icon(icon),
      title: switch (hit) {
        MusicLibrarySearchBookmark(:final entry)
            when entry.kind == MusicLibraryKind.song =>
          MusicStatusTitle.song(video: entry.toVideo(), child: titleLabel),
        MusicLibrarySearchRecording(:final video) =>
          MusicStatusTitle.song(video: video, child: titleLabel),
        MusicLibrarySearchBookmark(:final entry) => MusicStatusTitle.bookmark(
            kind: entry.kind, id: entry.id, child: titleLabel),
        MusicLibrarySearchFile(
          entry: OnDeviceMusicEntry(
            download: final file?,
            :final downloadFileProof
          )
        ) =>
          MusicStatusTitle.download(
              file: file, fileProof: downloadFileProof, child: titleLabel),
        _ => titleLabel,
      },
      subtitle: lyricLine == null
          ? Text(detail)
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(locals.musicSearchLyricLine(lyricLine),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
      isThreeLine: lyricLine != null,
      trailing: plays
          ? MusicSongSelectButton(
              selected: selection.active ? selected : null,
              onPressed: selection.active ? toggleSelection : select)
          : const Icon(Icons.chevron_right),
      onLongPress: plays && widget.active ? select : null,
      onTap: !widget.active
          ? null
          : selection.active
              ? (plays ? toggleSelection : null)
              : () => _activate(owner, query, types, hit, ownsSearch),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppCubit>().state;
    final owner = _owner(state);
    final files = context.select(_completedFiles);
    final visible = _visible;
    // The contextual menu and confirmation can briefly cover this route.
    final keepSelection = widget.songSelection.active &&
        widget.active &&
        _foreground &&
        TickerMode.of(context) &&
        _visibleOwner == owner;
    if (owner == null ||
        !(visible || keepSelection) ||
        !_sessionCurrent(owner)) {
      if (_visibleOwner != null) _fileEpoch++;
      _visibleOwner = null;
      _visibleSource = null;
    } else if (visible) {
      final activating =
          _visibleOwner != owner || _visibleSource?.call() == false;
      _visibleOwner = owner;
      _visibleSource = widget.isSessionCurrent;
      if (activating || !listEquals(files, _lastFiles)) {
        _fileEpoch++;
        if (_lyricScope != null) _resetDeviceLyrics();
        _checkingFiles |= activating;
        _lastFiles = files;
        _scheduleFileRefresh(force: activating);
      }
    }
    final query = widget.query;
    final types = widget.types;
    final lyricsMode = _lyricsMode;
    final hasQuery = query.trim().isNotEmpty;
    _setLyricScope(lyricsMode &&
            owner != null &&
            _visibleOwner == owner &&
            _current(owner) &&
            hasQuery
        ? (owner: owner, query: query)
        : null);
    if (!widget.active ||
        owner == null ||
        !hasQuery ||
        (lyricsMode && _lyricScope == null)) {
      return const SizedBox.shrink();
    }
    final locals = AppLocalizations.of(context)!;
    final library =
        MusicLibraryService.forProfile(owner.database, owner.profileId);
    return ListenableBuilder(
      listenable: Listenable.merge([library.changes, _fileChanges]),
      builder: (context, _) {
        if (_owner(context.read<AppCubit>().state) != owner) {
          return const SizedBox.shrink();
        }
        final hits = _hits(owner);
        final searchingLyrics = lyricsMode && _checkingLyrics;
        if (hits.isEmpty && !widget.songSelection.active) {
          final loading = searchingLyrics ||
              (_checkingFiles &&
                  types
                      .any((type) => type != MusicLibrarySearchType.playlists));
          return Center(
              child: loading
                  ? CircularProgressIndicator(
                      semanticsLabel:
                          lyricsMode ? locals.musicSearchLyricsLoading : null)
                  : Text(lyricsMode
                      ? locals.musicSearchLyricsEmpty
                      : locals.musicNoResults));
        }
        final view = ListView.builder(
          key: widget.scrollKey ??
              const PageStorageKey('music-search-library-results'),
          controller: widget.controller,
          primary: false,
          itemCount: hits.length + (searchingLyrics ? 1 : 0),
          itemBuilder: (context, index) => index == hits.length
              ? Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: LinearProgressIndicator(
                      semanticsLabel: locals.musicSearchLyricsLoading),
                )
              : _row(owner, query, types, hits[index], locals),
        );
        return Column(children: [
          if (widget.songSelection.active) _selectionBar(owner, hits, locals),
          Expanded(child: view),
        ]);
      },
    );
  }
}
