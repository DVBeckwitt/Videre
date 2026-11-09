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
import '../../main.dart';
import '../../media_handler.dart';
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

export '../../videos/models/db/progress.dart' show playbackHistoryRevision;

part 'player.freezed.dart';

const double targetHeight = 66;
const skipToVideoThrottleName = 'skip-to-video';
const stepMultiplier = 1.15;

const maxInt = -1 >>> 1;

var log = Logger('MiniPlayerController');

enum PlayerRepeat { noRepeat, repeatAll, repeatOne }

class PlayerCubit extends Cubit<PlayerState> with WidgetsBindingObserver {
  static PlayerCubit? _sessionOwner;
  String? _pitchVideoId;
  String? _speedVideoId;
  static Future<void> _sessionWrite = Future.value();
  final SettingsCubit settings;
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
  int _progressGeneration = 0;
  int _videoSwitchGeneration = 0;
  int _sponsorRequestGeneration = 0;
  String? _requestedBackendVideoId;
  bool _backendSwitchPending = false;
  bool _manualSelectionPending = false;
  Timer? _backendSuccessTimer;
  final _timers = <String, Timer>{};
  Duration? _backendProgressPosition;

  /// The current user's play/pause intent also applies to a replacement source.
  bool get requestedPlaying => _requestedPlaying ?? state.isPlaying;

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

  PlayerCubit(super.initialState, this.settings, {bool resume = false})
      : _resumeOnReady = resume {
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
    if (id == null || _sessionOwner != this) return _sessionWrite;
    final queueId = snapshot.currentQueueId!;
    final database = _profileDatabase;
    final watchRepository = _watchRepository;
    final watchRevision = _watchRevision;
    final setting = SettingsValue(
        playbackSessionSetting,
        PlaybackSession(
          videos: snapshot.videos
              .map((v) => playbackQueueId(v) == queueId
                  ? snapshot.currentlyPlaying ?? v
                  : v)
              .toList(),
          offlineIds: snapshot.offlineVideos.map((v) => v.videoId).toList(),
          currentId: queueId,
          seconds: snapshot.position.inSeconds,
          audio: snapshot.isAudio,
          played: snapshot.playedVideos,
          next: snapshot.playQueue.toList(),
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
    final offline = saved.offlineIds
        .map(_profileDatabase.getDownloadByVideoId)
        .whereType<DownloadedVideo>()
        .where((v) => v.downloadComplete)
        .toList();
    final ids = {
      ...saved.videos.map(playbackQueueId),
      ...offline.map((v) => v.videoId)
    };
    final musicSession = saved.videos.any((video) =>
            playbackQueueId(video) == saved.currentId &&
            video.musicMetadata != null) ||
        offline.any((video) =>
            video.videoId == saved.currentId && video.musicMetadata != null);
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
        isAudio: saved.audio && (!isTv || musicSession)));
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
    if (_backendSwitchPending && event.type != MediaEventType.backendRetry) {
      return;
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
    }
    handleMediaEvent(event);
    mapMediaEventToMediaHandler(event);

    emit(state.copyWith(mediaEvent: event));
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
      var playbackState = PlaybackState(
        controls: [
          state.hasQueue ? MediaControl.skipToPrevious : MediaControl.rewind,
          if (state.isPlaying) MediaControl.pause else MediaControl.play,
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
        processingState: const {
              MediaState.idle: AudioProcessingState.idle,
              MediaState.loading: AudioProcessingState.loading,
              MediaState.buffering: AudioProcessingState.buffering,
              MediaState.ready: AudioProcessingState.ready,
              MediaState.completed: AudioProcessingState.completed,
              MediaState.playing: AudioProcessingState.ready,
            }[event.state] ??
            AudioProcessingState.ready,
        playing: event.state == MediaState.idle ||
                event.state == MediaState.completed
            ? false
            : state.isPlaying,
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
    audioSession.configure(const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.allowBluetooth,
    ));
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
      final switching = switchToVideo(startVideos[0], startAt: state.startAt);
      startupGeneration = _videoSwitchGeneration;
      await switching;
      if (!startupActive()) return;
      generatePlayQueue();
    }
    // Stop and newer play requests can arrive while native services initialize.
    // Finish that setup for future explicit playback, but discard stale autoplay.
    if (_resumeOnReady && startupActive()) await resumeSession();
  }

