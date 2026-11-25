part of 'player.dart';

const _musicRequestsPayload = 'musicRequests';
const _musicRequestsBoundary = ':music-requests:';

class _MusicRequest {
  final PlaybackSession song;
  IdedVideo? display;

  _MusicRequest(this.song, [this.display]);
}

class _MusicRequests {
  final PlayerCubit player;
  final revision = ValueNotifier<int>(0);
  final _pending = ListQueue<_MusicRequest>();
  PlaybackSession? _collection;
  String? _activeId;
  IDbClient? _loadedProfile;
  Object? _transition;
  int _nextOrdinal = DateTime.now().microsecondsSinceEpoch;

  _MusicRequests(this.player);

  List<IdedVideo> get pending => List.unmodifiable(
      _pending.map((request) => request.display).whereType<IdedVideo>());

  bool get playing => _collection != null;
  bool get _transitioning => _transition != null;

  bool get _eligible =>
      !player.isClosed &&
      !player._isDisposing &&
      !player._switchingProfile &&
      !player._sessionTransitionPending &&
      !player._backendSwitchPending &&
      PlayerCubit._sessionOwner == player &&
      player.activePodcast == null &&
      player._profileDatabase.profileId == db.profileId &&
      !player.state.isHidden &&
      !player.state.isClosing &&
      player._inMusicQueue;

  bool get canPlay =>
      _eligible && !_transitioning && !playing && _pending.isNotEmpty;

  bool canAdd(IdedVideo entry) =>
      _eligible && !_transitioning && _admit(entry) != null;

  IdedVideo? _admit(IdedVideo entry) {
    final database = player._profileDatabase;
    if (entry is Video) {
      if (entry.filtered || entry.filterHide || entry.isUpcoming == true) {
        return null;
      }
      if (devicePlaylistFileProof(entry.videoId) != null) {
        final track = LocalMusicLibrary.instance
            .playlistTrackById(entry.videoId, visibleOnly: true);
        return track == null
            ? null
            : localMusicPlaybackEntry(track, database.profileId);
      }
      if (entry.musicMetadata == null ||
          !DownloadedVideo.isSafeFileId(entry.videoId)) {
        return null;
      }
      if (entry.explicitMusicDownload == null) return entry;
      return player
          ._explicitDownload(entry)
          ?.copyWith(explicitMusicDownload: entry.explicitMusicDownload);
    }
    if (entry is! DownloadedVideo || entry.profileId != database.profileId) {
      return null;
    }
    if (isLocalMusicPlaybackId(entry.videoId)) {
      final library = LocalMusicLibrary.instance;
      if (!library.acceptsSessionSelection(library.selectionId)) return null;
      final track = library.visibleTrackById(localMusicTrackId(entry.videoId));
      return track == null || track.uri != entry.storageUri
          ? null
          : localMusicPlaybackEntry(track, database.profileId);
    }
    final fingerprint =
        entry.explicitMusicDownload ?? musicDownloadFingerprint(entry);
    final saved =
        readyMusicDownload(database, entry.videoId, fingerprint: fingerprint);
    return saved == null || !player._sameSavedMusicFile(entry, saved)
        ? null
        : saved.copyWith(explicitMusicDownload: fingerprint);
  }

  DownloadedVideo? _admitDevice(OnDeviceMusicEntry entry) =>
      player._resolveOnDeviceMusic(
          [entry], LocalMusicLibrary.instance.selectionId)?.single;

  bool canAddDevice(OnDeviceMusicEntry entry) =>
      _eligible && !_transitioning && _admitDevice(entry) != null;

  bool add(IdedVideo entry,
          {PlaylistReference? recommendationSource,
          String? inheritedSourceKey}) =>
      _eligible &&
      !_transitioning &&
      _append(_admit(entry), recommendationSource,
          inheritedSourceKey: inheritedSourceKey);

  bool addDevice(OnDeviceMusicEntry entry,
          {PlaylistReference? recommendationSource}) =>
      _eligible &&
      !_transitioning &&
      _append(_admitDevice(entry), recommendationSource);

  bool _append(IdedVideo? entry, PlaylistReference? recommendationSource,
      {String? inheritedSourceKey}) {
    if (entry == null) return false;
    final id = '${entry.videoId}#${++_nextOrdinal}';
    final database = player._profileDatabase;
    final owner = database.profileId;
    final sourceKey = inheritedSourceKey ??
        player._musicRecommendationSourceKey(recommendationSource);
    final recommendationSources = {if (sourceKey != null) id: sourceKey};
    final PlaybackSession song;
    final IdedVideo display;
    if (entry is Video) {
      final selected = entry.copyWith(queueEntryId: id);
      display = selected;
      song = PlaybackSession(
          ownerProfileId: owner,
          currentId: id,
          seconds: 0,
          audio: true,
          videos: [selected],
          musicRecommendationSources: recommendationSources,
          musicHistoryEntries: {id});
    } else {
      final file = entry as DownloadedVideo;
      final device = isLocalMusicPlaybackId(file.videoId);
      display =
          device ? file.copyWith(videoId: id) : file.copyWith(queueEntryId: id);
      song = PlaybackSession(
          ownerProfileId: owner,
          currentId: id,
          seconds: 0,
          audio: true,
          offlineIds: [id],
          localSelectionId:
              device ? LocalMusicLibrary.instance.selectionId : null,
          offlineFingerprints: {
            if (file.explicitMusicDownload case final fingerprint?)
              id: fingerprint,
          },
          musicRecommendationSources: recommendationSources,
          musicHistoryEntries: {id});
    }
    _pending.add(_MusicRequest(song, display));
    _changed();
    return true;
  }

