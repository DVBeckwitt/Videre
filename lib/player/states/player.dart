import 'dart:async';
import 'dart:collection';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:back_button_interceptor/back_button_interceptor.dart';
import 'package:bloc/bloc.dart';
import 'package:clipious/player/models/sleep_timer.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:easy_debounce/easy_debounce.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:logging/logging.dart';
import 'package:simple_pip_mode/simple_pip.dart';

import '../../downloads/models/downloaded_video.dart';
import '../../main.dart';
import '../../media_handler.dart';
import '../../settings/models/db/settings.dart';
import '../../settings/states/settings.dart';
import '../../utils/models/pair.dart';
import '../../videos/models/db/progress.dart' as db_progress;
import '../../videos/models/db/history_video_cache.dart';
import '../../videos/models/sponsor_segment.dart';
import '../../videos/models/sponsor_segment_types.dart';
import '../../videos/models/video.dart';
import '../models/playback_session.dart';

part 'player.freezed.dart';

const double targetHeight = 66;
const skipToVideoThrottleName = 'skip-to-video';
const stepMultiplier = 1.15;

const maxInt = -1 >>> 1;

var log = Logger('MiniPlayerController');
final playbackHistoryRevision = ValueNotifier(0);

enum PlayerRepeat { noRepeat, repeatAll, repeatOne }

class PlayerCubit extends Cubit<PlayerState> with WidgetsBindingObserver {
  static PlayerCubit? _sessionOwner;
  static Future<void> _sessionWrite = Future.value();
  final SettingsCubit settings;
  late final AudioSession audioSession;
  bool? _remotePlaying;
  int _progressGeneration = 0;
  final bool _resumeOnReady;
  static const _pipChannel = MethodChannel('videre/pip');
  SimplePip? _pip;