  void handleMediaEvent(MediaEvent event) {
    switch (event.state) {
      case MediaState.completed:
        unawaited(saveProgress(state.currentlyPlaying?.lengthSeconds ??
            state.offlineCurrentlyPlaying?.lengthSeconds ??
            0));
        // A late completion must not undo a Stop already in progress.
        if (!state.isClosing) {
          if (settings.state.autoplayQueue) {
            playNext();
          } else if (_requestedPlaying != false) {
            pause();
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
    await _updateAutoPip(state, disable: true);
    _pip?.onPipEntered = null;
    _pip?.onPipExited = null;
    await _saveSession(state);
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
    // Background playback must stop before the closing animation can run.
    pause();
    _pitchVideoId = null;
    _speedVideoId = null;
    final generation = ++_progressGeneration;
    _videoSwitchGeneration++;
    _requestedBackendVideoId = null;
    _clearBackendProgress();
    unawaited(_saveSession(state));
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
    pause();
    final saved = _saveSession(state);
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
    if (_switchingProfile) return;
    final videoId = state.currentlyPlaying?.videoId ??
        state.offlineCurrentlyPlaying?.videoId;
    final length = state.currentlyPlaying?.lengthSeconds ??
        state.offlineCurrentlyPlaying?.lengthSeconds ??
        0;
    if (videoId != null && length > 0) {
      int currentPosition = timeInSeconds;
      // saving progress
      var currentProgress = (currentPosition / length).clamp(0.0, 1.0);
      if (currentProgress >= db_progress.watchedProgressThreshold) {
        currentProgress =
            1; // we consider a video with 90%+ progress as watched
      }
      var progress = db_progress.Progress.named(
          progress: currentProgress, videoId: videoId);

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
            account: account);
        if (accepted &&
            account != null &&
            progress.progress > 0.1 &&
            repository.pending(account.accountId).isNotEmpty) {
          unawaited(service.syncAccountHistory(account,
              database: database, pull: false));
        }
      } else {
        await database.saveProgress(progress);
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
        isMini: false, mediaEvent: mediaEvent, top: 0, isHidden: false));
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
    if (settings.state.playerRepeatMode == PlayerRepeat.repeatOne) {
      seek(Duration.zero);
      play();
    } else if (state.videos.isNotEmpty || state.offlineVideos.isNotEmpty) {
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
        // putting back current video in play queue
        final currentVideoId = state.currentQueueId;
        var playQueue = ListQueue<String>.from(state.playQueue);
        if (currentVideoId != null) {
          playQueue.addFirst(currentVideoId);
        }

        var playedVideos = List<String>.from(state.playedVideos);
        String toPlay = playedVideos.removeLast();
        final switching = state.videos.isNotEmpty
            ? switchToVideo(state.videos
                .firstWhere((element) => playbackQueueId(element) == toPlay))
            : switchToOfflineVideo(state.offlineVideos
                .firstWhere((element) => playbackQueueId(element) == toPlay));
        final generation = _videoSwitchGeneration;
        await switching;
        if (isClosed || generation != _videoSwitchGeneration) return;
        emit(state.copyWith(playQueue: playQueue, playedVideos: playedVideos));
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

  Future<void> _playVideos(List<IdedVideo> vids, {Duration? startAt}) async {
    if (vids.isNotEmpty) {
      bool isOffline = vids[0] is DownloadedVideo;

      const mediaEvent = MediaEvent(state: MediaState.loading);

      late List<Video> videos;
      late List<DownloadedVideo> offlineVideos;
      if (isOffline) {
        videos = [];
        offlineVideos = List<DownloadedVideo>.from(vids, growable: true).cast();
      } else {
        offlineVideos = [];
        videos = assignPlaybackQueueIds(vids.cast<Video>());
      }

      var selectedFullScreenIndex = 0;
      if (vids.length > 1) {
        selectedFullScreenIndex = 3;
      }
      emit(state.copyWith(
          offlineVideos: offlineVideos,
          videos: videos,
          startAt: startAt,
          mediaEvent: mediaEvent,
          playedVideos: [],
          selectedFullScreenIndex: selectedFullScreenIndex,
          top: 500));

      showBigPlayer();
      final switching = _switchToVideo(
          isOffline ? offlineVideos.first : videos.first,
          startAt: startAt,
          playing: _requestedPlaying);
      final generation = _videoSwitchGeneration;
      await switching;
      if (isClosed || generation != _videoSwitchGeneration) return;
      generatePlayQueue();
    }
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
    await _switchToVideo(listToCheckAgainst[index]);
  }

  /// Switches to a video without changing the queue
  Future<void> _switchToVideo(IdedVideo video,
      {Duration? startAt,
      bool? playing,
      BackendPlayback? backendRequest}) async {
    if (isClosed || _switchingProfile) return;
    // Selecting a song, including advancing the queue, starts it over. Explicit
    // session restoration and backend recovery still supply their own position.
    if ((video is Video && video.musicMetadata != null) ||
        (video is DownloadedVideo && video.musicMetadata != null)) {
      startAt ??= Duration.zero;
    }
    _requestedPlaying = playing;
    final generation = ++_videoSwitchGeneration;
    bool active() => !isClosed && generation == _videoSwitchGeneration;
    _progressGeneration++;
    _requestedBackendVideoId = video is Video ? video.videoId : null;
    _backendSwitchPending = true;
    _clearBackendProgress();
    emit(state.copyWith(
        isClosing: false, requestedBackend: null, backendRecovery: null));
    if (backendRequest != null) {
      _recordBackendRequest(video.videoId, backendRequest);
    }
    try {
      // we move the existing video to the stack of played video
      await audioSession.setActive(true);
      if (!active()) return;
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
        if (reuseLoaded && video.backendPlayback != null) {
          final currentServer = await db.getCurrentlySelectedServer();
          if (!active()) return;
          reuseLoaded = video.backendPlayback!.matches(currentServer);
        }
        if (reuseLoaded && video is Video && backendRequest == null) {
          v = video;
        } else {
          void onBackendRequest(BackendPlayback request) {
            if (!active()) return;
            _recordBackendRequest(video.videoId, request);
            if (request.retryIndex > 0 || request.manualSelection) {
              setEvent(MediaEvent(
                  state: MediaState.loading,
                  type: MediaEventType.backendRetry,
                  value: request.label));
            }
          }

          v = backendRequest == null
              ? await service.getVideo(video.videoId,
                  onBackendRequest: onBackendRequest)
              : await service.getVideoForBackend(video.videoId, backendRequest,
                  onBackendRequest: onBackendRequest, isCurrent: active);
          if (!active()) return;
        }
        if (video is Video) v = v.preservingMusicMetadataFrom(video);
        currentlyPlaying = v;
        mediaCommand = MediaCommand(MediaCommandType.switchVideo,
            value: SwitchVideoValue(video: v, startAt: startAt));
      } else {
        offlineCurrentlyPlaying = video;
        mediaCommand =
            MediaCommand(MediaCommandType.switchToOfflineVideo, value: video);
      }

      final length = currentlyPlaying?.lengthSeconds ??
          offlineCurrentlyPlaying?.lengthSeconds ??
          0;
      await _bindWatchSession(video.videoId,
          intentional: backendRequest == null);
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

      if (currentlyPlaying != null) {
        await _profileDatabase.upsertHistoryVideo(HistoryVideoCache(
            currentlyPlaying.videoId,
            currentlyPlaying.title ?? '',
            currentlyPlaying.author,
            ImageObject.getBestThumbnail(currentlyPlaying.videoThumbnails)
                    ?.url ??
                '',
            authorId: currentlyPlaying.authorId,
            lengthSeconds: currentlyPlaying.lengthSeconds));
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
      _backendSwitchPending = false;
      if (video is Video &&
          (state.backendRecovery != null || video.musicMetadata != null)) {
        pause();
        emit(state.copyWith(currentlyPlaying: video));
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
    if (_switchingProfile ||
        offlineVids.any(
            (video) => video.profileId != _profileDatabase.profileId)) return;
    _requestedPlaying = null;
    log.fine('Playing ${offlineVids.length} offline videos');
    await _playVideos(offlineVids);
  }

  Future<void> playVideo(List<Video> v,
      {bool? audio, Duration? startAt, bool? playing}) async {
    _requestedPlaying = playing;
    List<Video> videos = v.where((element) => !element.filtered).toList();
    // TODO: find how to do this with auto router
    log.fine('Playing ${videos.length} videos');

    setAudio(audio ?? (videos.firstOrNull?.musicMetadata != null));

    await _playVideos(videos, startAt: startAt);
  }

  Future<void> switchToOfflineVideo(DownloadedVideo video) async {
    if (video.profileId != _profileDatabase.profileId) return;
    await _switchToVideo(video);
  }

  Future<void> switchToVideo(Video video, {Duration? startAt}) async {
    await _switchToVideo(video, startAt: startAt);
  }

  void togglePlaying() {
    state.isPlaying ? pause() : play();
  }

  void play() {
    if (_switchingProfile || isClosed || _isDisposing) return;
    _requestedPlaying = true;
    final recovery = state.backendRecovery;
    emit(state.copyWith(
        backendRecovery:
            recovery != null && recovery.phase == BackendRecoveryPhase.ready
                ? recovery.withPhase(BackendRecoveryPhase.trying)
                : recovery,
        mediaCommand: MediaCommand(MediaCommandType.play)));
  }

  void pause() {
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
    emit(state.copyWith(isDragging: false));
    _debounce(
      'drag-end',
      animationDuration,
      () => emit(state.copyWith(showMiniPlaceholder: false)),
    );
    if (showMini) {
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
        if (musicThumbnails.isNotEmpty) {
          artworkUrl = thumbnail;
        } else {
          final playing = state.currentlyPlaying;
          final server = (playing?.videoId == e.videoId
                  ? playing?.backendPlayback?.server
                  : null) ??
              e.backendPlayback?.server ??
              await db.getCurrentlySelectedServer();
          artworkUrl = invidiousImageUrl(thumbnail, server);
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
      _progressGeneration++;
      // The replacement decoder reads its starting position when it mounts.
      emit(state.copyWith(isAudio: value, startAt: state.position));
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
