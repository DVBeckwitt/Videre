part of 'player.dart';

extension AndroidMusicResumptionPlayer on PlayerCubit {
  /// Only the Android engine's shared phone player owns the system checkpoint.
  bool get _canResumeFromAndroid =>
      ownsAudioDecoder && androidAutoSession != null;

  String _resumeIdentity(List<Object?> fields) =>
      sha256.convert(utf8.encode(jsonEncode(fields))).toString();

  String _resumeServerIdentity(Server server) => _resumeIdentity(
      [server.profileId, server.accountId, server.url, server.gatewayEnabled]);

  String _resumeDeviceIdentity(LocalMusicTrack track) => _resumeIdentity([
        track.playbackId,
        track.uri,
        track.sourceUri?.toString(),
        track.sizeBytes,
        track.dateModified?.millisecondsSinceEpoch,
      ]);

  bool androidMusicResumeUsesRemote(Video? video) =>
      video != null && _androidRemoteOccurrence == playbackQueueId(video);

  /// Called when the decoder has admitted the actual source, including a
  /// fallback from an opportunistic saved copy to a network stream.
  void setAndroidMusicResumeSource({
    required String occurrence,
    required Video? video,
    required DownloadedVideo? offlineVideo,
    required bool usingSavedDownload,
    String? savedDownloadSha256,
  }) {
    if (!_canResumeFromAndroid ||
        state.isClosing ||
        state.isHidden ||
        !state.isAudio ||
        state.currentQueueId != occurrence ||
        !_isMusicEntry(video ?? offlineVideo)) {
      return;
    }
    final generation = _videoSwitchGeneration;
    final revision = _androidResumeRevision;
    final scope = androidAutoSession;
    bool current() =>
        androidAutoSession == scope &&
        generation == _videoSwitchGeneration &&
        revision == _androidResumeRevision &&
        state.isAudio &&
        !state.isClosing &&
        !state.isHidden &&
        state.currentQueueId == occurrence;
    void record(AndroidMusicResumption source) {
      if (!current()) return;
      _androidResumeSuppressed = false;
      _androidResumeSource = source;
      unawaited(_saveSession(state));
    }

    final id = video?.videoId ?? offlineVideo!.videoId;
    if (isLocalMusicPlaybackId(id)) {
      final track = localMusicTrackForPlayback(id);
      if (track != null) {
        record(AndroidMusicResumption(occurrence,
            AndroidMusicResumeSource.device, _resumeDeviceIdentity(track)));
      }
      return;
    }

    final explicit =
        video?.explicitMusicDownload ?? offlineVideo?.explicitMusicDownload;
    if (explicit != null || usingSavedDownload || offlineVideo != null) {
      final file =
          readyMusicDownload(_profileDatabase, id, fingerprint: explicit);
      final connection = video?.playbackConnection ?? video?.backendPlayback;
      if (file == null ||
          (offlineVideo != null &&
              musicDownloadFingerprint(offlineVideo) !=
                  musicDownloadFingerprint(file)) ||
          (usingSavedDownload &&
              (connection == null ||
                  file.accountId != connection.preferredServer.accountId ||
                  savedDownloadSha256 == null ||
                  savedDownloadSha256 != file.playbackProvenance?.sha256))) {
        return;
      }
      unawaited(() async {
        final proof = await DownloadStorage().musicFileProof(file);
        final pin =
            proof == null ? null : musicDownloadFileFingerprint(file, proof);
        final expected =
            explicit == null ? null : pinnedMusicDownloadFileProof(explicit);
        if (pin == null || (expected != null && expected != proof)) return;
        record(AndroidMusicResumption(
            occurrence, AndroidMusicResumeSource.download, pin));
      }());
      return;
    }

    final server = (video?.backendPlayback ?? video?.playbackConnection)
            ?.preferredServer ??
        settings.appCubit.state.server;
    if (server != null && server.profileId == _profileDatabase.profileId) {
      record(AndroidMusicResumption(occurrence, AndroidMusicResumeSource.online,
          _resumeServerIdentity(server),
          authenticated: hasHistoryAccount(server)));
    }
  }

  void _finishAndroidMusicResumeStart() {
    _androidResumeStarting = false;
    _androidResumeStartupTimer?.cancel();
    _androidResumeStartupTimer = null;
  }

  void cancelPendingAndroidMusicResumption() {
    _finishAndroidMusicResumeStart();
    _androidResumeRevision++;
  }

  Future<void> stopFromAndroidTransport() async {
    hide();
    await PlayerCubit._sessionWrite;
  }

