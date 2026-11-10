import 'dart:async';
import 'dart:convert';

import '../../globals.dart' as globals;
import '../../service.dart';
import '../../settings/models/db/server.dart';
import '../../settings/models/db/video_filter.dart';
import '../../utils/interfaces/db.dart';
import '../../videos/models/video.dart';
import '../models/playlist.dart';
import '../models/playlist_reference.dart';

class PlaylistLoadSnapshot {
  final Playlist playlist;
  final bool loading;
  final bool complete;
  final Object? error;

  const PlaylistLoadSnapshot(this.playlist,
      {required this.loading, required this.complete, this.error});
}

/// Metadata paging belongs to the playlist playback session, not its screen.
/// The screen and player retain it independently so navigating away cannot
/// truncate the queue. Every page uses the account captured when it opened.
class PlaylistLoadSession {
  static const maximumPages = 1000;
  final IDbClient _database;
  final Service _service;
  late final bool Function() _ownerIsActive;
  final bool _refreshOnOpen;
  final _changes = StreamController<PlaylistLoadSnapshot>.broadcast();
  final _ready = Completer<void>();
  final _pageSignatures = <String>{};
  PlaylistReference? _reference;
  Server? _server;
  Playlist _playlist;
  bool _loading = false;
  bool _complete = false;
  Object? _error;
  int _retainers = 0;
  int _generation = 0;
  int _nextPage = 1;
  int _filtered = 0;
  bool _started = false;
  bool _disposed = false;
  bool _hasFreshPage = false;

  PlaylistLoadSession({
    required Playlist playlist,
    required IDbClient database,
    PlaylistReference? reference,
    Service? playlistService,
    bool Function()? ownerIsActive,
  })  : _database = database.forProfile(database.profileId),
        _reference = reference,
        _refreshOnOpen = reference != null,
        _service = playlistService ?? globals.service,
        _playlist =
            playlist.copyWith(videos: assignPlaylistEntryIds(playlist.videos)) {
    final owner = _database.profileId;
    _ownerIsActive = ownerIsActive ?? (() => globals.db.profileId == owner);
  }

  Future<void> get ready => _ready.future;
  PlaylistReference? get reference => _reference;
  Playlist get playlist => _playlist;
  List<Video> get videos => _playlist.videos;
  bool get loading => _loading;
  bool get complete => _complete;
  Object? get error => _error;
  bool get hasPlayableSnapshot => !_refreshOnOpen || _hasFreshPage;
  Stream<PlaylistLoadSnapshot> get changes => _changes.stream;

  void retain() {
    if (_disposed) throw StateError('Playlist loading session is closed');
    _retainers++;
    if (!_started) {
      _started = true;
      unawaited(_load());
    }
  }

  void release() {
    if (_disposed || _retainers == 0) return;
    if (--_retainers == 0) {
      _disposed = true;
      _generation++;
      if (!_ready.isCompleted) _ready.complete();
      unawaited(_changes.close());
    }
  }

  bool _current(int generation) =>
      !_disposed && generation == _generation && _ownerIsActive();

  void _publish() {
    if (!_disposed) {
      _changes.add(PlaylistLoadSnapshot(_playlist,
          loading: _loading, complete: _complete, error: _error));
    }
  }

  Future<void> _captureSource(int generation) async {
    if (_reference != null && !_reference!.matchesOwner(_database)) {
      throw StateError('This playlist belongs to another profile');
    }
    if (_playlist.isLocal) {
      _reference ??= PlaylistReference.forPlaylist(_playlist, _database);
      return;
    }
    final reference = _reference;
    final server = reference?.kind == PlaylistSourceKind.account
        ? reference!.resolveServer(_database)
        : await _database.getCurrentlySelectedServer();
    if (!_current(generation)) return;
    if (server == null || server.profileId != _database.profileId) {
      throw StateError('The playlist account is unavailable');
    }
    _server = server;
    _reference ??=
        PlaylistReference.forPlaylist(_playlist, _database, server: server);
  }

  Future<Playlist> _fetchPage(int page) async {
    if (_playlist.isLocal) {
      final local = _service
          .getLocalPlaylists(database: _database)
          .firstWhere((item) => item.playlistId == _playlist.playlistId);
      return local.copyWith(
          videos: await VideoFilter.filterVideos(local.videos));
    }
    final server = _server!;
    final current = _database.getAccount(server.accountId);
    if (current == null || current.url != server.url) {
      throw StateError('The playlist account is unavailable');
    }
    if (_reference!.kind == PlaylistSourceKind.account) {
      return _service.getUserPlaylist(_playlist.playlistId,
          page: page, serverOverride: current);
    }
    return _service.getPublicPlaylists(_playlist.playlistId,
        page: page, serverOverride: current);
  }

  Future<void> retry() async {
    if (_disposed || _loading || _complete) return;
    await _load();
  }

  Future<void> refresh() async {
    if (_disposed) return;
    _generation++;
    _loading = false;
    _complete = false;
    _nextPage = 1;
    _filtered = 0;
    _pageSignatures.clear();
    await _load(forceRefresh: true);
  }

  Future<void> _load({bool forceRefresh = false}) async {
    if (_disposed || _loading) return;
    final generation = _generation;
    _loading = true;
    _error = null;
    _publish();
    try {
      if (_reference != null &&
          (!_reference!.matchesOwner(_database) ||
              _reference!.playlistId != _playlist.playlistId)) {
        throw StateError('The playlist source no longer matches this screen');
      }
      if (_reference == null || (!_playlist.isLocal && _server == null)) {
        await _captureSource(generation);
      }
      if (!_current(generation)) return;
      if (!_ready.isCompleted) _ready.complete();
      _publish();
      if (!forceRefresh &&
          !_refreshOnOpen &&
          _nextPage == 1 &&
          _playlist.videos.length >= _playlist.videoCount) {
        _complete = true;
        return;
      }
      while (_current(generation) && !_complete) {
        if (_nextPage > maximumPages) {
          throw StateError('The playlist exceeded the page limit');
        }
        final page = await _fetchPage(_nextPage);
        if (!_current(generation)) return;
        if (page.playlistId != _reference!.playlistId) {
          throw StateError('The server returned another playlist');
        }
        final signature = jsonEncode([
          for (final video in page.videos)
            [video.videoId, video.indexId, video.index],
          page.removedByFilter,
        ]);
        if (page.videos.isNotEmpty && !_pageSignatures.add(signature)) {
          throw StateError('The server repeated a playlist page');
        }
        var merged = _nextPage == 1 ? <Video>[] : [..._playlist.videos];
        final identities =
            merged.map(playlistSourceEntryId).whereType<String>().toSet();
        for (final video in page.videos) {
          final identity = playlistSourceEntryId(video);
          if (identity == null || identities.add(identity)) merged.add(video);
        }
        merged = assignPlaylistEntryIds(merged);
        if (_nextPage > 1 &&
            merged.length == _playlist.videos.length &&
            page.videos.isNotEmpty) {
          throw StateError('The server did not advance the playlist');
        }
        _filtered += page.removedByFilter;
        _playlist = page.copyWith(videos: merged);
        _hasFreshPage = true;
        _nextPage++;
        _complete = _playlist.isLocal ||
            merged.length + _filtered >= page.videoCount ||
            (page.videos.isEmpty && page.removedByFilter == 0);
        _publish();
      }
    } catch (error) {
      if (_current(generation)) _error = error;
    } finally {
      if (!_ready.isCompleted && generation == _generation) _ready.complete();
      if (!_disposed && generation == _generation) {
        _loading = false;
        _publish();
      }
    }
  }
}
