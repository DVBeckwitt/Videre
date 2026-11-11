import 'dart:async';
import 'dart:collection';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:back_button_interceptor/back_button_interceptor.dart';
import 'package:bloc/bloc.dart';
import 'package:clipious/player/models/sleep_timer.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/invidious_image.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:logging/logging.dart';
import 'package:simple_pip_mode/simple_pip.dart';

import '../../downloads/models/downloaded_video.dart';
import '../../playlists/models/playlist.dart';
import '../../playlists/models/playlist_reference.dart';
import '../../playlists/services/playlist_load_session.dart';
import '../../playlists/services/playlist_progress.dart';
import '../../main.dart';
import '../../media_handler.dart';
import '../../service.dart' show VideoLoadObserver;
import '../../settings/models/db/settings.dart';
import '../../settings/models/db/server.dart';
import '../../utils/interfaces/db.dart';
import '../../videos/services/watch_history.dart';
import '../../settings/states/settings.dart';
import '../../utils/models/pair.dart';
import '../../videos/models/db/progress.dart' as db_progress;
import '../../videos/models/db/progress.dart' show playbackHistoryRevision;
import '../../videos/models/db/history_video_cache.dart';
import '../../videos/models/sponsor_segment.dart';
import '../../videos/models/sponsor_segment_types.dart';
import '../../videos/models/video.dart';
import '../models/playback_session.dart';
import '../models/playback_queue.dart';
import '../models/playback_pitch.dart';
import '../models/backend_playback.dart';
import '../models/backend_recovery.dart';
import '../models/playback_recovery.dart';

export '../../videos/models/db/progress.dart' show playbackHistoryRevision;

part 'player.freezed.dart';

const double targetHeight = 66;
const skipToVideoThrottleName = 'skip-to-video';
const stepMultiplier = 1.15;

const maxInt = -1 >>> 1;

var log = Logger('MiniPlayerController');

enum PlayerRepeat { noRepeat, repeatAll, repeatOne }

class _PlaybackRefreshRequest {
  final Video video;
  final int generation;
  final observers = <bool Function()>{};
  late final Future<Video?> result;

  _PlaybackRefreshRequest(this.video, this.generation);

  bool get active => observers.any((observer) => observer());
}

class PlayerCubit extends Cubit<PlayerState> with WidgetsBindingObserver {
  static PlayerCubit? _sessionOwner;
  String? _pitchVideoId;
  String? _speedVideoId;
  static Future<void> _sessionWrite = Future.value();
  final SettingsCubit settings;
  final PlaylistReference? _initialPlaylistReference;
  final PlaylistLoadSession? _initialPlaylistLoader;
  final int _initialPlaylistIndex;
  final bool? _initialPlaylistAudio;
  PlaylistReference? _playlistReference;
  PlaylistLoadSession? _playlistLoader;
  StreamSubscription<PlaylistLoadSnapshot>? _playlistLoadSubscription;
  final _playlistEntries = LinkedHashMap<String, Video>();
  int _playlistGeneration = 0;
  bool _waitingForPlaylist = false;
  bool _playlistSourceComplete = true;
  bool _sessionTransitionPending = false;
  String? _playlistCheckpointSignature;
  final playlistLoadingRevision = ValueNotifier(0);

  PlaylistReference? get playlistReference => _playlistReference;
  int get playlistGeneration => _playlistGeneration;
  bool get isPlaylistLoading => _playlistLoader?.loading ?? false;
  bool get playlistComplete =>
      _playlistReference == null ||
      (_playlistLoader?.complete ?? _playlistSourceComplete);
  Object? get playlistLoadingError => _playlistLoader?.error;
  late IDbClient _profileDatabase;
  WatchRepository? _watchRepository;
  Server? _watchAccount;
  String? _watchVideoId;
  int? _watchRevision;
  bool _switchingProfile = false;
  MediaHandler? _mediaSessionHandler;
  final _beforeProfileSwitch = <AsyncCallback>{};
  Future<void> _watchBinding = Future.value();
  late final AudioSession _audioSession;
  bool _hasAudioSession = false;
  AudioSession get audioSession => _audioSession;
  set audioSession(AudioSession value) {
    _audioSession = value;
    _hasAudioSession = true;
  }

  bool? _requestedPlaying;
  bool _playbackInterrupted = false;
  AudioInterruptionType? _audioInterruptionType;
  bool _videoFocusActivationRequired = false;
  final Future<bool> Function()? _activateVideoFocus;
  int _audioFocusRevision = 0;
  bool _resumePlaybackAfterInterruption = false;
  bool _resumeReplacedAudioAfterInterruption = false;
  int _transportIntentRevision = 0;
  int? _interruptionIntentRevision;
  int? _interruptionVideoGeneration;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  int _progressGeneration = 0;
  int _videoSwitchGeneration = 0;
  int _sponsorRequestGeneration = 0;
  String? _requestedBackendVideoId;
  bool _backendSwitchPending = false;
  bool _manualSelectionPending = false;
  Future<void>? _currentVideoRetry;
  int? _currentVideoRetryGeneration;
  PlaybackRecoveryBudget _playbackRecoveryBudget = PlaybackRecoveryBudget();
  _PlaybackRefreshRequest? _playbackRefresh;
  Video? _recoveringVideo;
  Duration? _recoveryProgressPosition;
  final Future<void> Function(Duration) _waitForPlaybackRecovery;
  Timer? _backendSuccessTimer;
  final _timers = <String, Timer>{};
  Duration? _backendProgressPosition;

  /// The current user's play/pause intent also applies to a replacement source.
  bool get requestedPlaying => _requestedPlaying ?? state.isPlaying;
  bool get playbackInterrupted =>
      _playbackInterrupted &&
      (!state.isAudio || _audioInterruptionType != AudioInterruptionType.duck);
  bool get shouldStartPlayback =>
      _requestedPlaying != false &&
      !playbackInterrupted &&
      (state.isAudio || !_videoFocusActivationRequired);

  void attachMediaHandler(MediaHandler handler) {
    _mediaSessionHandler = handler;
  }

  void addBeforeProfileSwitch(AsyncCallback callback) =>
      _beforeProfileSwitch.add(callback);

  void removeBeforeProfileSwitch(AsyncCallback callback) =>
      _beforeProfileSwitch.remove(callback);

  /// Changes before a new video's metadata is awaited, invalidating the old
  /// decoder's pending backend recovery as well as its native callbacks.
  int get backendPlaybackGeneration => _videoSwitchGeneration;
  bool _isDisposing = false;
  StreamSubscription<void>? _becomingNoisySubscription;
  final bool _resumeOnReady;
  static const _pipChannel = MethodChannel('videre/pip');
  SimplePip? _pip;