  /// Revoke only OS-initiated playback. The saved queue remains available
  /// through the app's explicit Resume action and through named queues.
  Future<void> revokeAndroidMusicResumption() async {
    if (!ownsAudioDecoder) return;
    _androidResumeSuppressed = true;
    _androidResumeSource = null;
    _androidRemoteOccurrence = null;
    cancelPendingAndroidMusicResumption();
    final database = _profileDatabase;
    await PlayerCubit._queueSessionWrite(() async {
      final value = database.getSettings(playbackSessionSetting)?.value;
      final stored = PlaybackSession.decode(value);
      if (stored?.androidResumption != null) {
        final json = jsonDecode(value!) as Map<String, dynamic>;
        json.remove('androidResumption');
        await database.saveSetting(
            SettingsValue(playbackSessionSetting, jsonEncode(json)));
      }
    }).catchError((Object _) {});
  }

  PlaybackSession? get _androidResumeCheckpoint {
    if (!_canResumeFromAndroid ||
        !_rememberMusicQueue ||
        _androidResumeSuppressed ||
        state.isClosing ||
        activePodcast != null) {
      return null;
    }
    final saved = savedSession;
    if (saved == null ||
        saved.ownerProfileId != _profileDatabase.profileId ||
        saved.androidResumption?.occurrence != saved.currentId ||
        saved.positionMilliseconds == null ||
        [
              ...saved.videos.map(playbackQueueId),
              ...saved.offlineIds,
            ].where((id) => id == saved.currentId).length !=
            1) {
      return null;
    }
    return saved;
  }

  bool _matchesResumeServer(Server? server, AndroidMusicResumption request) =>
      server != null &&
      server.profileId == _profileDatabase.profileId &&
      _resumeServerIdentity(server) == request.identity &&
      hasHistoryAccount(server) == request.authenticated;

  DownloadedVideo? _androidResumeFile(PlaybackSession checkpoint) {
    final source = checkpoint.androidResumption!;
    final id = checkpoint.currentSavedDownloadId ??
        checkpoint.videos
            .where((video) => playbackQueueId(video) == checkpoint.currentId)
            .firstOrNull
            ?.videoId;
    return id == null
        ? null
        : readyMusicDownload(_profileDatabase, id,
            fingerprint: source.identity);
  }

  Future<LocalMusicTrack?> _androidResumeDeviceTrack(
      PlaybackSession checkpoint, bool Function() current) async {
    final library = LocalMusicLibrary.instance;
    if (!isLocalMusicPlaybackId(checkpoint.currentId)) return null;
    await library.initialize();
    await library.revalidate();
    if (!current() ||
        !library.acceptsSessionSelection(checkpoint.localSelectionId)) {
      return null;
    }
    await library.loadForPlayback([localMusicTrackId(checkpoint.currentId)]);
    final track = localMusicTrackForPlayback(checkpoint.currentId);
    return current() &&
            library.acceptsSessionSelection(checkpoint.localSelectionId) &&
            track != null &&
            _resumeDeviceIdentity(track) ==
                checkpoint.androidResumption!.identity
        ? track
        : null;
  }

