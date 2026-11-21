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
import 'package:clipious/music/models/song_artwork.dart';
import 'package:clipious/music/services/music_sound_controller.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/podcasts/services/podcast_player.dart';
import 'package:clipious/podcasts/services/podcast_progress_store.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/invidious_image.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:logging/logging.dart';
import 'package:simple_pip_mode/simple_pip.dart';

import '../../downloads/models/downloaded_video.dart';
import '../../downloads/services/download_playback_source.dart';
import '../../music/models/local_music_track.dart';
import '../../music/models/song_transition.dart';
import '../../music/services/local_music_library.dart';
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
import '../models/manual_music_preparation.dart';
import '../models/playback_pitch.dart';
import '../models/backend_playback.dart';
import '../models/backend_recovery.dart';
import '../models/playback_recovery.dart';
import '../models/playback_learning_clock.dart';
import '../models/music_audio_quality.dart';
import '../models/local_music_playback.dart';

export '../../videos/models/db/progress.dart' show playbackHistoryRevision;

part 'player.freezed.dart';
part 'adjacent_music.dart';

typedef _PreparedMusicSelection = ({
  IdedVideo entry,
  Duration position,
  List<SponsorSegment> savedSponsors,
});

const double targetHeight = 66;
const skipToVideoThrottleName = 'skip-to-video';
const stepMultiplier = 1.15;

const maxInt = -1 >>> 1;

var log = Logger('MiniPlayerController');

enum PlayerRepeat { noRepeat, repeatAll, repeatOne }

enum _MusicEndWait { selection, replay }

class _PlaybackRefreshRequest {
  final Video video;
  final int generation;
  final observers = <bool Function()>{};
  late final Future<Video?> result;

  _PlaybackRefreshRequest(this.video, this.generation);

  bool get active => observers.any((observer) => observer());
}

class _RecommendationPlayback {
  final Video video;
  final RecommendationDomain domain;
  final RecommendationService service;
  final int generation;
  final String id;
  final clock = PlaybackLearningClock();
  Duration lastCheckpoint = Duration.zero;
  bool clickPending;

  _RecommendationPlayback(
      this.video, this.domain, this.service, this.id, this.clickPending)
      : generation = service.generation(domain);
}

class PlayerCubit extends Cubit<PlayerState> with WidgetsBindingObserver {
  static PlayerCubit? _sessionOwner;
  static final _runtimePlayers = <PlayerCubit>{};
  static PodcastPlayer? _podcastOwner;
  static Future<MediaHandler>? _sharedMediaInitialization;
  ({String id, bool music, bool live})? _tuningSource;
  int _nextLocalOccurrence = 1;
  static Future<void> _sessionWrite = Future.value();
  static const _learningCheckpointInterval = Duration(seconds: 15);
  final SettingsCubit settings;
  final musicSound = MusicSoundController();
  MusicAudioQualityMenu? musicAudioQuality;
  final _learningTime = Stopwatch()..start();
  final int Function()? _learningTimeMicroseconds;
  _RecommendationPlayback? _learningPlayback;
  int _learningSequence = 0;
  Future<void>? _learningWrite;
  String? _selectedWatchVideoId;
  final PlaylistReference? _initialPlaylistReference;
  final PlaylistLoadSession? _initialPlaylistLoader;
  final int _initialPlaylistIndex;
  final bool? _initialPlaylistAudio;
  final bool _initialFromMusic;
  // Origin follows the queue occurrence across mode switches and decoder retries.
  final _musicHistoryEntries = <String>{};
  bool _musicHistoryPlaylist = false;
  PlaybackHistoryWrite? _activeHistoryWrite;
  PlaybackHistoryWrite? _preparingHistoryWrite;
  final List<LocalMusicTrack>? _initialLocalMusic;
  PlaylistReference? _playlistReference;
  PlaylistLoadSession? _playlistLoader;
  StreamSubscription<PlaylistLoadSnapshot>? _playlistLoadSubscription;
  final _playlistEntries = LinkedHashMap<String, Video>();
  int _playlistGeneration = 0;
  bool _waitingForPlaylist = false;
  bool _waitingForPlaylistUserSkip = false;
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
  PodcastPlayer? _podcasts;
  PodcastPlayer get podcasts => _podcasts ??= PodcastPlayer(
      beforeStart: _prepareForPodcastPlayback,
      profileId: () => db.profileId,
      canPlay: () =>
          !isClosed &&
          !_isDisposing &&
          !_switchingProfile &&
          !NetworkProxy.instance.isChanging &&
          !settings.appCubit.state.globalLoading &&
          !settings.appCubit.state.sessionRecoveryRequired &&
          db.profileId == _profileDatabase.profileId,
      mediaHandler: () => _mediaSessionHandler,
      progressForProfile: (profileId) =>
          PodcastProgressStore.forProfile(db, profileId));
  PodcastPlayer? get activePodcast => _podcastOwner?.active == true
      ? _podcastOwner
      : _podcasts?.active == true
          ? _podcasts
          : null;
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
  ManualMusicPreparer? manualMusicPreparer;
  bool _preparingSelectedSong = false;
  _MusicEndWait? _musicEndWait;
  int _musicSelectionRequestRevision = 0;
  int get musicSelectionRequestRevision => _musicSelectionRequestRevision;
  ({
    int generation,
    int request,
    MediaCommand command
  })? _committingMusicSelection;
  bool get isCommittingMusicSelection =>
      _committingMusicSelection?.generation == _videoSwitchGeneration &&
      _committingMusicSelection?.request == _musicSelectionRequestRevision;
  bool isManualMusicSelectionCommand(MediaCommand command) =>
      isCommittingMusicSelection &&
      identical(_committingMusicSelection?.command, command);
  final musicSelectionFailureRevision = ValueNotifier<int>(0);
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
  ({int generation, IdedVideo entry, String title})? _openingSong;
  late final _adjacentMusic = _AdjacentMusicPreparation(this);
  int _sponsorRequestGeneration = 0;
  final _sponsorMemory = LinkedHashMap<String,
      ({DateTime expires, List<SponsorSegment> segments})>();
  final _sponsorPending = <String, Future<List<SponsorSegment>>>{};
  static final _sponsorVideoId = RegExp(r'^[A-Za-z0-9_-]{11}$');
  ({String? queueId, List<SponsorSegment> segments})? _savedSponsors;
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
  ({int generation, String from, String? to, Stopwatch elapsed})? _musicHandoff;
  Timer? _songGap;
  StreamSubscription<SettingsState>? _gapSettings;
  String? _sleepAtEndQueueId;
  DateTime? _sleepDeadline;
  Duration? _backendProgressPosition;
  (int, String?, String, bool)? _playbackStatusOwner;
  MediaEvent _lastPlaybackEvent = const MediaEvent(state: MediaState.idle);

  /// Decoder status survives presentation events such as minimizing the player.
  /// It belongs only to this queue occurrence, source generation and person.
  MediaEvent get _currentPlaybackEvent {
    if (isClosed || _switchingProfile || state.isClosing || !state.hasVideo) {
      return const MediaEvent(state: MediaState.idle);
    }
    if (_backendSwitchPending) {
      return const MediaEvent(state: MediaState.loading);
    }
    if (_playbackStatusOwner == null) return state.mediaEvent;
    return _playbackStatusOwner == _statusOwner(state)
        ? _lastPlaybackEvent
        : const MediaEvent(state: MediaState.idle);
  }

  MediaState get playbackStatus => _currentPlaybackEvent.state;

  PlaybackFailureReason? get playbackFailureReason {
    final event = _currentPlaybackEvent;
    final value = event.value;
    return event.state == MediaState.error && value is PlaybackFailureReason
        ? value
        : null;
  }

  (int, String?, String, bool) _statusOwner(PlayerState snapshot) => (
        _videoSwitchGeneration,
        snapshot.currentQueueId,
        db.profileId,
        snapshot.isAudio
      );

