part of 'player.dart';

class _AdjacentSong {
  final IdedVideo entry;
  late final Future<IdedVideo?> preparation;
  IdedVideo? source;

  _AdjacentSong(this.entry);
}

/// Only the mounted audio decoder requests preparation. A playlist, a saved
/// session, or an ordinary video playing as audio never initiates Music reads.
class _AdjacentMusicPreparation {
  final PlayerCubit player;
  final _listeners = <ValueChanged<List<IdedVideo>>>{};
  final _songs = <String, _AdjacentSong>{};
  List<IdedVideo> _published = const [];
  StreamSubscription<PlayerRepeat>? _repeatChanges;
  bool _scheduled = false;
  Video? recentlyPlayed;

  _AdjacentMusicPreparation(this.player);

  void add(ValueChanged<List<IdedVideo>> listener) {
    if (!_listeners.add(listener)) return;
    if (_listeners.length == 1) {
      _repeatChanges = player.settings.stream
          .map((settings) => settings.playerRepeatMode)
          .distinct()
          .listen((_) => schedule());
    }
    listener(_published);
    schedule();
  }

  void remove(ValueChanged<List<IdedVideo>> listener) {
    _listeners.remove(listener);
    if (_listeners.isEmpty) {
      unawaited(_repeatChanges?.cancel());
      _repeatChanges = null;
      reset();
    }
  }

  void reset() {
    _songs.clear();
    recentlyPlayed = null;
    _publish();
  }

  void dispose() {
    reset();
    _listeners.clear();
    unawaited(_repeatChanges?.cancel());
  }

  bool get _active =>
      _listeners.isNotEmpty &&
      !player.isClosed &&
      !player._isDisposing &&
      !player._switchingProfile &&
      player._profileDatabase.profileId == db.profileId &&
      !NetworkProxy.instance.isChanging &&
      player.state.isAudio &&
      !player.state.isClosing &&
      !player.state.isHidden;

  void schedule() {
    if (_listeners.isEmpty || _scheduled) return;
    _scheduled = true;
    // Foreground switch commands are delivered through a Bloc stream. Let the
    // decoder take its prepared source before retiring the previous window.
    Timer.run(() {
      _scheduled = false;
      if (!_active) {
        reset();
        return;
      }
      if (player._sessionTransitionPending) return;
      final wanted = [
        for (final previous in [false, true])
          if (player.adjacentMusicEntry(previous: previous) case final entry?)
            entry,
      ];
      _songs.removeWhere((id, song) => !wanted.any((e) => e == song.entry));
      for (final entry in wanted) {
        final id = playbackQueueId(entry);
        if (_songs.containsKey(id)) continue;
        final song = _songs[id] = _AdjacentSong(entry);
        song.preparation = Future.microtask(() => _prepare(song));
      }
      _publish();
    });
  }

  void _publish() {
    final ready = [
      for (final song in _songs.values)
        if (song.source case final source?) source,
    ];
    if (listEquals(ready, _published)) return;
    _published = List.unmodifiable(ready);
    for (final listener in List.of(_listeners)) {
      listener(_published);
    }
  }

  Future<IdedVideo?> _prepare(_AdjacentSong song) async {
    final entry = song.entry;
    final id = playbackQueueId(entry);
    final database = db;
    final profile = db.profileId;
    final proxy = NetworkProxy.instance.config;
    bool current() =>
        _active &&
        identical(_songs[id], song) &&
        identical(database, db) &&
        db.profileId == profile &&
        identical(proxy, NetworkProxy.instance.config);
    try {
      if (!current()) return null;
      IdedVideo? resolved;
      if (entry is DownloadedVideo) {
        if (entry.profileId != profile || !entry.audioOnly) return null;
        if (isLocalMusicPlaybackId(entry.videoId)) {
          final track = localMusicTrackForPlayback(entry.videoId);
          if (track == null) return null;
          resolved = localMusicPlaybackEntry(track, profile, occurrenceId: id);
        } else {
          resolved = entry;
        }
      } else if (entry is Video && !isLocalMusicPlaybackId(entry.videoId)) {
        final selected = await database.getCurrentlySelectedServer();
        if (!current()) return null;
        final playing = player.state.currentlyPlaying;
        final route = playing?.playbackConnection ?? playing?.backendPlayback;
        if (route == null || !route.matches(selected)) return null;
        final saved = await prepareDownloadedPlaybackVideo(
            database: database,
            video: entry,
            server: selected,
            audioOnly: true,
            isCurrent: current);
        if (!current()) return null;
        if (saved != null) {
          resolved = saved;
        } else {
          if (entry.downloadPlaybackOnly) return null;
          final recent = recentlyPlayed;
          final cached =
              recent != null && playbackQueueId(recent) == id ? recent : entry;
          final connection =
              cached.playbackConnection ?? cached.backendPlayback;
          final video = !cached.downloadPlaybackOnly &&
                  cached.adaptiveFormats != null &&
                  cached.formatStreams != null &&
                  connection?.matches(selected) == true
              ? cached
              : await service.getMusicVideo(entry.videoId,
                  onBackendRequest: (request) {
                  // The active account may change between the local probe
                  // and the metadata service choosing its request route.
                  if (!current() || !request.matches(selected)) {
                    throw StateError('The Music playback connection changed.');
                  }
                },
                  loadObserver:
                      VideoLoadObserver(isCurrent: current, onRetry: () {}));
          if (!current() || video.videoId != entry.videoId) return null;
          final activeServer = await database.getCurrentlySelectedServer();
          final loadedRoute = video.playbackConnection ?? video.backendPlayback;
          if (!current() ||
              !route.matches(activeServer) ||
              loadedRoute?.matches(activeServer) != true) {
            return null;
          }
          resolved = video.preservingMusicMetadataFrom(entry);
        }
      }
      if (!current()) return null;
      song.source = resolved;
      _publish();
      return resolved;
    } catch (_) {
      // Speculation never changes the playing item. A real selection can use
      // its ordinary retry, error, download and backend recovery paths.
      return null;
    }
  }

  Future<Video?> forPlayback(Video entry, Video? downloaded) async {
    final song = _songs[playbackQueueId(entry)];
    if (!_active || song == null || song.entry != entry) return downloaded;
    // A newly finished download wins immediately, even while a speculative
    // online request is still in flight. Keep native identity when it is the
    // same complete and freshly admitted saved rendition.
    final source = downloaded == null ? await song.preparation : song.source;
    if (source is! Video ||
        !_active ||
        !identical(_songs[playbackQueueId(entry)], song)) {
      return downloaded;
    }
    if (downloaded != null &&
        (!source.downloadPlaybackOnly ||
            admittedMusicDownload(source) !=
                admittedMusicDownload(downloaded))) {
      return downloaded;
    }
    if (downloaded == null && source.downloadPlaybackOnly) return null;
    final route = source.playbackConnection ?? source.backendPlayback;
    if (route == null ||
        !route.matches(await db.getCurrentlySelectedServer())) {
      return downloaded;
    }
    return source;
  }
}