  PlayerCubit(super.initialState, this.settings,
      {bool resume = false,
      PlaylistReference? playlistReference,
      PlaylistLoadSession? playlistLoader,
      int startIndex = 0,
      bool? playlistAudio,
      Future<void> Function(Duration)? playbackRecoveryDelay,
      Future<bool> Function()? videoFocusActivation})
      : _resumeOnReady = resume,
        _activateVideoFocus = videoFocusActivation,
        _waitForPlaybackRecovery =
            playbackRecoveryDelay ?? Future<void>.delayed,
        _initialPlaylistReference = playlistReference,
        _initialPlaylistLoader = playlistLoader,
        _initialPlaylistIndex = startIndex,
        _initialPlaylistAudio = playlistAudio {
    _profileDatabase = db.forProfile(db.profileId);
    // Metadata can be pending before any decoder mounts and registers its own
    // native teardown. The parent must invalidate that pending work as well.
    NetworkProxy.instance.addBeforeApply(_proxyChanging);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android && !isTv) {
      _pip = SimplePip(
        onPipEntered: () => _setPip(true),
        onPipExited: () => _setPip(false),
      );
      unawaited(_updateAutoPip(state));
    }
    onReady();
  }

  Future<void> _proxyChanging() async {
    if (isClosed) return;
    if (state.isHidden && !state.hasVideo) {
      // A restored queue is dormant, not active playback. Invalidate pending
      // intents without clearing it or starting a closing animation.
      _progressGeneration++;
      _videoSwitchGeneration++;
      return;
    }
    hide();
  }

  PlaybackSession? get savedSession => PlaybackSession.decode(
      _profileDatabase.getSettings(playbackSessionSetting)?.value);

  void _bindPlaylist(PlaylistReference? reference, List<Video> entries,
      {PlaylistLoadSession? loader,
      Iterable<Video>? sourceEntries,
      bool complete = true}) {
    // A new request can reuse the loader currently owned only by this player.
    // Retain it before releasing the previous request's ownership.
    loader?.retain();
    _releasePlaylistLoader();
    final generation = _playlistGeneration;
    _playlistLoader = loader;
    _playlistSourceComplete = complete;
    _playlistReference = reference;
    _playlistCheckpointSignature = null;
    _playlistEntries
      ..clear()
      ..addEntries((sourceEntries ?? entries)
          .map((video) => MapEntry(playbackQueueId(video), video)));
    if (reference != null && loader != null) {
      _playlistLoadSubscription = loader.changes.listen((snapshot) {
        if (isClosed || generation != _playlistGeneration) return;
        appendPlaylistVideos(snapshot.playlist.videos,
            reference: reference, generation: generation);
        if (snapshot.complete) unawaited(_saveSession(state));
        playlistLoadingRevision.value++;
        if (_waitingForPlaylist &&
            (state.playQueue.isNotEmpty || snapshot.complete)) {
          _waitingForPlaylist = false;
          unawaited(_playNextNow());
        }
      });
    }
    if (!_isDisposing) playlistLoadingRevision.value++;
  }

  void _releasePlaylistLoader() {
    _playlistGeneration++;
    _waitingForPlaylist = false;
    unawaited(_playlistLoadSubscription?.cancel());
    _playlistLoadSubscription = null;
    _playlistSourceComplete = playlistComplete;
    _playlistLoader?.release();
    _playlistLoader = null;
  }

  /// A late page belongs only to the playback request that retained its loader.
  /// Keep all previously seen IDs, including entries removed from the queue,
  /// so an overlapping or retried page cannot restore a removed item.
  bool appendPlaylistVideos(List<Video> videos,
      {required PlaylistReference reference, required int generation}) {
    if (isClosed ||
        _switchingProfile ||
        state.isClosing ||
        generation != _playlistGeneration ||
        _playlistReference != reference ||
        reference.profileId != _profileDatabase.profileId) return false;
    final additions = <Video>[];
    final byVideo = <String, List<Video>>{};
    for (final entry in _playlistEntries.values) {
      byVideo.putIfAbsent(entry.videoId, () => []).add(entry);
    }
    final occurrences = <String, int>{};
    for (final video in videos) {
      final occurrence = occurrences.update(video.videoId, (value) => value + 1,
          ifAbsent: () => 0);
      final candidates = byVideo[video.videoId] ?? const <Video>[];
      final stableId = video.indexId;
      final stable = stableId == null
          ? null
          : candidates.where((entry) => entry.indexId == stableId).firstOrNull;
      final ordinal =
          occurrence < candidates.length ? candidates[occurrence] : null;
      // Public playlist indices shift when the source is edited. The saved
      // queue remains a snapshot; refetching its pages must not duplicate those
      // occurrences or resurrect a user-removed item just because its index moved.
      if (stable != null ||
          (ordinal != null && (stableId == null || ordinal.indexId == null)))
        continue;
      final id = playbackQueueId(video);
      if (_playlistEntries.containsKey(id)) continue;
      _playlistEntries[id] = video;
      if (!video.filtered && !video.filterHide && video.isUpcoming != true) {
        additions.add(video);
      }
    }
    if (additions.isNotEmpty) {
      final next = additions.map(playbackQueueId).toList();
      if (settings.state.playerShuffleMode) next.shuffle();
      emit(state.copyWith(
          videos: [...state.videos, ...additions],
          playQueue: ListQueue.of([...state.playQueue, ...next])));
    }
    return true;
  }

  void retryPlaylistLoading() {
    final loader = _playlistLoader;
    if (loader != null) unawaited(loader.retry());
  }

  Future<void> _savePlaylistCheckpoint(Video entry,
      {required int generation,
      required int? watchRevision,
      required List<Video> entries,
      required bool audio,
      bool completed = false}) async {
    final reference = _playlistReference;
    if (reference == null ||
        !_playlistEntries.containsKey(playbackQueueId(entry))) return;
    final signature =
        '${playbackQueueId(entry)}:$completed:$audio:${entries.length}:$watchRevision';
    if (_playlistCheckpointSignature == signature) return;
    final repository = _watchRepository;
    bool active() =>
        !isClosed &&
        !_isDisposing &&
        !_switchingProfile &&
        !_sessionTransitionPending &&
        state.isAudio == audio &&
        generation == _playlistGeneration &&
        reference == _playlistReference &&
        (repository == null ||
            watchRevision != null &&
                repository.acceptsPlayback(entry.videoId, watchRevision));
    if (!active()) return;
    _playlistCheckpointSignature = signature;
    try {
      final accepted = await PlaylistProgressService.forProfile(
              _profileDatabase, _profileDatabase.profileId)
          .save(reference, entry,
              entries: entries,
              audio: audio,
              completed: completed,
              watchRevision: watchRevision,
              isCurrent: active);
      if (!accepted &&
          generation == _playlistGeneration &&
          reference == _playlistReference &&
          _playlistCheckpointSignature == signature) {
        _playlistCheckpointSignature = null;
      }
    } catch (error) {
      if (generation == _playlistGeneration &&
          reference == _playlistReference &&
          _playlistCheckpointSignature == signature) {
        _playlistCheckpointSignature = null;
      }
      log.warning('Could not save playlist position', error);
    }
  }

  @override
  void onChange(Change<PlayerState> change) {
    super.onChange(change);
    final before = change.currentState;
    final after = change.nextState;
    if (_autoPipEnabled(before) != _autoPipEnabled(after) ||
        before.aspectRatio != after.aspectRatio) {
      unawaited(_updateAutoPip(after));
    }
    if (after.hasVideo &&
        (before.currentlyPlaying != after.currentlyPlaying ||
            before.offlineCurrentlyPlaying != after.offlineCurrentlyPlaying)) {
      _sessionOwner = this;
    }
    if (before.videos != after.videos ||
        before.offlineVideos != after.offlineVideos ||
        before.currentlyPlaying != after.currentlyPlaying ||
        before.offlineCurrentlyPlaying != after.offlineCurrentlyPlaying ||
        before.playQueue != after.playQueue ||
        before.isAudio != after.isAudio ||
        before.position.inSeconds ~/ 5 != after.position.inSeconds ~/ 5) {
      unawaited(_saveSession(after));
    }
  }

  Future<void> _saveSession(PlayerState snapshot) {
    final id = snapshot.currentlyPlaying?.videoId ??
        snapshot.offlineCurrentlyPlaying?.videoId;
    if (id == null ||
        _sessionTransitionPending ||
        _sessionOwner != this ||
        ![
          ...snapshot.videos,
          ...snapshot.offlineVideos
        ].any((video) => playbackQueueId(video) == snapshot.currentQueueId)) {
      return _sessionWrite;
    }
    final queueId = snapshot.currentQueueId!;
    final database = _profileDatabase;
    final watchRepository = _watchRepository;
    final watchRevision = _watchRevision;
    final setting = SettingsValue(
        playbackSessionSetting,
        PlaybackSession(
          videos: snapshot.videos
              .map((v) => playbackQueueId(v) == queueId
                  ? (snapshot.currentlyPlaying ?? v)
                      .copyWith(index: v.index, indexId: v.indexId)
                  : v)
              .toList(),
          offlineIds: snapshot.offlineVideos.map((v) => v.videoId).toList(),
          currentId: queueId,
          seconds: snapshot.position.inSeconds,
          audio: snapshot.isAudio,
          played: snapshot.playedVideos,
          next: snapshot.playQueue.toList(),
          playlistReference: _playlistReference,
          playlistEntries: _playlistEntries.values.toList(),
          playlistComplete: playlistComplete,
        ).encode());
    // An older TV screen may close after its replacement has begun playing.
    return _sessionWrite = _sessionWrite.then((_) async {
      if (_sessionOwner == this) {
        if (watchRepository != null && watchRevision != null) {
          await watchRepository.saveSessionIfCurrent(
              id, watchRevision, setting);
        } else {
          await database.saveSetting(setting);
        }
      }
    }).catchError((Object error) {
      log.warning('Could not save playback session', error);
    });
  }

  void restoreSession() {
    final saved = savedSession;
    if (saved == null) return;
    _sessionTransitionPending = false;
    _bindPlaylist(
        saved.playlistReference?.profileId == _profileDatabase.profileId
            ? saved.playlistReference
            : null,
        saved.videos,
        complete: saved.playlistComplete,
        sourceEntries:
            saved.playlistEntries.isEmpty ? null : saved.playlistEntries);
    final offline = saved.offlineIds
        .map(_profileDatabase.getDownloadByVideoId)
        .whereType<DownloadedVideo>()
        .where((v) => v.downloadComplete)
        .toList();
    final ids = {
      ...saved.videos.map(playbackQueueId),
      ...offline.map((v) => v.videoId)
    };
    // Keep the player hidden until Resume is pressed; restoring must be silent.
    _requestedBackendVideoId = null;
    _clearBackendProgress();
    emit(state.copyWith(
        backendRecovery: null,
        videos: saved.videos,
        offlineVideos: offline,
        currentlyPlaying: null,
        requestedBackend: null,
        offlineCurrentlyPlaying: null,
        position: Duration(seconds: saved.seconds),
        startAt: Duration(seconds: saved.seconds),
        isHidden: true,
        playedVideos: saved.played.where(ids.contains).toList(),
        playQueue: ListQueue.from(saved.next.where(ids.contains)),
        isAudio: saved.audio));
  }

  Future<void> resumeSession() async {
    _requestedPlaying = null;
    final saved = savedSession;
    if (saved == null) return;
    restoreSession();
    final videos = state.videos.isNotEmpty ? state.videos : state.offlineVideos;
    final current =
        videos.where((v) => playbackQueueId(v) == saved.currentId).firstOrNull;
    if (current == null) return;
    final reference = _playlistReference;
    if (reference != null && !saved.playlistComplete) {
      final sourceEntries = _playlistEntries.values.toList();
      _bindPlaylist(reference, state.videos,
          sourceEntries: sourceEntries,
          loader: PlaylistLoadSession(
              playlist: Playlist(
                  title: reference.playlistId,
                  playlistId: reference.playlistId,
                  author: '',
                  videoCount: sourceEntries.length,
                  videos: sourceEntries),
              database: _profileDatabase,
              reference: reference));
    }
    showBigPlayer();
    await _switchToVideo(current, startAt: Duration(seconds: saved.seconds));
  }

  Future<void> playRemoteVideo(String videoId, int position, bool playing,
      {bool Function()? isActive}) async {
    final generation = _videoSwitchGeneration;
    final video =
        await service.getVideo(videoId).timeout(const Duration(seconds: 10));
    if (isClosed ||
        generation != _videoSwitchGeneration ||
        (isActive != null && !isActive())) {
      return;
    }
    await playVideo([
      video.copyWith(
        formatStreams: video.formatStreams ?? [],
        adaptiveFormats: video.adaptiveFormats ?? [],
      )
    ], startAt: Duration(seconds: position), playing: playing);
  }

  bool setRequestedBackend(String videoId, BackendPlayback? request) {
    // The old decoder may still report progress while the same video reloads.
    // Until metadata returns, only the new load's observer owns this status.
    if (isClosed ||
        _isDisposing ||
        _backendSwitchPending ||
        state.isClosing ||
        state.offlineCurrentlyPlaying != null ||
        (_requestedBackendVideoId ?? state.currentlyPlaying?.videoId) !=
            videoId) {
      return false;
    }
    _recordBackendRequest(videoId, request);
    return true;
  }

  void _recordBackendRequest(String videoId, BackendPlayback? request) {
    var recovery = state.backendRecovery;
    if (request != null &&
        (request.retryIndex > 0 || request.manualSelection) &&
        !identical(recovery?.request, request) &&
        !identical(state.requestedBackend, request)) {
      _clearBackendProgress();
      recovery = BackendRecovery(
          phase: BackendRecoveryPhase.trying,
          request: request,
          videoId: videoId,
          manual: request.manualSelection);
    }
    emit(state.copyWith(requestedBackend: request, backendRecovery: recovery));
  }

  void _clearBackendProgress() {
    _backendSuccessTimer?.cancel();
    _backendSuccessTimer = null;
    _backendProgressPosition = null;
  }

  bool _isRecoveryAttempt(String videoId, BackendPlayback? request) =>
      !isClosed &&
      !_isDisposing &&
      !_backendSwitchPending &&
      !state.isClosing &&
      state.offlineCurrentlyPlaying == null &&
      state.currentlyPlaying?.videoId == videoId &&
      request != null &&
      identical(state.requestedBackend, request) &&
      identical(state.backendRecovery?.request, request) &&
      state.backendRecovery?.videoId == videoId;

  /// Keep the active metadata with its decoder so switching video/audio modes
  /// starts from the recovered backend instead of the source that failed.
  void reportBackendVideoLoaded(Video video) {
    if (!_isRecoveryAttempt(video.videoId, video.backendPlayback)) return;
    final current = state.currentlyPlaying;
    if (current != null) video = video.preservingMusicMetadataFrom(current);
    emit(state.copyWith(currentlyPlaying: video));
  }

  bool _samePlaybackSource(Video first, Video second) =>
      first.videoId == second.videoId &&
      playbackQueueId(first) == playbackQueueId(second) &&
      (first.playbackSourceId != null
          ? identical(first.playbackSourceId, second.playbackSourceId)
          : identical(first, second));

  bool _currentPlaybackSource(Video video) =>
      !isClosed &&
      !_isDisposing &&
      !_switchingProfile &&
      !_backendSwitchPending &&
      !state.isClosing &&
      !state.isHidden &&
      state.offlineCurrentlyPlaying == null &&
      state.currentlyPlaying != null &&
      _samePlaybackSource(video, state.currentlyPlaying!);

  void _clearPlaybackRecovery({bool resetBudget = false}) {
    if (resetBudget) _playbackRecoveryBudget = PlaybackRecoveryBudget();
    _recoveringVideo = null;
    _recoveryProgressPosition = null;
    if (!isClosed && state.recoveringPlayback) {
      emit(state.copyWith(recoveringPlayback: false));
    }
  }

  /// Refreshes only the admitted source for the current queue occurrence.
  /// Null means the shared automatic budget is exhausted; refusals throw.
  Future<Video?> refreshCurrentPlayback(Video video,
      {required bool Function() isCurrent}) async {
    if (!_currentPlaybackSource(video) || !isCurrent()) {
      throw StateError('The playback source changed.');
    }
    var pending = _playbackRefresh;
    if (pending != null && pending.generation == _videoSwitchGeneration) {
      if (!_samePlaybackSource(pending.video, video)) {
        throw StateError('Another playback recovery is in progress.');
      }
    } else {
      pending = _PlaybackRefreshRequest(video, _videoSwitchGeneration);
      _playbackRefresh = pending;
    }
    final request = pending;
    final first = request.observers.isEmpty;
    request.observers.add(isCurrent);
    if (first) {
      request.result = _refreshCurrentPlayback(request).whenComplete(() {
        if (identical(_playbackRefresh, request)) _playbackRefresh = null;
      });
    }
    try {
      final refreshed = await request.result;
      if (!isCurrent() || request.generation != _videoSwitchGeneration) {
        throw StateError('The playback source changed.');
      }
      return refreshed;
    } finally {
      request.observers.remove(isCurrent);
    }
  }

  Future<Video?> _refreshCurrentPlayback(
      _PlaybackRefreshRequest request) async {
    final video = request.video;
    final route = video.playbackConnection ?? video.backendPlayback;
    final database = db;
    final profile = database.profileId;
    bool active() =>
        request.generation == _videoSwitchGeneration &&
        request.active &&
        identical(db, database) &&
        database.profileId == profile &&
        !NetworkProxy.instance.isChanging &&
        _currentPlaybackSource(video);
    Future<void> check() async {
      if (route == null ||
          !active() ||
          !route.matches(await database.getCurrentlySelectedServer()) ||
          !active()) {
        throw StateError('The playback connection changed.');
      }
    }

    try {
      await check();
      while (true) {
        final delay = _playbackRecoveryBudget.reserve();
        if (delay == null) {
          _clearPlaybackRecovery();
          return null;
        }
        _clearBackendProgress();
        _recoveringVideo = null;
        _recoveryProgressPosition = null;
        emit(state.copyWith(recoveringPlayback: true, backendRecovery: null));
        try {
          await _waitForPlaybackRecovery(delay);
          await check();
          final loaded =
              await service.refreshPlaybackVideo(video, isCurrent: active);
          await check();
          if (loaded.videoId != video.videoId ||
              loaded.playbackSourceId == null ||
              loaded.playbackConnection == null) {
            throw StateError('The refreshed playback source was not admitted.');
          }
          final current = state.currentlyPlaying!;
          final refreshed = loaded.preservingMusicMetadataFrom(current);
          _recoveringVideo = refreshed;
          emit(state.copyWith(currentlyPlaying: refreshed));
          return refreshed;
        } catch (error) {
          await check();
          if (!isPlaybackRefreshRetryable(error) ||
              !_playbackRecoveryBudget.hasRemaining) {
            rethrow;
          }
        }
      }
    } catch (_) {
      if (request.generation == _videoSwitchGeneration) {
        _clearPlaybackRecovery();
      }
      rethrow;
    }
  }

  bool _isPlaybackRecoverySource(Video video) {
    final recovering = _recoveringVideo;
    if (!state.recoveringPlayback ||
        recovering == null ||
        !_samePlaybackSource(recovering, video) ||
        !_currentPlaybackSource(video) ||
        NetworkProxy.instance.isChanging) {
      return false;
    }
    final route = video.playbackConnection ?? video.backendPlayback;
    final saved = route == null
        ? null
        : db
            .forProfile(route.preferredServer.profileId)
            .getAccount(route.preferredServer.accountId);
    return route != null &&
        route.preferredServer.profileId == db.profileId &&
        saved?.inUse == true &&
        route.matches(saved!);
  }

  void reportPlaybackRecoveryReady(Video video, {required bool playing}) {
    if (!playing && _isPlaybackRecoverySource(video)) _clearPlaybackRecovery();
  }

  void reportPlaybackRecoveryProgress(Video video, Duration position,
      {required bool playing}) {
    if (!_isPlaybackRecoverySource(video)) return;
    if (!playing) {
      _recoveryProgressPosition = null;
      return;
    }
    final previous = _recoveryProgressPosition;
    if (previous == null || position < previous) {
      _recoveryProgressPosition = position;
      return;
    }
    if (position - previous >= const Duration(milliseconds: 250)) {
      _clearPlaybackRecovery();
    }
  }

  /// Called only after a native source has initialized. A paused source is ready,
  /// but it has not proved that playback resumed.
  void reportBackendPlaybackReady(String videoId, BackendPlayback? request,
      {required bool playing}) {
    if (!_isRecoveryAttempt(videoId, request) || playing) return;
    final recovery = state.backendRecovery!;
    if (recovery.phase != BackendRecoveryPhase.trying) return;
    _backendProgressPosition = null;
    emit(state.copyWith(
        backendRecovery: recovery.withPhase(BackendRecoveryPhase.ready)));
  }

  /// Native playing samples, not metadata, seek, or generic ready events, prove
  /// recovery. Two advancing samples avoid a resume seek being called success.
  void reportBackendPlaybackProgress(
      String videoId, BackendPlayback? request, Duration position,
      {required bool playing}) {
    if (!_isRecoveryAttempt(videoId, request)) return;
    final recovery = state.backendRecovery!;
    if (recovery.phase != BackendRecoveryPhase.trying &&
        recovery.phase != BackendRecoveryPhase.ready) {
      return;
    }
    if (!playing) {
      _backendProgressPosition = null;
      return;
    }
    if (recovery.phase == BackendRecoveryPhase.ready) {
      emit(state.copyWith(
          backendRecovery: recovery.withPhase(BackendRecoveryPhase.trying)));
    }
    final previous = _backendProgressPosition;
    if (previous == null || position < previous) {
      _backendProgressPosition = position;
      return;
    }
    if (position - previous < const Duration(milliseconds: 250)) return;
    final succeeded = recovery.withPhase(BackendRecoveryPhase.succeeded);
    emit(state.copyWith(backendRecovery: succeeded));
    _backendSuccessTimer?.cancel();
    _backendSuccessTimer = Timer(const Duration(seconds: 4), () {
      if (!isClosed && identical(state.backendRecovery, succeeded)) {
        emit(state.copyWith(backendRecovery: null));
      }
    });
  }

  void setEvent(MediaEvent event) {
    if (isClosed || _isDisposing || _switchingProfile || state.isClosing)
      return;
    // The previous decoder can still emit while replacement metadata loads.
    if (_backendSwitchPending &&
        event.type != MediaEventType.backendRetry &&
        event.type != MediaEventType.metadataRetry) {
      return;
    }
    if (event.state == MediaState.error ||
        event.state == MediaState.completed) {
      _clearPlaybackRecovery();
    }
    if (event.state == MediaState.error && state.backendRecovery != null) {
      _clearBackendProgress();
      emit(state.copyWith(
          backendRecovery:
              state.backendRecovery!.withPhase(BackendRecoveryPhase.failed)));
    }
    if (event.type == MediaEventType.seek ||
        event.type == MediaEventType.pause) {
      _backendProgressPosition = null;
      _recoveryProgressPosition = null;
    }
    handleMediaEvent(event);
    mapMediaEventToMediaHandler(event);

    emit(state.copyWith(mediaEvent: event));
  }

  void _clearMetadataRetry() {
    if (state.mediaEvent.type == MediaEventType.metadataRetry) {
      // Metadata may be ready while the native source is still initializing.
      emit(state.copyWith(
          mediaEvent: const MediaEvent(state: MediaState.loading)));
    }
  }

  @override
  void didChangeMetrics() {
    var newOrientation = getOrientation();
    if (newOrientation != state.orientation) {
      emit(state.copyWith(orientation: newOrientation));

      onOrientationChange();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (isClosed) return;
    if (lifecycle == AppLifecycleState.resumed) {
      // AudioService can outlive the Activity that held these parameters.
      unawaited(_updateAutoPip(state));
      if (!_switchingProfile) unawaited(service.syncHistory());
    } else {
      unawaited(_saveSession(state));
    }
  }

  bool _autoPipEnabled(PlayerState snapshot) =>
      snapshot.hasVideo &&
      snapshot.isPlaying &&
      !snapshot.isAudio &&
      !snapshot.isHidden &&
      !snapshot.isClosing;

  double _pipAspectRatio(PlayerState snapshot) => snapshot.aspectRatio.isFinite
      ? snapshot.aspectRatio.clamp(0.42, 2.39)
      : 16 / 9;

  Future<void> _updateAutoPip(PlayerState snapshot,
      {bool disable = false}) async {
    if (_pip == null) return;
    try {
      await _pipChannel.invokeMethod<void>('configure', {
        'enabled': !disable && _autoPipEnabled(snapshot),
        'aspectRatio': _pipAspectRatio(snapshot),
      });
    } on MissingPluginException {
      // The background engine may currently have no Activity attached.
    } on PlatformException catch (error) {
      log.fine('Could not update picture-in-picture', error);
    }
  }

  void mapMediaEventToMediaHandler(MediaEvent event) {
    if (!isTv && event.type != MediaEventType.progress) {
      log.fine("Event state: ${event.state}, ${event.type}");
      // A buffered-position update does not mean the decoder finished buffering.
      final processingState = event.type == MediaEventType.bufferChanged
          ? mediaHandler.playbackState.value.processingState
          : const {
                MediaState.idle: AudioProcessingState.idle,
                MediaState.loading: AudioProcessingState.loading,
                MediaState.buffering: AudioProcessingState.buffering,
                MediaState.completed: AudioProcessingState.completed,
              }[event.state] ??
              AudioProcessingState.ready;
      final playing = state.isPlaying &&
          processingState != AudioProcessingState.idle &&
          processingState != AudioProcessingState.completed;
      var playbackState = PlaybackState(
        controls: [
          state.hasQueue ? MediaControl.skipToPrevious : MediaControl.rewind,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.stop,
          state.hasQueue ? MediaControl.skipToNext : MediaControl.fastForward,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.setShuffleMode,
          MediaAction.setRepeatMode
        },
        androidCompactActionIndices: const [0, 1, 3],
        // Android uses a spinner for BUFFERING even when playing is false.
        // Publish PAUSED through ready/false so the lock screen offers Play.
        processingState:
            !playing && processingState == AudioProcessingState.buffering
                ? AudioProcessingState.ready
                : processingState,
        playing: playing,
        updatePosition: state.position,
        bufferedPosition: state.bufferedPosition,
        speed: state.speed,
        queueIndex: currentIndex,
      );

      mediaHandler.playbackState.add(playbackState);
    }
  }

  int get currentIndex {
    return (state.videos.isNotEmpty ? state.videos : state.offlineVideos)
        .indexWhere(
            (element) => playbackQueueId(element) == state.currentQueueId);
  }

  Future<void> onReady() async {
    var startupGeneration = _videoSwitchGeneration;
    bool startupActive() =>
        !_isDisposing &&
        !isClosed &&
        startupGeneration == _videoSwitchGeneration;
    final startVideos = state.videos;
    if (startVideos.isEmpty) restoreSession();
    emit(state.copyWith(
        orientation: getOrientation(),
        forwardStep: settings.state.skipStep,
        rewindStep: settings.state.skipStep));
    // setting up audio session
    final session = await AudioSession.instance;
    if (_isDisposing || isClosed) return;
    audioSession = session;
    await audioSession.configure(const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.allowBluetooth,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: AndroidAudioUsage.media,
      ),
    ));
    if (_isDisposing || isClosed) return;
    _interruptionSubscription =
        audioSession.interruptionEventStream.listen(handleAudioInterruption);
    WidgetsBinding.instance.addObserver(this);
    if (!isTv) {
      _becomingNoisySubscription =
          audioSession.becomingNoisyEventStream.listen((event) {
        pause();
      });

      final handler = await AudioService.init(
        builder: () => MediaHandler(this),
        config: const AudioServiceConfig(
          androidNotificationChannelId:
              'com.github.dvbeckwitt.videre.channel.audio',
          androidNotificationChannelName: 'Video playback',
          androidNotificationOngoing: true,
        ),
      );
      if (_isDisposing || isClosed) return;
      mediaHandler = handler;
      BackButtonInterceptor.add(handleBackButton,
          name: 'miniPlayer', zIndex: 2, ifNotYetIntercepted: true);
    } else if (startVideos.isNotEmpty && startupActive()) {
      final reference = _initialPlaylistReference;
      final switching = reference == null
          ? playVideo(startVideos, startAt: state.startAt)
          : playPlaylist(startVideos,
              reference: reference,
              startIndex: _initialPlaylistIndex,
              startAt: state.startAt,
              audio: _initialPlaylistAudio,
              playlistLoader: _initialPlaylistLoader);
      startupGeneration = _videoSwitchGeneration;
      await switching;
      if (!startupActive()) return;
    }
    // Stop and newer play requests can arrive while native services initialize.
    // Finish that setup for future explicit playback, but discard stale autoplay.
    if (_resumeOnReady && startupActive()) await resumeSession();
  }

  void handleMediaEvent(MediaEvent event) {
    switch (event.state) {
      case MediaState.completed:
        final length = state.currentlyPlaying?.lengthSeconds ??
            state.offlineCurrentlyPlaying?.lengthSeconds ??
            0;
        if (_playlistReference != null) {
          unawaited(_completePlaylistEntry(length));
        } else {
          unawaited(saveProgress(length));
          // A late completion must not undo a Stop already in progress.
          if (!state.isClosing) {
            if (settings.state.autoplayQueue) {
              playNext();
            } else if (_requestedPlaying != false) {
              pause();
            }
          }
        }
        _setPlaying(false);
        break;
      default:
        break;
    }

    switch (event.type) {
      case MediaEventType.progress:
        onProgress(event.value);
        break;
      case MediaEventType.play:
        _setPlaying(_requestedPlaying != false);
        // Source setup can autoplay after a notification or PiP pause request.
        if (_requestedPlaying == false) pause();
        break;
      case MediaEventType.pause:
        _setPlaying(false);
        unawaited(_saveSession(state));
        playbackHistoryRevision.value++;
        break;
      case MediaEventType.volumeChanged:
        _setMuted(!event.value);
        break;
      case MediaEventType.aspectRatioChanged:
        emit(state.copyWith(aspectRatio: event.value));
        break;
      case MediaEventType.pitchChanged:
        final pitch = event.value;
        if (pitch is int &&
            pitch >= minimumPitchSemitones &&
            pitch <= maximumPitchSemitones) {
          emit(state.copyWith(pitchSemitones: pitch));
        }
        break;
      case MediaEventType.speedChanged:
        final speed = event.value;
        if (speed is num && speed.isFinite && speed > 0) {
          emit(state.copyWith(speed: speed.toDouble()));
        }
        break;
      default:
        break;
    }
  }

  Future<void> _completePlaylistEntry(int length) async {
    final generation = _videoSwitchGeneration;
    final playlistGeneration = _playlistGeneration;
    final queueId = state.currentQueueId;
    final profileId = _profileDatabase.profileId;
    try {
      // Advancing invalidates progress callbacks. Finish the source occurrence
      // first, even when the next queued item was added manually.
      await saveProgress(length);
    } catch (error, stack) {
      log.warning('Could not save completed playlist position', error, stack);
    }
    if (isClosed ||
        _isDisposing ||
        _switchingProfile ||
        state.isClosing ||
        generation != _videoSwitchGeneration ||
        playlistGeneration != _playlistGeneration ||
        queueId != state.currentQueueId ||
        profileId != _profileDatabase.profileId ||
        _requestedPlaying == false) return;
    if (settings.state.autoplayQueue) {
      playNext();
    } else {
      pause();
    }
  }

  void _setPip(bool pip) {
    if (isClosed) return;
    // Keep the same decoder running when the window closes, including offline.
    emit(state.copyWith(isPip: pip));
  }

  void _setMuted(bool muted) {
    emit(state.copyWith(muted: muted));
  }

  @override
  close() async {
    _isDisposing = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _clearBackendProgress();
    NetworkProxy.instance.removeBeforeApply(_proxyChanging);
    _progressGeneration++;
    _videoSwitchGeneration++;
    _requestedBackendVideoId = null;
    await _becomingNoisySubscription?.cancel();
    await _interruptionSubscription?.cancel();
    await _updateAutoPip(state, disable: true);
    _pip?.onPipEntered = null;
    _pip?.onPipExited = null;
    await _saveSession(state);
    _bindPlaylist(null, []);
    playlistLoadingRevision.dispose();
    if (_sessionOwner == this) _sessionOwner = null;
    playbackHistoryRevision.value++;
    BackButtonInterceptor.removeByName('miniPlayer');
    WidgetsBinding.instance.removeObserver(this);
    await super.close();
  }

  bool handleBackButton(bool stopDefaultButtonEvent, RouteInfo info) {
    if (state.fullScreenState == FullScreenState.fullScreen) {
      setFullScreen(FullScreenState.notFullScreen);
      return true;
    } else if (!state.isMini) {
      // we block the backbutton behavior and we make the player small
      showMiniPlayer();
      return true;
    } else {
      return false;
    }
  }

  void selectTab(int index) {
    emit(state.copyWith(selectedFullScreenIndex: index));
  }

  void setAudio(bool? newValue) {
    emit(state.copyWith(isAudio: newValue ?? false));
  }

  void hide() {
    if (isClosed || state.isClosing) return;
    _clearPlaybackRecovery(resetBudget: true);
    _clearMetadataRetry();
    // Background playback must stop before the closing animation can run.
    pause();
    _pitchVideoId = null;
    _speedVideoId = null;
    final generation = ++_progressGeneration;
    _videoSwitchGeneration++;
    _requestedBackendVideoId = null;
    _clearBackendProgress();
    unawaited(_saveSession(state));
    _releasePlaylistLoader();
    playbackHistoryRevision.value++;
    var mediaEvent = MediaEvent(
        state: MediaState.playing,
        type: MediaEventType.miniDisplayChanged,
        value: state.isMini);
    emit(state.copyWith(
        isClosing: true, requestedBackend: null, backendRecovery: null));
    cancelSleep();
    Future.delayed(
      animationDuration * 1.5,
      () {
        if (isClosed || generation != _progressGeneration) return;
        emit(state.copyWith(
            isMini: true,
            mediaEvent: mediaEvent,
            top: null,
            height: targetHeight,
            isHidden: true,
            videos: [],
            playedVideos: [],
            currentlyPlaying: null,
            requestedBackend: null,
            offlineCurrentlyPlaying: null,
            offlineVideos: [],
            isClosing: false));
        _playlistReference = null;
        setEvent(const MediaEvent(state: MediaState.idle));
      },
    );

    if (_hasAudioSession) audioSession.setActive(false);
  }

  double get getBottom => state.isHidden ? -targetHeight : 0;

  /// Save under the old person before the application selects the new one.
  /// Clear immediately: an animation callback must never clear the next queue.
  Future<void> prepareForProfileSwitch() async {
    if (isClosed) return;
    _clearPlaybackRecovery(resetBudget: true);
    _clearMetadataRetry();
    pause();
    final saved = _saveSession(state);
    _bindPlaylist(null, []);
    _switchingProfile = true;
    _progressGeneration++;
    _videoSwitchGeneration++;
    _requestedBackendVideoId = null;
    _backendSwitchPending = false;
    _manualSelectionPending = false;
    _clearBackendProgress();
    cancelSleep();
    _pitchVideoId = null;
    _speedVideoId = null;
    // Invoke teardown before the empty state removes the decoder widgets.
    // Its synchronous prefix invalidates setup; await native stop below.
    final stopping = Future.wait(
        List.of(_beforeProfileSwitch).map((callback) => callback()));
    // Late decoder events are blocked above. Publish idle explicitly because
    // the UI can dispose before its queued pause event reaches AudioService.
    final clearingSession = _mediaSessionHandler?.clearSession();
    emit(PlayerState.init(null));
    await Future.wait(
        [saved, stopping, if (clearingSession != null) clearingSession]);
    if (_sessionOwner == this) _sessionOwner = null;
    if (_hasAudioSession) await audioSession.setActive(false);
    await _updateAutoPip(state, disable: true);
    _watchRepository = null;
    _watchAccount = null;
    _watchVideoId = null;
    _watchRevision = null;
  }

  Future<void> reloadForProfile() async {
    if (isClosed) return;
    _profileDatabase = db.forProfile(db.profileId);
    _watchBinding = Future.value();
    _switchingProfile = false;
    restoreSession();
  }

  Future<void> _bindWatchSession(String videoId, {bool intentional = false}) {
    final database = _profileDatabase;
    final generation = _videoSwitchGeneration;
    final binding = _watchBinding.then((_) async {
      if (_switchingProfile ||
          generation != _videoSwitchGeneration ||
          isClosed) {
        return;
      }
      if (!intentional && _watchVideoId == videoId) return;
      final repository = WatchRepository.forDatabase(database);
      Server? account;
      try {
        account = await database.getCurrentlySelectedServer();
      } catch (_) {
        // Offline/local playback does not require a configured server.
      }
      if (_switchingProfile ||
          generation != _videoSwitchGeneration ||
          isClosed) {
        return;
      }
      final revision = await repository?.beginPlayback(videoId);
      if (_switchingProfile ||
          generation != _videoSwitchGeneration ||
          isClosed) {
        return;
      }
      _watchRepository = repository;
      _watchAccount = account;
      _watchVideoId = videoId;
      _watchRevision = revision;
    });
    // A temporary storage failure must not poison every later playback attempt.
    _watchBinding = binding.then<void>((_) {}, onError: (Object _) {});
    return binding;
  }

  Future<void> saveProgress(int timeInSeconds) async {
    if (isClosed || _isDisposing || _switchingProfile) return;
    final videoId = state.currentlyPlaying?.videoId ??
        state.offlineCurrentlyPlaying?.videoId;
    final length = state.currentlyPlaying?.lengthSeconds ??
        state.offlineCurrentlyPlaying?.lengthSeconds ??
        0;
    final playlistGeneration = _playlistGeneration;
    final audio = state.isAudio;
    final entries = _playlistEntries.values.toList();
    final entry = state.videos
            .where((video) => playbackQueueId(video) == state.currentQueueId)
            .firstOrNull ??
        state.currentlyPlaying;
    if (videoId != null && length > 0) {
      int currentPosition = timeInSeconds;
      // saving progress
      var currentProgress = (currentPosition / length).clamp(0.0, 1.0);
      if (currentProgress >= db_progress.watchedProgressThreshold) {
        currentProgress =
            1; // we consider a video with 90%+ progress as watched
      }
      var progress = db_progress.Progress.named(
          progress: currentProgress,
          videoId: videoId,
          positionSeconds: currentPosition.clamp(0, length),
          durationSeconds: length);

      final generation = _progressGeneration;
      await _bindWatchSession(videoId);
      if (_switchingProfile ||
          generation != _progressGeneration ||
          _watchVideoId != videoId) return;
      final repository = _watchRepository;
      final revision = _watchRevision;
      final database = _profileDatabase;
      final account = _watchAccount;
      if (repository != null && revision != null) {
        final accepted = await repository.recordPlayback(
            videoId, currentProgress, revision,
            account: account,
            positionSeconds: progress.positionSeconds,
            durationSeconds: length);
        if (accepted && entry != null) {
          await _savePlaylistCheckpoint(entry,
              generation: playlistGeneration,
              watchRevision: revision,
              entries: entries,
              audio: audio,
              completed: currentPosition >= length);
        }
        if (accepted &&
            account != null &&
            progress.progress > 0.1 &&
            repository.pending(account.accountId).isNotEmpty) {
          unawaited(service.syncAccountHistory(account,
              database: database, pull: false));
        }
      } else {
        await database.saveProgress(progress);
        if (entry != null) {
          await _savePlaylistCheckpoint(entry,
              generation: playlistGeneration,
              watchRevision: null,
              entries: entries,
              audio: audio,
              completed: currentPosition >= length);
        }
      }
    }
  }

  void queueVideos(List<Video> videos) {
    final ids = state.videos.map((video) => video.videoId).toSet();
    final additions = videos
        .where((video) => !video.filtered && ids.add(video.videoId))
        .toList();
    if (additions.isEmpty) return;
    emit(state
        .copyWith(offlineVideos: [], videos: [...state.videos, ...additions]));
    generatePlayQueue();
  }

  void showBigPlayer() {
    var mediaEvent = MediaEvent(
        state: MediaState.playing,
        type: MediaEventType.miniDisplayChanged,
        value: state.isMini);

    emit(state.copyWith(
        isMini: false,
        mediaEvent: mediaEvent,
        top: 0,
        isHidden: false,
        isDragging: false,
        dragDistance: 0,
        showMiniPlaceholder: false));
    onOrientationChange();
  }

  void showMiniPlayer() {
    if (state.currentlyPlaying != null ||
        state.offlineCurrentlyPlaying != null) {
      var mediaEvent = MediaEvent(
          state: MediaState.playing,
          type: MediaEventType.miniDisplayChanged,
          value: state.isMini);
      emit(state.copyWith(
        isMini: true,
        mediaEvent: mediaEvent,
        top: null,
        isHidden: false,
        isDragging: false,
        dragDistance: 0,
        showMiniPlaceholder: false,
      ));
    }
  }

  Future<void> onProgress(Duration? position) async {
    if (isClosed || _switchingProfile) return;
    final generation = _progressGeneration;
    final videoId = state.currentlyPlaying?.videoId ??
        state.offlineCurrentlyPlaying?.videoId;
    var newPosition = position ?? Duration.zero;
    int currentPosition = newPosition.inSeconds;
    // Pause/background must see the latest position even while storage is busy.
    emit(state.copyWith(position: newPosition));
    await saveProgress(currentPosition);
    if (isClosed ||
        generation != _progressGeneration ||
        state.position != newPosition ||
        videoId !=
            (state.currentlyPlaying?.videoId ??
                state.offlineCurrentlyPlaying?.videoId)) return;
    log.fine("video progress event");

    if (state.sponsorSegments.isNotEmpty) {
      final positionInMs = newPosition.inMilliseconds;
      Pair<int> nextSegment = state.sponsorSegments.firstWhere(
          (e) => e.first <= positionInMs && positionInMs < e.last,
          orElse: () => const Pair<int>(-1, -1));

      if (nextSegment.first != -1) {
        log.fine('sponsor skipped');
        emit(state.copyWith(
            mediaEvent: const MediaEvent(
                state: MediaState.playing,
                type: MediaEventType.sponsorSkipped)));
        // The end is exclusive, so landing there cannot trigger another skip.
        seek(Duration(milliseconds: nextSegment.last));
      }
    }
  }

  Future<void> _playNextNow() async {
    if (settings.state.playerRepeatMode != PlayerRepeat.repeatOne &&
        state.playQueue.isEmpty &&
        !playlistComplete) {
      // The end of a loaded page is not the end of the playlist. Keep the
      // current item until more metadata arrives or the user retries a failure.
      _waitingForPlaylist = true;
      playlistLoadingRevision.value++;
      return;
    }
    if (settings.state.playerRepeatMode == PlayerRepeat.repeatOne) {
      seek(Duration.zero);
      play();
    } else if (state.videos.isNotEmpty || state.offlineVideos.isNotEmpty) {
      if (state.playQueue.isNotEmpty ||
          settings.state.playerRepeatMode == PlayerRepeat.repeatAll) {
        _sessionTransitionPending = true;
      }
      //moving current video to played list
      final currentVideoId = state.currentQueueId;
      if (currentVideoId != null) {
        var newPlayedVideos = List<String>.from(state.playedVideos)
          ..add(currentVideoId);
        emit(state.copyWith(playedVideos: newPlayedVideos));
      }

      if (state.playQueue.isNotEmpty) {
        String toPlay = state.playQueue.removeFirst();
        if (state.videos.isNotEmpty) {
          await switchToVideo(state.videos
              .firstWhere((element) => playbackQueueId(element) == toPlay));
        } else {
          await switchToOfflineVideo(state.offlineVideos
              .firstWhere((element) => playbackQueueId(element) == toPlay));
        }
      } else if (settings.state.playerRepeatMode == PlayerRepeat.repeatAll) {
        emit(state.copyWith(playedVideos: [], playQueue: ListQueue.from([])));
        final switching = state.videos.isNotEmpty
            ? switchToVideo(state.videos[0])
            : switchToOfflineVideo(state.offlineVideos[0]);
        final generation = _videoSwitchGeneration;
        await switching;
        if (isClosed || generation != _videoSwitchGeneration) return;
        generatePlayQueue();
      }
    }
  }

  void playNext() {
    EasyThrottle.throttle(
        skipToVideoThrottleName, const Duration(seconds: 1), _playNextNow);
  }

  void playPrevious() {
    EasyThrottle.throttle(skipToVideoThrottleName, const Duration(seconds: 1),
        () async {
      if (state.playedVideos.isNotEmpty) {
        _sessionTransitionPending = true;
        // putting back current video in play queue
        final currentVideoId = state.currentQueueId;
        var playQueue = ListQueue<String>.from(state.playQueue);
        if (currentVideoId != null) {
          playQueue.addFirst(currentVideoId);
        }

        var playedVideos = List<String>.from(state.playedVideos);
        String toPlay = playedVideos.removeLast();
        emit(state.copyWith(playQueue: playQueue, playedVideos: playedVideos));
        await (state.videos.isNotEmpty
            ? switchToVideo(state.videos
                .firstWhere((element) => playbackQueueId(element) == toPlay))
            : switchToOfflineVideo(state.offlineVideos
                .firstWhere((element) => playbackQueueId(element) == toPlay)));
      } else {
        // if there's nothing to go back to, we just repeat the last video
        seek(Duration.zero);
        play();
      }
    });
  }

  void _setPlaying(bool playing) {
    emit(state.copyWith(isPlaying: playing));
  }

  Future<void> _playVideos(List<IdedVideo> vids,
      {Duration? startAt, int startIndex = 0}) async {
    if (vids.isEmpty) return;
    RangeError.checkValidIndex(startIndex, vids, 'startIndex');
    final isOffline = vids.first is DownloadedVideo;
    final videos =
        isOffline ? <Video>[] : assignPlaybackQueueIds(vids.cast<Video>());
    final offlineVideos =
        isOffline ? List<DownloadedVideo>.from(vids) : <DownloadedVideo>[];
    final entries = isOffline ? offlineVideos : videos;
    final previous = settings.state.playerShuffleMode
        ? <String>[]
        : entries.take(startIndex).map(playbackQueueId).toList();
    final next = entries
        .asMap()
        .entries
        .where((entry) =>
            entry.key != startIndex &&
            (settings.state.playerShuffleMode || entry.key > startIndex))
        .map((entry) => playbackQueueId(entry.value))
        .toList();
    if (settings.state.playerShuffleMode) next.shuffle();
    emit(state.copyWith(
        offlineVideos: offlineVideos,
        videos: videos,
        startAt: startAt,
        mediaEvent: const MediaEvent(state: MediaState.loading),
        playedVideos: previous,
        playQueue: ListQueue.of(next),
        selectedFullScreenIndex: vids.length > 1 ? 3 : 0,
        top: 500));

    showBigPlayer();
    await _switchToVideo(entries[startIndex],
        startAt: startAt, playing: _requestedPlaying);
  }

  /// skip to queue video of index
  /// if we're not shuffling, we also rebuild the playnext and played previously queue
  Future<void> skipToVideo(int index) async {
    var listToCheckAgainst =
        state.videos.isNotEmpty ? state.videos : state.offlineVideos;
    if (index < 0 || index >= listToCheckAgainst.length) {
      return;
    }

    if (settings.state.playerShuffleMode) {
      final selectedId = playbackQueueId(listToCheckAgainst[index]);
      final currentId = state.currentQueueId;
      if (selectedId == currentId) return;
      _sessionTransitionPending = true;
      emit(state.copyWith(
          playedVideos: [
            ...state.playedVideos,
            if (currentId != null) currentId,
          ],
          playQueue:
              ListQueue.of(state.playQueue.where((id) => id != selectedId))));
    } else {
      _sessionTransitionPending = true;
      List<String> played = [];
      List<String> playNext = [];
      for (int i = 0; i < listToCheckAgainst.length; i++) {
        var v = listToCheckAgainst[i];
        if (i < index) {
          played.add(playbackQueueId(v));
        } else if (i > index) {
          playNext.add(playbackQueueId(v));
        }
      }
      emit(state.copyWith(
          playedVideos: played, playQueue: ListQueue.from(playNext)));
    }
    await _switchToVideo(listToCheckAgainst[index]);
  }

  /// Switches to a video without changing the queue
  Future<void> _switchToVideo(IdedVideo video,
      {Duration? startAt,
      bool? playing,
      BackendPlayback? backendRequest,
      bool retainOnFailure = false}) async {
    if (isClosed || _switchingProfile) return;
    _waitingForPlaylist = false;
    _sessionTransitionPending = true;
    // Selecting a song, including advancing the queue, starts it over. Explicit
    // session restoration and backend recovery still supply their own position.
    if ((video is Video && video.musicMetadata != null) ||
        (video is DownloadedVideo && video.musicMetadata != null)) {
      startAt ??= Duration.zero;
    }
    _requestedPlaying = playing;
    final generation = ++_videoSwitchGeneration;
    _clearPlaybackRecovery(resetBudget: true);
    bool active() => !isClosed && generation == _videoSwitchGeneration;
    _clearMetadataRetry();
    _progressGeneration++;
    _requestedBackendVideoId = video is Video ? video.videoId : null;
    _backendSwitchPending = true;
    _clearBackendProgress();
    // Replacing the video disposes its controls and active gesture recognizer.
    // Settle first, because that disposal does not deliver drag end/cancel.
    videoDragCancelled();
    emit(state.copyWith(
        isClosing: false, requestedBackend: null, backendRecovery: null));
    if (backendRequest != null && !retainOnFailure) {
      _recordBackendRequest(video.videoId, backendRequest);
    }
    try {
      // we move the existing video to the stack of played video
      final focusRevision = _audioFocusRevision;
      final focusGranted =
          await (_videoFocusActivationRequired && !state.isAudio
              ? (_activateVideoFocus?.call() ?? audioSession.setActive(true))
              : audioSession.setActive(true));
      if (!active()) return;
      if (focusGranted && focusRevision == _audioFocusRevision) {
        _videoFocusActivationRequired = false;
      }
      if (retainOnFailure && backendRequest != null) {
        final selected = await db.getCurrentlySelectedServer();
        if (!active()) return;
        if (backendRequest.matches(selected)) {
          _recordBackendRequest(video.videoId, backendRequest);
        } else {
          // A changed account or routing policy owns a new connection snapshot.
          backendRequest = null;
        }
      }
      bool isOffline = video is DownloadedVideo;
      // we want to switch to audio mode as soon as we can to prevent problems when switching from audio to video or the other way
      if (isOffline) {
        setAudio(video.audioOnly);
      }

      const mediaEvent = MediaEvent(state: MediaState.loading);

      List<Video> videos = List.from(state.videos);
      List<DownloadedVideo> offlineVideos = List.from(state.offlineVideos);
      var currentlyPlaying = state.currentlyPlaying;
      var offlineCurrentlyPlaying = state.offlineCurrentlyPlaying;
      if (isOffline) {
        videos = [];
        currentlyPlaying = null;
      } else {
        offlineVideos = [];
        offlineCurrentlyPlaying = null;
      }

      emit(state.copyWith(
          mediaEvent: mediaEvent,
          videos: videos,
          currentlyPlaying: currentlyPlaying,
          offlineVideos: offlineVideos,
          offlineCurrentlyPlaying: offlineCurrentlyPlaying));

      late MediaCommand mediaCommand;
      currentlyPlaying = state.currentlyPlaying;
      offlineCurrentlyPlaying = state.offlineCurrentlyPlaying;
      if (!isOffline) {
        late Video v;
        var reuseLoaded = video is Video &&
            video.formatStreams != null &&
            video.adaptiveFormats != null;
        final cachedConnection = video is Video
            ? video.playbackConnection ?? video.backendPlayback
            : null;
        if (reuseLoaded && cachedConnection != null) {
          final currentServer = await db.getCurrentlySelectedServer();
          if (!active()) return;
          reuseLoaded = cachedConnection.matches(currentServer);
        }
        if (reuseLoaded && video is Video && backendRequest == null) {
          v = video;
        } else {
          var metadataPending = true;
          void onBackendRequest(BackendPlayback request) {
            if (!active() || !metadataPending) return;
            _recordBackendRequest(video.videoId, request);
            if (request.retryIndex > 0 || request.manualSelection) {
              setEvent(MediaEvent(
                  state: MediaState.loading,
                  type: MediaEventType.backendRetry,
                  value: request.label));
            }
          }

          try {
            v = backendRequest == null
                ? await service.getVideo(video.videoId,
                    onBackendRequest: onBackendRequest,
                    loadObserver: VideoLoadObserver(
                      isCurrent: () => active() && metadataPending,
                      onRetry: () {
                        if (!active() || !metadataPending) return;
                        setEvent(const MediaEvent(
                            state: MediaState.loading,
                            type: MediaEventType.metadataRetry));
                      },
                    ))
                : await service.getVideoForBackend(
                    video.videoId, backendRequest,
                    onBackendRequest: onBackendRequest, isCurrent: active);
          } finally {
            metadataPending = false;
          }
          if (!active()) return;
          _clearMetadataRetry();
        }
        if (video is Video) v = v.preservingMusicMetadataFrom(video);
        currentlyPlaying = v;
        if (retainOnFailure) startAt = state.position;
        mediaCommand = MediaCommand(MediaCommandType.switchVideo,
            value: SwitchVideoValue(video: v, startAt: startAt));
      } else {
        offlineCurrentlyPlaying = video;
        if (retainOnFailure) startAt = state.position;
        mediaCommand =
            MediaCommand(MediaCommandType.switchToOfflineVideo, value: video);
      }

      final length = currentlyPlaying?.lengthSeconds ??
          offlineCurrentlyPlaying?.lengthSeconds ??
          0;
      await _bindWatchSession(video.videoId,
          intentional: backendRequest == null && !retainOnFailure);
      if (!active() || _switchingProfile) return;
      final progress = _profileDatabase.getVideoProgress(video.videoId);
      final resumeAt = startAt ??
          Duration(seconds: progress < 0.9 ? (length * progress).floor() : 0);
      _sessionOwner = this;
      _backendSwitchPending = false;
      if (currentlyPlaying != null) {
        _recordBackendRequest(
            currentlyPlaying.videoId, currentlyPlaying.backendPlayback);
      }
      // A drag can also begin while the replacement metadata is loading.
      videoDragCancelled();
      // Persist only coherent queue/current/context snapshots. A new request
      // may have changed playlist ownership or audio mode before metadata arrived.
      _sessionTransitionPending = false;
      emit(state.copyWith(
          position: resumeAt,
          startAt: startAt,
          sponsorSegments: [],
          forwardStep: settings.state.skipStep,
          rewindStep: settings.state.skipStep,
          mediaCommand: mediaCommand,
          currentlyPlaying: currentlyPlaying,
          requestedBackend: currentlyPlaying?.backendPlayback,
          offlineCurrentlyPlaying: offlineCurrentlyPlaying));
      unawaited(_saveSession(state));
      if (_playlistReference != null) {
        await saveProgress(resumeAt.inSeconds);
        if (!active()) return;
      }

      if (currentlyPlaying != null) {
        await _profileDatabase.upsertHistoryVideo(HistoryVideoCache(
            currentlyPlaying.videoId,
            currentlyPlaying.title ?? '',
            currentlyPlaying.author,
            ImageObject.getBestThumbnail(currentlyPlaying.videoThumbnails)
                    ?.url ??
                '',
            authorId: currentlyPlaying.authorId,
            lengthSeconds: currentlyPlaying.lengthSeconds,
            musicMetadata: currentlyPlaying.musicMetadata));
        if (!active()) return;
        playbackHistoryRevision.value++;
      }

      await setSponsorBlock();
      if (!active()) return;

      if (!isTv) {
        try {
          final item = await getMediaItem(currentIndex);
          if (active()) mediaHandler.mediaItem.add(item);
        } catch (error, stack) {
          // Artwork/storage failures must not remove a playable queue item.
          log.warning('Could not update playback notification', error, stack);
        }
      }
    } catch (err) {
      if (!active()) return;
      _clearMetadataRetry();
      _backendSwitchPending = false;
      if (retainOnFailure ||
          (video is Video &&
              (state.backendRecovery != null || video.musicMetadata != null))) {
        pause();
        videoDragCancelled();
        if (retainOnFailure) _sessionTransitionPending = false;
        // Retry belongs to this selection, even when metadata never arrived.
        // Do not carry the previous video's position into a newly chosen song.
        emit(state.copyWith(
            currentlyPlaying: video is Video ? video : null,
            offlineCurrentlyPlaying: video is DownloadedVideo ? video : null,
            isPlaying: false,
            position:
                retainOnFailure ? state.position : startAt ?? state.position,
            startAt:
                retainOnFailure ? state.position : startAt ?? state.startAt));
        setEvent(const MediaEvent(state: MediaState.error));
        return;
      }
      if (state.videos.length == 1) {
        // if we can't get video details, we need to stop everything
        log.severe(
            "Couldn't play video  '${video.videoId}', stopping player to avoid app crash");
        hide();
      } else {
        // if we have more than 1 video
        log.severe(
            "Couldn't play video  '${video.videoId}', removing it from the queue");

        removeVideoFromQueue(playbackQueueId(video));
        _playNextNow();
      }
    }
  }

  /// Retry the current video with a user-selected backend. This does not change
  /// the preferred backend unless the picker explicitly asks to save it.
  Future<void> selectBackend(String? value,
      {bool saveAsPreferred = false,
      String? expectedVideoId,
      BackendPlayback? expectedRequest}) async {
    final video = state.currentlyPlaying;
    final request = state.requestedBackend ?? video?.backendPlayback;
    if (isClosed ||
        state.isClosing ||
        _manualSelectionPending ||
        _backendSwitchPending ||
        video == null ||
        state.offlineCurrentlyPlaying != null ||
        request == null ||
        request.server.backendSelector == null ||
        (expectedVideoId != null && expectedVideoId != video.videoId) ||
        (expectedRequest != null && !identical(expectedRequest, request))) {
      throw StateError('The current video or connection changed.');
    }
    final generation = _videoSwitchGeneration;
    bool active() =>
        !isClosed &&
        !state.isClosing &&
        generation == _videoSwitchGeneration &&
        state.currentlyPlaying?.videoId == video.videoId &&
        identical(
            state.requestedBackend ?? state.currentlyPlaying?.backendPlayback,
            request);
    _manualSelectionPending = true;
    try {
      var saved = await db.getCurrentlySelectedServer();
      if (!active() || !request.matches(saved)) {
        throw StateError('The current video or connection changed.');
      }
      // Validation and merging are shared with server settings: no arbitrary
      // cookie names or values, and unrelated preferences/login cookies survive.
      final updated = saved.backendSelector!.withSelection(saved, value);
      if (saveAsPreferred) {
        await db.upsertServer(updated);
        final selected = await db.getCurrentlySelectedServer();
        if (selected.url == updated.url) {
          await fileDb.useServer(selected);
          final app = settings.appCubit;
          if (!app.isClosed && app.state.server?.url == selected.url) {
            app.setServer(selected);
          }
        }
        saved = updated;
      }
      if (!active()) throw StateError('The current video changed.');
      final selection = BackendPlayback.manual(saved, value);
      if (!selection.matches(await db.getCurrentlySelectedServer()) ||
          !active()) {
        throw StateError('The playback connection changed.');
      }
      final startAt = state.position;
      final playing =
          state.mediaEvent.state == MediaState.error ? true : requestedPlaying;
      pause();
      await _switchToVideo(video,
          startAt: startAt, playing: playing, backendRequest: selection);
    } finally {
      _manualSelectionPending = false;
    }
  }

  Future<void> playOfflineVideos(List<DownloadedVideo> offlineVids) async {
    if (offlineVids.isEmpty ||
        _switchingProfile ||
        offlineVids.any(
            (video) => video.profileId != _profileDatabase.profileId)) return;
    _requestedPlaying = null;
    _sessionTransitionPending = true;
    _bindPlaylist(null, []);
    log.fine('Playing ${offlineVids.length} offline videos');
    await _playVideos(offlineVids);
  }

  Future<void> playVideo(List<Video> v,
      {bool? audio, Duration? startAt, bool? playing}) async {
    if (isClosed || _switchingProfile) return;
    final videos = v.where((element) => !element.filtered).toList();
    if (videos.isEmpty) return;
    _sessionTransitionPending = true;
    _bindPlaylist(null, []);
    _requestedPlaying = playing;
    // TODO: find how to do this with auto router
    log.fine('Playing ${videos.length} videos');

    setAudio(audio ?? (videos.firstOrNull?.musicMetadata != null));

    await _playVideos(videos, startAt: startAt);
  }

  /// Start the selected occurrence and its surrounding queue as one operation.
  /// The index refers to the supplied playlist before filtered entries are
  /// removed, so filtering cannot silently select a different video.
  Future<void> playPlaylist(List<Video> entries,
      {required PlaylistReference reference,
      int startIndex = 0,
      Duration? startAt,
      bool? audio,
      bool? playing,
      PlaylistLoadSession? playlistLoader}) async {
    if (isClosed || _switchingProfile) return;
    if (reference.profileId != _profileDatabase.profileId) {
      throw StateError('This playlist belongs to another profile.');
    }
    RangeError.checkValidIndex(startIndex, entries, 'startIndex');
    final assigned = assignPlaylistEntryIds(entries);
    final selected = assigned[startIndex];
    if (selected.filtered ||
        selected.filterHide ||
        selected.isUpcoming == true) {
      throw StateError('This playlist entry is not available for playback.');
    }
    final videos = assigned
        .where((video) =>
            !video.filtered && !video.filterHide && video.isUpcoming != true)
        .toList();
    final index = videos.indexWhere(
        (video) => playbackQueueId(video) == playbackQueueId(selected));
    _sessionTransitionPending = true;
    _requestedPlaying = playing;
    _bindPlaylist(reference, assigned, loader: playlistLoader);
    setAudio(audio ?? selected.musicMetadata != null);
    final playback = _playVideos(videos, startAt: startAt, startIndex: index);
    if (playlistLoader != null) {
      appendPlaylistVideos(playlistLoader.playlist.videos,
          reference: reference, generation: _playlistGeneration);
    }
    await playback;
  }

  Future<void> switchToOfflineVideo(DownloadedVideo video) async {
    if (video.profileId != _profileDatabase.profileId) return;
    await _switchToVideo(video);
  }

  Future<void> switchToVideo(Video video, {Duration? startAt}) async {
    await _switchToVideo(video, startAt: startAt);
  }

  /// An explicit Retry keeps the current queue occurrence and position even if
  /// fresh metadata fails. Repeated taps share the current attempt.
  /// Per-video manual backend choices persist; automatic recovery starts a new
  /// bounded attempt from the saved preference.
  Future<void> retryCurrentVideo() {
    final pending = _currentVideoRetry;
    if (pending != null &&
        _currentVideoRetryGeneration == _videoSwitchGeneration) {
      return pending;
    }
    if (isClosed ||
        _isDisposing ||
        _switchingProfile ||
        state.isClosing ||
        state.isHidden ||
        _backendSwitchPending ||
        _manualSelectionPending) {
      return Future.value();
    }
    final video = state.currentlyPlaying;
    final offline = state.offlineCurrentlyPlaying;
    final IdedVideo? retry =
        video?.copyWith(formatStreams: null, adaptiveFormats: null) ?? offline;
    if (retry == null) return Future.value();
    final previousRoute = video?.backendPlayback;
    final selector = previousRoute?.server.backendSelector;
    final manualRoute =
        previousRoute?.manualSelection == true && selector != null
            ? BackendPlayback.manual(previousRoute!.preferredServer,
                selector.selectedValue(previousRoute.server))
            : null;
    final operation = _switchToVideo(retry,
        startAt: state.position,
        playing: true,
        backendRequest: manualRoute,
        retainOnFailure: true);
    late final Future<void> result;
    result = operation.whenComplete(() {
      if (identical(_currentVideoRetry, result)) {
        _currentVideoRetry = null;
        _currentVideoRetryGeneration = null;
      }
    });
    _currentVideoRetry = result;
    _currentVideoRetryGeneration = _videoSwitchGeneration;
    return result;
  }

  void togglePlaying() {
    state.isPlaying ? pause() : play();
  }

  void handleAudioInterruption(AudioInterruptionEvent event) {
    if (isClosed || _isDisposing) return;
    if (event.begin) {
      if (_playbackInterrupted && _audioInterruptionType == event.type) return;
      _audioFocusRevision++;
      // Permanent loss abandons focus and has no promised end event. Cancel
      // automatic playback, while allowing a later explicit Play to ask again.
      final permanent = event.type == AudioInterruptionType.unknown;
      final continuing = !permanent &&
          _playbackInterrupted &&
          _interruptionIntentRevision == _transportIntentRevision &&
          _interruptionVideoGeneration == _videoSwitchGeneration;
      final resume = continuing
          ? _resumePlaybackAfterInterruption
          : requestedPlaying ||
              (_backendSwitchPending && _requestedPlaying != false);
      _playbackInterrupted = !permanent;
      _audioInterruptionType = event.type;
      if (permanent) {
        _requestedPlaying = false;
        _transportIntentRevision++;
        _videoFocusActivationRequired = true;
      }
      _recoveryProgressPosition = null;
      // A second temporary focus type belongs to the same interruption. Native
      // Pause reports must not replace the original user intent or forget that
      // a replacement audio decoder mounted while playback was blocked.
      _resumeReplacedAudioAfterInterruption =
          continuing && _resumeReplacedAudioAfterInterruption;
      _interruptionIntentRevision = _transportIntentRevision;
      _interruptionVideoGeneration = _videoSwitchGeneration;
      _resumePlaybackAfterInterruption = !_switchingProfile &&
          !permanent &&
          (state.hasVideo || _backendSwitchPending) &&
          resume &&
          !state.isClosing &&
          !state.isHidden;
      // just_audio owns ordinary audio focus. Video needs a pause command but
      // the interruption must not overwrite the user's remembered intent.
      if (!_switchingProfile &&
          !state.isAudio &&
          state.hasVideo &&
          !state.isClosing) {
        emit(
            state.copyWith(mediaCommand: MediaCommand(MediaCommandType.pause)));
      }
      return;
    }
    if (!_playbackInterrupted) return;
    _playbackInterrupted = false;
    _audioInterruptionType = null;
    final resumePlayback = _resumePlaybackAfterInterruption &&
        !_switchingProfile &&
        event.type != AudioInterruptionType.unknown &&
        _interruptionIntentRevision == _transportIntentRevision &&
        _interruptionVideoGeneration == _videoSwitchGeneration &&
        _requestedPlaying != false &&
        (!state.isAudio || _resumeReplacedAudioAfterInterruption) &&
        !state.isClosing &&
        !state.isHidden;
    _resumePlaybackAfterInterruption = false;
    _resumeReplacedAudioAfterInterruption = false;
    if (resumePlayback) {
      // Ordinary audio resumes through just_audio. A decoder mounted during
      // the interruption never received its beginning, so it needs this command.
      if (_videoFocusActivationRequired && !state.isAudio) {
        unawaited(_playVideoAfterFocusLoss(
            _videoSwitchGeneration, _transportIntentRevision));
      } else {
        emit(state.copyWith(mediaCommand: MediaCommand(MediaCommandType.play)));
      }
    }
  }

  void play() {
    if (_switchingProfile || isClosed || _isDisposing) return;
    _transportIntentRevision++;
    _requestedPlaying = true;
    if (!state.isAudio &&
        _videoFocusActivationRequired &&
        !playbackInterrupted) {
      unawaited(_playVideoAfterFocusLoss(
          _videoSwitchGeneration, _transportIntentRevision));
      return;
    }
    if (_playbackInterrupted) {
      _resumePlaybackAfterInterruption = true;
      _interruptionIntentRevision = _transportIntentRevision;
      _interruptionVideoGeneration = _videoSwitchGeneration;
    }
    final recovery = state.backendRecovery;
    emit(state.copyWith(
        backendRecovery:
            recovery != null && recovery.phase == BackendRecoveryPhase.ready
                ? recovery.withPhase(BackendRecoveryPhase.trying)
                : recovery,
        mediaCommand: MediaCommand(_playbackInterrupted && !state.isAudio
            ? MediaCommandType.pause
            : MediaCommandType.play)));
  }

  Future<void> _playVideoAfterFocusLoss(
      int generation, int intentRevision) async {
    final focusRevision = _audioFocusRevision;
    bool granted;
    try {
      granted =
          await (_activateVideoFocus?.call() ?? audioSession.setActive(true));
    } catch (_) {
      granted = false;
    }
    if (isClosed ||
        _isDisposing ||
        _switchingProfile ||
        generation != _videoSwitchGeneration ||
        intentRevision != _transportIntentRevision ||
        focusRevision != _audioFocusRevision ||
        _requestedPlaying != true ||
        state.isAudio ||
        state.isHidden ||
        state.isClosing ||
        playbackInterrupted) {
      return;
    }
    if (!granted) {
      _requestedPlaying = false;
      emit(state.copyWith(mediaCommand: MediaCommand(MediaCommandType.pause)));
      return;
    }
    _videoFocusActivationRequired = false;
    _audioInterruptionType = null;
    _resumePlaybackAfterInterruption = false;
    emit(state.copyWith(mediaCommand: MediaCommand(MediaCommandType.play)));
  }

  void pause() {
    _transportIntentRevision++;
    _waitingForPlaylist = false;
    _requestedPlaying = false;
    emit(state.copyWith(mediaCommand: MediaCommand(MediaCommandType.pause)));
  }

  void removeVideoFromQueue(String queueId) {
    var videos = List<Video>.from(state.videos);
    var offlineVideos = List<DownloadedVideo>.from(state.offlineVideos);
    var listToUpdate = videos.isNotEmpty ? videos : offlineVideos;
    if (!listToUpdate.any((video) => playbackQueueId(video) == queueId)) return;
    if (listToUpdate.length == 1) {
      hide();
    } else {
      var playQueue = ListQueue<String>.from(state.playQueue)
        ..removeWhere((element) => element == queueId);
      var playedVideos = List<String>.from(state.playedVideos)
        ..removeWhere((element) => element == queueId);
      listToUpdate
          .removeWhere((element) => playbackQueueId(element) == queueId);
      emit(state.copyWith(
          videos: videos,
          offlineVideos: offlineVideos,
          playQueue: playQueue,
          playedVideos: playedVideos));
    }
  }

  void videoDragged(DragUpdateDetails details) {
    // we  change the display mode if there's a big enough drag movement to avoid jittery behavior when dragging slow
    var isMini = state.isMini;
    var mediaEvent = state.mediaEvent;
    if (details.delta.dy.abs() > 3) {
      isMini = details.delta.dy > 0;
      mediaEvent = MediaEvent(
          state: MediaState.playing,
          type: MediaEventType.miniDisplayChanged,
          value: state.isMini);
    }
    var dragDistance = state.dragDistance + details.delta.dy;
    // we're going down, putting threshold high easier to switch to mini player
    emit(state.copyWith(
        isDragging: true,
        showMiniPlaceholder: true,
        top: details.globalPosition.dy - targetHeight / 2,
        dragDistance: dragDistance,
        isMini: isMini,
        mediaEvent: mediaEvent));
  }

  void videoDraggedEnd(DragEndDetails details) {
    bool showMini =
        state.dragDistance.abs() > 200 ? state.isMini : state.dragStartMini;
    // Settle the position and drag state together. A stale absolute top must
    // never survive after the gesture ends or is interrupted by Android.
    if (showMini) {
      showMiniPlayer();
    } else {
      showBigPlayer();
    }
  }

  void videoDragCancelled() {
    if (isClosed || !state.isDragging || state.isClosing) return;
    if (state.dragStartMini) {
      showMiniPlayer();
    } else {
      showBigPlayer();
    }
  }

  void videoDragStarted(DragStartDetails details) {
    emit(state.copyWith(dragDistance: 0, dragStartMini: state.isMini));
  }

  void onQueueReorder(int oldItemIndex, int newItemIndex) {
    var videos = List<Video>.from(state.videos);
    var offlineVideos = List<DownloadedVideo>.from(state.offlineVideos);
    var listToUpdate = videos.isNotEmpty ? videos : offlineVideos;
    if (oldItemIndex < 0 ||
        oldItemIndex >= listToUpdate.length ||
        newItemIndex < 0 ||
        newItemIndex > listToUpdate.length) return;
    // Flutter reports the insertion slot before removing the dragged item.
    if (oldItemIndex < newItemIndex) newItemIndex--;
    if (oldItemIndex == newItemIndex) return;
    var movedItem = listToUpdate.removeAt(oldItemIndex);
    listToUpdate.insert(newItemIndex, movedItem);
    var playedVideos = state.playedVideos;
    final currentId = state.currentQueueId;
    final current =
        listToUpdate.indexWhere((video) => playbackQueueId(video) == currentId);
    if (!settings.state.playerShuffleMode && current >= 0) {
      // Queue order determines previous/next playback outside shuffle mode.
      playedVideos = listToUpdate.take(current).map(playbackQueueId).toList();
    }
    emit(state.copyWith(
        playedVideos: playedVideos,
        videos: videos,
        offlineVideos: offlineVideos));
    generatePlayQueue();
  }

  void playVideoNext(Video video) {
    if (state.videos.isEmpty) {
      playVideo([video]);
    } else {
      final existing = state.videos
              .where((item) => playbackQueueId(item) == playbackQueueId(video))
              .firstOrNull ??
          state.videos
              .where((item) => item.videoId == video.videoId)
              .firstOrNull;
      final target = existing ?? video.copyWith(queueEntryId: null);
      final videos =
          existing == null ? [...state.videos, target] : state.videos;
      final queueId = playbackQueueId(target);
      var playQueue = ListQueue<String>.from(state.playQueue)
        ..removeWhere((id) => id == queueId)
        ..addFirst(queueId);
      emit(state.copyWith(videos: videos, playQueue: playQueue));
    }
  }

  Future<void> setSponsorBlock() async {
    final generation = _videoSwitchGeneration;
    final request = ++_sponsorRequestGeneration;
    final queueId = state.currentQueueId;
    final offline = state.offlineCurrentlyPlaying;
    final videoId = state.currentlyPlaying?.videoId ?? offline?.videoId;
    final types = SponsorSegmentType.values
        .where((type) => type.isEnabled(
            _profileDatabase.getSettings(type.settingsName())?.value))
        .toList();
    List<SponsorSegment> segments = [];
    if (videoId != null && types.isNotEmpty) {
      if (offline != null) {
        segments = offline.sponsorSegments;
      } else {
        try {
          segments = await service
              .getSponsorSegments(videoId, types)
              .timeout(const Duration(seconds: 3), onTimeout: () => []);
        } catch (error) {
          // Optional community metadata must never prevent playback.
          log.fine('SponsorBlock unavailable', error);
        }
      }
    }
    if (!isClosed &&
        !_isDisposing &&
        !_switchingProfile &&
        generation == _videoSwitchGeneration &&
        request == _sponsorRequestGeneration &&
        state.currentQueueId == queueId) {
      emit(state.copyWith(sponsorSegments: _sponsorIntervals(segments, types)));
    }
  }

  List<Pair<int>> _sponsorIntervals(
      List<SponsorSegment> segments, List<SponsorSegmentType> types) {
    final length = state.currentlyPlaying?.lengthSeconds ??
        state.offlineCurrentlyPlaying?.lengthSeconds ??
        0;
    final intervals = <Pair<int>>[];
    for (final segment in segments) {
      if (segment.actionType != 'skip' ||
          !types.contains(segment.category) ||
          segment.segment.length != 2) {
        continue;
      }
      final start = segment.segment[0];
      final end = segment.segment[1];
      if (!start.isFinite ||
          !end.isFinite ||
          start < 0 ||
          end <= start ||
          (length > 0 && start >= length)) {
        continue;
      }
      final boundedEnd = length > 0 ? end.clamp(0, length) : end;
      final startMs = start * 1000;
      final endMs = boundedEnd * 1000;
      if (!startMs.isFinite || !endMs.isFinite || endMs > maxInt) continue;
      final interval = Pair(startMs.round(), endMs.round());
      if (interval.last > interval.first) intervals.add(interval);
    }
    intervals.sort((a, b) => a.first.compareTo(b.first));
    final merged = <Pair<int>>[];
    for (final interval in intervals) {
      if (merged.isEmpty || interval.first > merged.last.last) {
        merged.add(interval);
      } else if (interval.last > merged.last.last) {
        merged[merged.length - 1] = Pair(merged.last.first, interval.last);
      }
    }
    return merged;
  }

  void seek(Duration duration) {
    _recoveryProgressPosition = null;
    if (duration.inSeconds < 0) {
      duration = Duration.zero;
    }

    var videoLength = state.currentlyPlaying?.lengthSeconds ??
        state.offlineCurrentlyPlaying?.lengthSeconds ??
        1;
    if (duration.inSeconds > (videoLength)) {
      duration = Duration(seconds: videoLength);
    }

    emit(state.copyWith(
        position: duration,
        mediaCommand: MediaCommand(MediaCommandType.seek, value: duration)));
  }

  void fastForward() {
    var newPosition = state.position + Duration(seconds: state.forwardStep);
    seek(newPosition);
    log.info('fast forward $newPosition - step: ${state.forwardStep}');
    emit(state.copyWith(
      totalFastForward: state.totalFastForward + state.forwardStep,
      forwardStep: (state.forwardStep *
              (settings.state.skipExponentially ? stepMultiplier : 1))
          .floor(),
    ));
    _debounce('fast-forward-step', const Duration(seconds: 1), () {
      emit(state.copyWith(
        forwardStep: settings.state.skipStep,
        totalFastForward: 0,
      ));
    });
  }

  void rewind() {
    seek(state.position - Duration(seconds: state.rewindStep));
    emit(state.copyWith(
      totalRewind: state.totalRewind + state.rewindStep,
      rewindStep: (state.rewindStep *
              (settings.state.skipExponentially ? stepMultiplier : 1))
          .floor(),
    ));
    _debounce('fast-rewind-step', const Duration(seconds: 1), () {
      emit(state.copyWith(
        rewindStep: settings.state.skipStep,
        totalRewind: 0,
      ));
    });
  }

  Future<MediaItem?> getMediaItem(int index) async {
    if (state.videos.isNotEmpty) {
      var e = state.videos[index];
      final music = e.musicMetadata;
      final musicThumbnails = music?.thumbnails ?? const [];
      final thumbnail = ImageObject.getBestThumbnail(
              musicThumbnails.isEmpty ? e.videoThumbnails : musicThumbnails)
          ?.url;
      String? artworkUrl;
      Map<String, String>? artworkHeaders;
      if (thumbnail != null && thumbnail.isNotEmpty) {
        final playing = state.currentlyPlaying;
        final server = (playing?.videoId == e.videoId
                ? playing?.backendPlayback?.server
                : null) ??
            e.backendPlayback?.server ??
            await db.getCurrentlySelectedServer();
        artworkUrl = invidiousImageUrl(thumbnail, server);
        if (artworkUrl != null) {
          artworkHeaders = server.headersForUrl(artworkUrl);
        }
      }
      return MediaItem(
          id: e.videoId,
          title: music?.title ?? e.title ?? '',
          artist: music?.artist ?? e.author,
          duration: Duration(seconds: e.lengthSeconds ?? 1),
          album: music?.album ?? '',
          artUri: artworkUrl == null ? null : Uri.tryParse(artworkUrl),
          artHeaders: artworkHeaders);
    } else if (state.offlineVideos.isNotEmpty) {
      var e = state.offlineVideos[index];
      var path = await e.thumbnailPath;
      return MediaItem(
          id: e.videoId,
          title: e.musicMetadata?.title ?? e.title,
          artist: e.musicMetadata?.artist ?? e.author,
          duration: Duration(seconds: e.lengthSeconds),
          album: e.musicMetadata?.album ?? '',
          artUri: Uri.file(path));
    }
    return null;
  }

  void setSpeed(double d) {
    emit(state.copyWith(
        speed: d,
        mediaCommand: MediaCommand(MediaCommandType.speed, value: d)));
  }

  /// Speed belongs to the video, not the decoder used to play it. Only a new
  /// video applies the saved preference or returns to normal speed.
  double speedForVideo(String videoId) {
    if (_speedVideoId != videoId) {
      _speedVideoId = videoId;
      emit(state.copyWith(
          speed: settings.state.rememberPlayBackSpeed
              ? settings.state.lastSpeed
              : 1));
    }
    return state.speed;
  }

  /// Retain pitch across decoders/retries for this video, never across videos.
  int pitchForVideo(String videoId) {
    if (_pitchVideoId != videoId) {
      _pitchVideoId = videoId;
      emit(state.copyWith(pitchSemitones: 0));
    }
    return state.pitchSemitones;
  }

  void setPitchSemitones(int semitones) {
    final pitch = clampPitchSemitones(semitones);
    emit(state.copyWith(
        pitchSemitones: pitch,
        mediaCommand: MediaCommand(MediaCommandType.pitch, value: pitch)));
  }

  void setFullScreen(FullScreenState fsState) {
    emit(state.copyWith(
        fullScreenState: fsState,
        mediaCommand: MediaCommand(fsState == FullScreenState.notFullScreen
            ? MediaCommandType.exitFullScreen
            : MediaCommandType.enterFullScreen),
        mediaEvent: MediaEvent(
            state: state.mediaEvent.state,
            type: MediaEventType.fullScreenChanged,
            value: fsState)));

    switch (fsState) {
      case FullScreenState.fullScreen:
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
        if (settings.state.forceLandscapeFullScreen && state.aspectRatio > 1) {
          SystemChrome.setPreferredOrientations([
            DeviceOrientation.landscapeLeft,
          ]);
        }
        break;
      default:
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
            overlays: SystemUiOverlay.values);
        SystemChrome.setPreferredOrientations([]);
        SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle());
    }
  }

  Future<void> enterPip() async {
    if (_pip == null || !state.hasVideo || state.isAudio) return;
    try {
      if (!await SimplePip.isPipAvailable || isClosed) return;
      await _pip!.enterPipMode(
        aspectRatio: ((_pipAspectRatio(state) * 1000).round(), 1000),
        autoEnter: _autoPipEnabled(state),
      );
    } on MissingPluginException {
      // PiP is optional on Android devices.
    } on PlatformException catch (error) {
      log.fine('Could not enter picture-in-picture', error);
    }
  }

  void setMuted(bool muted) {
    emit(state.copyWith(
        mediaCommand: MediaCommand(
            muted ? MediaCommandType.mute : MediaCommandType.unmute)));
  }

  Duration get duration => Duration(
      seconds: (state.currentlyPlaying?.lengthSeconds ??
          state.offlineCurrentlyPlaying?.lengthSeconds ??
          1));

  double get progress {
    final length = duration.inMilliseconds;
    return length <= 0
        ? 0
        : (state.position.inMilliseconds / length).clamp(0.0, 1.0);
  }

  void switchAudio(bool value) {
    if (state.currentlyPlaying != null &&
        !state.isClosing &&
        state.isAudio != value) {
      final resumeVideo = !value &&
          _videoFocusActivationRequired &&
          state.isPlaying &&
          requestedPlaying;
      if (_playbackInterrupted &&
          _interruptionVideoGeneration == _videoSwitchGeneration) {
        _resumeReplacedAudioAfterInterruption =
            value && _audioInterruptionType == AudioInterruptionType.pause;
      }
      _progressGeneration++;
      // The replacement decoder reads its starting position when it mounts.
      videoDragCancelled();
      emit(state.copyWith(isAudio: value, startAt: state.position));
      if (resumeVideo) play();
      if (_playlistReference != null) {
        unawaited(saveProgress(state.position.inSeconds));
      }
    }
  }

  void generatePlayQueue() {
    final played = state.playedVideos.toSet();
    final currentId = state.currentQueueId;
    if (currentId != null) played.add(currentId);
    List<String> videos =
        (state.videos.isNotEmpty ? state.videos : state.offlineVideos)
            .where((element) => !played.contains(playbackQueueId(element)))
            .map(playbackQueueId)
            .toList();

    // if we're in shuffle mode, we shuffle the collection
    if (settings.state.playerShuffleMode) {
      videos.shuffle();
    }

    ListQueue<String> playQueue = ListQueue.from(videos);
    emit(state.copyWith(playQueue: playQueue));
  }

  void onOrientationChange() {
    // A PiP window resize is not a rotation of the phone.
    if (!state.isPip &&
        getDeviceType() == DeviceType.phone &&
        (state.orientation == Orientation.landscape) &&
        !state.isMini &&
        settings.state.fullscreenOnRotate) {
      setFullScreen(FullScreenState.fullScreen);
    }
  }

  void sleep(SleepTimer sleepTimer) {
    emit(state.copyWith(hasTimer: true));

    _debounce(
      'video-sleep-timer',
      sleepTimer.duration,
      () {
        emit(state.copyWith(hasTimer: false));
        pause();
        if (sleepTimer.stopVideo && !isClosed) {
          hide();
        }
      },
    );
  }

  void cancelSleep() {
    emit(state.copyWith(hasTimer: false));
    _timers.remove('video-sleep-timer')?.cancel();
  }

  void _debounce(String name, Duration delay, VoidCallback callback) {
    if (_isDisposing || isClosed) return;
    _timers.remove(name)?.cancel();
    _timers[name] = Timer(delay, () {
      _timers.remove(name);
      if (!_isDisposing && !isClosed) callback();
    });
  }
}