  void remove(IdedVideo entry) {
    if (!_eligible || _transitioning) return;
    final request =
        _pending.where((item) => identical(item.display, entry)).firstOrNull;
    if (request != null && _pending.remove(request)) _changed();
  }

  Future<bool> start() async {
    if (!canPlay) return false;
    final checkpoint = player.captureMusicPlaybackCheckpoint();
    if (checkpoint == null) return false;
    return _playPending(checkpoint, begin: true, playing: true);
  }

  Future<bool> advance({required bool userInitiated}) async {
    final checkpoint = _collection;
    if (checkpoint == null || !_eligible || _transitioning) return false;
    final keepPlaying = !userInitiated || player.intendsPlayback;
    bool mayCommit() =>
        userInitiated ||
        (player.intendsPlayback &&
            !player.playbackInterrupted &&
            player.settings.state.autoplayQueue &&
            player._sleepAtEndQueueId == null);
    if (_pending.isNotEmpty &&
        await _playPending(checkpoint,
            begin: false, playing: keepPlaying, canCommit: mayCommit)) {
      return true;
    }
    if (mayCommit() && identical(checkpoint, _collection) && _pending.isEmpty) {
      return returnToCollection(playing: keepPlaying, canCommit: mayCommit);
    }
    return false;
  }

  Future<bool> _playPending(PlaybackSession collection,
      {required bool begin,
      required bool playing,
      bool Function()? canCommit}) async {
    final transition = _transition = Object();
    revision.value++;
    final database = player._profileDatabase;
    final previous = player.state.currentQueueId;
    bool current() =>
        !player.isClosed &&
        !player._isDisposing &&
        !player._switchingProfile &&
        !player.state.isHidden &&
        !player.state.isClosing &&
        identical(database, player._profileDatabase) &&
        database.profileId == db.profileId &&
        player.state.currentQueueId == previous &&
        identical(_transition, transition) &&
        canCommit?.call() != false;
    try {
      while (current() && _pending.isNotEmpty) {
        final request = _pending.first;
        if (request.song.hasDeviceEntries) {
          final library = LocalMusicLibrary.instance;
          await library.initialize();
          if (!current()) return false;
          if (library.acceptsSessionSelection(request.song.localSelectionId)) {
            await library
                .loadForPlayback([localMusicTrackId(request.song.currentId)]);
          }
          if (!current()) return false;
        }
        if (_display(request.song) == null) {
          _pending.removeFirst();
          _changed();
          continue;
        }
        return await player.restoreMusicPlaybackCheckpoint(request.song,
            playing: playing, canCommit: current, onCommit: () {
          _pending.removeFirst();
          if (begin) _collection = collection;
          _activeId = request.song.currentId;
          _transition = null;
          _changed(persist: false);
        });
      }
      return false;
    } catch (error) {
      log.fine('Could not play a Music request (${error.runtimeType})');
      return false;
    } finally {
      _endTransition(transition);
    }
  }

  Future<bool> returnToCollection(
      {bool? playing,
      bool Function()? canCommit,
      bool expandPlayer = false}) async {
    final checkpoint = _collection;
    if (checkpoint == null || (!expandPlayer && !_eligible) || _transitioning) {
      return false;
    }
    final transition = _transition = Object();
    revision.value++;
    try {
      return await player.restoreMusicPlaybackCheckpoint(checkpoint,
          playing: playing ?? player.intendsPlayback,
          expandPlayer: expandPlayer,
          canCommit: () =>
              identical(_collection, checkpoint) &&
              identical(_transition, transition) &&
              canCommit?.call() != false,
          onCommit: () {
            _activeId = null;
            _collection = null;
            _transition = null;
            _changed(persist: false);
          });
    } catch (error) {
      log.fine(
          'Could not resume the interrupted collection (${error.runtimeType})');
      return false;
    } finally {
      _endTransition(transition);
    }
  }

  Future<bool> resumeCollectionAfterUnavailableRequest(PlaybackSession saved) {
    restore(saved);
    if (_activeId != saved.currentId) return Future.value(false);
    return returnToCollection(
        playing: true,
        expandPlayer: true,
        canCommit: () => player.savedSession?.currentId == saved.currentId);
  }