  PlayerCubit(super.initialState, this.settings, {bool resume = false})
      : _resumeOnReady = resume {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android && !isTv) {
      _pip = SimplePip(
        onPipEntered: () => _setPip(true),
        onPipExited: () => _setPip(false),
      );
      unawaited(_updateAutoPip(state));
    }
    onReady();
  }

  PlaybackSession? get savedSession =>
      PlaybackSession.decode(db.getSettings(playbackSessionSetting)?.value);

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
    final database = db;
    final setting = SettingsValue(
        playbackSessionSetting,
        PlaybackSession(
          videos: snapshot.videos
              .map((v) => v.videoId == id ? snapshot.currentlyPlaying ?? v : v)
              .toList(),
          offlineIds: snapshot.offlineVideos.map((v) => v.videoId).toList(),
          currentId: id,
          seconds: snapshot.position.inSeconds,
          audio: snapshot.isAudio,
          played: snapshot.playedVideos,
          next: snapshot.playQueue.toList(),
        ).encode());
    // An older TV screen may close after its replacement has begun playing.
    return _sessionWrite = _sessionWrite.then((_) async {
      if (_sessionOwner == this) await database.saveSetting(setting);
    }).catchError((Object error) {
      log.warning('Could not save playback session', error);
    });
  }

  void restoreSession() {
    final saved = savedSession;
    if (saved == null) return;
    final offline = saved.offlineIds
        .map(db.getDownloadByVideoId)
        .whereType<DownloadedVideo>()
        .where((v) => v.downloadComplete)
        .toList();
    final ids = {
      ...saved.videos.map((v) => v.videoId),
      ...offline.map((v) => v.videoId)
    };
    // Keep the player hidden until Resume is pressed; restoring must be silent.
    emit(state.copyWith(
        videos: saved.videos,
        offlineVideos: offline,
        currentlyPlaying: null,
        offlineCurrentlyPlaying: null,
        position: Duration(seconds: saved.seconds),
        startAt: Duration(seconds: saved.seconds),
        isHidden: true,
        playedVideos: saved.played.where(ids.contains).toList(),
        playQueue: ListQueue.from(saved.next.where(ids.contains)),
        isAudio: saved.audio && !isTv));
  }

  Future<void> resumeSession() async {
    _remotePlaying = null;
    final saved = savedSession;
    if (saved == null) return;
    restoreSession();
    final videos = state.videos.isNotEmpty ? state.videos : state.offlineVideos;
    final current =
        videos.where((v) => v.videoId == saved.currentId).firstOrNull;
    if (current == null) return;
    showBigPlayer();
    await _switchToVideo(current, startAt: Duration(seconds: saved.seconds));
  }

  Future<void> playRemoteVideo(String videoId, int position, bool playing,
      {bool Function()? isActive}) async {
    final video =
        await service.getVideo(videoId).timeout(const Duration(seconds: 10));
    if (isClosed || (isActive != null && !isActive())) return;
    await playVideo([
      video.copyWith(
        formatStreams: video.formatStreams ?? [],
        adaptiveFormats: video.adaptiveFormats ?? [],
      )
    ], startAt: Duration(seconds: position), playing: playing);
  }

  void setEvent(MediaEvent event) {
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
    String? currentVideoId = state.currentlyPlaying?.videoId ??
        state.offlineCurrentlyPlaying?.videoId;
    return (state.videos.isNotEmpty ? state.videos : state.offlineVideos)
        .indexWhere((element) => element.videoId == currentVideoId);
  }

  Future<void> onReady() async {
    final startVideos = state.videos;
    if (startVideos.isEmpty) restoreSession();
    emit(state.copyWith(
        orientation: getOrientation(),
        forwardStep: settings.state.skipStep,
        rewindStep: settings.state.skipStep));
    // setting up audio session
    audioSession = await AudioSession.instance;
    audioSession.configure(const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.allowBluetooth,
    ));
    WidgetsBinding.instance.addObserver(this);
    if (!isTv) {
      audioSession.becomingNoisyEventStream.listen((event) {
        pause();
      });

      mediaHandler = await AudioService.init(
        builder: () => MediaHandler(this),
        config: const AudioServiceConfig(
          androidNotificationChannelId:
              'com.github.dvbeckwitt.videre.channel.audio',
          androidNotificationChannelName: 'Video playback',
          androidNotificationOngoing: true,
        ),
      );
      BackButtonInterceptor.add(handleBackButton,
          name: 'miniPlayer', zIndex: 2, ifNotYetIntercepted: true);
    } else if (isTv && startVideos.isNotEmpty) {
      await switchToVideo(startVideos[0], startAt: state.startAt);
      generatePlayQueue();
    }
    if (_resumeOnReady) await resumeSession();
  }

  void handleMediaEvent(MediaEvent event) {
    switch (event.state) {
      case MediaState.completed:
        if (state.currentlyPlaying != null) {
          saveProgress(state.currentlyPlaying!.lengthSeconds ?? 0);
        }
        playNext();
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
        _setPlaying(_remotePlaying != false);
        // Native source setup may autoplay after a newer remote pause command.
        // Retain the latest intent until another command or video replaces it.
        if (_remotePlaying == false) pause();
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
    _progressGeneration++;
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

  void setVideos(List<Video> videos) {
    var newVideos = videos.where((element) => !element.filtered).toList();
    emit(state.copyWith(videos: newVideos, offlineVideos: []));
  }

  void selectTab(int index) {
    emit(state.copyWith(selectedFullScreenIndex: index));
  }

  void setAudio(bool? newValue) {
    emit(state.copyWith(isAudio: newValue ?? false));
  }

  void hide() {
    unawaited(_saveSession(state));
    playbackHistoryRevision.value++;
    var mediaEvent = MediaEvent(
        state: MediaState.playing,
        type: MediaEventType.miniDisplayChanged,
        value: state.isMini);
    emit(state.copyWith(isClosing: true));
    cancelSleep();
    Future.delayed(
      animationDuration * 1.5,
      () {
        emit(state.copyWith(
            isMini: true,
            mediaEvent: mediaEvent,
            top: null,
            height: targetHeight,
            isHidden: true,
            videos: [],
            playedVideos: [],
            currentlyPlaying: null,
            offlineCurrentlyPlaying: null,
            offlineVideos: [],
            isClosing: false));
        setEvent(const MediaEvent(state: MediaState.idle));
      },
    );

    audioSession.setActive(false);
  }

  double get getBottom => state.isHidden ? -targetHeight : 0;

  Future<void> saveProgress(int timeInSeconds) async {
    final videoId = state.currentlyPlaying?.videoId ??
        state.offlineCurrentlyPlaying?.videoId;
    final length = state.currentlyPlaying?.lengthSeconds ??
        state.offlineCurrentlyPlaying?.lengthSeconds ??
        0;
    if (videoId != null && length > 0) {
      int currentPosition = timeInSeconds;
      // saving progress
      var currentProgress = (currentPosition / length).clamp(0.0, 1.0);
      if (currentProgress >= 0.9) {
        currentProgress =
            1; // we consider a video with 90%+ progress as watched
      }
      var progress = db_progress.Progress.named(
          progress: currentProgress, videoId: videoId);

      await db.saveProgress(progress);

      if (progress.progress > 0.1) {
        EasyThrottle.throttle('invidious-progress-sync-${progress.videoId}',
            const Duration(minutes: 10), () async {
          if (await service.isLoggedIn()) {
            service.addToUserHistory(progress.videoId);
          }
        });
      }
    }
  }

  void queueVideos(List<Video> videos) {
    var stateVideos = List<Video>.from(state.videos);
    if (videos.isNotEmpty) {
      //removing videos that are already in the queue
      stateVideos.addAll(videos
          .where((v) =>
              state.videos.indexWhere((v2) => v2.videoId == v.videoId) == -1)
          .where((element) => !element.filtered));
    } else {
      playVideo(videos);
    }
    log.fine('Videos in queue ${videos.length}');
    emit(state.copyWith(offlineVideos: [], videos: stateVideos));
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
    if (isClosed) return;
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

    // if we're already within the last 5 seconds we don't skip to avoid infinite skip loop on late outro segment
    if (state.sponsorSegments.isNotEmpty &&
        state.position.inSeconds <
            (state.currentlyPlaying?.lengthSeconds ?? maxInt) - 5) {
      log.fine('sponsor skipped');
      double positionInMs = currentPosition * 1000;
      Pair<int> nextSegment = state.sponsorSegments.firstWhere(
          (e) => e.first <= positionInMs && positionInMs <= e.last,
          orElse: () => const Pair<int>(-1, -1));

      if (nextSegment.first != -1) {
        // sometimes when reaching the end of a video, the sponsor skip keeps on being triggered
        // we remove on second of last segment if it is the case
        var skipTo = nextSegment.last + 1000;

        emit(state.copyWith(
            mediaEvent: const MediaEvent(
                state: MediaState.playing,
                type: MediaEventType.sponsorSkipped)));
        //for some reasons this needs to be last
        seek(Duration(milliseconds: skipTo + 1000));
      }
    }
  }

  Future<void> _playNextNow() async {
    if (settings.state.playerRepeatMode == PlayerRepeat.repeatOne) {
      seek(Duration.zero);
      play();
    } else if (state.videos.isNotEmpty || state.offlineVideos.isNotEmpty) {
      //moving current video to played list
      String? currentVideoId = state.currentlyPlaying?.videoId ??
          state.offlineCurrentlyPlaying?.videoId;
      if (currentVideoId != null) {
        // state.playedVideos.remove(currentVideoId);
        var newPlayedVideos = List<String>.from(state.playedVideos)
          ..add(currentVideoId);
        emit(state.copyWith(playedVideos: newPlayedVideos));
      }

      if (state.playQueue.isNotEmpty) {
        String toPlay = state.playQueue.removeFirst();
        if (state.videos.isNotEmpty) {
          await switchToVideo(
              state.videos.firstWhere((element) => element.videoId == toPlay));
        } else {
          await switchToOfflineVideo(state.offlineVideos
              .firstWhere((element) => element.videoId == toPlay));
        }
      } else if (settings.state.playerRepeatMode == PlayerRepeat.repeatAll) {
        emit(state.copyWith(playedVideos: [], playQueue: ListQueue.from([])));
        if (state.videos.isNotEmpty) {
          await switchToVideo(state.videos[0]);
        } else {
          await switchToOfflineVideo(state.offlineVideos[0]);
        }
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
        String? currentVideoId = state.currentlyPlaying?.videoId ??
            state.offlineCurrentlyPlaying?.videoId;
        var playQueue = ListQueue<String>.from(state.playQueue);
        if (currentVideoId != null) {
          // state.playQueue.remove(currentVideoId);
          playQueue.addFirst(currentVideoId);
        }

        var playedVideos = List<String>.from(state.playedVideos);
        String toPlay = playedVideos.removeLast();
        if (state.videos.isNotEmpty) {
          await switchToVideo(
              state.videos.firstWhere((element) => element.videoId == toPlay));
        } else {
          await switchToOfflineVideo(state.offlineVideos
              .firstWhere((element) => element.videoId == toPlay));
        }
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
        videos = List<Video>.from(vids, growable: true).cast();
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
      if (isOffline) {
        await switchToOfflineVideo(state.offlineVideos[0]);
      } else {
        await switchToVideo(state.videos[0], startAt: startAt);
      }
      generatePlayQueue();
    }
  }

  /// skip to queue video of index
  /// if we're not shuffling, we also rebuild the playnext and played previously queue
  void skipToVideo(int index) {
    var listToCheckAgainst =
        state.videos.isNotEmpty ? state.videos : state.offlineVideos;
    if (index < 0 || index >= listToCheckAgainst.length) {
      return;
    }

    if (settings.state.playerShuffleMode) {
    } else {
      List<String> played = [];
      List<String> playNext = [];
      for (int i = 0; i < listToCheckAgainst.length; i++) {
        var v = listToCheckAgainst[i];
        if (i < index) {
          played.add(v.videoId);
        } else if (i > index) {
          playNext.add(v.videoId);
        }
      }
      emit(state.copyWith(
          playedVideos: played, playQueue: ListQueue.from(playNext)));
    }
    _switchToVideo(listToCheckAgainst[index]);
  }

  /// Switches to a video without changing the queue
  Future<void> _switchToVideo(IdedVideo video, {Duration? startAt}) async {
    _progressGeneration++;
    try {
      // we move the existing video to the stack of played video
      await audioSession.setActive(true);
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

      // List<IdedVideo> toCheck = isOffline ? state.offlineVideos : state.videos;

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
        if (video is Video &&
            video.formatStreams != null &&
            video.adaptiveFormats != null) {
          v = video;
        } else {
          v = await service.getVideo(video.videoId);
        }
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
      final progress = db.getVideoProgress(video.videoId);
      final resumeAt = startAt ??
          Duration(seconds: progress < 0.9 ? (length * progress).floor() : 0);
      _sessionOwner = this;
      emit(state.copyWith(
          position: resumeAt,
          startAt: startAt,
          sponsorSegments: [],
          forwardStep: settings.state.skipStep,
          rewindStep: settings.state.skipStep,
          mediaCommand: mediaCommand,
          currentlyPlaying: currentlyPlaying,
          offlineCurrentlyPlaying: offlineCurrentlyPlaying));
      unawaited(_saveSession(state));

      if (currentlyPlaying != null) {
        await db.upsertHistoryVideo(HistoryVideoCache(
            currentlyPlaying.videoId,
            currentlyPlaying.title ?? '',
            currentlyPlaying.author,
            ImageObject.getBestThumbnail(currentlyPlaying.videoThumbnails)
                    ?.url ??
                '',
            authorId: currentlyPlaying.authorId,
            lengthSeconds: currentlyPlaying.lengthSeconds));
        playbackHistoryRevision.value++;
      }

      await setSponsorBlock();

      if (!isTv) {
        mediaHandler.skipToQueueItem(currentIndex);
      }
    } catch (err) {
      if (state.videos.length == 1) {
        // if we can't get video details, we need to stop everything
        log.severe(
            "Couldn't play video  '${video.videoId}', stopping player to avoid app crash");
        hide();
      } else {
        // if we have more than 1 video
        log.severe(
            "Couldn't play video  '${video.videoId}', removing it from the queue");

        removeVideoFromQueue(video.videoId);
        _playNextNow();
      }
    }
  }

  Future<void> playOfflineVideos(List<DownloadedVideo> offlineVids) async {
    _remotePlaying = null;
    log.fine('Playing ${offlineVids.length} offline videos');
    await _playVideos(offlineVids);
  }

  Future<void> playVideo(List<Video> v,
      {bool? audio, Duration? startAt, bool? playing}) async {
    _remotePlaying = playing;
    List<Video> videos = v.where((element) => !element.filtered).toList();
    // TODO: find how to do this with auto router
    log.fine('Playing ${videos.length} videos');

    setAudio(audio);

    await _playVideos(videos, startAt: startAt);
  }

  Future<void> switchToOfflineVideo(DownloadedVideo video) async {
    await _switchToVideo(video);
  }

  Future<void> switchToVideo(Video video, {Duration? startAt}) async {
    await _switchToVideo(video, startAt: startAt);
  }

  void togglePlaying() {
    state.isPlaying ? pause() : play();
  }

  void play() {
    if (_remotePlaying != null) _remotePlaying = true;
    emit(state.copyWith(
        mediaCommand: const MediaCommand(MediaCommandType.play)));
  }

  void pause() {
    if (_remotePlaying != null) _remotePlaying = false;
    emit(state.copyWith(mediaCommand: MediaCommand(MediaCommandType.pause)));
  }

  void removeVideoFromQueue(String videoId) {
    var videos = List<Video>.from(state.videos);
    var offlineVideos = List<DownloadedVideo>.from(state.offlineVideos);
    var listToUpdate = videos.isNotEmpty ? videos : offlineVideos;
    if (listToUpdate.length == 1) {
      hide();
    } else {
      var playQueue = ListQueue<String>.from(state.playQueue)
        ..removeWhere((element) => element == videoId);
      var playedVideos = List<String>.from(state.playedVideos)
        ..removeWhere((element) => element == videoId);
      listToUpdate.removeWhere((element) => element.videoId == videoId);
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
    Future.delayed(
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
    log.fine('Dragged video');
    var videos = List<Video>.from(state.videos);
    var offlineVideos = List<DownloadedVideo>.from(state.offlineVideos);
    var listToUpdate = videos.isNotEmpty ? videos : offlineVideos;
    var movedItem = listToUpdate.removeAt(oldItemIndex);

    listToUpdate.insert(newItemIndex, movedItem);
    log.fine(
        'Reordered list: $oldItemIndex new index: ${listToUpdate.indexOf(movedItem)}');
    var playedVideos = List<String>.from(state.playedVideos);
    if (newItemIndex <= currentIndex) {
      playedVideos.add(listToUpdate[newItemIndex].videoId);
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
      var videos = List<Video>.from(state.videos)..add(video);
      var playQueue = ListQueue<String>.from(state.playQueue)
        ..addFirst(video.videoId);
      emit(state.copyWith(videos: videos, playQueue: playQueue));
    }
  }

  Future<void> setSponsorBlock() async {
    List<Pair<int>> newSegments = [];
    final videoId = state.currentlyPlaying?.videoId;
    if (videoId != null) {
      List<SponsorSegmentType> types = SponsorSegmentType.values
          .where((e) => e.isEnabled(db.getSettings(e.settingsName())?.value))
          .toList();

      if (types.isNotEmpty) {
        List<SponsorSegment> sponsorSegments = await service
            .getSponsorSegments(videoId, types)
            .timeout(const Duration(seconds: 3), onTimeout: () => []);
        List<Pair<int>> segments = List.from(sponsorSegments.map((e) {
          Duration start = Duration(seconds: e.segment[0].floor());
          Duration end = Duration(seconds: e.segment[1].floor());
          Pair<int> segment = Pair(start.inMilliseconds, end.inMilliseconds);
          return segment;
        }));

        newSegments = segments;
        log.fine('we found ${segments.length} segments to skip');
      }
    }
    if (!isClosed && state.currentlyPlaying?.videoId == videoId) {
      emit(state.copyWith(sponsorSegments: newSegments));
    }
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
    EasyDebounce.debounce('fast-forward-step', const Duration(seconds: 1), () {
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
    EasyDebounce.debounce('fast-rewind-step', const Duration(seconds: 1), () {
      emit(state.copyWith(
        rewindStep: settings.state.skipStep,
        totalRewind: 0,
      ));
    });
  }

  Future<MediaItem?> getMediaItem(int index) async {
    if (state.videos.isNotEmpty) {
      var e = state.videos[index];
      return MediaItem(
          id: e.videoId,
          title: e.title ?? '',
          artist: e.author,
          duration: Duration(seconds: e.lengthSeconds ?? 1),
          album: '',
          artUri: Uri.parse(
              ImageObject.getBestThumbnail(e.videoThumbnails)?.url ?? ''));
    } else if (state.offlineVideos.isNotEmpty) {
      var e = state.offlineVideos[index];
      var path = await e.thumbnailPath;
      return MediaItem(
          id: e.videoId,
          title: e.title,
          artist: e.author,
          duration: Duration(seconds: e.lengthSeconds),
          album: '',
          artUri: Uri.file(path));
    }
    return null;
  }

  void setSpeed(double d) {
    emit(state.copyWith(
        mediaCommand: MediaCommand(MediaCommandType.speed, value: d)));
  }

  void setFullScreen(FullScreenState fsState) {
    // emit(state.copyWith(mediaCommand: MediaCommand(MediaCommandType.fullScreen, value: fsState)));
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
        // SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(statusBarColor: Colors.black));
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

  void togglePlay() {
    if (state.isPlaying) {
      pause();
    } else {
      play();
    }
  }

  Duration get duration => Duration(
      seconds: (state.currentlyPlaying?.lengthSeconds ??
          state.offlineCurrentlyPlaying?.lengthSeconds ??
          1));

  double get progress =>
      state.position.inMilliseconds / duration.inMilliseconds;

  void switchAudio(bool value) {
    if (state.currentlyPlaying != null) {
      emit(state.copyWith(isAudio: value));
      switchToVideo(state.currentlyPlaying!, startAt: state.position);
    }
  }

  void generatePlayQueue() {
    // get videos minus the one we already played and the currently playing video
    List<String> videos =
        (state.videos.isNotEmpty ? state.videos : state.offlineVideos)
            .where((element) => !state.playedVideos.contains(element.videoId))
            .where((element) =>
                element.videoId !=
                (state.currentlyPlaying?.videoId ??
                    state.offlineCurrentlyPlaying?.videoId))
            .map((e) => e.videoId)
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

    EasyDebounce.debounce(
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
    EasyDebounce.cancel('video-sleep-timer');
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

  const PlayerState._();

//
  static PlayerState init(List<Video>? videos) {
    return PlayerState(videos: videos ?? [], playQueue: ListQueue.from([]));
  }
}
