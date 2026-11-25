import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../downloads/models/downloaded_video.dart';
import '../../../downloads/states/download_manager.dart';
import '../../../globals.dart' show db;
import '../../../l10n/generated/app_localizations.dart';
import '../../../playlists/models/playlist.dart';
import '../../../playlists/models/playlist_reference.dart';
import '../../../settings/models/db/server.dart';
import '../../../utils/interfaces/db.dart';
import '../../models/music_library_entry.dart';
import '../../models/on_device_music_entry.dart';
import '../../services/music_library_search.dart';
import '../../services/music_library_service.dart';
import '../../services/music_playlist_covers.dart';
import '../screens/music.dart';
import '../screens/music_library.dart';
import 'music_playlist_cover.dart';
import 'music_status_title.dart';

typedef _SearchOwner = ({
  IDbClient database,
  String profileId,
  int sessionRevision,
  Server? server,
});

/// Results from the current profile's saved library and verified audio files.
class MusicLibrarySearchResults extends StatefulWidget {
  const MusicLibrarySearchResults({
    super.key,
    required this.query,
    required this.active,
    this.type = MusicLibrarySearchType.all,
    this.controller,
    this.scrollKey,
    this.searchFocusNode,
    this.isCurrent,
    this.isSessionCurrent,
  });