  void _updatePlaybackStatus(Change<PlayerState> change) {
    final next = change.nextState;
    final owner = _statusOwner(next);
    final changedOwner = _playbackStatusOwner != owner;
    if (changedOwner || !next.hasVideo || next.isClosing || _switchingProfile) {
      _lastPlaybackEvent = const MediaEvent(state: MediaState.idle);
      _playbackStatusOwner = owner;
    }
    final event = next.mediaEvent;
    if (next.hasVideo &&
        !next.isClosing &&
        !_switchingProfile &&
        (event != change.currentState.mediaEvent ||
            changedOwner &&
                (change.currentState.currentQueueId == null ||
                    event.state == MediaState.loading))) {
      if (event.type == null ||
          event.state == MediaState.loading ||
          event.state == MediaState.buffering ||
          event.state == MediaState.error ||
          event.state == MediaState.completed) {
        _lastPlaybackEvent = event;
      } else if (event.type == MediaEventType.progress &&
          _lastPlaybackEvent.state != MediaState.error &&
          _lastPlaybackEvent.state != MediaState.completed) {
        _lastPlaybackEvent = const MediaEvent(state: MediaState.playing);
      }
    }
  }

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
    _podcasts?.publishMediaSession();
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
      List<LocalMusicTrack>? initialLocalMusic,
      int startIndex = 0,
      bool? playlistAudio,
      bool fromMusic = false,
      Future<void> Function(Duration)? playbackRecoveryDelay,
      Future<bool> Function()? videoFocusActivation,
      int Function()? learningTimeMicroseconds})
      : _resumeOnReady = resume,
        _initialLocalMusic = initialLocalMusic,
        _learningTimeMicroseconds = learningTimeMicroseconds,
        _activateVideoFocus = videoFocusActivation,
        _waitForPlaybackRecovery =
            playbackRecoveryDelay ?? Future<void>.delayed,
        _initialPlaylistReference = playlistReference,
        _initialPlaylistLoader = playlistLoader,
        _initialPlaylistIndex = startIndex,
        _initialFromMusic = fromMusic,
        _initialPlaylistAudio = playlistAudio {
    _profileDatabase = db.forProfile(db.profileId);
    _runtimePlayers.add(this);
    LocalMusicLibrary.instance.addListener(_localLibraryChanged);
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
    _activeHistoryWrite?.cancel();
    _cancelMusicSelection();
    _adjacentMusic.reset();
    _clearSponsorPreparation();
    await _finishLearning();
    final podcast = activePodcast;
    if (podcast != null) await podcast.stop();
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

  void _localLibraryChanged() {
    if (isClosed || _isDisposing || _switchingProfile || state.isClosing) {
      return;
    }
    final entries = state.offlineVideos;
    if (!entries.any((entry) => isLocalMusicPlaybackId(entry.videoId))) return;
    final removed = entries
        .where((entry) => localMusicTrackForPlayback(entry.videoId) == null)
        .map((entry) => entry.videoId)
        .toSet();
    if (removed.isNotEmpty &&
        (removed.length == entries.length ||
            removed.contains(state.currentQueueId) ||
            _backendSwitchPending)) {
      // Synchronously invalidate pending opens, then stop any native reader.
      // A forgotten folder must not become the resumable session again.
      _sessionTransitionPending = true;
      hide();
      for (final stop in List.of(_beforeProfileSwitch)) {
        unawaited(stop());
      }
      final handler = _mediaSessionHandler;
      if (handler != null && _sessionOwner == this) {
        unawaited(handler.clearSession());
      }
      emit(state.copyWith(
          offlineVideos: [],
          offlineCurrentlyPlaying: null,
          playedVideos: [],
          playQueue: ListQueue<String>()));
      final database = _profileDatabase;
      _sessionWrite = _sessionWrite.then((_) async {
        final saved = PlaybackSession.decode(
            database.getSettings(playbackSessionSetting)?.value);
        if (removed.contains(saved?.currentId)) {
          await database.saveSetting(SettingsValue(playbackSessionSetting, ''));
        }
      }).catchError((Object error) {
        log.warning(
            'Could not clear the unavailable local Music session', error);
      });
      return;
    }
    DownloadedVideo refresh(DownloadedVideo entry) {
      final track = localMusicTrackForPlayback(entry.videoId);
      if (track == null) return entry;
      final updated = localMusicPlaybackEntry(track, entry.profileId,
          occurrenceId: entry.videoId);
      return updated.lengthSeconds == 0 && entry.lengthSeconds != 0
          ? updated.copyWith(lengthSeconds: entry.lengthSeconds)
          : updated;
    }

    final refreshed = [
      for (final entry in entries)
        if (!removed.contains(entry.videoId)) refresh(entry),
    ];
    final current = state.offlineCurrentlyPlaying;
    final updated = current == null ? null : refresh(current);
    if (!listEquals(refreshed, entries) || updated != current) {
      // Publish better labels and newly authorized URIs. The mounted decoder
      // keeps its open descriptor. The next open resolves the current URI.
      emit(state.copyWith(
        offlineVideos: refreshed,
        offlineCurrentlyPlaying: updated,
        playedVideos: removed.isEmpty
            ? state.playedVideos
            : state.playedVideos.where((id) => !removed.contains(id)).toList(),
        playQueue: removed.isEmpty
            ? state.playQueue
            : ListQueue.of(
                state.playQueue.where((id) => !removed.contains(id))),
      ));
    }
    final handler = _mediaSessionHandler;
    final item = handler?.mediaItem.value;
    if (handler != null &&
        item != null &&
        _sessionOwner == this &&
        updated != null &&
        item.id == updated.videoId) {
      final track = localMusicTrackForPlayback(updated.videoId);
      if (track != null) {
        final refreshedItem = _localMediaItem(updated, track);
        if (refreshedItem != item) handler.mediaItem.add(refreshedItem);
      }
    }
  }

  void _bindPlaylist(PlaylistReference? reference, List<Video> entries,
      {PlaylistLoadSession? loader,
      Iterable<Video>? sourceEntries,
      bool complete = true}) {
    _adjacentMusic.reset();
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
        final handoff = _musicHandoff;
        if (handoff != null &&
            handoff.to == null &&
            snapshot.error != null &&
            state.playQueue.isEmpty) {
          _clearMusicHandoff(endAudioWait: true);
          _waitingForPlaylist = true;
        }
        if (_waitingForPlaylist &&
            (state.playQueue.isNotEmpty || snapshot.complete)) {
          _waitingForPlaylist = false;
          if (_waitingForPlaylistUserSkip || !_inMusicQueue) {
            unawaited(_playNextNow(userInitiated: _waitingForPlaylistUserSkip));
          } else if (_musicHandoff != null || _mayAdvanceMusic) {
            // Receiving a retried page does not restore playback permission
            // lost to a pause, focus change, or disabled queue autoplay.
            _advanceAfterSongEnd();
          }
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
      if (_musicHistoryPlaylist) _musicHistoryEntries.addAll(next);
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
    _updatePlaybackStatus(change);
    super.onChange(change);
    final before = change.currentState;
    final after = change.nextState;
    final handoff = _musicHandoff;
    if (handoff != null &&
        handoff.generation == _videoSwitchGeneration &&
        !_sessionTransitionPending &&
        (after.isAudio != before.isAudio ||
            (handoff.to != null && _nextMusicQueueId(after) != handoff.to))) {
      _clearMusicHandoff(endAudioWait: true);
    }
    if (before.currentQueueId != after.currentQueueId && after.isAudio) {
      _adjacentMusic.recentlyPlayed = before.currentlyPlaying;
    }
    if (before.hasQueue != after.hasQueue &&
        before.currentQueueId == after.currentQueueId) {
      _publishLocalQueueNavigation(after);
    }
    if (before.currentlyPlaying != after.currentlyPlaying ||
        before.offlineCurrentlyPlaying != after.offlineCurrentlyPlaying ||
        before.playQueue != after.playQueue ||
        before.playedVideos != after.playedVideos ||
        before.videos != after.videos ||
        before.offlineVideos != after.offlineVideos ||
        before.isAudio != after.isAudio ||
        before.isHidden != after.isHidden ||
        before.isClosing != after.isClosing) {
      _adjacentMusic.schedule();
    }
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
    if (isLocalMusicPlaybackId(id) && localMusicTrackForPlayback(id) == null) {
      return _sessionWrite;
    }
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
          localSelectionId: isLocalMusicPlaybackId(id)
              ? LocalMusicLibrary.instance.selectionId
              : null,
          seconds: snapshot.position.inSeconds,
          audio: snapshot.isAudio,
          musicHistoryEntries: {
            for (final entry in [...snapshot.videos, ...snapshot.offlineVideos])
              if (_musicHistoryEntries.contains(playbackQueueId(entry)))
                playbackQueueId(entry),
          },
          musicHistoryPlaylist: _musicHistoryPlaylist,
          played: snapshot.playedVideos,
          next: snapshot.playQueue.toList(),
          playlistReference: _playlistReference,
          playlistEntries: _playlistEntries.values.toList(),
          playlistComplete: playlistComplete,
        ).encode());
    // An older TV screen may close after its replacement has begun playing.
    return _sessionWrite = _sessionWrite.then((_) async {
      if (_sessionOwner == this) {
        if (!isLocalMusicPlaybackId(id) &&
            watchRepository != null &&
            watchRevision != null) {
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
    if (isLocalMusicPlaybackId(saved.currentId) &&
        !LocalMusicLibrary.instance
            .acceptsSessionSelection(saved.localSelectionId)) {
      return;
    }
    _sessionTransitionPending = false;
    _musicHistoryEntries
      ..clear()
      ..addAll(saved.musicHistoryEntries ?? const <String>{});
    _musicHistoryPlaylist = saved.musicHistoryPlaylist;
    _bindPlaylist(
        saved.playlistReference?.profileId == _profileDatabase.profileId
            ? saved.playlistReference
            : null,
        saved.videos,
        complete: saved.playlistComplete,
        sourceEntries:
            saved.playlistEntries.isEmpty ? null : saved.playlistEntries);
    final offline = saved.offlineIds
        .map((id) {
          if (!isLocalMusicPlaybackId(id)) {
            return _profileDatabase.getDownloadByVideoId(id);
          }
          final track = localMusicTrackForPlayback(id);
          return track == null
              ? null
              : localMusicPlaybackEntry(track, _profileDatabase.profileId,
                  occurrenceId: id);
        })
        .whereType<DownloadedVideo>()
        .where((v) => isLocalMusicPlaybackId(v.videoId) || v.downloadComplete)
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

  Future<void> resumeSession({bool? fromMusic}) async {
    _requestedPlaying = null;
    final saved = savedSession;
    if (saved == null) return;
    if (isLocalMusicPlaybackId(saved.currentId)) {
      final generation = _videoSwitchGeneration;
      final profile = _profileDatabase.profileId;
      final library = LocalMusicLibrary.instance;
      final retry = state.mediaEvent.state == MediaState.error;
      setEvent(const MediaEvent(state: MediaState.loading));
      await library.initialize();
      if (retry) await library.revalidate();
      if (library.acceptsSessionSelection(saved.localSelectionId)) {
        if (retry &&
            library.loaded &&
            localMusicTrackForPlayback(saved.currentId) == null) {
          await library.refresh();
        } else {
          await library
              .loadForPlayback(saved.offlineIds.map(localMusicTrackId));
        }
      }
      if (isClosed ||
          _isDisposing ||
          _switchingProfile ||
          generation != _videoSwitchGeneration ||
          profile != db.profileId ||
          savedSession?.currentId != saved.currentId) {
        return;
      }
      if (!library.acceptsSessionSelection(saved.localSelectionId) ||
          localMusicTrackForPlayback(saved.currentId) == null) {
        setEvent(const MediaEvent(state: MediaState.error));
        return;
      }
    }
    restoreSession();
    // Resuming a pre-split queue from Music is a new listening action. A
    // modern queue already records each occurrence's original section.
    if (saved.musicHistoryEntries == null && (fromMusic ?? _initialFromMusic)) {
      _musicHistoryEntries.addAll(
          [...state.videos, ...state.offlineVideos].map(playbackQueueId));
      _musicHistoryPlaylist = _playlistReference != null;
    }
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
    if (isLocalMusicPlaybackId(videoId)) return;
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
          if (!isPlaybackRefreshRetryable(error,
                  hasAlternate: video.backendPlayback?.canRetry == true) ||
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

  Video? get _learningVideo {
    final online = state.currentlyPlaying;
    if (online != null) return online;
    final offline = state.offlineCurrentlyPlaying;
    return offline == null || isLocalMusicPlaybackId(offline.videoId)
        ? null
        : Video(
            videoId: offline.videoId,
            title: offline.title,
            author: offline.author,
            lengthSeconds: offline.lengthSeconds,
            musicMetadata: offline.musicMetadata);
  }

  void _beginLearning(Video? video, {bool selectedByUser = false}) {
    if (video == null ||
        _switchingProfile ||
        _isDisposing ||
        NetworkProxy.instance.isChanging) return;
    final domain = video.musicMetadata == null
        ? RecommendationDomain.video
        : RecommendationDomain.music;
    final recommendations =
        RecommendationService.forProfile(db, _profileDatabase.profileId);
    final previous = _learningPlayback;
    if (previous != null &&
        previous.video.videoId == video.videoId &&
        previous.domain == domain &&
        previous.generation == recommendations.generation(domain)) return;
    _learningPlayback = _RecommendationPlayback(
        video,
        domain,
        recommendations,
        '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}-${++_learningSequence}',
        selectedByUser && domain == RecommendationDomain.video);
  }

  void _observeLearning(MediaEvent event) {
    if (event.type == MediaEventType.playbackSample &&
        event.value is Duration) {
      // A reset or pause/resume of learning starts a fresh clock. Consumption
      // accumulated before that privacy decision cannot reappear afterward.
      _beginLearning(_learningVideo);
      if (event.state == MediaState.playing &&
          requestedPlaying &&
          !playbackInterrupted) {
        _learningPlayback?.clock.sample(
            event.value as Duration,
            _learningTimeMicroseconds?.call() ??
                _learningTime.elapsedMicroseconds,
            speed: state.speed);
        _recordConfirmedWatchClick();
        _checkpointLearning();
      } else {
        _learningPlayback?.clock.interrupt();
      }
    } else if (event.type != MediaEventType.progress &&
        (event.state != MediaState.playing ||
            event.type == MediaEventType.pause ||
            event.type == MediaEventType.seek ||
            event.type == MediaEventType.speedChanged ||
            event.type == MediaEventType.backendRetry)) {
      _learningPlayback?.clock.interrupt();
      if (event.type == MediaEventType.pause) _checkpointLearning(force: true);
    }
  }

  void _recordConfirmedWatchClick() {
    final occurrence = _learningPlayback;
    if (occurrence == null ||
        !occurrence.clickPending ||
        occurrence.clock.played <= Duration.zero) {
      return;
    }
    occurrence.clickPending = false;
    unawaited(occurrence.service
        .recordVideoClick(occurrence.video,
            occurrenceId: occurrence.id,
            expectedGeneration: occurrence.generation)
        .catchError((Object error) {
      log.fine('Could not record local watch selection', error);
    }));
  }

  void _checkpointLearning({bool force = false}) {
    final session = _learningPlayback;
    if (session == null) return;
    final played = session.clock.played;
    if (played <= session.lastCheckpoint ||
        (!force &&
            played - session.lastCheckpoint < _learningCheckpointInterval)) {
      return;
    }
    final previous = session.lastCheckpoint;
    session.lastCheckpoint = played;
    unawaited(session.service
        .checkpointPlayback(session.video,
            domain: session.domain,
            played: played,
            duration: Duration(seconds: session.video.lengthSeconds ?? 0),
            sessionId: session.id,
            expectedGeneration: session.generation)
        .catchError((Object error) {
      if (session.lastCheckpoint == played) {
        session.lastCheckpoint = previous;
      }
      log.fine('Could not checkpoint local playback learning', error);
    }));
  }

  void _recoverLearning() {
    unawaited(RecommendationService.forProfile(db, _profileDatabase.profileId)
        .recoverPlayback()
        .catchError((Object error) {
      log.fine('Could not recover local playback learning', error);
    }));
  }

  Future<void> _finishLearning({bool skipped = false, bool completed = false}) {
    final session = _learningPlayback;
    _learningPlayback = null;
    if (session == null) return _learningWrite ?? Future<void>.value();
    final played = session.clock.played;
    final write = (_learningWrite ?? Future<void>.value()).then((_) async {
      try {
        await session.service.recordPlayback(session.video,
            domain: session.domain,
            played: played,
            duration: Duration(seconds: session.video.lengthSeconds ?? 0),
            sessionId: session.id,
            expectedGeneration: session.generation,
            skipped: skipped,
            completed: completed);
      } catch (error) {
        // Recommendation persistence is optional and cannot interrupt media.
        log.fine('Could not save local listening preferences', error);
      }
    });
    _learningWrite = write;
    unawaited(write.whenComplete(() {
      if (identical(_learningWrite, write)) _learningWrite = null;
    }));
    return write;
  }

  void setEvent(MediaEvent event) {
    if (isClosed ||
        _isDisposing ||
        _switchingProfile ||
        state.isClosing ||
        activePodcast != null) return;
    // The previous decoder can still emit while replacement metadata loads.
    if (_backendSwitchPending &&
        event.type != MediaEventType.backendRetry &&
        event.type != MediaEventType.metadataRetry) {
      return;
    }
    if (event.type == MediaEventType.playbackSample) {
      _observeLearning(event);
      return;
    }
    if (event.state == MediaState.error ||
        event.state == MediaState.completed) {
      _clearPlaybackRecovery();
    }
    final handoff = _musicHandoff;
    if (event.type == MediaEventType.play ||
        event.type == MediaEventType.pause ||
        event.state == MediaState.error ||
        event.state == MediaState.idle) {
      _musicEndWait = null;
    }
    if (event.state == MediaState.error ||
        ((event.type == MediaEventType.play ||
                event.type == MediaEventType.pause) &&
            handoff != null &&
            handoff.generation + 1 == _videoSwitchGeneration &&
            handoff.to == state.currentQueueId)) {
      // The incoming decoder has already consumed its transition. Rebuilding
      // it later in the same song must not trigger a second fade-in.
      _clearMusicHandoff();
    }
    if (event.state == MediaState.completed &&
        (state.backendRecovery?.phase == BackendRecoveryPhase.trying ||
            state.backendRecovery?.phase == BackendRecoveryPhase.ready)) {
      // A short restored tail can end before two native samples prove recovery.
      // End that attempt's notice without presenting unobserved success.
      _clearBackendProgress();
      emit(state.copyWith(backendRecovery: null));
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
    _observeLearning(event);
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
      if (!_switchingProfile && !isLocalMusicPlaybackId(state.currentQueueId)) {
        unawaited(service.syncHistory());
      }
    } else {
      _checkpointLearning(force: true);
      unawaited(_saveSession(state));
      final podcast = activePodcast;
      if (podcast != null) unawaited(podcast.saveProgress());
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
    if (activePodcast != null) return;
    if (!isTv && event.type != MediaEventType.progress) {
      log.fine("Event state: ${event.state}, ${event.type}");
      final handoff = _musicHandoff;
      final waitingForSong = (_musicEndWait != null ||
              (handoff != null && settings.state.autoplayQueue)) &&
          state.isAudio &&
          !state.isHidden &&
          !state.isClosing &&
          shouldStartPlayback &&
          event.type != MediaEventType.pause &&
          event.state != MediaState.idle &&
          event.state != MediaState.error;
      // A buffered-position update does not mean the decoder finished buffering.
      // Keep Android's media service and CPU wake lock until the next song
      // starts, including intentional silence and source preparation.
      final processingState = waitingForSong
          ? AudioProcessingState.buffering
          : event.type == MediaEventType.bufferChanged
              ? mediaHandler.playbackState.value.processingState
              : const {
                    MediaState.idle: AudioProcessingState.idle,
                    MediaState.loading: AudioProcessingState.loading,
                    MediaState.buffering: AudioProcessingState.buffering,
                    MediaState.completed: AudioProcessingState.completed,
                  }[event.state] ??
                  AudioProcessingState.ready;
      final playing = waitingForSong ||
          (state.isPlaying &&
              shouldStartPlayback &&
              event.type != MediaEventType.pause &&
              event.state != MediaState.error &&
              processingState != AudioProcessingState.idle &&
              processingState != AudioProcessingState.completed);
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

  void _publishLocalQueueNavigation(PlayerState snapshot) {
    final current = snapshot.currentQueueId;
    final handler = _mediaSessionHandler;
    if (handler == null ||
        _sessionOwner != this ||
        activePodcast != null ||
        snapshot.isHidden ||
        snapshot.isClosing ||
        !isLocalMusicPlaybackId(current) ||
        handler.mediaItem.value?.id != current) {
      return;
    }
    // Queue edits can happen while the decoder is paused and sends no events.
    // Keep the native transport state intact while replacing its seek/skip
    // actions to match the new queue.
    final playback = handler.playbackState.value;
    final controls = [
      for (final control in playback.controls)
        if (control == MediaControl.rewind ||
            control == MediaControl.skipToPrevious)
          snapshot.hasQueue ? MediaControl.skipToPrevious : MediaControl.rewind
        else if (control == MediaControl.fastForward ||
            control == MediaControl.skipToNext)
          snapshot.hasQueue ? MediaControl.skipToNext : MediaControl.fastForward
        else
          control,
    ];
    if (listEquals(playback.controls, controls)) return;
    handler.playbackState.add(playback.copyWith(
      controls: controls,
      queueIndex: snapshot.offlineVideos
          .indexWhere((entry) => playbackQueueId(entry) == current),
    ));
  }

  int get currentIndex {
    return (state.videos.isNotEmpty ? state.videos : state.offlineVideos)
        .indexWhere(
            (element) => playbackQueueId(element) == state.currentQueueId);
  }

  Future<MediaHandler> _initializeMediaHandler() async {
    final handler = await (_sharedMediaInitialization ??= AudioService.init(
      builder: () => MediaHandler(this),
      config: const AudioServiceConfig(
        androidNotificationChannelId:
            'com.github.dvbeckwitt.videre.channel.audio',
        androidNotificationChannelName: 'Video playback',
        androidNotificationOngoing: true,
      ),
    ));
    if (!isClosed && !_isDisposing) attachMediaHandler(handler);
    return handler;
  }

  Future<void> onReady() async {
    _recoverLearning();
    var startupGeneration = _videoSwitchGeneration;
    bool startupActive() =>
        !_isDisposing &&
        !isClosed &&
        startupGeneration == _videoSwitchGeneration;
    final startVideos = state.videos;
    final startDownload = state.offlineVideos.firstOrNull;
    if (startVideos.isEmpty &&
        startDownload == null &&
        _initialLocalMusic == null) {
      restoreSession();
    }
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

      final handler = await _initializeMediaHandler();
      if (_isDisposing || isClosed) return;
      mediaHandler = handler;
      BackButtonInterceptor.add(handleBackButton,
          name: 'miniPlayer', zIndex: 2, ifNotYetIntercepted: true);
    } else if (_initialLocalMusic != null && startupActive()) {
      await playLocalMusic(_initialLocalMusic,
          startIndex: _initialPlaylistIndex);
    } else if (startDownload != null && startupActive()) {
      final owned = db.profileId == startDownload.profileId &&
          _profileDatabase.profileId == startDownload.profileId;
      final download = owned
          ? _profileDatabase.getDownloadByVideoId(startDownload.videoId)
          : null;
      if (download == null ||
          download.profileId != startDownload.profileId ||
          download.accountId != startDownload.accountId ||
          !download.downloadComplete ||
          download.downloadFailed ||
          download.storageFailed ||
          download.authenticationRequired ||
          isLocalMusicPlaybackId(download.videoId)) {
        setEvent(const MediaEvent(state: MediaState.error));
      } else {
        await playOfflineVideos([download], fromMusic: _initialFromMusic);
      }
    } else if (startVideos.isNotEmpty && startupActive()) {
      final reference = _initialPlaylistReference;
      final switching = reference == null
          ? playVideo(startVideos,
              fromMusic: _initialFromMusic,
              startAt: state.startAt,
              startIndex:
                  _initialPlaylistIndex == 0 ? null : _initialPlaylistIndex)
          : playPlaylist(startVideos,
              fromMusic: _initialFromMusic,
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
        // Repeating a song and finishing an explicit selection can both
        // continue playback without a distinct automatic queue successor.
        if (state.isPlaying &&
            _inMusicQueue &&
            shouldStartPlayback &&
            _sleepAtEndQueueId == null) {
          final repeat = settings.state.playerRepeatMode;
          if (settings.state.autoplayQueue &&
              (repeat == PlayerRepeat.repeatOne ||
                  (repeat == PlayerRepeat.repeatAll &&
                      _nextMusicQueueId(state) == state.currentQueueId))) {
            _musicEndWait = _MusicEndWait.replay;
          } else if (_preparingSelectedSong) {
            _musicEndWait = _MusicEndWait.selection;
          }
        }
        final nextSong = _automaticMusicTarget;
        if (nextSong != null ||
            (_mayAdvanceMusic &&
                state.playQueue.isEmpty &&
                !playlistComplete &&
                _playlistLoader?.error == null)) {
          final target = nextSong == null ? null : playbackQueueId(nextSong);
          // A repeated EOF cannot restart a pause or advance a second entry.
          if (_musicHandoff?.generation == _videoSwitchGeneration &&
              _musicHandoff?.to == target) {
            return;
          }
          _musicHandoff = (
            generation: _videoSwitchGeneration,
            from: state.currentQueueId!,
            to: target,
            elapsed: Stopwatch()..start()
          );
        }
        unawaited(_finishLearning(completed: true));
        final stopAtEnd = _sleepAtEndQueueId != null &&
            _sleepAtEndQueueId == state.currentQueueId;
        if (stopAtEnd) {
          cancelSleep();
          pause();
        }
        final length = state.currentlyPlaying?.lengthSeconds ??
            state.offlineCurrentlyPlaying?.lengthSeconds ??
            0;
        if (_playlistReference != null) {
          unawaited(_completePlaylistEntry(length, advance: !stopAtEnd));
        } else {
          unawaited(saveProgress(length));
          // A late completion must not undo a Stop already in progress.
          if (!state.isClosing && !stopAtEnd) {
            if (settings.state.autoplayQueue) {
              _advanceAfterSongEnd();
            } else if (!_preparingSelectedSong && _requestedPlaying != false) {
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

  Future<void> _completePlaylistEntry(int length,
      {required bool advance}) async {
    final handoff = _musicHandoff;
    final commandRevision = _transportIntentRevision;
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
    if (!advance ||
        isClosed ||
        _isDisposing ||
        _switchingProfile ||
        state.isClosing ||
        generation != _videoSwitchGeneration ||
        playlistGeneration != _playlistGeneration ||
        queueId != state.currentQueueId ||
        (handoff != null && handoff != _musicHandoff) ||
        commandRevision != _transportIntentRevision ||
        profileId != _profileDatabase.profileId ||
        _requestedPlaying == false) return;
    if (settings.state.autoplayQueue) {
      _advanceAfterSongEnd();
    } else if (!_preparingSelectedSong) {
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
    _activeHistoryWrite?.cancel();
    _cancelMusicSelection();
    _clearMusicHandoff();
    _adjacentMusic.dispose();
    LocalMusicLibrary.instance.removeListener(_localLibraryChanged);
    await _finishLearning();
    _runtimePlayers.remove(this);
    if (identical(_podcastOwner, _podcasts)) _podcastOwner = null;
    if (_podcasts != null) await _podcasts!.close();
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _clearBackendProgress();
    NetworkProxy.instance.removeBeforeApply(_proxyChanging);
    _progressGeneration++;
    _videoSwitchGeneration++;
    _requestedBackendVideoId = null;
    await musicSound.resetSession();
    musicSound.dispose();
    await _becomingNoisySubscription?.cancel();
    await _interruptionSubscription?.cancel();
    await _updateAutoPip(state, disable: true);
    _pip?.onPipEntered = null;
    _pip?.onPipExited = null;
    await _saveSession(state);
    _bindPlaylist(null, []);
    playlistLoadingRevision.dispose();
    musicSelectionFailureRevision.dispose();
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

  int _tabForVideo(PlayerState snapshot, IdedVideo? video) {
    final selected = snapshot.selectedFullScreenIndex;
    if (selected == 1 &&
        video is Video &&
        playbackQueueId(video) != snapshot.currentQueueId &&
        settings.state.hideCommentsByDefault) {
      return 0;
    }
    return selected;
  }

  void setAudio(bool? newValue) {
    if (state.isAudio && newValue != true) _cancelMusicSelection();
    emit(state.copyWith(isAudio: newValue ?? false));
  }

  void hide() {
    if (isClosed || state.isClosing) return;
    _exitFullscreenOnStop();
    _activeHistoryWrite?.cancel();
    _cancelMusicSelection();
    unawaited(_finishLearning());
    unawaited(musicSound.resetSession());
    _clearPlaybackRecovery(resetBudget: true);
    _clearMetadataRetry();
    // Background playback must stop before the closing animation can run.
    pause();
    _tuningSource = null;
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

  Future<void> _prepareForPodcastPlayback() async {
    if (isClosed || _isDisposing || _switchingProfile) return;
    final previous = _podcastOwner;
    _podcastOwner = _podcasts;
    if (previous != null && !identical(previous, _podcasts)) {
      await previous.stop();
    }
    if (!identical(_podcastOwner, _podcasts) || _podcasts?.active != true) {
      return;
    }
    // TV routes have their own PlayerCubit. Retire pending setup and decoders
    // across those routes before allowing one publisher source to take over.
    await Future.wait([
      for (final player in List.of(_runtimePlayers))
        if (!player.isClosed && !player._isDisposing)
          player._stopForPodcastPlayback(),
    ]);
    if (isTv &&
        _mediaSessionHandler == null &&
        identical(_podcastOwner, _podcasts) &&
        _podcasts?.active == true) {
      final handler = await _initializeMediaHandler();
      if (!isClosed && !_isDisposing) mediaHandler = handler;
    }
  }

  Future<void> _stopForPodcastPlayback() async {
    if (state.hasVideo || _backendSwitchPending || !state.isHidden) {
      hide();
    } else {
      _progressGeneration++;
      _videoSwitchGeneration++;
    }
    // Teardown hooks stop the native decoder now, not after the player overlay's
    // closing animation. The saved music/video queue remains restorable.
    await Future.wait(
        List.of(_beforeProfileSwitch).map((callback) => callback()));
    await _updateAutoPip(state, disable: true);
  }

  /// Explicit credential edits retire only this account's online decoders.
  /// Offline downloads and another person's playback do not depend on them.
  static Future<void> stopForAccountChange(Server account) async {
    for (final player in List.of(_runtimePlayers)) {
      if (player.isClosed ||
          player._isDisposing ||
          player._switchingProfile ||
          player._profileDatabase.profileId != account.profileId ||
          player.state.offlineCurrentlyPlaying != null) continue;
      final generation = player._videoSwitchGeneration;
      Server? selected;
      try {
        selected = await player._profileDatabase.getCurrentlySelectedServer();
      } catch (_) {
        continue;
      }
      if (!player.isClosed &&
          !player._isDisposing &&
          generation == player._videoSwitchGeneration &&
          selected.profileId == account.profileId &&
          selected.accountId == account.accountId) {
        await player._stopForPodcastPlayback();
      }
    }
  }

  /// Android removed the task from Recents. The cached playback engine can
  /// outlive its Activity, and TV routes can own separate decoders.
  static Future<void> stopForTaskRemoval(MediaHandler handler) async {
    final players = _runtimePlayers
        .where((p) => !p.isClosed && !p._isDisposing && !p._switchingProfile)
        .toList();
    final audioSession =
        players.where((p) => p._hasAudioSession).firstOrNull?.audioSession;
    bool hasActiveOwner() =>
        _sessionOwner?.state.hasVideo == true ||
        _runtimePlayers.any((player) => player._podcasts?.active == true);
    try {
      await Future.wait([
        for (final player in players)
          player._retirePlaybackSession(changingProfile: false),
      ]);
    } finally {
      // Publishing idle can destroy the detached Flutter engine. Finish saving
      // and stopping decoders first, and preserve a newly started session.
      if (!hasActiveOwner()) {
        try {
          await audioSession?.setActive(false);
        } finally {
          if (!hasActiveOwner()) await handler.clearSession();
        }
      }
    }
  }

  Future<void> prepareForProfileSwitch() =>
      _retirePlaybackSession(changingProfile: true);

  /// Save under the current person and retire decoders without a UI animation.
  Future<void> _retirePlaybackSession({required bool changingProfile}) async {
    if (isClosed) return;
    _exitFullscreenOnStop();
    _activeHistoryWrite?.cancel();
    _cancelMusicSelection();
    _adjacentMusic.reset();
    _clearSponsorPreparation();
    _selectedWatchVideoId = null;
    final learning = _finishLearning();
    // A pending takeover has its own controller before becoming the global
    // podcast owner. On task removal, each player must stop its own controller.
    final podcast = changingProfile ? activePodcast : _podcasts;
    final stoppingPodcast = podcast?.stop(clearMediaSession: changingProfile);
    final clearingSound = musicSound.resetSession();
    _clearPlaybackRecovery(resetBudget: true);
    _clearMetadataRetry();
    pause();
    final saved = _saveSession(state);
    _watchRepository = null;
    _watchAccount = null;
    _watchVideoId = null;
    _watchRevision = null;
    _bindPlaylist(null, []);
    if (changingProfile) _switchingProfile = true;
    _progressGeneration++;
    final generation = ++_videoSwitchGeneration;
    _requestedBackendVideoId = null;
    _backendSwitchPending = false;
    _manualSelectionPending = false;
    _clearBackendProgress();
    cancelSleep();
    _tuningSource = null;
    // Invoke teardown before the empty state removes the decoder widgets.
    // Its synchronous prefix invalidates setup; await native stop below.
    final stopping = Future.wait(
        List.of(_beforeProfileSwitch).map((callback) => callback()));
    // Late decoder events are blocked above. Publish idle explicitly because
    // the UI can dispose before its queued pause event reaches AudioService.
    final clearingSession =
        changingProfile ? _mediaSessionHandler?.clearSession() : null;
    emit(PlayerState.init(null));
    await Future.wait([
      learning,
      saved,
      stopping,
      clearingSound,
      if (stoppingPodcast != null) stoppingPodcast,
      if (clearingSession != null) clearingSession
    ]);
    if (!changingProfile &&
        (isClosed || generation != _videoSwitchGeneration)) {
      return;
    }
    if (_sessionOwner == this) _sessionOwner = null;
    if (changingProfile) {
      if (_hasAudioSession) await audioSession.setActive(false);
      await _updateAutoPip(state, disable: true);
    }
  }

  Future<void> reloadForProfile() async {
    if (isClosed) return;
    _profileDatabase = db.forProfile(db.profileId);
    _watchBinding = Future.value();
    _switchingProfile = false;
    _recoverLearning();
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
    if (isLocalMusicPlaybackId(videoId)) return;
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

  // A Video action may reuse a Video occurrence, but a Music occurrence of
  // the same upload keeps its own history when played, replayed, or restored.
  Iterable<Video> get _videoSectionQueue => state.videos
      .where((entry) => !_musicHistoryEntries.contains(playbackQueueId(entry)));

  void queueVideos(List<Video> videos) {
    final ids = _videoSectionQueue.map((video) => video.videoId).toSet();
    final additions = videos
        .where((video) => !video.filtered && ids.add(video.videoId))
        .toList();
    if (additions.isEmpty) return;
    final queue = assignPlaybackQueueIds([...state.videos, ...additions]);
    _musicHistoryEntries
        .removeAll(queue.skip(state.videos.length).map(playbackQueueId));
    emit(state.copyWith(offlineVideos: [], videos: queue));
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
    if (state.hasVideo || openingSongTitle != null) {
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

  /// The chosen queue entry can be displayed while the decoder opens it.
  IdedVideo? get openingMusicEntry {
    final song = _openingSong;
    if (song == null ||
        song.generation != _videoSwitchGeneration ||
        !_sessionTransitionPending ||
        !state.isAudio ||
        state.isHidden ||
        state.isClosing) {
      return null;
    }
    return song.entry;
  }

  String? get openingSongTitle {
    final opening = openingMusicEntry;
    return opening != null && playbackQueueId(opening) != state.currentQueueId
        ? _openingSong?.title
        : null;
  }

  bool get _inMusicQueue {
    final current = openingMusicEntry ??
        state.currentlyPlaying ??
        state.offlineCurrentlyPlaying;
    return state.isAudio && _isMusicEntry(current);
  }

  bool _isMusicEntry(IdedVideo? entry) => switch (entry) {
        Video() => entry.musicMetadata != null,
        DownloadedVideo() => entry.musicMetadata != null,
        _ => false,
      };

  IdedVideo? adjacentMusicEntry({required bool previous}) {
    if (!_inMusicQueue || state.isClosing || state.isHidden) return null;
    final current = openingMusicEntry;
    final activeId =
        current == null ? state.currentQueueId : playbackQueueId(current);
    final entries =
        state.videos.isNotEmpty ? state.videos : state.offlineVideos;
    final id =
        previous ? state.playedVideos.lastOrNull : _nextMusicQueueId(state);
    if (id == null || id == activeId) return null;
    final target =
        entries.where((video) => playbackQueueId(video) == id).firstOrNull;
    return _isMusicEntry(target) ? target : null;
  }

  String? _nextMusicQueueId(PlayerState snapshot) {
    if (snapshot.playQueue.isNotEmpty) return snapshot.playQueue.first;
    if (!playlistComplete ||
        settings.state.playerRepeatMode != PlayerRepeat.repeatAll) {
      return null;
    }
    final first =
        snapshot.videos.firstOrNull ?? snapshot.offlineVideos.firstOrNull;
    return first == null ? null : playbackQueueId(first);
  }

  bool get _mayAdvanceMusic =>
      _inMusicQueue &&
      !_isDisposing &&
      !isClosed &&
      !_switchingProfile &&
      !state.isHidden &&
      !state.isClosing &&
      !NetworkProxy.instance.isChanging &&
      db.profileId == _profileDatabase.profileId &&
      !_sessionTransitionPending &&
      !_backendSwitchPending &&
      _requestedPlaying != false &&
      !playbackInterrupted &&
      _sleepAtEndQueueId == null &&
      settings.state.autoplayQueue &&
      settings.state.playerRepeatMode != PlayerRepeat.repeatOne;

  IdedVideo? get _automaticMusicTarget =>
      _mayAdvanceMusic ? adjacentMusicEntry(previous: false) : null;

  /// The actual automatic traversal, including shuffle and a repeat-all wrap.
  /// Only an actively playing Music decoder may start a second song early.
  IdedVideo? get automaticMusicSuccessor =>
      state.isPlaying ? _automaticMusicTarget : null;

  /// Remains valid across EOF accounting and the incoming decoder's takeover.
  /// A manual selection, even of this same occurrence, starts another handoff.
  bool isAutomaticMusicHandoffTo(String queueId) {
    final handoff = _musicHandoff;
    if (handoff == null ||
        handoff.to != queueId ||
        _isDisposing ||
        isClosed ||
        _switchingProfile ||
        state.isClosing ||
        state.isHidden ||
        !state.isAudio ||
        playbackInterrupted ||
        _requestedPlaying == false) {
      return false;
    }
    if (handoff.generation == _videoSwitchGeneration) {
      final target = _automaticMusicTarget;
      return handoff.from == state.currentQueueId &&
          target != null &&
          playbackQueueId(target) == queueId;
    }
    final opening = openingMusicEntry;
    return handoff.generation + 1 == _videoSwitchGeneration &&
        (opening == null ? state.currentQueueId : playbackQueueId(opening)) ==
            queueId;
  }

  void _clearMusicHandoff({bool endAudioWait = false}) {
    final handoff = _musicHandoff;
    if (handoff != null && handoff.to == null) {
      _waitingForPlaylist = false;
    }
    _songGap?.cancel();
    _songGap = null;
    unawaited(_gapSettings?.cancel());
    _gapSettings = null;
    _musicHandoff = null;
    if (handoff != null && endAudioWait) {
      mapMediaEventToMediaHandler(
          const MediaEvent(state: MediaState.completed));
    }
  }

  void _advanceAfterSongEnd() {
    var handoff = _musicHandoff;
    if (handoff == null || handoff.generation != _videoSwitchGeneration) {
      if (!_inMusicQueue ||
          (_requestedPlaying != false && !playbackInterrupted)) {
        playNext(userInitiated: false);
      }
      return;
    }
    if (handoff.to == null) {
      // A playlist may have reached the end of its loaded page. Count the
      // time already spent awaiting more entries toward the requested gap.
      if (!_mayAdvanceMusic) {
        _clearMusicHandoff(endAudioWait: true);
        return;
      }
      final target = _automaticMusicTarget;
      if (target == null) {
        if (playlistComplete) {
          _clearMusicHandoff(endAudioWait: true);
        } else {
          _watchSongWaitSettings();
        }
        playNext(userInitiated: false);
        return;
      }
      _musicHandoff = handoff = (
        generation: handoff.generation,
        from: handoff.from,
        to: playbackQueueId(target),
        elapsed: handoff.elapsed
      );
    }
    _songGap?.cancel();
    _songGap = null;
    if (!isAutomaticMusicHandoffTo(handoff.to!)) {
      _clearMusicHandoff(endAudioWait: true);
      return;
    }
    if (settings.state.songTransitionMode == SongTransitionMode.pause) {
      final remaining =
          Duration(seconds: settings.state.songTransitionSeconds) -
              handoff.elapsed.elapsed;
      if (remaining > Duration.zero) {
        _songGap = Timer(remaining, _advanceAfterSongEnd);
        _watchSongWaitSettings();
        return;
      }
    }
    unawaited(_gapSettings?.cancel());
    _gapSettings = null;
    playNext(userInitiated: false);
  }

  void _watchSongWaitSettings() {
    _gapSettings ??= settings.stream.listen((_) {
      final handoff = _musicHandoff;
      if (handoff == null || handoff.generation != _videoSwitchGeneration) {
        return;
      }
      // A slow page cannot be required to release Android's playback service.
      // A known successor also needs its configured silence recalculated.
      if (handoff.to != null || !_mayAdvanceMusic) _advanceAfterSongEnd();
    });
  }

  void addAdjacentMusicListener(ValueChanged<List<IdedVideo>> listener) =>
      _adjacentMusic.add(listener);

  void removeAdjacentMusicListener(ValueChanged<List<IdedVideo>> listener) =>
      _adjacentMusic.remove(listener);

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

  Future<void> _playNextNow({bool userInitiated = false}) async {
    if (settings.state.playerRepeatMode != PlayerRepeat.repeatOne &&
        state.playQueue.isEmpty &&
        !playlistComplete) {
      // The end of a loaded page is not the end of the playlist. Keep the
      // current item until more metadata arrives or the user retries a failure.
      _waitingForPlaylist = true;
      _waitingForPlaylistUserSkip |= userInitiated;
      playlistLoadingRevision.value++;
      return;
    }
    if (state.playQueue.isEmpty &&
        settings.state.playerRepeatMode == PlayerRepeat.noRepeat) return;
    final skipped = userInitiated || _waitingForPlaylistUserSkip;
    _waitingForPlaylistUserSkip = false;
    if (settings.state.playerRepeatMode == PlayerRepeat.repeatOne &&
        (!userInitiated || !_inMusicQueue || state.playQueue.isEmpty)) {
      seek(Duration.zero);
      play();
    } else if (state.videos.isNotEmpty || state.offlineVideos.isNotEmpty) {
      unawaited(_finishLearning(skipped: skipped));
      if (state.playQueue.isNotEmpty ||
          settings.state.playerRepeatMode == PlayerRepeat.repeatAll) {
        _sessionTransitionPending = true;
      }
      //moving current video to played list
      final opening = openingMusicEntry;
      final currentVideoId =
          opening == null ? state.currentQueueId : playbackQueueId(opening);
      if (currentVideoId != null) {
        var newPlayedVideos = List<String>.from(state.playedVideos)
          ..add(currentVideoId);
        emit(state.copyWith(playedVideos: newPlayedVideos));
      }

      if (state.playQueue.isNotEmpty) {
        final remaining = ListQueue.of(state.playQueue);
        final toPlay = remaining.removeFirst();
        emit(state.copyWith(playQueue: remaining));
        final entries =
            state.videos.isNotEmpty ? state.videos : state.offlineVideos;
        await _switchQueueSuccessor(
            entries.firstWhere((entry) => playbackQueueId(entry) == toPlay),
            automatic: !skipped);
      } else if (settings.state.playerRepeatMode == PlayerRepeat.repeatAll) {
        emit(state.copyWith(playedVideos: [], playQueue: ListQueue.from([])));
        final switching = _switchQueueSuccessor(
            state.videos.isNotEmpty ? state.videos[0] : state.offlineVideos[0],
            automatic: !skipped);
        final generation = _videoSwitchGeneration;
        await switching;
        if (isClosed || generation != _videoSwitchGeneration) return;
        generatePlayQueue();
      }
    }
  }

  Future<void> _switchQueueSuccessor(IdedVideo target,
      {required bool automatic}) {
    final handoff = _musicHandoff;
    if (automatic &&
        handoff != null &&
        handoff.generation == _videoSwitchGeneration &&
        handoff.to == playbackQueueId(target)) {
      return _switchToVideo(target, preserveMusicHandoff: true);
    }
    return target is Video
        ? switchToVideo(target)
        : switchToOfflineVideo(target as DownloadedVideo);
  }

  void playNext({bool userInitiated = true}) {
    if (userInitiated) {
      _cancelMusicSelection();
      _clearMusicHandoff();
    }
    if (_inMusicQueue) {
      if (userInitiated || !_sessionTransitionPending) {
        unawaited(_playNextNow(userInitiated: userInitiated));
      }
      return;
    }
    EasyThrottle.throttle(skipToVideoThrottleName, const Duration(seconds: 1),
        () async {
      await _playNextNow(userInitiated: userInitiated);
    });
  }

  void playPrevious() {
    _cancelMusicSelection();
    _clearMusicHandoff();
    Future<void> previous() async {
      if (state.playedVideos.isNotEmpty) {
        unawaited(_finishLearning(skipped: true));
        _sessionTransitionPending = true;
        // putting back current video in play queue
        final opening = openingMusicEntry;
        final currentVideoId =
            opening == null ? state.currentQueueId : playbackQueueId(opening);
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
    }

    if (_inMusicQueue) {
      unawaited(previous());
    } else {
      EasyThrottle.throttle(
          skipToVideoThrottleName, const Duration(seconds: 1), previous);
    }
  }

  void _setPlaying(bool playing) {
    emit(state.copyWith(isPlaying: playing));
  }

  void _releaseMusicEndWait() {
    if (_musicEndWait == null) return;
    _musicEndWait = null;
    mapMediaEventToMediaHandler(const MediaEvent(state: MediaState.completed));
  }

  void _abandonMusicSelection({bool keepEndWait = false}) {
    _preparingHistoryWrite?.cancel();
    _preparingHistoryWrite = null;
    _preparingSelectedSong = false;
    if (!keepEndWait && _musicEndWait == _MusicEndWait.selection) {
      _releaseMusicEndWait();
    }
    manualMusicPreparer?.cancelMusicSelection();
  }

  void _cancelMusicSelection({bool keepEndWait = false}) {
    _musicSelectionRequestRevision++;
    _abandonMusicSelection(keepEndWait: keepEndWait);
  }

  bool get _canPrepareMusicSelection =>
      manualMusicPreparer != null &&
      _inMusicQueue &&
      !state.isHidden &&
      !state.isClosing &&
      (state.isPlaying || _musicHandoff != null || _musicEndWait != null);

  PlaybackHistoryWrite? _beginHistoryWrite(IdedVideo entry, {bool? fromMusic}) {
    if (isLocalMusicPlaybackId(entry.videoId)) return null;
    final music =
        fromMusic ?? _musicHistoryEntries.contains(playbackQueueId(entry));
    return _profileDatabase.beginPlaybackHistory(
        music ? PlaybackHistoryOrigin.music : PlaybackHistoryOrigin.video,
        entry.videoId);
  }

  Future<_PreparedMusicSelection?> _prepareMusicSelection(
      IdedVideo entry, Duration startAt,
      {bool? fromMusic}) async {
    _preparingHistoryWrite = _beginHistoryWrite(entry, fromMusic: fromMusic);
    _preparingSelectedSong = true;
    final request = _musicSelectionRequestRevision;
    final preparer = manualMusicPreparer!;
    final database = _profileDatabase;
    final proxy = NetworkProxy.instance.config;
    final library = LocalMusicLibrary.instance;
    final localSelection = library.selectionId;
    bool current() =>
        !isClosed &&
        !_isDisposing &&
        !_switchingProfile &&
        !state.isClosing &&
        !state.isHidden &&
        state.isAudio &&
        _musicSelectionRequestRevision == request &&
        identical(preparer, manualMusicPreparer) &&
        identical(database, _profileDatabase) &&
        database.profileId == db.profileId &&
        !NetworkProxy.instance.isChanging &&
        identical(proxy, NetworkProxy.instance.config);
    try {
      var savedSponsors = const <SponsorSegment>[];
      if (entry is Video) {
        final resolved = await _resolvePlaybackVideo(entry,
            audio: true, active: current, onPrepared: (source) {
          savedSponsors = source.download.sponsorSegments;
        });
        if (!current() || resolved == null) return null;
        entry = resolved;
      } else if (entry is DownloadedVideo) {
        if (entry.profileId != database.profileId) {
          throw StateError('This audio file belongs to another profile');
        }
        if (isLocalMusicPlaybackId(entry.videoId)) {
          final track = localMusicTrackForPlayback(entry.videoId);
          if (track == null) throw StateError('Local music file unavailable');
          entry = localMusicPlaybackEntry(track, database.profileId,
              occurrenceId: entry.videoId);
        }
        savedSponsors = entry.sponsorSegments;
      }
      final length = entry is Video
          ? entry.lengthSeconds
          : (entry as DownloadedVideo).lengthSeconds;
      final sponsorTypes = _enabledSponsorTypes;
      final cached = entry is Video
          ? _sponsorMemory[_sponsorCacheKey(entry.videoId, sponsorTypes)]
          : null;
      final remote = cached != null && cached.expires.isAfter(DateTime.now())
          ? _sponsorIntervals(cached.segments, sponsorTypes,
              videoLength: length ?? 0)
          : const <Pair<int>>[];
      final intervals = remote.isEmpty
          ? _sponsorIntervals(savedSponsors, sponsorTypes,
              videoLength: length ?? 0)
          : remote;
      final skip = intervals
          .where((segment) =>
              segment.first <= startAt.inMilliseconds &&
              startAt.inMilliseconds < segment.last)
          .firstOrNull;
      final position =
          skip == null ? startAt : Duration(milliseconds: skip.last);
      while (current()) {
        try {
          if (!await preparer.prepareMusicSelection(entry, position, current) ||
              !current()) {
            break;
          }
          if (entry is DownloadedVideo &&
              isLocalMusicPlaybackId(entry.videoId) &&
              (!library.acceptsSessionSelection(localSelection) ||
                  localMusicTrackForPlayback(entry.videoId)?.uri !=
                      entry.storageUri)) {
            throw StateError('Local music file unavailable');
          }
          return (
            entry: entry,
            position: position,
            savedSponsors: savedSponsors
          );
        } on ManualMusicSourceFailure {
          final failed = entry;
          if (failed is! Video || failed.downloadPlaybackOnly || !current()) {
            break;
          }
          // Retry the candidate's own backend without changing the active
          // song's requested route, connection status, or playback.
          final next =
              await service.retryVideoBackend(failed, isCurrent: current);
          if (!current() || next == null) break;
          entry = next;
        }
      }
    } catch (error) {
      if (current()) {
        log.fine('Could not prepare selected song (${error.runtimeType})');
      }
    }
    if (current()) {
      _abandonMusicSelection();
      musicSelectionFailureRevision.value++;
    }
    return null;
  }

  Future<void> _playVideos(List<IdedVideo> vids,
      {Duration? startAt,
      int startIndex = 0,
      bool fromMusic = false,
      bool selectedByUser = false,
      required bool audio,
      required VoidCallback bindQueue}) async {
    if (vids.isEmpty) return;
    RangeError.checkValidIndex(startIndex, vids, 'startIndex');
    final isOffline = vids.first is DownloadedVideo;
    final videos =
        isOffline ? <Video>[] : assignPlaybackQueueIds(vids.cast<Video>());
    final offlineVideos =
        isOffline ? List<DownloadedVideo>.from(vids) : <DownloadedVideo>[];
    final List<IdedVideo> entries = isOffline ? offlineVideos : videos;
    final selected = entries[startIndex];
    _cancelMusicSelection(keepEndWait: audio && _isMusicEntry(selected));
    final request = _musicSelectionRequestRevision;
    final intent = _transportIntentRevision;
    _PreparedMusicSelection? prepared;
    if (audio && _isMusicEntry(selected) && _canPrepareMusicSelection) {
      prepared = await _prepareMusicSelection(
          selected, startAt ?? Duration.zero,
          fromMusic: fromMusic);
      if (prepared == null || request != _musicSelectionRequestRevision) return;
    }
    final playingAfterPreparation = _requestedPlaying;
    bindQueue();
    _musicHistoryEntries.clear();
    if (fromMusic) _musicHistoryEntries.addAll(entries.map(playbackQueueId));
    _musicHistoryPlaylist = fromMusic && _playlistReference != null;
    if (prepared != null && intent != _transportIntentRevision) {
      _requestedPlaying = playingAfterPreparation;
    }
    setAudio(audio);
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
    PlayerState installQueue(PlayerState snapshot) => snapshot.copyWith(
        offlineVideos: offlineVideos,
        videos: videos,
        startAt: startAt,
        mediaEvent: const MediaEvent(state: MediaState.loading),
        playedVideos: previous,
        playQueue: ListQueue.of(next),
        selectedFullScreenIndex: vids.length > 1 ? 3 : 0,
        top: 500);

    if (prepared == null) {
      emit(installQueue(state));
      showBigPlayer();
    }
    await _switchToVideo(selected,
        startAt: startAt,
        playing: _requestedPlaying,
        selectedByUser: selectedByUser,
        preparedMusic: prepared,
        installQueue: prepared == null ? null : installQueue,
        expandPlayer: prepared != null);
  }

  /// skip to queue video of index
  /// if we're not shuffling, we also rebuild the playnext and played previously queue
  Future<void> skipToVideo(int index) async {
    var listToCheckAgainst =
        state.videos.isNotEmpty ? state.videos : state.offlineVideos;
    if (index < 0 || index >= listToCheckAgainst.length) {
      return;
    }
    final selected = listToCheckAgainst[index];
    final selectedId = playbackQueueId(selected);
    var currentId = state.currentQueueId;
    final switching = selectedId != currentId;
    var shuffled = settings.state.playerShuffleMode;
    _cancelMusicSelection();
    if (!switching && shuffled) return;
    final request = _musicSelectionRequestRevision;
    _PreparedMusicSelection? prepared;
    if (switching && _isMusicEntry(selected) && _canPrepareMusicSelection) {
      prepared = await _prepareMusicSelection(selected, Duration.zero);
      if (prepared == null || request != _musicSelectionRequestRevision) return;
      listToCheckAgainst =
          state.videos.isNotEmpty ? state.videos : state.offlineVideos;
      currentId = state.currentQueueId;
      shuffled = settings.state.playerShuffleMode;
      index = listToCheckAgainst
          .indexWhere((entry) => playbackQueueId(entry) == selectedId);
      if (index < 0 || currentId == selectedId) {
        _abandonMusicSelection();
        return;
      }
    }
    if (switching) {
      unawaited(_finishLearning(skipped: true));
      _sessionTransitionPending = true;
    }

    if (shuffled) {
      emit(state.copyWith(
          playedVideos: [
            ...state.playedVideos,
            if (currentId != null) currentId,
          ],
          playQueue:
              ListQueue.of(state.playQueue.where((id) => id != selectedId))));
    } else {
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
    if (switching) {
      await _switchToVideo(selected,
          selectedByUser: true,
          preparedMusic: prepared,
          playing: prepared == null ? null : _requestedPlaying);
    } else {
      await _saveSession(state);
    }
  }

  Future<Video?> _resolvePlaybackVideo(Video video,
      {required bool audio,
      required bool Function() active,
      bool retainOnFailure = false,
      BackendPlayback? backendRequest,
      void Function(DownloadPlaybackSource)? onPrepared,
      void Function(BackendPlayback)? onBackendRequest,
      VoidCallback? onRetry}) async {
    if (backendRequest == null && !retainOnFailure) {
      final downloaded = await prepareDownloadedPlaybackVideo(
          database: db,
          video: video,
          audioOnly: audio,
          preferredQuality: settings.state.rememberVideoQuality
              ? settings.state.lastVideoQuality
              : null,
          onPrepared: onPrepared,
          isCurrent: active);
      if (!active()) return null;
      final prepared = await _adjacentMusic.forPlayback(video, downloaded);
      if (!active()) return null;
      if (prepared != null) return prepared.preservingMusicMetadataFrom(video);
    }
    if (backendRequest == null &&
        video.formatStreams != null &&
        video.adaptiveFormats != null) {
      final connection = video.playbackConnection ?? video.backendPlayback;
      if (connection == null ||
          connection.matches(await db.getCurrentlySelectedServer())) {
        return active() ? video : null;
      }
      if (!active()) return null;
    }
    final music = video.musicMetadata != null;
    final loadVideo = music ? service.getMusicVideo : service.getVideo;
    final loadBackendVideo =
        music ? service.getMusicVideoForBackend : service.getVideoForBackend;
    var resolving = true;
    bool stillResolving() => resolving && active();
    try {
      final result = backendRequest == null
          ? await loadVideo(video.videoId, onBackendRequest: (request) {
              if (stillResolving()) onBackendRequest?.call(request);
            },
              loadObserver: VideoLoadObserver(
                  isCurrent: stillResolving, onRetry: onRetry ?? () {}))
          : await loadBackendVideo(video.videoId, backendRequest,
              isCurrent: active);
      return active() ? result.preservingMusicMetadataFrom(video) : null;
    } finally {
      resolving = false;
    }
  }

  /// Select an occurrence, installing a prepared replacement queue atomically.
  Future<void> _switchToVideo(IdedVideo video,
      {Duration? startAt,
      bool? playing,
      BackendPlayback? backendRequest,
      bool selectedByUser = false,
      bool preserveMusicHandoff = false,
      bool retainOnFailure = false,
      _PreparedMusicSelection? preparedMusic,
      PlayerState Function(PlayerState)? installQueue,
      bool expandPlayer = false}) async {
    if (isClosed || _switchingProfile) return;
    if (preparedMusic != null) {
      _preparingSelectedSong = false;
      if ((_musicHandoff != null || _musicEndWait != null) &&
          !state.isPlaying &&
          shouldStartPlayback) {
        _musicEndWait = _MusicEndWait.selection;
      }
    }
    if (!preserveMusicHandoff) _clearMusicHandoff();
    final device = isLocalMusicPlaybackId(video.videoId);
    if (device) {
      final track = localMusicTrackForPlayback(video.videoId);
      if (video is! DownloadedVideo ||
          track == null ||
          video.profileId != _profileDatabase.profileId) {
        if (preparedMusic != null) {
          _abandonMusicSelection();
          musicSelectionFailureRevision.value++;
          _sessionTransitionPending = false;
        } else {
          setEvent(const MediaEvent(state: MediaState.error));
        }
        return;
      }
      // Data supplied by another caller or an obsolete queue entry grants no
      // read permission and must not supply a URI, title or artwork override.
      video = localMusicPlaybackEntry(track, _profileDatabase.profileId,
          occurrenceId: video.videoId);
      if (preparedMusic != null &&
          (preparedMusic.entry as DownloadedVideo).storageUri !=
              video.storageUri) {
        _abandonMusicSelection();
        musicSelectionFailureRevision.value++;
        _sessionTransitionPending = false;
        return;
      }
    }
    if (_sleepAtEndQueueId != null &&
        _sleepAtEndQueueId != playbackQueueId(video)) {
      // Muzza SleepTimer.kt pauses on a media-item transition. Recovery of the
      // same queue occurrence keeps the timer even if its source URL changes.
      cancelSleep();
      pause();
      playing = false;
    }
    if (backendRequest == null && !retainOnFailure) {
      _activeHistoryWrite?.cancel();
      _activeHistoryWrite = preparedMusic == null
          ? _beginHistoryWrite(video)
          : _preparingHistoryWrite;
      _preparingHistoryWrite = null;
      unawaited(_finishLearning());
    } else {
      _learningPlayback?.clock.interrupt();
    }
    _waitingForPlaylist = false;
    _sessionTransitionPending = true;
    _waitingForPlaylistUserSkip = false;
    // Selecting a song, including advancing the queue, starts it over. Explicit
    // session restoration and backend recovery still supply their own position.
    final music = switch (video) {
      Video() => video.musicMetadata,
      DownloadedVideo() => video.musicMetadata,
      _ => null,
    };
    if (preparedMusic != null) {
      startAt = preparedMusic.position;
    } else if (music != null) {
      startAt ??= Duration.zero;
    }
    _requestedPlaying = playing;
    final generation = ++_videoSwitchGeneration;
    _openingSong = music == null
        ? null
        : (generation: generation, entry: video, title: music.title);
    _clearPlaybackRecovery(resetBudget: true);
    bool active() => !isClosed && generation == _videoSwitchGeneration;
    final sponsorTypes = _enabledSponsorTypes;
    List<SponsorSegment>? preparedSponsorSegments;
    var savedSponsorSegments =
        preparedMusic?.savedSponsors ?? const <SponsorSegment>[];
    // Start optional community metadata while source metadata and focus are
    // loading. It never delays source setup, even on a failed connection.
    final sponsorPreparation = video is DownloadedVideo
        ? Future.value(video.sponsorSegments)
        : _loadSponsorSegments(video.videoId, sponsorTypes);
    unawaited(sponsorPreparation.then((segments) {
      if (active()) preparedSponsorSegments = segments;
    }));
    final podcast = activePodcast;
    if (podcast != null) await podcast.stop();
    if (!active()) return;
    _clearMetadataRetry();
    _progressGeneration++;
    _requestedBackendVideoId = video is Video ? video.videoId : null;
    _backendSwitchPending = true;
    _clearBackendProgress();
    // Replacing the video disposes its controls and active gesture recognizer.
    // Settle first, because that disposal does not deliver drag end/cancel.
    videoDragCancelled();
    if (preparedMusic == null) {
      emit(state.copyWith(
          isClosing: false, requestedBackend: null, backendRecovery: null));
    }
    if (backendRequest != null && !retainOnFailure) {
      _recordBackendRequest(video.videoId, backendRequest);
    }
    try {
      // we move the existing video to the stack of played video
      if (preparedMusic == null) {
        final focusRevision = _audioFocusRevision;
        final focusGranted =
            await (_videoFocusActivationRequired && !state.isAudio
                ? (_activateVideoFocus?.call() ?? audioSession.setActive(true))
                : audioSession.setActive(true));
        if (!active()) return;
        if (focusGranted && focusRevision == _audioFocusRevision) {
          _videoFocusActivationRequired = false;
        }
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

      if (preparedMusic == null) {
        emit(state.copyWith(
            mediaEvent: mediaEvent,
            videos: videos,
            currentlyPlaying: currentlyPlaying,
            offlineVideos: offlineVideos,
            offlineCurrentlyPlaying: offlineCurrentlyPlaying));
      }
      late MediaCommand mediaCommand;
      if (!isOffline) {
        final v = preparedMusic?.entry as Video? ??
            await _resolvePlaybackVideo(video as Video,
                audio: state.isAudio,
                active: active,
                retainOnFailure: retainOnFailure,
                backendRequest: backendRequest, onPrepared: (source) {
              savedSponsorSegments = source.download.sponsorSegments;
            }, onBackendRequest: (request) {
              _recordBackendRequest(video.videoId, request);
              if (request.retryIndex > 0 || request.manualSelection) {
                setEvent(MediaEvent(
                    state: MediaState.loading,
                    type: MediaEventType.backendRetry,
                    value: request.label));
              }
            }, onRetry: () {
              if (!active()) return;
              setEvent(const MediaEvent(
                  state: MediaState.loading,
                  type: MediaEventType.metadataRetry));
            });
        if (!active() || v == null) return;
        _clearMetadataRetry();
        currentlyPlaying = v;
        if (retainOnFailure) startAt = state.position;
        mediaCommand = MediaCommand(MediaCommandType.switchVideo,
            value: SwitchVideoValue(video: v, startAt: startAt));
      } else {
        offlineCurrentlyPlaying =
            preparedMusic?.entry as DownloadedVideo? ?? video;
        if (retainOnFailure) startAt = state.position;
        mediaCommand = MediaCommand(MediaCommandType.switchToOfflineVideo,
            value: offlineCurrentlyPlaying);
      }

      final length = currentlyPlaying?.lengthSeconds ??
          offlineCurrentlyPlaying?.lengthSeconds ??
          0;
      if (device) {
        _watchRepository = null;
        _watchAccount = null;
        _watchVideoId = null;
        _watchRevision = null;
      } else if (preparedMusic == null) {
        await _bindWatchSession(video.videoId,
            intentional: backendRequest == null && !retainOnFailure);
      }
      if (!active() || _switchingProfile) return;
      final progress =
          device ? 0.0 : _profileDatabase.getVideoProgress(video.videoId);
      var resumeAt = startAt ??
          Duration(seconds: progress < 0.9 ? (length * progress).floor() : 0);
      final preparedIntervals = _sponsorIntervals(
          preparedSponsorSegments ?? [], _enabledSponsorTypes,
          videoLength: length);
      final initialSegments = preparedIntervals.isNotEmpty
          ? preparedIntervals
          : _sponsorIntervals(
              offlineCurrentlyPlaying?.sponsorSegments ?? savedSponsorSegments,
              _enabledSponsorTypes,
              videoLength: length);
      final initialSkip = initialSegments
          .where((segment) =>
              segment.first <= resumeAt.inMilliseconds &&
              resumeAt.inMilliseconds < segment.last)
          .firstOrNull;
      if (initialSkip != null && preparedMusic == null) {
        resumeAt = Duration(milliseconds: initialSkip.last);
        startAt = resumeAt;
        if (currentlyPlaying != null) {
          mediaCommand = MediaCommand(MediaCommandType.switchVideo,
              value:
                  SwitchVideoValue(video: currentlyPlaying, startAt: startAt));
        }
      }
      _sessionOwner = this;
      _openingSong = null;
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
      final snapshot = installQueue?.call(state) ?? state;
      if (preparedMusic != null) {
        _committingMusicSelection = (
          generation: generation,
          request: _musicSelectionRequestRevision,
          command: mediaCommand,
        );
      }
      emit(snapshot.copyWith(
          position: resumeAt,
          startAt: startAt,
          sponsorSegments: initialSegments,
          forwardStep: settings.state.skipStep,
          rewindStep: settings.state.skipStep,
          mediaCommand: mediaCommand,
          currentlyPlaying: currentlyPlaying,
          selectedFullScreenIndex: _tabForVideo(snapshot, currentlyPlaying),
          backendRecovery:
              preparedMusic == null ? snapshot.backendRecovery : null,
          requestedBackend: currentlyPlaying?.backendPlayback,
          offlineCurrentlyPlaying: offlineCurrentlyPlaying));
      if (expandPlayer) showBigPlayer();
      _beginLearning(_learningVideo, selectedByUser: selectedByUser);
      _savedSponsors = savedSponsorSegments.isEmpty
          ? null
          : (queueId: state.currentQueueId, segments: savedSponsorSegments);
      unawaited(_saveSession(state));
      if (preparedMusic != null && !device) {
        try {
          await _bindWatchSession(video.videoId, intentional: true);
        } catch (error) {
          log.fine(
              'Could not record history for selected song (${error.runtimeType})');
        }
        if (!active()) return;
      }
      if (_playlistReference != null) {
        await saveProgress(resumeAt.inSeconds);
        if (!active()) return;
      }

      final historyVideo = _learningVideo;
      final historyWrite = _activeHistoryWrite;
      if (historyWrite != null && historyVideo != null) {
        await historyWrite.record(HistoryVideoCache(
            historyVideo.videoId,
            historyVideo.title ?? '',
            historyVideo.author,
            ImageObject.getBestThumbnail(historyVideo.videoThumbnails)?.url ??
                '',
            authorId: historyVideo.authorId,
            playedFromDownload: offlineCurrentlyPlaying != null,
            downloadAccountId: offlineCurrentlyPlaying?.accountId,
            lengthSeconds: historyVideo.lengthSeconds,
            musicMetadata: historyVideo.musicMetadata));
        if (!active()) return;
        _activeHistoryWrite = null;
        playbackHistoryRevision.value++;
      }

      await setSponsorBlock(
          prepared: sponsorPreparation, preparedTypes: sponsorTypes);
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
      if (preparedMusic != null && isCommittingMusicSelection) {
        log.fine('Could not record selected song details (${err.runtimeType})');
        return;
      }
      _clearMusicHandoff();
      _openingSong = null;
      _clearMetadataRetry();
      _backendSwitchPending = false;
      if (device ||
          retainOnFailure ||
          (video is Video &&
              (state.backendRecovery != null || video.musicMetadata != null))) {
        pause();
        videoDragCancelled();
        _sessionTransitionPending = false;
        // Retry belongs to this selection, even when metadata never arrived.
        // Do not carry the previous video's position into a newly chosen song.
        emit(state.copyWith(
            currentlyPlaying: video is Video ? video : null,
            selectedFullScreenIndex: _tabForVideo(state, video),
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
      final selection =
          BackendPlayback.manual(saved, value, health: service.backendHealth);
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

  Future<void> playOfflineVideos(List<DownloadedVideo> offlineVids,
      {int startIndex = 0, bool fromMusic = false}) async {
    if (offlineVids.isEmpty ||
        startIndex < 0 ||
        startIndex >= offlineVids.length ||
        _switchingProfile ||
        offlineVids.any(
            (video) => video.profileId != _profileDatabase.profileId)) return;
    if (offlineVids.any((video) => isLocalMusicPlaybackId(video.videoId))) {
      return;
    }
    log.fine('Playing ${offlineVids.length} offline videos');
    await _playVideos(offlineVids,
        fromMusic: fromMusic,
        startIndex: startIndex,
        audio: offlineVids[startIndex].audioOnly, bindQueue: () {
      _requestedPlaying = null;
      _sessionTransitionPending = true;
      _bindPlaylist(null, []);
    });
  }

  Future<void> playLocalMusic(List<LocalMusicTrack> tracks,
      {int startIndex = 0}) async {
    if (isClosed ||
        _isDisposing ||
        _switchingProfile ||
        _profileDatabase.profileId != db.profileId) return;
    final entries = <DownloadedVideo>[];
    final seen = <String>{};
    for (final requested in tracks) {
      final track = localMusicTrackForPlayback(requested.playbackId);
      if (track == null) {
        _cancelMusicSelection();
        if (_canPrepareMusicSelection) {
          musicSelectionFailureRevision.value++;
        } else {
          setEvent(const MediaEvent(state: MediaState.error));
        }
        return;
      }
      final id = seen.add(track.playbackId)
          ? track.playbackId
          : _newLocalOccurrence(track.playbackId, seen.contains);
      seen.add(id);
      entries.add(localMusicPlaybackEntry(track, _profileDatabase.profileId,
          occurrenceId: id));
    }
    if (startIndex < 0 || startIndex >= entries.length) {
      _cancelMusicSelection();
      if (_canPrepareMusicSelection) {
        musicSelectionFailureRevision.value++;
      } else {
        setEvent(const MediaEvent(state: MediaState.error));
      }
      return;
    }
    await _playVideos(entries, startIndex: startIndex, audio: true,
        bindQueue: () {
      _requestedPlaying = null;
      _sessionTransitionPending = true;
      _bindPlaylist(null, []);
    });
  }

  String _newLocalOccurrence(String trackId, bool Function(String) isUsed) {
    String id;
    do {
      id = '$trackId#${_nextLocalOccurrence++}';
    } while (isUsed(id));
    return id;
  }

  bool get isLocalMusicSession =>
      !state.isHidden &&
      !state.isClosing &&
      (isLocalMusicPlaybackId(state.currentQueueId) ||
          isLocalMusicPlaybackId(state.offlineVideos.firstOrNull?.videoId));

  bool get isOtherPlaybackSession =>
      activePodcast != null ||
      (!state.isHidden &&
          !state.isClosing &&
          !isLocalMusicSession &&
          (state.hasVideo ||
              state.videos.isNotEmpty ||
              state.offlineVideos.isNotEmpty ||
              state.mediaEvent.state == MediaState.loading));

  Future<void> enqueueLocalMusic(LocalMusicTrack requested,
      {required bool playNext}) async {
    if (isClosed ||
        _isDisposing ||
        _switchingProfile ||
        state.isClosing ||
        _profileDatabase.profileId != db.profileId ||
        isOtherPlaybackSession) {
      return;
    }
    final track = localMusicTrackForPlayback(requested.playbackId);
    if (track == null) return;
    if (!isLocalMusicSession) {
      await playLocalMusic([track]);
      return;
    }
    if (_sessionTransitionPending || _backendSwitchPending) return;

    final entries = state.offlineVideos;
    final currentIndex = entries
        .indexWhere((entry) => playbackQueueId(entry) == state.currentQueueId);
    if (currentIndex < 0) return;
    final used = entries.map(playbackQueueId).toSet();
    final id = _newLocalOccurrence(track.playbackId, used.contains);
    final entry = localMusicPlaybackEntry(track, _profileDatabase.profileId,
        occurrenceId: id);
    final order = ListQueue.of(state.playQueue);
    if (playNext) {
      order.addFirst(id);
    } else {
      order.addLast(id);
    }
    final updated = List<DownloadedVideo>.of(entries)
      ..insert(playNext ? currentIndex + 1 : entries.length, entry);
    emit(state.copyWith(offlineVideos: updated, playQueue: order));
    await _saveSession(state);
  }

  /// Paired immediately with playVideo by an explicit watch command. A
  /// preview, restore or automatic advance supplies no marker.
  void noteWatchSelection(String videoId) {
    _selectedWatchVideoId = videoId;
  }

  Future<void> playVideo(List<Video> v,
      {bool? audio,
      Duration? startAt,
      bool? playing,
      int? startIndex,
      bool fromMusic = false}) async {
    final selected = _selectedWatchVideoId;
    _selectedWatchVideoId = null;
    if (isClosed || _switchingProfile || v.isEmpty) return;
    if (startIndex != null) {
      RangeError.checkValidIndex(startIndex, v, 'startIndex');
      if (v[startIndex].filtered) return;
    }
    final videos = v.where((element) => !element.filtered).toList();
    if (videos.isEmpty) return;
    final index = startIndex == null
        ? 0
        : v.take(startIndex).where((video) => !video.filtered).length;
    // TODO: find how to do this with auto router
    log.fine('Playing ${videos.length} videos');

    await _playVideos(videos,
        fromMusic: fromMusic,
        startAt: startAt,
        startIndex: index,
        selectedByUser: selected == videos[index].videoId,
        audio: audio ?? (videos[index].musicMetadata != null), bindQueue: () {
      _sessionTransitionPending = true;
      _bindPlaylist(null, []);
      _requestedPlaying = playing;
    });
  }

  /// Start the selected occurrence and its surrounding queue as one operation.
  /// The index refers to the supplied playlist before filtered entries are
  /// removed, so filtering cannot silently select a different video.
  Future<void> playPlaylist(List<Video> entries,
      {required PlaylistReference reference,
      bool fromMusic = false,
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
    playlistLoader?.retain();
    try {
      await _playVideos(videos,
          fromMusic: fromMusic,
          startAt: startAt,
          startIndex: index,
          audio: audio ?? selected.musicMetadata != null, bindQueue: () {
        _sessionTransitionPending = true;
        _requestedPlaying = playing;
        _bindPlaylist(reference, assigned, loader: playlistLoader);
      });
      if (playlistLoader != null &&
          identical(_playlistLoader, playlistLoader)) {
        appendPlaylistVideos(playlistLoader.playlist.videos,
            reference: reference, generation: _playlistGeneration);
      }
    } finally {
      playlistLoader?.release();
    }
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
                selector.selectedValue(previousRoute.server),
                health: service.backendHealth)
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
      _learningPlayback?.clock.interrupt();
      _checkpointLearning(force: true);
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
      if (permanent || playbackInterrupted) {
        _releaseMusicEndWait();
        _clearMusicHandoff(endAudioWait: true);
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
    _clearMusicHandoff();
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
    _releaseMusicEndWait();
    _clearMusicHandoff(endAudioWait: true);
    _learningPlayback?.clock.interrupt();
    _checkpointLearning(force: true);
    _transportIntentRevision++;
    _waitingForPlaylist = false;
    _waitingForPlaylistUserSkip = false;
    _requestedPlaying = false;
    emit(state.copyWith(mediaCommand: MediaCommand(MediaCommandType.pause)));
  }

  /// Move an upcoming occurrence in the actual playback order used by Muzza's
  /// queue. The mounted item and played history never enter this reorder.
  void moveQueueOccurrence(String movedId, {String? beforeId}) {
    if (isClosed || _switchingProfile || _sessionTransitionPending) return;
    final order = state.playQueue.toList();
    if (movedId == beforeId ||
        movedId == state.currentQueueId ||
        (beforeId != null && beforeId == state.currentQueueId) ||
        !order.contains(movedId) ||
        (beforeId != null && !order.contains(beforeId))) {
      return;
    }
    final upcoming = order.toSet();
    order.remove(movedId);
    order.insert(
        beforeId == null ? order.length : order.indexOf(beforeId), movedId);

    List<T> applyOrder<T extends IdedVideo>(List<T> source) {
      if (settings.state.playerShuffleMode || source.isEmpty) return source;
      final byId = {for (final item in source) playbackQueueId(item): item};
      if (!upcoming.every(byId.containsKey)) return source;
      var index = 0;
      return [
        for (final item in source)
          if (upcoming.contains(playbackQueueId(item)))
            byId[order[index++]]!
          else
            item,
      ];
    }

    emit(state.copyWith(
        videos: applyOrder(state.videos),
        offlineVideos: applyOrder(state.offlineVideos),
        playQueue: ListQueue.of(order)));
  }

  List<IdedVideo> _musicQueueTimeline() => playbackQueueTraversal<IdedVideo>(
        state.videos.isNotEmpty ? state.videos : state.offlineVideos,
        played: state.playedVideos,
        current: state.currentQueueId,
        upcoming: state.playQueue,
      );

  /// Moves a song in the Music timeline without switching the mounted item.
  void moveMusicQueueOccurrence(String movedId, {String? beforeId}) {
    final currentId = state.currentQueueId;
    if (isClosed ||
        _switchingProfile ||
        _sessionTransitionPending ||
        state.isClosing ||
        movedId == currentId) {
      return;
    }
    final currentUpcoming = state.playQueue;
    if (currentId == null) {
      moveQueueOccurrence(movedId, beforeId: beforeId);
      return;
    }
    final timeline = _musicQueueTimeline();
    final ids = timeline.map(playbackQueueId).toList();
    final from = ids.indexOf(movedId);
    final to = beforeId == null ? ids.length : ids.indexOf(beforeId);
    final active = ids.indexOf(currentId);
    if (from < 0 || to < 0 || active < 0 || from == to || from + 1 == to) {
      return;
    }

    // Restored sessions can contain visible tail entries with no saved next
    // slot. Queue only the ones that must precede the explicitly moved song.
    final scheduled = currentUpcoming.toSet();
    final tail = to > active
        ? ids
            .getRange(active + 1, to)
            .where((id) => id != movedId && !scheduled.contains(id))
        : const <String>[];
    if (scheduled.contains(movedId) &&
        beforeId != currentId &&
        (scheduled.contains(beforeId) || (beforeId == null && tail.isEmpty))) {
      moveQueueOccurrence(movedId, beforeId: beforeId);
      return;
    }

    final previous = state.playedVideos.where((id) => id != movedId).toList();
    final upcoming = [...currentUpcoming.where((id) => id != movedId), ...tail];
    final destination = to <= active ? previous : upcoming;
    final slot = beforeId == null || beforeId == currentId
        ? -1
        : destination.indexOf(beforeId);
    destination.insert(slot < 0 ? destination.length : slot, movedId);
    final entry = timeline.removeAt(from);
    timeline.insert(to > from ? to - 1 : to, entry);
    final shuffled = settings.state.playerShuffleMode;
    final online = state.videos.isNotEmpty;
    emit(state.copyWith(
      videos: shuffled || !online
          ? state.videos
          : timeline.whereType<Video>().toList(),
      offlineVideos: shuffled || online
          ? state.offlineVideos
          : timeline.whereType<DownloadedVideo>().toList(),
      playedVideos: previous,
      playQueue: ListQueue.of(upcoming),
    ));
  }

  /// Select a row in the same timeline order displayed by the Music queue.
  Future<void> selectQueueOccurrence(String id) async {
    if (isClosed ||
        _switchingProfile ||
        _sessionTransitionPending ||
        state.currentQueueId == null) {
      return;
    }
    _cancelMusicSelection();
    if (state.currentQueueId == id) return;
    var timeline = _musicQueueTimeline();
    var index = timeline.indexWhere((item) => playbackQueueId(item) == id);
    if (index < 0) return;
    final selected = timeline[index];
    if (selected is DownloadedVideo &&
        selected.profileId != _profileDatabase.profileId) {
      return;
    }
    final request = _musicSelectionRequestRevision;
    _PreparedMusicSelection? prepared;
    if (_isMusicEntry(selected) && _canPrepareMusicSelection) {
      prepared = await _prepareMusicSelection(selected, Duration.zero);
      if (prepared == null || request != _musicSelectionRequestRevision) return;
      timeline = _musicQueueTimeline();
      index = timeline.indexWhere((item) => playbackQueueId(item) == id);
      if (index < 0 || state.currentQueueId == id) {
        _abandonMusicSelection();
        return;
      }
    }
    unawaited(_finishLearning(skipped: true));
    _sessionTransitionPending = true;
    emit(state.copyWith(
        playedVideos: timeline.take(index).map(playbackQueueId).toList(),
        playQueue:
            ListQueue.of(timeline.skip(index + 1).map(playbackQueueId))));
    await _switchToVideo(selected,
        selectedByUser: true,
        preparedMusic: prepared,
        playing: prepared == null ? null : _requestedPlaying);
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

  void removeInactiveQueueOccurrences(Set<String> occurrenceIds) {
    if (isClosed || _isDisposing || _switchingProfile || state.isClosing)
      return;
    final current = state.currentQueueId;
    if (current == null) return;
    bool retain(IdedVideo video) {
      final occurrence = playbackQueueId(video);
      return occurrence == current || !occurrenceIds.contains(occurrence);
    }

    final videos = state.videos.where(retain).toList();
    final offline = state.offlineVideos.where(retain).toList();
    if (videos.length == state.videos.length &&
        offline.length == state.offlineVideos.length) return;
    emit(state.copyWith(
      videos: videos,
      offlineVideos: offline,
      playedVideos: state.playedVideos
          .where((id) => id == current || !occurrenceIds.contains(id))
          .toList(),
      playQueue: ListQueue.of(state.playQueue.where(
        (id) => id == current || !occurrenceIds.contains(id),
      )),
    ));
  }

  /// Muzza QueueSelectionMenu adds new occurrences of the selected songs.
  /// Resolve copies against the current queue before exposing them to playback.
  void enqueueQueueCopies(List<Video> selection, {required bool next}) {
    if (isClosed ||
        _isDisposing ||
        _switchingProfile ||
        state.isClosing ||
        selection.isEmpty ||
        state.videos.isEmpty) return;
    final current = state.currentQueueId;
    final index =
        state.videos.indexWhere((video) => playbackQueueId(video) == current);
    if (index < 0) return;
    final originalLength = state.videos.length;
    final combined = assignPlaybackQueueIds([...state.videos, ...selection]);
    final copies = combined.skip(originalLength).toList();
    final ids = copies.map(playbackQueueId);
    _musicHistoryEntries.addAll(ids);
    emit(state.copyWith(
      videos: next
          ? [
              ...combined.take(index + 1),
              ...copies,
              ...combined.take(originalLength).skip(index + 1),
            ]
          : combined,
      playQueue: ListQueue.of(
          next ? [...ids, ...state.playQueue] : [...state.playQueue, ...ids]),
    ));
  }

  bool _canEnqueueMusicSelection(List<Video> selection) =>
      !isClosed &&
      !_isDisposing &&
      !_switchingProfile &&
      !_sessionTransitionPending &&
      !_backendSwitchPending &&
      !state.isClosing &&
      !state.isHidden &&
      selection.isNotEmpty &&
      _profileDatabase.profileId == db.profileId &&
      state.currentQueueId != null;

  List<DownloadedVideo>? _offlineMusicSelection(
      List<Video> selection, List<DownloadedVideo>? downloads) {
    if (state.offlineCurrentlyPlaying == null ||
        isLocalMusicPlaybackId(state.offlineCurrentlyPlaying?.videoId) ||
        !state.offlineVideos
            .any((video) => playbackQueueId(video) == state.currentQueueId)) {
      return null;
    }
    final selectedIds = selection.map((song) => song.videoId).toSet();
    // Saved-only queues use the download ID as their occurrence key. Do not
    // manufacture duplicates or convert the active decoder into an online queue.
    if (selectedIds.length != selection.length ||
        state.offlineVideos
            .any((video) => selectedIds.contains(video.videoId))) {
      return null;
    }
    final explicit = downloads == null
        ? null
        : {for (final download in downloads) download.videoId: download};
    if (explicit != null &&
        (downloads!.length != selection.length ||
            explicit.length != selection.length ||
            !selectedIds.every(explicit.containsKey))) {
      return null;
    }
    try {
      final result = <DownloadedVideo>[];
      for (final song in selection) {
        final saved = _profileDatabase.getDownloadByVideoId(song.videoId);
        if (saved == null ||
            saved.videoId != song.videoId ||
            !saved.downloadComplete ||
            saved.downloadFailed ||
            saved.storageFailed ||
            saved.authenticationRequired ||
            saved.profileId != _profileDatabase.profileId ||
            (explicit != null && explicit[song.videoId] != saved)) {
          return null;
        }
        result.add(saved);
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  bool canEnqueueMusicSongs(List<Video> selection,
      {List<DownloadedVideo>? downloads}) {
    if (!_canEnqueueMusicSelection(selection)) return false;
    if (state.videos.isNotEmpty) {
      return state.currentlyPlaying != null &&
          state.videos
              .any((video) => playbackQueueId(video) == state.currentQueueId);
    }
    return _offlineMusicSelection(selection, downloads) != null;
  }

  /// Shared by Muzza-style song menus. The local lookup and insertion are
  /// synchronous so no stale queue/profile snapshot can commit after an await.
  Future<bool> enqueueMusicSongs(List<Video> selection,
      {required bool next, List<DownloadedVideo>? downloads}) {
    if (!_canEnqueueMusicSelection(selection)) return Future.value(false);
    if (state.videos.isNotEmpty) {
      if (!canEnqueueMusicSongs(selection, downloads: downloads)) {
        return Future.value(false);
      }
      enqueueQueueCopies(selection, next: next);
      return Future.value(true);
    }
    final additions = _offlineMusicSelection(selection, downloads);
    if (additions == null) return Future.value(false);
    final index = state.offlineVideos
        .indexWhere((video) => playbackQueueId(video) == state.currentQueueId);
    final ids = additions.map(playbackQueueId);
    _musicHistoryEntries.addAll(ids);
    emit(state.copyWith(
      offlineVideos: next
          ? [
              ...state.offlineVideos.take(index + 1),
              ...additions,
              ...state.offlineVideos.skip(index + 1),
            ]
          : [...state.offlineVideos, ...additions],
      playQueue: ListQueue.of(
          next ? [...ids, ...state.playQueue] : [...state.playQueue, ...ids]),
    ));
    return Future.value(true);
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
    if (settings.state.playerShuffleMode) {
      // Move only the requested upcoming occurrence. Preserve the relative
      // shuffled order of every other song and the actual playback history.
      final movedId = playbackQueueId(movedItem);
      final next = state.playQueue.toList();
      if (next.remove(movedId)) {
        final nextVisibleId = listToUpdate
            .skip(newItemIndex + 1)
            .map(playbackQueueId)
            .where(next.contains)
            .firstOrNull;
        final slot =
            nextVisibleId == null ? next.length : next.indexOf(nextVisibleId);
        next.insert(slot, movedId);
        emit(state.copyWith(playQueue: ListQueue.of(next)));
      }
    } else {
      generatePlayQueue();
    }
  }

  void playVideoNext(Video video) {
    if (state.videos.isEmpty) {
      playVideo([video]);
    } else {
      final existing = _videoSectionQueue
              .where((item) => playbackQueueId(item) == playbackQueueId(video))
              .firstOrNull ??
          _videoSectionQueue
              .where((item) => item.videoId == video.videoId)
              .firstOrNull;
      final videos = existing == null
          ? assignPlaybackQueueIds(
              [...state.videos, video.copyWith(queueEntryId: null)])
          : state.videos;
      final queueId = playbackQueueId(existing ?? videos.last);
      _musicHistoryEntries.remove(queueId);
      var playQueue = ListQueue<String>.from(state.playQueue)
        ..removeWhere((id) => id == queueId)
        ..addFirst(queueId);
      emit(state.copyWith(videos: videos, playQueue: playQueue));
    }
  }

  List<SponsorSegmentType> get _enabledSponsorTypes => SponsorSegmentType.values
      .where((type) => type
          .isEnabled(_profileDatabase.getSettings(type.settingsName())?.value))
      .toList();

  void _clearSponsorPreparation() {
    _sponsorMemory.clear();
    _sponsorPending.clear();
    _savedSponsors = null;
  }

  /// Begin the optional lookup before a route waits for video metadata.
  Future<List<SponsorSegment>> prepareSponsorSegments(String videoId) async {
    if (videoId.length != 11 || !_sponsorVideoId.hasMatch(videoId)) return [];
    try {
      return await _loadSponsorSegments(videoId, _enabledSponsorTypes);
    } catch (error) {
      log.fine('SponsorBlock preparation unavailable', error);
      return [];
    }
  }

  String _sponsorCacheKey(String videoId, List<SponsorSegmentType> types) =>
      '${_profileDatabase.profileId}:${identityHashCode(service)}:$videoId:'
      '${types.map((type) => type.index).join(',')}';

  Future<List<SponsorSegment>> _loadSponsorSegments(
      String videoId, List<SponsorSegmentType> types) async {
    if (isLocalMusicPlaybackId(videoId) ||
        types.isEmpty ||
        isClosed ||
        _isDisposing ||
        _switchingProfile ||
        NetworkProxy.instance.isChanging) {
      return [];
    }
    final profile = _profileDatabase.profileId;
    final proxy = NetworkProxy.instance.config;
    final api = service;
    final key = _sponsorCacheKey(videoId, types);
    final cached = _sponsorMemory.remove(key);
    if (cached != null && cached.expires.isAfter(DateTime.now())) {
      _sponsorMemory[key] = cached;
      return cached.segments;
    }
    final existing = _sponsorPending[key];
    if (existing != null) return existing;
    if (_sponsorPending.length >= 32) return [];
    late final Future<List<SponsorSegment>> loading;
    loading = Future<List<SponsorSegment>>.sync(
            () => api.getSponsorSegments(videoId, types))
        .timeout(const Duration(seconds: 3))
        .then((segments) {
      if (!isClosed &&
          !_isDisposing &&
          !_switchingProfile &&
          _profileDatabase.profileId == profile &&
          identical(NetworkProxy.instance.config, proxy) &&
          identical(_sponsorPending[key], loading)) {
        _sponsorMemory[key] = (
          expires: DateTime.now().add(const Duration(minutes: 30)),
          segments: List.unmodifiable(segments)
        );
        while (_sponsorMemory.length > 128) {
          _sponsorMemory.remove(_sponsorMemory.keys.first);
        }
      }
      return segments;
    }).catchError((Object error) {
      log.fine('SponsorBlock unavailable', error);
      return <SponsorSegment>[];
    }).whenComplete(() {
      if (identical(_sponsorPending[key], loading)) {
        _sponsorPending.remove(key);
      }
    });
    _sponsorPending[key] = loading;
    return loading;
  }

  Future<void> setSponsorBlock(
      {Future<List<SponsorSegment>>? prepared,
      List<SponsorSegmentType>? preparedTypes}) async {
    final generation = _videoSwitchGeneration;
    final request = ++_sponsorRequestGeneration;
    final queueId = state.currentQueueId;
    final offline = state.offlineCurrentlyPlaying;
    final videoId = state.currentlyPlaying?.videoId ?? offline?.videoId;
    final types = _enabledSponsorTypes;
    List<SponsorSegment> segments = [];
    if (videoId != null && types.isNotEmpty) {
      if (offline != null) {
        segments = offline.sponsorSegments;
      } else {
        segments =
            await ((listEquals(types, preparedTypes) ? prepared : null) ??
                _loadSponsorSegments(videoId, types));
      }
    }
    if (!isClosed &&
        !_isDisposing &&
        !_switchingProfile &&
        generation == _videoSwitchGeneration &&
        request == _sponsorRequestGeneration &&
        state.currentQueueId == queueId) {
      final remote = _sponsorIntervals(segments, types);
      final saved = _savedSponsors;
      final next = remote.isEmpty && saved != null && saved.queueId == queueId
          ? _sponsorIntervals(saved.segments, types)
          : remote;
      emit(state.copyWith(sponsorSegments: next));
    }
  }

  List<Pair<int>> _sponsorIntervals(
      List<SponsorSegment> segments, List<SponsorSegmentType> types,
      {int? videoLength}) {
    final length = videoLength ??
        state.currentlyPlaying?.lengthSeconds ??
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

  void seek(Duration position) {
    _clearMusicHandoff(endAudioWait: true);
    _learningPlayback?.clock.interrupt();
    _recoveryProgressPosition = null;
    final end = duration;
    if (position.isNegative || end.isNegative) {
      position = Duration.zero;
    } else if (position > end) {
      position = end;
    }

    emit(state.copyWith(
        position: position,
        mediaCommand: MediaCommand(MediaCommandType.seek, value: position)));
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
    final profile = db.profileId;
    if (state.videos.isNotEmpty) {
      final e = state.videos[index];
      final playing = state.currentlyPlaying;
      final source = playing != null &&
              playing.videoId == e.videoId &&
              playbackQueueId(playing) == playbackQueueId(e)
          ? playing
          : e;
      final music = source.musicMetadata ?? e.musicMetadata;
      Uri? artwork;
      Map<String, String>? artworkHeaders;
      if (music != null && source.downloadPlaybackOnly) {
        final local = admittedMusicDownload(source);
        if (local?.profileId == profile) {
          artwork = (await local?.existingSongArtwork)?.uri;
        }
      } else {
        final connection = music == null
            ? source.backendPlayback ?? e.backendPlayback
            : source.playbackConnection ??
                source.backendPlayback ??
                e.playbackConnection ??
                e.backendPlayback;
        final owner = connection?.server;
        final images = music == null
            ? e.videoThumbnails
            : displaySongThumbnails(
                e.videoId,
                music.thumbnails,
                [
                  ...source.videoThumbnails,
                  if (!identical(source, e)) ...e.videoThumbnails,
                ],
                artTrack: music.isArtTrack || source.isStockArtTrack,
                instanceUrl: owner?.url ?? settings.appCubit.state.server?.url);
        final thumbnail = music == null
            ? ImageObject.getBestThumbnail(images)?.url
            : ImageObject.getThumbnailUrlsForSize(images,
                    width: 256, height: 256)
                .firstOrNull;
        if (thumbnail != null && thumbnail.isNotEmpty) {
          final server = owner ?? await db.getCurrentlySelectedServer();
          final url = invidiousImageUrl(thumbnail, server);
          if (url != null) {
            artwork = Uri.tryParse(url);
            artworkHeaders = server.headersForUrl(url);
          }
        }
      }
      return MediaItem(
          id: e.videoId,
          title: music?.title ?? e.title ?? '',
          artist: music?.artist ?? e.author,
          duration: Duration(seconds: e.lengthSeconds ?? 1),
          album: music?.album ?? '',
          artUri: artwork,
          artHeaders: artworkHeaders);
    } else if (state.offlineVideos.isNotEmpty) {
      final e = state.offlineVideos[index];
      if (e.musicMetadata != null && e.profileId != profile) return null;
      if (isLocalMusicPlaybackId(e.videoId)) {
        final track = localMusicTrackForPlayback(e.videoId);
        if (track == null) return null;
        return _localMediaItem(e, track);
      }
      final artwork = e.musicMetadata == null
          ? Uri.file(await e.thumbnailPath)
          : (await e.existingSongArtwork)?.uri;
      return MediaItem(
          id: e.videoId,
          title: e.musicMetadata?.title ?? e.title,
          artist: e.musicMetadata?.artist ?? e.author,
          duration: Duration(seconds: e.lengthSeconds),
          album: e.musicMetadata?.album ?? '',
          artUri: artwork);
    }
    return null;
  }

  MediaItem _localMediaItem(DownloadedVideo entry, LocalMusicTrack track) =>
      MediaItem(
          id: entry.videoId,
          title: track.title,
          artist: track.artist,
          album: track.album,
          duration: track.durationMs > 0
              ? Duration(milliseconds: track.durationMs)
              : Duration(seconds: entry.lengthSeconds),
          artUri: track.artPath == null ? null : Uri.file(track.artPath!));

  /// The document provider can omit duration tags on an otherwise seekable
  /// audio file. Publish the decoder's duration only for the admitted song.
  void reportLocalMusicDuration(String id, Duration duration) {
    final track = localMusicTrackForPlayback(id);
    final current = state.offlineCurrentlyPlaying;
    if (isClosed ||
        _switchingProfile ||
        state.isClosing ||
        track == null ||
        track.durationMs > 0 ||
        current == null ||
        current.videoId != id ||
        current.lengthSeconds > 0 ||
        duration <= Duration.zero) {
      return;
    }
    final seconds = (duration.inMilliseconds + 999) ~/ 1000;
    final updated = current.copyWith(lengthSeconds: seconds);
    emit(state.copyWith(offlineCurrentlyPlaying: updated, offlineVideos: [
      for (final entry in state.offlineVideos)
        if (entry.videoId == id) updated else entry
    ]));
    final handler = _mediaSessionHandler;
    final item = handler?.mediaItem.value;
    if (_sessionOwner == this && item != null && item.id == id) {
      handler!.mediaItem
          .add(item.copyWith(duration: Duration(seconds: seconds)));
    }
  }

  void setSpeed(double d) {
    emit(state.copyWith(
        speed: d,
        mediaCommand: MediaCommand(MediaCommandType.speed, value: d)));
  }

  /// A standby decoder can preview an incoming song before it becomes active.
  ({double speed, int pitch}) playbackTuningFor(IdedVideo entry,
      {bool preview = false}) {
    final source = (
      id: entry.videoId,
      music: state.isAudio && _isMusicEntry(entry),
      live: entry is Video && entry.liveNow == true,
    );
    if (_tuningSource == source) {
      return (speed: state.speed, pitch: state.pitchSemitones);
    }
    final remember = !source.live && settings.state.rememberPlayBackSpeed;
    final speed =
        remember ? settings.state.playbackSpeed(music: source.music) : 1.0;
    final pitch =
        remember && !kIsWeb && defaultTargetPlatform == TargetPlatform.android
            ? settings.state.playbackPitch(music: source.music)
            : 0;
    if (!preview) {
      _tuningSource = source;
      emit(state.copyWith(speed: speed, pitchSemitones: pitch));
    }
    return (speed: speed, pitch: pitch);
  }

  void rememberPlaybackTuning(IdedVideo? entry, {double? speed, int? pitch}) {
    if (entry == null || entry is Video && entry.liveNow == true) return;
    final music = state.isAudio && _isMusicEntry(entry);
    void save(Future<void> write) {
      unawaited(write.catchError((Object error, StackTrace stack) {
        log.warning('Could not save playback speed or pitch', error, stack);
      }));
    }

    if (speed != null) save(settings.setLastSpeed(speed, music: music));
    if (pitch != null) save(settings.setLastPitch(pitch, music: music));
  }

  void setPitchSemitones(int semitones) {
    final pitch = clampPitchSemitones(semitones);
    emit(state.copyWith(
        pitchSemitones: pitch,
        mediaCommand: MediaCommand(MediaCommandType.pitch, value: pitch)));
  }

  void _exitFullscreenOnStop() {
    if (state.fullScreenState == FullScreenState.fullScreen) {
      setFullScreen(FullScreenState.notFullScreen);
    }
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
    // Music has its own responsive artwork/queue layout. Video fullscreen
    // would hide those controls when the phone turns or expands in landscape.
    final musicAudio = state.isAudio &&
        (state.currentlyPlaying?.musicMetadata ??
                state.offlineCurrentlyPlaying?.musicMetadata) !=
            null;
    // A PiP window resize is not a rotation of the phone.
    if (!musicAudio &&
        !state.isClosing &&
        !state.isHidden &&
        !state.isPip &&
        getDeviceType() == DeviceType.phone &&
        (state.orientation == Orientation.landscape) &&
        !state.isMini &&
        settings.state.fullscreenOnRotate) {
      setFullScreen(FullScreenState.fullScreen);
    }
  }

  void sleep(SleepTimer sleepTimer) {
    _sleepAtEndQueueId = null;
    _sleepDeadline = DateTime.now().add(sleepTimer.duration);
    emit(state.copyWith(hasTimer: true));

    _debounce(
      'video-sleep-timer',
      sleepTimer.duration,
      () {
        _sleepDeadline = null;
        emit(state.copyWith(hasTimer: false));
        pause();
        if (sleepTimer.stopVideo && !isClosed) {
          hide();
        }
      },
    );
  }

  /// Muzza's alternate sleep mode is tied to a real item transition or end,
  /// rather than a timer derived from playback position.
  void sleepAtEndOfTrack() {
    final occurrence = state.currentQueueId;
    if (isClosed ||
        _isDisposing ||
        _switchingProfile ||
        state.isClosing ||
        state.isHidden ||
        !state.isAudio ||
        state.mediaEvent.state == MediaState.completed ||
        occurrence == null) {
      return;
    }
    _timers.remove('video-sleep-timer')?.cancel();
    _sleepDeadline = null;
    _sleepAtEndQueueId = occurrence;
    emit(state.copyWith(hasTimer: true));
  }

  Duration? get sleepRemaining {
    final remaining = _sleepAtEndQueueId != null
        ? duration - state.position
        : _sleepDeadline?.difference(DateTime.now());
    return remaining?.isNegative == true ? Duration.zero : remaining;
  }

  void cancelSleep() {
    _sleepAtEndQueueId = null;
    _sleepDeadline = null;
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