  void _endTransition(Object transition) {
    if (!identical(_transition, transition)) return;
    _transition = null;
    if (!player._isDisposing) {
      observe(player.state);
      revision.value++;
    }
  }

  IdedVideo? _display(PlaybackSession song) {
    if (song.videos.singleOrNull case final video?) return video;
    final id = song.currentId;
    final database = player._profileDatabase;
    if (song.hasDeviceEntries) {
      final library = LocalMusicLibrary.instance;
      if (!library.acceptsSessionSelection(song.localSelectionId)) return null;
      final track = library.visibleTrackById(localMusicTrackId(id));
      return track == null
          ? null
          : localMusicPlaybackEntry(track, database.profileId,
              occurrenceId: id);
    }
    final source = savedDownloadSourceId(id);
    final fingerprint = song.offlineFingerprints[id];
    if (source == null || fingerprint == null) return null;
    return readyMusicDownload(database, source, fingerprint: fingerprint)
        ?.copyWith(queueEntryId: id, explicitMusicDownload: fingerprint);
  }

  void _changed({bool persist = true}) {
    revision.value++;
    _loadedProfile ??= player._profileDatabase;
    if (persist) unawaited(player._saveSession(player.state));
  }

  String encodeWithSession(String session) {
    if (_pending.isEmpty && _collection == null) return session;
    // The transport and its return point must survive process death together.
    // A named queue still contains only its own listening snapshot.
    final json = jsonDecode(session) as Map<String, dynamic>;
    json[_musicRequestsPayload] = {
      'pending': [
        for (final request in _pending)
          request.song.encode(portableArtwork: true),
      ],
      if (_collection != null && _activeId != null) ...{
        'return': _collection!.encode(portableArtwork: true),
        'active': _activeId,
      },
    };
    return jsonEncode(json);
  }

  void restore(PlaybackSession? activeSession) {
    final database = player._profileDatabase;
    if (identical(_loadedProfile, database)) return;
    _loadedProfile = database;
    _transition = null;
    _collection = null;
    _activeId = null;
    _pending.clear();
    PlaybackSession? decode(Object? value) {
      final song = value is String ? PlaybackSession.decode(value) : null;
      return song != null &&
              song.ownerProfileId == database.profileId &&
              song.audio
          ? song
          : null;
    }

    try {
      final raw = database.getSettings(playbackSessionSetting)?.value;
      final session =
          raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
      final json = session?[_musicRequestsPayload] as Map<String, dynamic>?;
      final collection = decode(json?['return']);
      final activeId = json?['active'];
      if (collection != null && activeId is String) {
        final contained = activeSession?.currentId == activeId ||
            (activeSession?.offlineIds.contains(activeId) ?? false) ||
            (activeSession?.videos
                    .any((video) => playbackQueueId(video) == activeId) ??
                false);
        if (contained) {
          _collection = collection;
          _activeId = activeId;
        }
      }
      for (final item in json?['pending'] as List? ?? const []) {
        final song = decode(item);
        if (song != null) _pending.add(_MusicRequest(song, _display(song)));
      }
    } on FormatException {
      // An unreadable draft must never keep regular playback from restoring.
    } on TypeError {
      // An older or malformed local value may have an unknown shape.
    }
    revision.value++;
    if (_pending.any((request) => request.song.hasDeviceEntries)) {
      unawaited(_loadDeviceLabels(database));
    }
  }

  Future<void> _loadDeviceLabels(IDbClient database) async {
    final library = LocalMusicLibrary.instance;
    try {
      await library.initialize();
      if (!identical(_loadedProfile, database) ||
          database.profileId != db.profileId ||
          player._isDisposing) {
        return;
      }
      await library.loadForPlayback(_pending
          .map((request) => request.song)
          .where((song) =>
              song.hasDeviceEntries &&
              library.acceptsSessionSelection(song.localSelectionId))
          .map((song) => localMusicTrackId(song.currentId)));
      if (!identical(_loadedProfile, database) ||
          database.profileId != db.profileId ||
          player._isDisposing) {
        return;
      }
      for (final request
          in _pending.where((item) => item.song.hasDeviceEntries)) {
        request.display = _display(request.song);
      }
      revision.value++;
    } catch (error) {
      log.fine('Could not load device request labels (${error.runtimeType})');
    }
  }

  void observe(PlayerState next) {
    final active = _activeId;
    final current = next.currentQueueId;
    if (active == null || current == null || _transitioning) return;
    final entries = [
      ...next.videos.map(playbackQueueId),
      ...next.offlineVideos.map(playbackQueueId),
    ];
    if (!entries.contains(current)) return;
    if (entries.contains(active)) {
      _activeId = current;
    } else {
      _activeId = null;
      _collection = null;
      _changed(persist: false);
    }
  }
}