  final String query;
  final bool active;
  final MusicLibrarySearchType type;
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
  final _search = MusicLibrarySearch();
  late final _fileChanges = _search.fileChanges;
  _SearchOwner? _visibleOwner;
  bool Function()? _visibleSource;
  List<DownloadedVideo> _lastFiles = const [];
  int _fileEpoch = 0;
  late bool _foreground;
  bool _scheduled = false;
  bool _force = false;
  bool _checkingFiles = false;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _fileChanges.addListener(_scheduleFileRefresh);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fileChanges.removeListener(_scheduleFileRefresh);
    _search.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (resumed == _foreground) return;
    _foreground = resumed;
    _fileEpoch++;
    if (!resumed || !widget.active) return;
    if (_visibleOwner == null) {
      setState(() {});
    } else {
      _scheduleFileRefresh(force: true);
    }
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
      if (current() && _checkingFiles) setState(() => _checkingFiles = false);
    }
  }

  List<MusicLibrarySearchHit> _hits(_SearchOwner owner) =>
      _search.search(widget.query,
          database: owner.database,
          profileId: owner.profileId,
          type: widget.type);

  Future<void> _activate(
    _SearchOwner owner,
    String query,
    MusicLibrarySearchType type,
    MusicLibrarySearchHit requested,
    bool Function()? ownsSearch,
  ) async {
    bool current() =>
        _current(owner) &&
        widget.query == query &&
        widget.type == type &&
        (ownsSearch?.call() ?? true);
    if (!current() || !_visible) return;
    final hits = _hits(owner);
    final hit = hits.where((item) => item.key == requested.key).firstOrNull;
    if (hit == null) return;
    final locals = AppLocalizations.of(context)!;
    final searchFocus = widget.searchFocusNode;
    try {
      switch (hit) {
        case MusicLibrarySearchBookmark(:final entry):
          if (entry.kind == MusicLibraryKind.song) {
            final songs = [
              for (final bookmark
                  in hits.whereType<MusicLibrarySearchBookmark>())
                if (bookmark.entry.kind == MusicLibraryKind.song)
                  bookmark.entry.toVideo(),
            ];
            final index = songs.indexWhere((song) => song.videoId == entry.id);
            if (index < 0) return;
            searchFocus?.unfocus();
            await MusicScreen.playTracks(context, songs,
                startIndex: index, queueTitle: locals.musicSavedSongs);
          } else {
            searchFocus?.unfocus();
            await Navigator.of(context).push<void>(MaterialPageRoute(
                builder: (_) => MusicScreen(
                      artistId: entry.kind == MusicLibraryKind.artist
                          ? entry.id
                          : null,
                      playlistId: entry.kind == MusicLibraryKind.artist
                          ? null
                          : entry.id,
                    )));
          }
        case MusicLibrarySearchPlaylist(:final playlist):
          final source = PlaylistReference.forPlaylist(
              playlist, owner.database.forProfile(owner.profileId));
          searchFocus?.unfocus();
          await Navigator.of(context).push<void>(MaterialPageRoute(
              builder: (_) => MusicLibraryPage(source: source)));
        case MusicLibrarySearchFile(:final entry):
          bool present(MusicLibrarySearchFile file) =>
              file.entry.download == null ||
              _completedFiles(context.read<DownloadManagerCubit?>())
                  .contains(file.entry.download);
          final files =
              hits.whereType<MusicLibrarySearchFile>().where(present).toList();
          final index = files.indexWhere((file) => file.entry.id == entry.id);
          if (index < 0) return;
          searchFocus?.unfocus();
          await MusicScreen.playOnDeviceTracks(
              context, [for (final file in files) file.entry],
              startIndex: index,
              queueTitle: locals.onDevice,
              isCurrent: () =>
                  current() &&
                  _hits(owner)
                      .whereType<MusicLibrarySearchFile>()
                      .any((file) => file.key == hit.key && present(file)));
      }
    } catch (_) {
      if (mounted && current() && _visible) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(locals.musicPlaybackError)));
      }
    }
  }

  Widget _row(_SearchOwner owner, String query, MusicLibrarySearchType type,
      MusicLibrarySearchHit hit, AppLocalizations locals) {
    final ownsSearch = widget.isCurrent;
    final (title, kind, icon, plays) = switch (hit) {
      MusicLibrarySearchBookmark(:final entry) => (
          hit.title,
          switch (entry.kind) {
            MusicLibraryKind.song => locals.musicSavedSongs,
            MusicLibraryKind.artist => locals.channel,
            MusicLibraryKind.album => locals.musicOpenAlbum,
            MusicLibraryKind.playlist => locals.musicPlaylists,
          },
          switch (entry.kind) {
            MusicLibraryKind.song => Icons.music_note_outlined,
            MusicLibraryKind.artist => Icons.person_outline,
            MusicLibraryKind.album => Icons.album_outlined,
            MusicLibraryKind.playlist => Icons.playlist_play,
          },
          entry.kind == MusicLibraryKind.song,
        ),
      MusicLibrarySearchPlaylist(:final playlist) => (
          playlist.playlistId == localWatchLaterId
              ? locals.watchLater
              : hit.title,
          locals.musicPlaylists,
          Icons.playlist_play,
          false,
        ),
      MusicLibrarySearchFile() => (
          hit.title,
          locals.onDevice,
          Icons.audio_file_outlined,
          true
        ),
    };
    final subtitle = hit.subtitle?.trim();
    final titleLabel = Text(title);
    return ListTile(
      key: ValueKey(('music-library-search-hit', hit.key)),
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
      subtitle: Text(
          subtitle == null || subtitle.isEmpty ? kind : '$kind · $subtitle'),
      trailing: Icon(plays ? Icons.play_arrow : Icons.chevron_right),
      onTap: widget.active
          ? () => _activate(owner, query, type, hit, ownsSearch)
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppCubit>().state;
    final owner = _owner(state);
    final files = context.select(_completedFiles);
    if (owner == null || !_visible || !_sessionCurrent(owner)) {
      if (_visibleOwner != null) _fileEpoch++;
      _visibleOwner = null;
      _visibleSource = null;
    } else {
      final activating =
          _visibleOwner != owner || _visibleSource?.call() == false;
      if (activating) _fileEpoch++;
      _visibleOwner = owner;
      _visibleSource = widget.isSessionCurrent;
      if (activating || !listEquals(files, _lastFiles)) {
        _checkingFiles |= activating;
        _lastFiles = files;
        _scheduleFileRefresh(force: activating);
      }
    }
    final query = widget.query;
    final type = widget.type;
    if (!widget.active || owner == null || query.trim().isEmpty) {
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
        if (hits.isEmpty) {
          return Center(
              child: _checkingFiles && type != MusicLibrarySearchType.playlists
                  ? const CircularProgressIndicator()
                  : Text(locals.musicNoResults));
        }
        return ListView.builder(
          key: widget.scrollKey ??
              const PageStorageKey('music-search-library-results'),
          controller: widget.controller,
          primary: false,
          itemCount: hits.length,
          itemBuilder: (context, index) =>
              _row(owner, query, type, hits[index], locals),
        );
      },
    );
  }
}