  Future<MediaItem?> androidRecentMusic() async {
    final checkpoint = _androidResumeCheckpoint;
    if (checkpoint == null) return null;
    final scope = androidAutoSession;
    final revision = _androidResumeRevision;
    bool current() =>
        androidAutoSession == scope && revision == _androidResumeRevision;
    try {
      checkpoint.playlistReference?.resolveServer(_profileDatabase);
      final source = checkpoint.androidResumption!;
      MusicMetadata? music;
      switch (source.source) {
        case AndroidMusicResumeSource.device:
          final track = await _androidResumeDeviceTrack(checkpoint, current);
          if (track != null) {
            music = localMusicPlaybackEntry(track, _profileDatabase.profileId,
                    occurrenceId: checkpoint.currentId)
                .musicMetadata;
          }
        case AndroidMusicResumeSource.download:
          final file = _androidResumeFile(checkpoint);
          if (file != null &&
              await DownloadStorage().musicFileProof(file) ==
                  pinnedMusicDownloadFileProof(source.identity)) {
            music = file.musicMetadata;
          }
        case AndroidMusicResumeSource.online:
          final server = await _profileDatabase.getCurrentlySelectedServer();
          if (_matchesResumeServer(server, source)) {
            music = checkpoint.videos
                .where(
                    (video) => playbackQueueId(video) == checkpoint.currentId)
                .firstOrNull
                ?.musicMetadata;
          }
      }
      final latest = _androidResumeCheckpoint?.androidResumption;
      if (!current() ||
          latest?.occurrence != source.occurrence ||
          latest?.source != source.source ||
          latest?.identity != source.identity ||
          music == null ||
          music.title.trim().isEmpty) {
        return null;
      }
      final artist = music.artist.trim();
      return MediaItem(
        id: 'system-resume:${_resumeIdentity([
              checkpoint.ownerProfileId,
              source.occurrence,
              source.identity,
            ])}',
        title: music.title,
        artist: artist.isEmpty ? 'Videre' : artist,
        album: music.album,
        artUri: Uri.parse(
            'android.resource://${packageInfo!.packageName}/mipmap/ic_launcher'),
        playable: true,
      );
    } catch (error) {
      log.fine('Could not read recent Music (${error.runtimeType})');
      return null;
    }
  }

  /// Only the media handler calls this, after a positive Android transport
  /// request. Browsing the recent root and normal app startup stay silent.
  Future<bool> resumeMusicFromAndroid(
      Future<bool> Function() enterForeground) async {
    await _playerReady;
    final checkpoint = _androidResumeCheckpoint;
    if (checkpoint == null ||
        state.hasVideo ||
        !state.isHidden ||
        _backendSwitchPending ||
        _sessionTransitionPending) {
      return false;
    }
    final source = checkpoint.androidResumption!;
    final scope = androidAutoSession;
    final revision = _androidResumeRevision;
    final generation = _videoSwitchGeneration;
    bool allowed() =>
        scope != null &&
        androidAutoSession == scope &&
        revision == _androidResumeRevision &&
        _rememberMusicQueue &&
        activePodcast == null;
    try {
      if (!await enterForeground() ||
          !allowed() ||
          generation != _videoSwitchGeneration ||
          state.hasVideo) {
        return false;
      }
      _androidResumeStarting = true;
      final restored = await _restoreMusicPlaybackCheckpoint(checkpoint,
          playing: true,
          namedId: checkpoint.namedQueueId,
          expandPlayer: false,
          canCommit: allowed, onCommit: () {
        _androidRemoteOccurrence =
            source.source == AndroidMusicResumeSource.online
                ? source.occurrence
                : null;
        _androidResumeSource = source;
        _androidResumeStartupTimer = Timer(const Duration(seconds: 15), () {
          if (!allowed() || state.currentQueueId != source.occurrence) return;
          _finishAndroidMusicResumeStart();
          if (state.isPlaying) return;
          pause();
          setEvent(const MediaEvent(state: MediaState.error));
        });
      }, resolveSystemSource: (entry, current) async {
        switch (source.source) {
          case AndroidMusicResumeSource.device:
            final track = await _androidResumeDeviceTrack(checkpoint, current);
            return track == null || entry is! DownloadedVideo
                ? null
                : (entry: entry, resolved: null);
          case AndroidMusicResumeSource.download:
            final file = _androidResumeFile(checkpoint);
            if (file == null ||
                await DownloadStorage().musicFileProof(file) !=
                    pinnedMusicDownloadFileProof(source.identity) ||
                !current()) {
              return null;
            }
            return switch (entry) {
              Video() => (
                  entry: entry,
                  resolved:
                      entry.copyWith(explicitMusicDownload: source.identity)
                ),
              DownloadedVideo() => (
                  entry: entry.copyWith(explicitMusicDownload: source.identity),
                  resolved: null
                ),
              _ => null,
            };
          case AndroidMusicResumeSource.online:
            final server = await _profileDatabase.getCurrentlySelectedServer();
            if (entry is! Video ||
                entry.explicitMusicDownload != null ||
                !_matchesResumeServer(server, source) ||
                !current() ||
                (source.authenticated &&
                    !await service.validateCurrentSession()) ||
                !current()) {
              return null;
            }
            final resolved = await _resolvePlaybackVideo(entry,
                audio: true,
                active: current,
                backendRequest: BackendPlayback(server));
            return resolved == null || !current()
                ? null
                : (entry: entry, resolved: resolved);
        }
      }).timeout(const Duration(seconds: 15), onTimeout: () {
        if (allowed() && state.currentQueueId != source.occurrence) {
          cancelPendingAndroidMusicResumption();
        }
        return state.currentQueueId == source.occurrence;
      });
      if (!restored && allowed()) _finishAndroidMusicResumeStart();
      return restored;
    } catch (error) {
      if (allowed()) _finishAndroidMusicResumeStart();
      log.fine('Could not resume Android Music (${error.runtimeType})');
      return false;
    }
  }
}