@freezed
sealed class PlayerState with _$PlayerState {
  const factory PlayerState(
      {
      // player display properties
      @Default(true) bool isMini,
      @Default(false) bool hasTimer,
      double? top,
      @Default(false) bool isDragging,
      @Default(0) int selectedFullScreenIndex,
      @Default(true) bool isHidden,
      @Default(false) bool isClosing,
      @Default(0) double dragDistance,
      @Default(false) bool showMiniPlaceholder,
      @Default(true) bool dragStartMini,
      @Default(targetHeight) double height,
      @Default(FullScreenState.notFullScreen) FullScreenState fullScreenState,
      @Default(false) bool muted,
      @Default(16 / 9) double aspectRatio,

      // videos to play
      Video? currentlyPlaying,
      BackendPlayback? requestedBackend,
      BackendRecovery? backendRecovery,
      @Default(false) bool recoveringPlayback,
      DownloadedVideo? offlineCurrentlyPlaying,
      @Default([]) List<Video> videos,
      @Default([]) List<DownloadedVideo> offlineVideos,

      // playlist controls
      @Default([]) List<String> playedVideos,
      required ListQueue<String> playQueue,
      @Default(false) bool isAudio,

      // playing video data
      @Default(false) bool isPip,
      @Default(Offset.zero) Offset offset,
      Duration? startAt,
      @Default(Duration.zero) Duration position,
      @Default(Duration.zero) Duration bufferedPosition,
      @Default(false) bool isPlaying,
      @Default(1.0) double speed,
      @Default(0) int pitchSemitones,

      // events
      // command we send down the stack, namely video / audio player
      MediaCommand? mediaCommand,

      // events we receive from bottom of stack
      @Default(MediaEvent(state: MediaState.idle)) MediaEvent mediaEvent,

      // sponsor block variables
      @Default([]) List<Pair<int>> sponsorSegments,
      @Default(Pair(0, 0)) Pair<int> nextSegment,

      // step in seconds when fast forawrd or fast rewind
      @Default(defaultStep) int forwardStep,
      @Default(defaultStep) rewindStep,
      @Default(0) int totalFastForward,
      @Default(0) totalRewind,
      @Default(Orientation.portrait) Orientation orientation}) = _PlayerState;

  bool get hasVideo =>
      currentlyPlaying != null || offlineCurrentlyPlaying != null;

  bool get hasQueue => offlineVideos.length > 1 || videos.length > 1;

  String? get currentQueueId {
    final video = currentlyPlaying ?? offlineCurrentlyPlaying;
    return video == null ? null : playbackQueueId(video);
  }

  const PlayerState._();

//
  static PlayerState init(List<Video>? videos) {
    return PlayerState(
        videos: assignPlaybackQueueIds(videos ?? []),
        playQueue: ListQueue.from([]));
  }
}
