import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show Platform;

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
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/app_languages.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/song_artwork.dart';
import 'package:clipious/music/services/music_media_save.dart';
import 'package:clipious/music/services/music_sound_controller.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/recommendations/music_playlist_recommendation_exclusions.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/podcasts/services/podcast_player.dart';
import 'package:clipious/podcasts/services/podcast_progress_store.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/interfaces/media_player.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/invidious_image.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:simple_pip_mode/simple_pip.dart';
import 'package:uuid/uuid.dart';

import '../../downloads/models/downloaded_video.dart';
import '../../downloads/services/download_playback_source.dart';
import '../../downloads/services/explicit_music_download.dart';
import '../../music/models/device_playlist_track.dart';
import '../../music/models/local_music_track.dart';
import '../../music/models/music_background_playback.dart';
import '../../music/models/music_content_advisory.dart';
import '../../music/models/music_song_tap_queue_scope.dart';
import '../../music/models/music_mix.dart';
import '../../music/models/music_track.dart';
import '../../music/models/on_device_music_entry.dart';
import '../../music/models/song_transition.dart';
import '../../music/services/local_music_library.dart';
import '../../music/services/music_listening_history.dart';
import '../../music/services/cached_music.dart';
import '../../music/services/music_home_widget.dart';
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
import '../models/named_music_queue.dart';
import '../models/manual_music_preparation.dart';
import '../models/playback_pitch.dart';
import '../models/backend_playback.dart';
import '../models/backend_recovery.dart';
import '../models/playback_recovery.dart';
import '../models/playback_learning_clock.dart';
import '../models/music_audio_quality.dart';
import '../models/music_passage_target.dart';
import '../models/local_music_playback.dart';
import '../models/music_queue_shuffle.dart';
import '../models/watch_audio_track.dart';

export '../../videos/models/db/progress.dart' show playbackHistoryRevision;

part 'player.freezed.dart';
part 'adjacent_music.dart';
part 'music_requests.dart';

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

typedef _MusicHandoff = ({
  int generation,
  int intentRevision,
  String from,
  String? to,
  PlayerRepeat? replay,
  Stopwatch elapsed,
});

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
  late final _MusicRequests _musicRequests = _MusicRequests(this);

  List<IdedVideo> get musicRequests => _musicRequests.pending;
  ValueListenable<int> get musicRequestRevision => _musicRequests.revision;
  bool get playingMusicRequests => _musicRequests.playing;
  bool get canPlayMusicRequests => _musicRequests.canPlay;
  bool get hasMusicRequestSuccessor => _inMusicQueue && _musicRequests.playing;

  bool canAddMusicRequest(IdedVideo entry) => _musicRequests.canAdd(entry);
  bool addMusicRequest(IdedVideo entry,
      {PlaylistReference? recommendationSource,
      bool inheritCurrentRecommendationSource = false}) {
    final IdedVideo? current =
        state.currentlyPlaying ?? state.offlineCurrentlyPlaying;
    final currentId = state.currentQueueId;
    final sourceKey = inheritCurrentRecommendationSource &&
            current?.videoId == entry.videoId &&
            playbackQueueId(entry) == currentId
        ? _musicRecommendationSources[currentId]
        : null;
    return _musicRequests.add(entry,
        recommendationSource: recommendationSource,
        inheritedSourceKey: sourceKey);
  }

  bool canAddDeviceMusicRequest(OnDeviceMusicEntry entry) =>
      _musicRequests.canAddDevice(entry);
  bool addDeviceMusicRequest(OnDeviceMusicEntry entry,
          {PlaylistReference? recommendationSource}) =>
      _musicRequests.addDevice(entry,
          recommendationSource: recommendationSource);

  void removeMusicRequest(IdedVideo entry) => _musicRequests.remove(entry);

  Future<bool> playMusicRequests() => _musicRequests.start();
  Future<bool> returnFromMusicRequests() => _musicRequests.returnToCollection();

  static PlayerCubit? _sessionOwner;
  final musicMediaSave = MusicMediaSave();
  ({
    MediaControl control,
    int generation,
    MusicMediaSaveRequest request
  })? _musicMediaSaveTarget;
  static final _runtimePlayers = <PlayerCubit>{};
  static PodcastPlayer? _podcastOwner;
  static Future<MediaHandler>? _sharedMediaInitialization;
  ({String id, bool music, bool live})? _tuningSource;
  int _nextLocalOccurrence = 1;
  String? _queuedDeviceSelectionId;
  static Future<void> _sessionWrite = Future.value();
  final _namedMusicQueuesRevision = ValueNotifier(0);
  String? _activeNamedMusicQueueId;
  String? _namedMusicQueuesValue;
  List<NamedMusicQueue> _namedMusicQueues = const [];
  static const _learningCheckpointInterval = Duration(seconds: 15);
  final SettingsCubit settings;
  final musicSound = MusicSoundController();
  MusicAudioQualityMenu? musicAudioQuality;
  final _musicContentAdvisory =
      ValueNotifier<PlayingMusicContentAdvisory?>(null);
  ValueListenable<PlayingMusicContentAdvisory?> get musicContentAdvisory =>
      _musicContentAdvisory;
  int? _watchAudioGeneration;
  String? _requestedWatchAudioTrack;
  String? _effectiveWatchAudioTrack;
  String? _watchProgressiveUrl;
  final _learningTime = Stopwatch()..start();
  final int Function()? _learningTimeMicroseconds;
  _RecommendationPlayback? _learningPlayback;
  bool _learningOccurrenceExcluded = false;
  int _learningSequence = 0;
  Future<void>? _learningWrite;
  String? _selectedWatchVideoId;
  final PlaylistReference? _initialPlaylistReference;
  final PlaylistReference? _initialRecommendationSource;
  final PlaylistLoadSession? _initialPlaylistLoader;
  final int _initialPlaylistIndex;
  final bool? _initialPlaylistAudio;
  final bool _initialPlaylistShuffleOnce;
  final String? _initialQueueTitle;
  final ({
    String title,
    bool Function() isCurrent,
    List<PlaylistReference?>? recommendationSources,
  })? _initialMusicCollection;
  final Future<bool?> Function(PlayerCubit)? _initialMusicMix;
  final bool _initialFromMusic;
  final bool _initialSongTap;
  // Origin follows the queue occurrence across mode switches and decoder retries.
  final _musicHistoryEntries = <String>{};
  final _musicRecommendationSources = <String, String>{};
  bool _musicHistoryPlaylist = false;
  PlaybackHistoryWrite? _activeHistoryWrite;
  PlaybackHistoryWrite? _preparingHistoryWrite;
  final List<LocalMusicTrack>? _initialLocalMusic;
  final List<OnDeviceMusicEntry>? _initialOnDeviceMusic;
  final bool Function()? _initialOnDeviceMusicIsCurrent;
  PlaylistReference? _playlistReference;
  String? _musicQueueTitle;
  MusicMix? _musicMix;
  Object? _musicMixRequest;
  final _musicMixGenerated = <String>{};
  final _musicMixRemoved = <String>{};
  PlaylistLoadSession? _playlistLoader;
  StreamSubscription<PlaylistLoadSnapshot>? _playlistLoadSubscription;
  final _playlistEntries = LinkedHashMap<String, Video>();
  final _musicShuffleAnchors = <String>{};
  bool _playlistMembershipKnown = false;
  int _playlistGeneration = 0;
  String _passageQueueId = const Uuid().v4();
  bool _waitingForPlaylist = false;
  bool _waitingForPlaylistUserSkip = false;
  bool _playlistSourceComplete = true;
  bool _sessionTransitionPending = false;
  String? _playlistCheckpointSignature;
  final playlistLoadingRevision = ValueNotifier(0);

  PlaylistReference? get playlistReference => _playlistReference;

  PlaylistReference? get musicRecommendationSourceForCurrentEntry {
    final source = _playlistReference;
    final key = _musicRecommendationSourceKey(source);
    return key != null &&
            _musicRecommendationSources[state.currentQueueId] == key
        ? source
        : null;
  }

  String? _musicRecommendationSourceKey(PlaylistReference? source) =>
      source != null && source.matchesOwner(_profileDatabase)
          ? musicPlaylistRecommendationKey(source)
          : null;

  void _assignMusicRecommendationSource(
      Iterable<String> occurrences, PlaylistReference? source,
      {List<PlaylistReference?>? recommendationSources}) {
    final key = _musicRecommendationSourceKey(source);
    for (final (index, occurrence) in occurrences.indexed) {
      final sourceKey = recommendationSources == null
          ? key
          : _musicRecommendationSourceKey(recommendationSources[index]);
      if (sourceKey == null) {
        _musicRecommendationSources.remove(occurrence);
      } else {
        _musicRecommendationSources[occurrence] = sourceKey;
      }
    }
  }

  String? get musicQueueTitle {
    final reference = _playlistReference;
    if (reference == null) return _musicQueueTitle;
    final title = normalizedQueueTitle(_playlistLoader?.playlist.title);
    return title != null && title != reference.playlistId
        ? title
        : reference.displayTitle ?? _musicQueueTitle;
  }

  int get playlistGeneration => _playlistGeneration;
  int get playbackOccurrenceRevision => _videoSwitchGeneration;
  int get transportIntentRevision => _transportIntentRevision;

  bool get canPreviewMusic =>
      !isClosed &&
      !_isDisposing &&
      !_switchingProfile &&
      !state.isClosing &&
      !playbackInterrupted &&
      activePodcast == null &&
      !_sessionTransitionPending &&
      openingMusicEntry == null &&
      state.mediaEvent.state != MediaState.loading &&
      state.mediaEvent.state != MediaState.buffering &&
      (!state.isPlaying || state.isAudio) &&
      (!state.hasVideo || state.isPlaying || _requestedPlaying != true);

  /// A local playlist's source entries exclude songs appended to playback.
  Video? get currentLocalPlaylistEntry {
    final source = _playlistReference;
    final entry = _playlistEntries[state.currentQueueId];
    if (!_playlistMembershipKnown ||
        source == null ||
        source.kind != PlaylistSourceKind.local ||
        source.profileId != _profileDatabase.profileId ||
        _switchingProfile ||
        _sessionTransitionPending ||
        entry == null ||
        state.currentlyPlaying?.videoId != entry.videoId ||
        entry.explicitMusicDownload != null) {
      return null;
    }
    return entry;
  }

  bool get isPlaylistLoading => _playlistLoader?.loading ?? false;
  bool get playlistComplete =>
      _playlistReference == null ||
      (_playlistLoader?.complete ?? _playlistSourceComplete);
  Object? get playlistLoadingError => _playlistLoader?.error;
  late IDbClient _profileDatabase;
  WatchRepository? _watchRepository;
  Server? _watchAccount;
  String? _watchVideoId;
  bool _watchLocalOnly = false;
  int? _watchRevision;
  bool _switchingProfile = false;
  MediaHandler? _mediaSessionHandler;
  StreamSubscription<Object?>? _carBrowseSubscription;

  Object? get androidAutoSession {
    final app = settings.appCubit.state;
    final proxy = NetworkProxy.instance;
    if (isClosed ||
        _isDisposing ||
        _switchingProfile ||
        app.globalLoading ||
        app.sessionRecoveryRequired ||
        app.profileId != db.profileId ||
        _profileDatabase.profileId != db.profileId ||
        proxy.isChanging) {
      return null;
    }
    return (db, app.profileId, app.sessionRevision, app.server, proxy.config);
  }

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
  // The audio decoder reserves a successor before a crossfade starts.
  ValueGetter<bool>? hasOpeningMusicCrossfade;
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
  _MusicHandoff? _musicHandoff;
  bool _musicAdvanceDeferredForFocus = false;
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

  /// New sources start by default once playback is allowed to begin.
  bool get intendsPlayback => _requestedPlaying != false;

  bool get playbackInterrupted =>
      _playbackInterrupted &&
      (!state.isAudio || _audioInterruptionType != AudioInterruptionType.duck);

  bool get _interruptionOwnsTransportIntent =>
      _playbackInterrupted &&
      _interruptionIntentRevision == _transportIntentRevision &&
      _interruptionVideoGeneration == _videoSwitchGeneration;

  bool get shouldStartPlayback =>
      intendsPlayback &&
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

  /// Also changes on a mode switch, even when the queue occurrence stays.
  int get playbackPositionGeneration => _progressGeneration;
  bool _isDisposing = false;
  bool _playerDragActive = false;
  StreamSubscription<void>? _becomingNoisySubscription;
  StreamSubscription<double>? _mediaVolumeSubscription;
  double? _lastMediaVolume;
  final bool _resumeOnReady;
  late final Future<void> _playerReady;
  static const _pipChannel = MethodChannel('videre/pip');
  SimplePip? _pip;
  MusicHomeWidget? _musicHomeWidget;
  void Function(IdedVideo entry, bool Function() isCurrent)?
      saveMusicHomeWidgetSong;

  PlayerCubit(super.initialState, this.settings,
      {bool resume = false,
      PlaylistReference? playlistReference,
      PlaylistReference? initialRecommendationSource,
      PlaylistLoadSession? playlistLoader,
      List<LocalMusicTrack>? initialLocalMusic,
      List<OnDeviceMusicEntry>? initialOnDeviceMusic,
      bool Function()? initialOnDeviceMusicIsCurrent,
      int startIndex = 0,
      bool? playlistAudio,
      bool playlistShuffleOnce = false,
      String? initialQueueTitle,
      ({
        String title,
        bool Function() isCurrent,
        List<PlaylistReference?>? recommendationSources,
      })? initialMusicCollection,
      Future<bool?> Function(PlayerCubit)? initialMusicMix,
      bool fromMusic = false,
      bool initialSongTap = false,
      Future<void> Function(Duration)? playbackRecoveryDelay,
      Future<bool> Function()? videoFocusActivation,
      int Function()? learningTimeMicroseconds})
      : _resumeOnReady = resume,
        _initialLocalMusic = initialLocalMusic,
        _initialOnDeviceMusic = initialOnDeviceMusic,
        _initialOnDeviceMusicIsCurrent = initialOnDeviceMusicIsCurrent,
        _learningTimeMicroseconds = learningTimeMicroseconds,
        _activateVideoFocus = videoFocusActivation,
        _waitForPlaybackRecovery =
            playbackRecoveryDelay ?? Future<void>.delayed,
        _initialPlaylistReference = playlistReference,
        _initialRecommendationSource = initialRecommendationSource,
        _initialPlaylistLoader = playlistLoader,
        _initialPlaylistIndex = startIndex,
        _initialQueueTitle = initialQueueTitle,
        _initialMusicCollection = initialMusicCollection,
        _initialMusicMix = initialMusicMix,
        _initialFromMusic = fromMusic,
        _initialPlaylistShuffleOnce = playlistShuffleOnce,
        _initialSongTap = initialSongTap,
        _initialPlaylistAudio = playlistAudio {
    _profileDatabase = db.forProfile(db.profileId);
    _initializeNamedMusicQueues();
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
      final musicHomeWidget = MusicHomeWidget(
        readPlayback: _musicHomeWidgetPlayback,
        onAction: _handleMusicHomeWidgetAction,
        updates: [stream, settings.stream, settings.appCubit.stream],
      );
      _musicHomeWidget = musicHomeWidget;
      playlistLoadingRevision.addListener(musicHomeWidget.refresh);
    }
    _playerReady = onReady();
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

  PlaybackSession? get savedSession {
    final saved = PlaybackSession.decode(
        _profileDatabase.getSettings(playbackSessionSetting)?.value);
    if (saved == null) return null;
    final cached = saved.videos.map(CachedMusicPlayback.of).nonNulls;
    if (cached.isEmpty) return saved;
    final server = settings.appCubit.state.server;
    final owner = server == null ? null : cachedMusicOwner(server);
    return cached.every((song) => song.owner == owner) ? saved : null;
  }

  void _checkDevicePlaylistQueue() {
    final removed = {
      for (final entry in state.videos)
        if (isLocalMusicPlaybackId(entry.videoId) &&
            localMusicTrackForPlayback(entry.videoId) == null)
          playbackQueueId(entry),
    };
    if (removed.isEmpty) return;
    final opening = openingMusicEntry;
    if (removed.contains(state.currentQueueId) ||
        (opening != null && removed.contains(playbackQueueId(opening)))) {
      _sessionTransitionPending = true;
      hide();
      for (final stop in List.of(_beforeProfileSwitch)) {
        unawaited(stop());
      }
      final handler = _mediaSessionHandler;
      if (handler != null && _sessionOwner == this) {
        unawaited(handler.clearSession());
      }
      final database = _profileDatabase;
      _sessionWrite = _sessionWrite.then((_) async {
        final saved = PlaybackSession.decode(
            database.getSettings(playbackSessionSetting)?.value);
        if (removed.contains(saved?.currentId)) {
          await database.saveSetting(SettingsValue(playbackSessionSetting, ''));
        }
      }).catchError((Object error) {
        log.warning(
            'Could not clear the unavailable device playlist session', error);
      });
      emit(state.copyWith(
          videos: [],
          currentlyPlaying: null,
          playedVideos: [],
          playQueue: ListQueue<String>()));
      return;
    }
    emit(state.copyWith(
        videos: state.videos
            .where((entry) => !removed.contains(playbackQueueId(entry)))
            .toList(),
        playedVideos:
            state.playedVideos.where((id) => !removed.contains(id)).toList(),
        playQueue: ListQueue.of(
            state.playQueue.where((id) => !removed.contains(id)))));
    unawaited(_saveSession(state));
  }

  ValueListenable<int> get namedMusicQueuesRevision =>
      _namedMusicQueuesRevision;

  List<NamedMusicQueue> get namedMusicQueues =>
      _readNamedMusicQueues(_profileDatabase);

  String? get activeNamedMusicQueueId => _activeNamedMusicQueueId;

  bool get _canEditNamedMusicQueues =>
      !isClosed &&
      !_isDisposing &&
      !_switchingProfile &&
      _profileDatabase.profileId == db.profileId;

  bool get canSaveNamedMusicQueue =>
      _canEditNamedMusicQueues &&
      !state.isHidden &&
      !state.isClosing &&
      !_sessionTransitionPending &&
      _inMusicQueue &&
      state.currentQueueId != null;

  List<NamedMusicQueue> _readNamedMusicQueues(IDbClient database) {
    final value = database.getSettings(namedMusicQueuesSetting)?.value;
    if (!identical(database, _profileDatabase)) {
      return NamedMusicQueue.decodeAll(value);
    }
    if (value != _namedMusicQueuesValue) {
      _namedMusicQueuesValue = value;
      _namedMusicQueues = NamedMusicQueue.decodeAll(value);
    }
    return _namedMusicQueues;
  }

  void _notifyNamedMusicQueues(IDbClient database) {
    if (!_isDisposing && !isClosed && identical(_profileDatabase, database)) {
      _namedMusicQueuesRevision.value++;
    }
  }

  void _setActiveNamedMusicQueue(String? id) {
    if (_activeNamedMusicQueueId == id) return;
    _activeNamedMusicQueueId = id;
    _notifyNamedMusicQueues(_profileDatabase);
  }

  Future<void> _writeNamedMusicQueues(
      IDbClient database, Iterable<NamedMusicQueue> queues) async {
    await database.saveSetting(SettingsValue(
        namedMusicQueuesSetting, NamedMusicQueue.encodeAll(queues)));
    _notifyNamedMusicQueues(database);
  }

  Future<T> _queueSessionWrite<T>(Future<T> Function() write) {
    final result = _sessionWrite.then((_) => write());
    _sessionWrite = result.then<void>((_) {}, onError: (Object error) {
      log.warning('Could not save playback queues', error.runtimeType);
    });
    return result;
  }

  void _initializeNamedMusicQueues() {
    final database = _profileDatabase;
    if (database.getSettings(namedMusicQueuesSetting) != null) return;
    final legacy = savedSession;
    final currentVideo = legacy?.videos
        .where((video) => playbackQueueId(video) == legacy.currentId)
        .firstOrNull;
    final sourceId = legacy?.currentSavedDownloadId;
    final isMusic = legacy != null &&
        legacy.audio &&
        (currentVideo?.musicMetadata != null ||
            legacy.musicHistoryEntries?.contains(legacy.currentId) == true ||
            isLocalMusicPlaybackId(legacy.currentId) ||
            (sourceId != null &&
                readyMusicDownload(database, sourceId) != null));
    unawaited(_queueSessionWrite(() async {
      if (database.getSettings(namedMusicQueuesSetting) != null) return;
      await _writeNamedMusicQueues(database, [
        if (isMusic)
          NamedMusicQueue(const Uuid().v4(), legacy.queueTitle ?? '', legacy),
      ]);
    }).catchError((Object _) {}));
  }

  Future<NamedMusicQueue?> saveNamedMusicQueue(String name) async {
    final title = normalizedQueueTitle(name);
    if (title == null || !canSaveNamedMusicQueue) return null;
    final database = _profileDatabase;
    final generation = _videoSwitchGeneration;
    final id = const Uuid().v4();
    final snapshot = _makeSessionSnapshot(state, namedQueueId: id);
    if (snapshot == null) return null;
    final queue = NamedMusicQueue(id, title, snapshot);
    await _queueSessionWrite(() => _writeNamedMusicQueues(database, [
          ..._readNamedMusicQueues(database),
          queue,
        ]));
    if (_canEditNamedMusicQueues &&
        identical(database, _profileDatabase) &&
        generation == _videoSwitchGeneration &&
        canSaveNamedMusicQueue) {
      _setActiveNamedMusicQueue(id);
      await _saveSession(state);
    }
    return queue;
  }

  Future<bool> renameNamedMusicQueue(String id, String name) async {
    final title = normalizedQueueTitle(name);
    if (title == null || !_canEditNamedMusicQueues) return false;
    final database = _profileDatabase;
    return _queueSessionWrite(() async {
      final queues = _readNamedMusicQueues(database);
      if (queues.every((queue) => queue.id != id)) return false;
      await _writeNamedMusicQueues(database, [
        for (final queue in queues)
          queue.id == id ? NamedMusicQueue(id, title, queue.snapshot) : queue,
      ]);
      return true;
    });
  }

  Future<bool> deleteNamedMusicQueue(String id) async {
    if (!_canEditNamedMusicQueues) return false;
    final database = _profileDatabase;
    return _queueSessionWrite(() async {
      final queues = _readNamedMusicQueues(database);
      if (queues.every((queue) => queue.id != id)) return false;
      await _writeNamedMusicQueues(
          database, queues.where((queue) => queue.id != id));
      if (identical(database, _profileDatabase) &&
          _activeNamedMusicQueueId == id) {
        _setActiveNamedMusicQueue(null);
      }
      return true;
    });
  }

  void _localLibraryChanged() {
    if (isClosed || _isDisposing || _switchingProfile || state.isClosing) {
      return;
    }
    if (state.videos.any((entry) => isLocalMusicPlaybackId(entry.videoId))) {
      _checkDevicePlaylistQueue();
      return;
    }
    final entries = state.offlineVideos;
    if (!entries.any((entry) => isLocalMusicPlaybackId(entry.videoId))) return;
    final library = LocalMusicLibrary.instance;
    final authorized =
        library.acceptsSessionSelection(_queuedDeviceSelectionId);
    final removed = entries
        .where((entry) =>
            isLocalMusicPlaybackId(entry.videoId) &&
            (!authorized || localMusicTrackForPlayback(entry.videoId) == null))
        .map((entry) => entry.videoId)
        .toSet();
    if (removed.isNotEmpty &&
        (removed.length == entries.length ||
            removed.contains(state.currentQueueId) ||
            (_backendSwitchPending &&
                removed.contains(openingMusicEntry?.videoId)))) {
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
      bool membershipKnown = true,
      bool complete = true,
      String? queueTitle,
      String? passageQueueId}) {
    _mediaSessionHandler?.clearCarQueue();
    _musicMix = null;
    _musicMixGenerated.clear();
    _musicMixRemoved.clear();
    _adjacentMusic.reset();
    // A new request can reuse the loader currently owned only by this player.
    // Retain it before releasing the previous request's ownership.
    loader?.retain();
    _releasePlaylistLoader();
    final generation = _playlistGeneration;
    _playlistLoader = loader;
    _playlistSourceComplete = complete;
    _playlistReference = reference;
    _passageQueueId = passageQueueId ?? const Uuid().v4();
    _playlistMembershipKnown = reference != null && membershipKnown;
    _musicQueueTitle = normalizedQueueTitle(queueTitle);
    _playlistCheckpointSignature = null;
    _playlistEntries
      ..clear()
      ..addEntries((sourceEntries ?? entries)
          .where((video) => video.explicitMusicDownload == null)
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
    _musicShuffleAnchors.clear();
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
      final device = isLocalMusicPlaybackId(video.videoId);
      if (device &&
          (!state.isAudio || reference.kind != PlaylistSourceKind.local)) {
        continue;
      }
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
      if (!video.filtered &&
          !video.filterHide &&
          video.isUpcoming != true &&
          (!device || localMusicTrackForPlayback(video.videoId) != null)) {
        additions.add(video);
      }
    }
    if (additions.isNotEmpty) {
      final next = additions.map(playbackQueueId).toList();
      if (_musicHistoryPlaylist) _musicHistoryEntries.addAll(next);
      _assignMusicRecommendationSource(
          next, _musicHistoryPlaylist ? reference : null);
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
    if (before.currentQueueId != after.currentQueueId) {
      _musicRequests.observe(after);
    }
    if (_musicShuffleAnchors.isNotEmpty &&
        (before.videos != after.videos ||
            before.offlineVideos != after.offlineVideos)) {
      final entries =
          after.videos.isNotEmpty ? after.videos : after.offlineVideos;
      final ids = entries.map(playbackQueueId).toSet();
      _musicShuffleAnchors.removeWhere((id) => !ids.contains(id));
    }
    if (before.currentQueueId != after.currentQueueId) {
      _musicMixGenerated.remove(after.currentQueueId);
    }
    final handoff = _musicHandoff;
    if (handoff != null &&
        handoff.generation == _videoSwitchGeneration &&
        !_sessionTransitionPending &&
        (after.isAudio != before.isAudio ||
            after.currentQueueId != handoff.from ||
            (handoff.replay != PlayerRepeat.repeatOne &&
                handoff.to != null &&
                !(handoff.to == _musicRequestsBoundary &&
                    hasMusicRequestSuccessor &&
                    after.playQueue.isEmpty) &&
                _nextMusicQueueId(after) != handoff.to))) {
      _clearMusicHandoff(endAudioWait: true);
    }
    if (before.currentQueueId != after.currentQueueId && after.isAudio) {
      _adjacentMusic.recentlyPlayed = before.currentlyPlaying;
    }
    if ((before.offlineVideos != after.offlineVideos ||
            before.videos != after.videos ||
            before.playQueue != after.playQueue ||
            before.playedVideos != after.playedVideos ||
            before.isHidden != after.isHidden ||
            before.isClosing != after.isClosing ||
            before.isAudio != after.isAudio) &&
        before.currentQueueId == after.currentQueueId) {
      _publishQueueNavigation(after);
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
        (before.mediaCommand != after.mediaCommand &&
            after.mediaCommand?.type == MediaCommandType.seek &&
            localMusicTrackForPlayback(after.currentlyPlaying?.videoId ??
                        after.offlineCurrentlyPlaying?.videoId)
                    ?.isCueTrack ==
                true) ||
        (_activeNamedMusicQueueId != null &&
            ((before.isPlaying && !after.isPlaying) ||
                (before.mediaCommand != after.mediaCommand &&
                    after.mediaCommand?.type == MediaCommandType.seek))) ||
        before.position.inSeconds ~/ 5 != after.position.inSeconds ~/ 5) {
      unawaited(_saveSession(after));
    }
  }

  Future<void> _saveSession(PlayerState snapshot) {
    if (_sessionTransitionPending || _sessionOwner != this) {
      return _sessionWrite;
    }
    final saved = _makeSessionSnapshot(snapshot,
        namedQueueId: snapshot.isAudio ? _activeNamedMusicQueueId : null);
    if (saved == null) return _sessionWrite;
    final id = snapshot.currentlyPlaying?.videoId ??
        snapshot.offlineCurrentlyPlaying!.videoId;
    final database = _profileDatabase;
    final watchRepository = _watchRepository;
    final watchRevision = _watchRevision;
    final setting = SettingsValue(playbackSessionSetting,
        _musicRequests.encodeWithSession(saved.encode()));
    // An older TV screen may close after its replacement has begun playing.
    return _queueSessionWrite(() async {
      if (_sessionOwner != this) return;
      final namedId = saved.namedQueueId;
      if (namedId != null) {
        final queues = _readNamedMusicQueues(database);
        if (queues.any((queue) => queue.id == namedId)) {
          await _writeNamedMusicQueues(database, [
            for (final queue in queues)
              queue.id == namedId
                  ? NamedMusicQueue(namedId, queue.name, saved)
                  : queue,
          ]);
        }
      }
      if (!isLocalMusicPlaybackId(id) &&
          watchRepository != null &&
          watchRevision != null) {
        await watchRepository.saveSessionIfCurrent(id, watchRevision, setting);
      } else {
        await database.saveSetting(setting);
      }
    }).catchError((Object _) {});
  }

  PlaybackSession? _makeSessionSnapshot(PlayerState snapshot,
      {String? namedQueueId}) {
    final id = snapshot.currentlyPlaying?.videoId ??
        snapshot.offlineCurrentlyPlaying?.videoId;
    if (id == null ||
        ![
          ...snapshot.videos,
          ...snapshot.offlineVideos
        ].any((video) => playbackQueueId(video) == snapshot.currentQueueId)) {
      return null;
    }
    final queueId = snapshot.currentQueueId!;
    final localTrack = localMusicTrackForPlayback(id);
    if (isLocalMusicPlaybackId(id) && localTrack == null) {
      return null;
    }
    return PlaybackSession(
      videos: snapshot.videos
          .map((v) => playbackQueueId(v) == queueId
              ? (snapshot.currentlyPlaying ?? v)
                  .copyWith(index: v.index, indexId: v.indexId)
              : v)
          .toList(),
      offlineIds: snapshot.offlineVideos.map(playbackQueueId).toList(),
      offlineFingerprints: {
        for (final entry in snapshot.offlineVideos)
          if (entry.explicitMusicDownload case final fingerprint?)
            playbackQueueId(entry): fingerprint
          else if (namedQueueId != null &&
              !isLocalMusicPlaybackId(entry.videoId) &&
              entry.audioOnly &&
              entry.musicMetadata != null)
            playbackQueueId(entry): musicDownloadFingerprint(entry),
      },
      currentId: queueId,
      localSelectionId: _queuedDeviceSelectionId,
      seconds: snapshot.position.inSeconds,
      positionMilliseconds: snapshot.position.inMilliseconds,
      positionFractionUs: localTrack?.isCueTrack == true
          ? snapshot.position.inMicroseconds % Duration.microsecondsPerSecond
          : 0,
      namedQueueId: namedQueueId,
      ownerProfileId: _profileDatabase.profileId,
      audio: snapshot.isAudio,
      musicHistoryEntries: {
        for (final entry in [...snapshot.videos, ...snapshot.offlineVideos])
          if (_musicHistoryEntries.contains(playbackQueueId(entry)))
            playbackQueueId(entry),
      },
      musicHistoryPlaylist: _musicHistoryPlaylist,
      musicRecommendationSources: {
        for (final entry in [...snapshot.videos, ...snapshot.offlineVideos])
          if (_musicRecommendationSources[playbackQueueId(entry)]
              case final source?)
            playbackQueueId(entry): source,
      },
      played: snapshot.playedVideos,
      next: snapshot.playQueue.toList(),
      playlistReference: _playlistReference,
      playlistEntries: _playlistReference?.kind == PlaylistSourceKind.local &&
              !_playlistMembershipKnown
          ? const []
          : _playlistEntries.values.toList(),
      playlistComplete: playlistComplete,
      queueTitle: musicQueueTitle,
      passageQueueId: snapshot.isAudio ? _passageQueueId : null,
    );
  }

  void restoreSession() {
    final saved = savedSession;
    _musicRequests.restore(saved);
    if (saved == null) return;
    final namedId = saved.namedQueueId;
    _setActiveNamedMusicQueue(
        namedMusicQueues.any((queue) => queue.id == namedId) ? namedId : null);
    final deviceAccepted = LocalMusicLibrary.instance
        .acceptsSessionSelection(saved.localSelectionId);
    final deviceId = saved.currentDeviceId;
    if (deviceId != null &&
        devicePlaylistFileProof(localMusicTrackId(deviceId)) == null &&
        !deviceAccepted) {
      return;
    }
    _sessionTransitionPending = false;
    _bindRestoredSession(saved, deviceAccepted);
    final offline = _sessionOfflineEntries(saved, deviceAccepted);
    // Keep the player hidden until Resume is pressed; restoring must be silent.
    _requestedBackendVideoId = null;
    _clearBackendProgress();
    emit(_installSessionQueue(state, saved, offline).copyWith(
      backendRecovery: null,
      currentlyPlaying: null,
      requestedBackend: null,
      offlineCurrentlyPlaying: null,
      position: saved.position,
      isHidden: true,
    ));
  }

  List<DownloadedVideo> _sessionOfflineEntries(
          PlaybackSession saved, bool deviceAccepted) =>
      saved.offlineIds
          .map((id) {
            if (!isLocalMusicPlaybackId(id)) {
              final sourceId = savedDownloadSourceId(id);
              if (sourceId == null) return null;
              final fingerprint = saved.offlineFingerprints[id];
              if (fingerprint != null) {
                return readyMusicDownload(_profileDatabase, sourceId,
                        fingerprint: fingerprint)
                    ?.copyWith(
                        queueEntryId: id == sourceId ? null : id,
                        explicitMusicDownload: fingerprint);
              }
              final download = _profileDatabase.getDownloadByVideoId(sourceId);
              return id == sourceId
                  ? download
                  : download?.copyWith(queueEntryId: id);
            }
            if (!deviceAccepted) return null;
            final track = localMusicTrackForPlayback(id);
            return track == null
                ? null
                : localMusicPlaybackEntry(track, _profileDatabase.profileId,
                    occurrenceId: id);
          })
          .whereType<DownloadedVideo>()
          .where((v) => isLocalMusicPlaybackId(v.videoId) || v.downloadComplete)
          .toList();

  PlayerState _installSessionQueue(
      PlayerState base, PlaybackSession saved, List<DownloadedVideo> offline) {
    final videos = saved.videos
        .where((video) =>
            !isLocalMusicPlaybackId(video.videoId) ||
            localMusicTrackForPlayback(video.videoId) != null)
        .toList();
    final ids = {
      ...videos.map(playbackQueueId),
      ...offline.map(playbackQueueId)
    };
    return base.copyWith(
        videos: videos,
        offlineVideos: offline,
        playedVideos: saved.played.where(ids.contains).toList(),
        playQueue: ListQueue.from(saved.next.where(ids.contains)),
        startAt: saved.position,
        isAudio: saved.audio);
  }

  void _bindRestoredSession(PlaybackSession saved, bool deviceAccepted,
      {bool reloadPlaylist = false}) {
    _queuedDeviceSelectionId = saved.hasDeviceEntries && deviceAccepted
        ? saved.localSelectionId
        : null;
    _musicHistoryEntries
      ..clear()
      ..addAll(saved.musicHistoryEntries ?? const <String>{});
    _musicHistoryPlaylist = saved.musicHistoryPlaylist;
    final reference = saved.playlistReference;
    final ownedReference =
        reference?.profileId == _profileDatabase.profileId ? reference : null;
    final entries = saved.playlistEntries;
    _musicRecommendationSources
      ..clear()
      ..addAll(saved.musicRecommendationSources);
    if (_musicHistoryPlaylist && saved.musicRecommendationSources.isEmpty) {
      _assignMusicRecommendationSource(
          entries.map(playbackQueueId), ownedReference);
    }
    _bindPlaylist(ownedReference, saved.videos,
        queueTitle: saved.queueTitle,
        passageQueueId: saved.passageQueueId,
        complete: saved.playlistComplete,
        membershipKnown: entries.isNotEmpty,
        sourceEntries: entries.isEmpty ? null : entries,
        loader:
            reloadPlaylist && ownedReference != null && !saved.playlistComplete
                ? _restoredPlaylistLoader(ownedReference, entries)
                : null);
  }

  PlaylistLoadSession _restoredPlaylistLoader(
          PlaylistReference reference, List<Video> entries) =>
      PlaylistLoadSession(
        playlist: Playlist(
            title: reference.playlistId,
            playlistId: reference.playlistId,
            author: '',
            videoCount: entries.length,
            videos: entries),
        database: _profileDatabase,
        reference: reference,
      );

  Future<NamedMusicQueueResumeResult> resumeNamedMusicQueue(String id) async {
    const unavailable = NamedMusicQueueResumeResult.unavailable;
    if (!_canEditNamedMusicQueues || state.isClosing) return unavailable;
    if (id == _activeNamedMusicQueueId &&
        !state.isHidden &&
        state.hasVideo &&
        state.isAudio &&
        !_sessionTransitionPending &&
        state.mediaEvent.state != MediaState.error) {
      showBigPlayer();
      if (!state.isPlaying) play();
      return NamedMusicQueueResumeResult.restored;
    }
    final database = _profileDatabase;
    final generation = _videoSwitchGeneration;
    await _sessionWrite;
    if (!_canEditNamedMusicQueues ||
        !identical(database, _profileDatabase) ||
        generation != _videoSwitchGeneration) {
      return unavailable;
    }
    final saved =
        namedMusicQueues.where((queue) => queue.id == id).firstOrNull?.snapshot;
    if (saved == null) return unavailable;
    final restored = await _restoreMusicPlaybackCheckpoint(saved,
        playing: true,
        namedId: id,
        canCommit: () => namedMusicQueues.any((queue) => queue.id == id));
    return restored ? NamedMusicQueueResumeResult.restored : unavailable;
  }

  /// Capture the current Music occurrence and profile before replacing its queue.
  PlaybackSession? captureMusicPlaybackCheckpoint() => canSaveNamedMusicQueue
      ? _makeSessionSnapshot(state, namedQueueId: _activeNamedMusicQueueId)
      : null;

  /// Resolve the target source before replacing playback. [onCommit] runs
  /// synchronously with queue installation, before publishing the player state.
  Future<bool> restoreMusicPlaybackCheckpoint(PlaybackSession checkpoint,
          {required bool playing,
          bool Function()? canCommit,
          VoidCallback? onCommit,
          bool expandPlayer = false}) =>
      _restoreMusicPlaybackCheckpoint(checkpoint,
          playing: playing,
          namedId: checkpoint.namedQueueId,
          canCommit: canCommit,
          onCommit: onCommit,
          expandPlayer: expandPlayer);

  Future<bool> _restoreMusicPlaybackCheckpoint(PlaybackSession saved,
      {required bool playing,
      String? namedId,
      bool Function()? canCommit,
      VoidCallback? onCommit,
      bool expandPlayer = true}) async {
    if (!_canEditNamedMusicQueues ||
        state.isClosing ||
        !saved.audio ||
        (saved.ownerProfileId != null &&
            saved.ownerProfileId != _profileDatabase.profileId)) {
      return false;
    }
    _cancelMusicSelection(keepEndWait: true);
    final request = _musicSelectionRequestRevision;
    final generation = _videoSwitchGeneration;
    final database = _profileDatabase;
    final proxy = NetworkProxy.instance.config;
    bool allowed() =>
        _canEditNamedMusicQueues &&
        identical(database, _profileDatabase) &&
        !NetworkProxy.instance.isChanging &&
        identical(proxy, NetworkProxy.instance.config) &&
        !state.isClosing &&
        (canCommit?.call() ?? true);
    bool current() =>
        allowed() &&
        generation == _videoSwitchGeneration &&
        request == _musicSelectionRequestRevision;
    final library = LocalMusicLibrary.instance;
    try {
      saved.playlistReference?.resolveServer(database);
      if (saved.hasDeviceEntries) {
        await library.initialize();
        await library.revalidate();
        if (!current()) return false;
        if (library.acceptsSessionSelection(saved.localSelectionId) ||
            saved.videos.any(
                (video) => devicePlaylistFileProof(video.videoId) != null)) {
          await library.loadForPlayback(saved.deviceTrackIds);
        }
      }
      if (!current()) return false;
      final deviceAccepted =
          library.acceptsSessionSelection(saved.localSelectionId);
      final offline = _sessionOfflineEntries(saved, deviceAccepted);
      final entries = saved.videos.isEmpty ? offline : saved.videos;
      final entry = entries
          .where((item) => playbackQueueId(item) == saved.currentId)
          .firstOrNull;
      if (entry == null) return false;

      final shouldPrepare = _canPrepareMusicSelection;
      final fromMusic =
          saved.musicHistoryEntries?.contains(saved.currentId) ?? true;
      final prepared = shouldPrepare
          ? await _prepareMusicSelection(entry, saved.position,
              fromMusic: fromMusic, exactStartAt: true, canCommit: allowed)
          : null;
      if (!current() || (shouldPrepare && prepared == null)) {
        if (request == _musicSelectionRequestRevision) _abandonMusicSelection();
        return false;
      }
      var sponsors = const <SponsorSegment>[];
      final resolved = prepared == null && entry is Video
          ? await _resolvePlaybackVideo(entry,
              audio: true,
              active: current,
              onPrepared: (source) =>
                  sponsors = source.download.sponsorSegments)
          : null;
      await _playerReady;
      bool sourceStillAvailable() {
        if (!allowed()) return false;
        saved.playlistReference?.resolveServer(database);
        if (entry is Video) {
          if (isLocalMusicPlaybackId(entry.videoId)) {
            return devicePlaylistFileProof(entry.videoId) != null &&
                localMusicTrackForPlayback(entry.videoId) != null;
          }
          return entry.explicitMusicDownload == null ||
              _explicitDownload(entry) != null;
        }
        return _sessionOfflineEntries(
                saved, library.acceptsSessionSelection(saved.localSelectionId))
            .any((item) => playbackQueueId(item) == saved.currentId);
      }

      if (!current() ||
          (prepared == null && entry is Video && resolved == null) ||
          !sourceStillAvailable()) {
        if (request == _musicSelectionRequestRevision) _abandonMusicSelection();
        return false;
      }
      unawaited(_saveSession(state));
      var installed = false;
      await _switchToVideo(entry,
          startAt: saved.position,
          playing: playing,
          preparedMusic: prepared,
          resolvedVideo: resolved,
          resolvedSponsors: sponsors,
          audio: true,
          exactStartAt: true,
          historyFromMusic: fromMusic,
          expandPlayer: expandPlayer,
          canInstallQueue: sourceStillAvailable, installQueue: (base) {
        _setActiveNamedMusicQueue(
            namedMusicQueues.any((queue) => queue.id == namedId)
                ? namedId
                : null);
        _bindRestoredSession(saved, deviceAccepted, reloadPlaylist: true);
        onCommit?.call();
        installed = true;
        return _installSessionQueue(base, saved, offline).copyWith(
            isClosing: false,
            mediaEvent: const MediaEvent(state: MediaState.loading));
      });
      return installed;
    } catch (error) {
      if (current()) _abandonMusicSelection();
      log.fine('Could not open saved Music queue (${error.runtimeType})');
      return false;
    }
  }

  Future<void> resumeSession({bool? fromMusic}) async {
    _requestedPlaying = null;
    final saved = savedSession;
    if (saved == null) return;
    if (saved.hasDeviceEntries) {
      final deviceId = saved.currentDeviceId;
      final currentIsDevice = deviceId != null;
      final generation = _videoSwitchGeneration;
      final profile = _profileDatabase.profileId;
      final library = LocalMusicLibrary.instance;
      final persistentDevice = deviceId != null &&
          devicePlaylistFileProof(localMusicTrackId(deviceId)) != null;
      final retry = state.mediaEvent.state == MediaState.error;
      if (currentIsDevice) {
        setEvent(const MediaEvent(state: MediaState.loading));
      }
      await library.initialize();
      if (retry) await library.revalidate();
      final accepted = library.acceptsSessionSelection(saved.localSelectionId);
      if (accepted ||
          saved.videos.any((v) => isLocalMusicPlaybackId(v.videoId))) {
        if (currentIsDevice &&
            retry &&
            library.loaded &&
            localMusicTrackForPlayback(deviceId) == null) {
          await library.refresh();
        } else {
          await library.loadForPlayback(saved.deviceTrackIds);
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
      if (currentIsDevice &&
          ((!persistentDevice &&
                  !library.acceptsSessionSelection(saved.localSelectionId)) ||
              localMusicTrackForPlayback(deviceId) == null)) {
        if (await _musicRequests
            .resumeCollectionAfterUnavailableRequest(saved)) {
          return;
        }
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
      _assignMusicRecommendationSource(
          saved.playlistEntries.map(playbackQueueId), _playlistReference);
    }
    final videos = state.videos.isNotEmpty ? state.videos : state.offlineVideos;
    final current =
        videos.where((v) => playbackQueueId(v) == saved.currentId).firstOrNull;
    if (current == null) {
      if (await _musicRequests.resumeCollectionAfterUnavailableRequest(saved)) {
        return;
      }
      if (saved.offlineFingerprints.containsKey(saved.currentId)) {
        setEvent(const MediaEvent(state: MediaState.error));
      }
      return;
    }
    if (current is Video &&
        current.explicitMusicDownload != null &&
        _explicitDownload(current) == null) {
      return;
    }
    final reference = _playlistReference;
    if (reference != null && !saved.playlistComplete) {
      final sourceEntries = _playlistEntries.values.toList();
      _bindPlaylist(reference, state.videos,
          queueTitle: saved.queueTitle,
          passageQueueId: _passageQueueId,
          sourceEntries: sourceEntries,
          membershipKnown: _playlistMembershipKnown,
          loader: _restoredPlaylistLoader(reference, sourceEntries));
    }
    showBigPlayer();
    await _switchToVideo(current, startAt: saved.position);
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

  bool _currentWatchAudioSource(Video video) =>
      video.musicMetadata == null &&
      video.liveNow != true &&
      video.explicitMusicDownload == null &&
      !video.downloadPlaybackOnly &&
      !_sessionTransitionPending &&
      db.profileId == _profileDatabase.profileId &&
      _currentPlaybackSource(video);

  WatchAudioPreference? watchAudioPreferenceFor(Video video) {
    if (!_currentWatchAudioSource(video)) return null;
    if (_watchAudioGeneration != _videoSwitchGeneration) {
      return (trackId: null, progressiveUrl: null);
    }
    return (
      trackId: _requestedWatchAudioTrack ?? _effectiveWatchAudioTrack,
      progressiveUrl: _watchProgressiveUrl,
    );
  }

  void _ownWatchAudioGeneration() {
    if (_watchAudioGeneration == _videoSwitchGeneration) return;
    _watchAudioGeneration = _videoSwitchGeneration;
    _requestedWatchAudioTrack = null;
    _effectiveWatchAudioTrack = null;
    _watchProgressiveUrl = null;
  }

  /// Reports a successfully mounted ordinary audio rendition. A fallback
  /// does not erase a listener's explicit choice for the current occurrence.
  void rememberWatchAudioTrack(Video video, String trackId,
      {bool explicit = true}) {
    final id = trackId.trim();
    if (!state.isAudio || !_currentWatchAudioSource(video) || id.isEmpty) {
      return;
    }
    _ownWatchAudioGeneration();
    if (explicit) _requestedWatchAudioTrack = id;
    _effectiveWatchAudioTrack = id;
  }

  /// Keep exact muxed bytes available for the mode switch when the provider
  /// cannot identify the audio track. These URLs live only in this player.
  void rememberWatchProgressiveAudio(Video video, String url, String? trackId) {
    if (state.isAudio || !_currentWatchAudioSource(video)) return;
    _ownWatchAudioGeneration();
    _effectiveWatchAudioTrack = trackId;
    _watchProgressiveUrl = url;
  }

  bool get playbackRefreshExhausted => !_playbackRecoveryBudget.hasRemaining;

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
    if (video.explicitMusicDownload != null ||
        CachedMusicPlayback.of(video) != null) {
      return null;
    }
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
    if (online != null) {
      return isLocalMusicPlaybackId(online.videoId) ? null : online;
    }
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
        _learningOccurrenceExcluded ||
        _switchingProfile ||
        _isDisposing ||
        NetworkProxy.instance.isChanging) {
      return;
    }
    final domain = video.musicMetadata == null
        ? RecommendationDomain.video
        : RecommendationDomain.music;
    final recommendations =
        RecommendationService.forProfile(db, _profileDatabase.profileId);
    final previous = _learningPlayback;
    // The playlist choice applies from the next listen. A pause or backend
    // retry keeps the current occurrence's decision and consumption clock.
    final source = _musicRecommendationSources[state.currentQueueId];
    if (previous == null && source != null) {
      _learningOccurrenceExcluded =
          isMusicPlaylistRecommendationExcluded(_profileDatabase, source);
      if (_learningOccurrenceExcluded) return;
    }
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
      if (_sessionTransitionPending) return;
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
    _learningOccurrenceExcluded = false;
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
      final save = processingState == AudioProcessingState.idle
          ? null
          : _activeMusicMediaSaveControl(state);
      final carQueueId = mediaHandler.carQueueItemId(state.currentQueueId);
      var playbackState = PlaybackState(
        controls: [
          state.hasQueue ? MediaControl.skipToPrevious : MediaControl.rewind,
          if (playing) MediaControl.pause else MediaControl.play,
          // Android 13+ uses the order of the custom actions for its slots.
          if (save != null) save,
          MediaControl.stop,
          state.hasQueue || hasMusicRequestSuccessor
              ? MediaControl.skipToNext
              : MediaControl.fastForward,
        ],
        systemActions: {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.setShuffleMode,
          MediaAction.setRepeatMode,
          if (carQueueId != null) MediaAction.skipToQueueItem,
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
        queueIndex: carQueueId ?? currentIndex,
      );

      mediaHandler.playbackState.add(playbackState);
    }
  }

  void _bindMusicMediaSave(MediaItem? item) {
    _musicMediaSaveTarget = null;
    if (item == null ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        !state.isAudio) {
      return;
    }
    final entry = state.currentlyPlaying ?? state.offlineCurrentlyPlaying;
    if (entry == null || !_isMusicEntry(entry)) return;
    final library = LocalMusicLibrary.instance;
    final localTrack = localMusicTrackForPlayback(entry.videoId);
    final deviceId =
        localTrack == null ? null : devicePlaylistVideo(localTrack)?.videoId;
    if (isLocalMusicPlaybackId(entry.videoId) && deviceId == null) return;
    final deviceSelection = library.selectionId;
    final app = settings.appCubit;
    final profile = _profileDatabase.profileId;
    final session = app.state;
    bool isCurrent() =>
        !isClosed &&
        !_isDisposing &&
        !_switchingProfile &&
        !app.isClosed &&
        !app.state.globalLoading &&
        !app.state.sessionRecoveryRequired &&
        app.state.profileId == profile &&
        app.state.sessionRevision == session.sessionRevision &&
        app.state.server == session.server &&
        db.profileId == profile &&
        (deviceId == null ||
            (library.visibilityProfile == profile &&
                library.acceptsSessionSelection(deviceSelection) &&
                library.playlistTrackById(deviceId, visibleOnly: true) !=
                    null));
    if (!isCurrent()) return;
    final locale = parseSavedLocale(settings.state.locale) ??
        basicLocaleListResolution(
            WidgetsBinding.instance.platformDispatcher.locales,
            AppLocalizations.supportedLocales);
    _musicMediaSaveTarget = (
      control: MediaControl.custom(
        name: '$musicMediaSaveActionPrefix${const Uuid().v4()}',
        androidIcon: 'drawable/audio_service_playlist_add',
        label: lookupAppLocalizations(locale).musicSaveToPlaylist,
      ),
      generation: _videoSwitchGeneration,
      request: (entry: entry, deviceTrack: localTrack, isCurrent: isCurrent),
    );
  }

  MediaControl? _activeMusicMediaSaveControl(PlayerState snapshot) {
    final target = _musicMediaSaveTarget;
    return target != null &&
            _sessionOwner == this &&
            activePodcast == null &&
            snapshot.isAudio &&
            !snapshot.isHidden &&
            !snapshot.isClosing &&
            !_sessionTransitionPending &&
            target.generation == _videoSwitchGeneration &&
            playbackQueueId(target.request.entry) == snapshot.currentQueueId &&
            target.request.isCurrent()
        ? target.control
        : null;
  }

  static void requestMediaPlaylistSave(MediaHandler handler, String action) {
    final owner = _sessionOwner;
    if (owner == null || owner._mediaSessionHandler != handler) return;
    final control = owner._activeMusicMediaSaveControl(owner.state);
    if (control == null ||
        control.customAction?.name != action ||
        !handler.playbackState.value.controls.contains(control)) {
      return;
    }
    owner.musicMediaSave
        .request(owner._musicMediaSaveTarget!.request, control.label);
  }

  void _publishQueueNavigation(PlayerState snapshot) {
    final current = snapshot.currentQueueId;
    final handler = _mediaSessionHandler;
    final online = snapshot.currentlyPlaying;
    final mediaId = online != null &&
            !isLocalMusicPlaybackId(online.videoId) &&
            online.explicitMusicDownload == null
        ? online.videoId
        : current;
    if (handler == null || _sessionOwner != this || activePodcast != null) {
      return;
    }
    final music = _isMusicEntry(online ?? snapshot.offlineCurrentlyPlaying);
    if (!music ||
        snapshot.isHidden ||
        snapshot.isClosing ||
        !snapshot.isAudio ||
        !snapshot.hasVideo) {
      handler.clearCarQueue();
    }
    if (snapshot.isHidden ||
        snapshot.isClosing ||
        !snapshot.isAudio ||
        !snapshot.hasVideo ||
        handler.mediaItem.value?.id != mediaId) {
      return;
    }
    // Queue edits can happen while the decoder is paused and sends no events.
    // Keep the native transport state intact while refreshing its queue actions.
    final playback = handler.playbackState.value;
    final save = playback.controls.isEmpty
        ? null
        : _activeMusicMediaSaveControl(snapshot);
    final controls = [
      for (final control in playback.controls)
        if (control == MediaControl.rewind ||
            control == MediaControl.skipToPrevious)
          snapshot.hasQueue ? MediaControl.skipToPrevious : MediaControl.rewind
        else if (control == MediaControl.fastForward ||
            control == MediaControl.skipToNext)
          snapshot.hasQueue || hasMusicRequestSuccessor
              ? MediaControl.skipToNext
              : MediaControl.fastForward
        else if (control.customAction?.name
                .startsWith(musicMediaSaveActionPrefix) !=
            true)
          control,
    ];
    if (save != null) {
      final stop = controls.indexOf(MediaControl.stop);
      controls.insert(stop < 0 ? controls.length : stop, save);
    }
    final entries =
        snapshot.videos.isNotEmpty ? snapshot.videos : snapshot.offlineVideos;
    if (music) {
      _publishCarQueue(handler, snapshot, current);
    }
    final carQueueId = handler.carQueueItemId(current);
    final index = carQueueId ??
        entries.indexWhere((entry) => playbackQueueId(entry) == current);
    final actions = {
      ...playback.systemActions
          .where((action) => action != MediaAction.skipToQueueItem),
      if (carQueueId != null) MediaAction.skipToQueueItem,
    };
    if (index < 0 ||
        (index == playback.queueIndex &&
            listEquals(playback.controls, controls) &&
            setEquals(playback.systemActions, actions))) {
      return;
    }
    handler.playbackState.add(playback.copyWith(
      controls: controls,
      systemActions: actions,
      queueIndex: index,
    ));
  }

  void _publishCarQueue(
      MediaHandler handler, PlayerState snapshot, String? current) {
    final scope = androidAutoSession;
    if (scope == null) return;
    final items = _musicQueueTimeline(snapshot).where(_isMusicEntry).toList();
    final active =
        items.indexWhere((entry) => playbackQueueId(entry) == current);
    if (active < 0) return;
    // Bound the media-session transaction while keeping the active row and
    // nearby items accessible even in a very large queue.
    final first =
        (active - 50).clamp(0, (items.length - 100).clamp(0, items.length));
    handler.publishCarQueue((
      this,
      scope,
      _playlistGeneration
    ), [
      for (final entry in items.skip(first).take(100)) _carQueueRow(entry),
    ], musicQueueTitle ?? 'Music');
  }

  CarQueueRow _carQueueRow(IdedVideo entry) {
    final metadata = switch (entry) {
      Video() => entry.musicMetadata!,
      DownloadedVideo() => entry.musicMetadata!,
      _ =>
        throw ArgumentError('Only songs can be included in the music queue.'),
    };
    String label(String? value) =>
        String.fromCharCodes((value ?? '').runes.take(256));
    final occurrence = playbackQueueId(entry);
    return (
      occurrence: occurrence,
      item: MediaItem(
        id: 'car-queue:${sha256.convert(utf8.encode(occurrence))}',
        title: label(metadata.title),
        artist: label(metadata.artist),
        album: label(metadata.album),
      ),
    );
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
        _initialLocalMusic == null &&
        _initialOnDeviceMusic == null) {
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
    if (!kIsWeb && Platform.isAndroid) {
      _mediaVolumeSubscription =
          FlutterVolumeController.addListener(handleMediaVolumeChange)
            ..onError((Object error) {
              log.fine('Media volume listener failed (${error.runtimeType})');
            });
    }
    WidgetsBinding.instance.addObserver(this);
    if (!isTv) {
      _becomingNoisySubscription =
          audioSession.becomingNoisyEventStream.listen((event) {
        pause();
      });

      final handler = await _initializeMediaHandler();
      if (_isDisposing || isClosed) return;
      mediaHandler = handler;
      if (handler.controller == this) {
        handler.refreshCarBrowser();
        _carBrowseSubscription =
            settings.appCubit.stream.listen((_) => handler.refreshCarBrowser());
      }
      BackButtonInterceptor.add(handleBackButton,
          name: 'miniPlayer', zIndex: 2, ifNotYetIntercepted: true);
    } else if (_initialOnDeviceMusic != null && startupActive()) {
      await playOnDeviceMusic(_initialOnDeviceMusic,
          startIndex: _initialPlaylistIndex,
          queueTitle: _initialQueueTitle,
          songTap: _initialSongTap,
          isCurrent: _initialOnDeviceMusicIsCurrent);
    } else if (_initialLocalMusic != null && startupActive()) {
      await playLocalMusic(_initialLocalMusic,
          startIndex: _initialPlaylistIndex,
          queueTitle: _initialQueueTitle,
          songTap: _initialSongTap);
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
    } else if (_initialMusicCollection case final collection?
        when startVideos.isNotEmpty && startupActive()) {
      if (!collection.isCurrent()) {
        setEvent(const MediaEvent(state: MediaState.error));
        return;
      }
      await playMusicCollectionQueue(startVideos,
          queueTitle: collection.title,
          isCurrent: collection.isCurrent,
          recommendationSources: collection.recommendationSources);
    } else if (_initialMusicMix case final startMix? when startupActive()) {
      await startInitialMusicMix(startMix);
    } else if (startVideos.isNotEmpty && startupActive()) {
      final reference = _initialPlaylistReference;
      final switching = reference == null
          ? playVideo(startVideos,
              fromMusic: _initialFromMusic,
              songTap: _initialSongTap,
              startAt: state.startAt,
              queueTitle: _initialQueueTitle,
              recommendationSource: _initialRecommendationSource,
              startIndex:
                  _initialPlaylistIndex == 0 ? null : _initialPlaylistIndex)
          : playPlaylist(startVideos,
              fromMusic: _initialFromMusic,
              songTap: _initialSongTap,
              reference: reference,
              startIndex: _initialPlaylistIndex,
              startAt: state.startAt,
              audio: _initialPlaylistAudio,
              shuffleOnce: _initialPlaylistShuffleOnce,
              playlistLoader: _initialPlaylistLoader);
      startupGeneration = _videoSwitchGeneration;
      await switching;
      if (!startupActive()) return;
    }
    // Stop and newer play requests can arrive while native services initialize.
    // Finish that setup for future explicit playback, but discard stale autoplay.
    if (_resumeOnReady && startupActive()) await resumeSession();
  }

  Future<void> startInitialMusicMix(
      Future<bool?> Function(PlayerCubit) startMix) async {
    final occurrence = playbackOccurrenceRevision;
    setEvent(const MediaEvent(state: MediaState.loading));
    if (await startMix(this) != true &&
        !isClosed &&
        !_isDisposing &&
        !state.isClosing &&
        playbackOccurrenceRevision == occurrence) {
      setEvent(const MediaEvent(state: MediaState.error));
    }
  }

  void handleMediaEvent(MediaEvent event) {
    switch (event.state) {
      case MediaState.completed:
        // A repeated EOF cannot restart a pause or advance a second entry.
        if (_hasPendingMusicHandoff) return;
        final stopAtEnd = (_sleepAtEndQueueId != null &&
                _sleepAtEndQueueId == state.currentQueueId) ||
            _countFinishedSleepTrack();
        final allowHandoff = !stopAtEnd && _hasAutomaticAudioIntent;
        final replay = allowHandoff &&
                (state.isPlaying ||
                    (_interruptionOwnsTransportIntent &&
                        _resumePlaybackAfterInterruption))
            ? _musicReplayMode
            : null;
        if (replay != null) {
          _musicEndWait = _MusicEndWait.replay;
        } else if (!stopAtEnd &&
            _preparingSelectedSong &&
            state.isPlaying &&
            _inMusicQueue &&
            shouldStartPlayback &&
            _sleepAtEndQueueId == null) {
          _musicEndWait = _MusicEndWait.selection;
        }
        final target = replay != null
            ? state.currentQueueId
            : allowHandoff
                ? _nextMusicBoundaryId
                : null;
        if (replay != null ||
            target != null ||
            (allowHandoff &&
                _hasAutomaticMusicIntent &&
                state.playQueue.isEmpty &&
                !playlistComplete &&
                _playlistLoader?.error == null)) {
          _musicHandoff = (
            generation: _videoSwitchGeneration,
            intentRevision: _transportIntentRevision,
            from: state.currentQueueId!,
            to: target,
            replay: replay,
            elapsed: Stopwatch()..start(),
          );
          if (replay != null) _watchSongWaitSettings();
        }
        unawaited(_finishLearning(completed: true));
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
        if (_requestedPlaying == false) {
          pause();
        } else if (event.state == MediaState.playing && !playbackInterrupted) {
          _recordMusicListeningStart();
        }
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
    final musicHomeWidget = _musicHomeWidget;
    Future<void>? closingWidget;
    if (musicHomeWidget != null) {
      playlistLoadingRevision.removeListener(musicHomeWidget.refresh);
      closingWidget = musicHomeWidget.close();
    }
    musicMediaSave.dispose();
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
    await _mediaVolumeSubscription?.cancel();
    await _interruptionSubscription?.cancel();
    await _carBrowseSubscription?.cancel();
    await _updateAutoPip(state, disable: true);
    _pip?.onPipEntered = null;
    _pip?.onPipExited = null;
    await _saveSession(state);
    _bindPlaylist(null, []);
    playlistLoadingRevision.dispose();
    musicSelectionFailureRevision.dispose();
    _musicRequests.revision.dispose();
    _musicContentAdvisory.dispose();
    _namedMusicQueuesRevision.dispose();
    if (_sessionOwner == this) _sessionOwner = null;
    playbackHistoryRevision.value++;
    BackButtonInterceptor.removeByName('miniPlayer');
    WidgetsBinding.instance.removeObserver(this);
    await closingWidget;
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
    _playerDragActive = false;
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
        _musicQueueTitle = null;
        _musicRecommendationSources.clear();
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
    _mediaSessionHandler?.clearCarQueue();
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
    final owner = _sessionOwner;
    final continuing = owner != null &&
            players.contains(owner) &&
            owner._keepMusicOnTaskRemoval(handler.playbackState.value)
        ? owner
        : null;
    final audioSession =
        players.where((p) => p._hasAudioSession).firstOrNull?.audioSession;
    bool hasActiveOwner() =>
        _sessionOwner?.state.hasVideo == true ||
        _runtimePlayers.any((player) => player._podcasts?.active == true);
    try {
      await Future.wait([
        for (final player in players)
          if (identical(player, continuing))
            player._saveSession(player.state)
          else
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

  bool _keepMusicOnTaskRemoval(PlaybackState media) =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      settings.state.musicTaskRemoval == MusicTaskRemoval.keepPlaying &&
      activePodcast == null &&
      !state.isHidden &&
      !state.isClosing &&
      state.isAudio &&
      _isMusicEntry(state.currentlyPlaying ?? state.offlineCurrentlyPlaying) &&
      requestedPlaying &&
      media.playing &&
      (media.processingState == AudioProcessingState.ready ||
          media.processingState == AudioProcessingState.buffering ||
          media.processingState == AudioProcessingState.loading);

  Future<void> prepareForProfileSwitch() =>
      _retirePlaybackSession(changingProfile: true);

  /// Save under the current person and retire decoders without a UI animation.
  Future<void> _retirePlaybackSession({required bool changingProfile}) async {
    if (isClosed) return;
    musicMediaSave.clear();
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
    _musicRecommendationSources.clear();
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
    _setActiveNamedMusicQueue(null);
    _initializeNamedMusicQueues();
    _recoverLearning();
    restoreSession();
    _notifyNamedMusicQueues(_profileDatabase);
  }

  Future<void> _bindWatchSession(String videoId,
      {bool intentional = false, bool localOnly = false}) {
    final database = _profileDatabase;
    final generation = _videoSwitchGeneration;
    final binding = _watchBinding.then((_) async {
      if (_switchingProfile ||
          generation != _videoSwitchGeneration ||
          isClosed) {
        return;
      }
      if (!intentional &&
          _watchVideoId == videoId &&
          _watchLocalOnly == localOnly) {
        return;
      }
      final repository = WatchRepository.forDatabase(database);
      Server? account;
      try {
        if (!localOnly) account = await database.getCurrentlySelectedServer();
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
      _watchLocalOnly = localOnly;
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
      await _bindWatchSession(videoId,
          localOnly: _localWatchHistory(
              state.currentlyPlaying, state.offlineCurrentlyPlaying));
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
    _playerDragActive = false;
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
    _playerDragActive = false;
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

  bool get isMusicAudio => _inMusicQueue;

  bool get _inMusicQueue {
    final current = openingMusicEntry ??
        state.currentlyPlaying ??
        state.offlineCurrentlyPlaying;
    return state.isAudio && _isMusicEntry(current);
  }

  MusicHomeWidgetPlayback? _musicHomeWidgetPlayback() {
    final app = settings.appCubit;
    if (isClosed ||
        _isDisposing ||
        _switchingProfile ||
        _sessionOwner != this ||
        _profileDatabase.profileId != db.profileId ||
        app.isClosed ||
        app.state.globalLoading ||
        app.state.sessionRecoveryRequired ||
        activePodcast != null ||
        state.isHidden ||
        state.isClosing ||
        !state.isAudio) {
      return null;
    }
    final current = state.currentlyPlaying ?? state.offlineCurrentlyPlaying;
    final metadata = switch (current) {
      Video() => current.musicMetadata,
      DownloadedVideo() => current.musicMetadata,
      _ => null,
    };
    if (current == null || metadata == null) return null;

    final status = switch (playbackStatus) {
      MediaState.error => MusicHomeWidgetStatus.unavailable,
      MediaState.completed => MusicHomeWidgetStatus.ended,
      _ when !shouldStartPlayback => MusicHomeWidgetStatus.paused,
      MediaState.idle || MediaState.loading => MusicHomeWidgetStatus.loading,
      MediaState.buffering => MusicHomeWidgetStatus.buffering,
      _ => state.isPlaying
          ? MusicHomeWidgetStatus.playing
          : MusicHomeWidgetStatus.paused,
    };
    final canSkip = !_sessionTransitionPending && !_backendSwitchPending;
    return (
      owner: (
        _profileDatabase.profileId,
        playbackQueueId(current),
        _videoSwitchGeneration
      ),
      title: metadata.title,
      artist: metadata.artist,
      status: status,
      canPrevious: canSkip,
      canNext: canSkip &&
          (state.playQueue.isNotEmpty ||
              !playlistComplete ||
              settings.state.playerRepeatMode != PlayerRepeat.noRepeat),
      canSave: canSkip && !isLocalMusicPlaybackId(current.videoId),
    );
  }

  void _handleMusicHomeWidgetAction(MusicHomeWidgetAction action) {
    switch (action) {
      case MusicHomeWidgetAction.play:
        play();
      case MusicHomeWidgetAction.pause:
        pause();
      case MusicHomeWidgetAction.previous:
        playPrevious();
      case MusicHomeWidgetAction.next:
        playNext();
      case MusicHomeWidgetAction.save:
        final current = state.currentlyPlaying ?? state.offlineCurrentlyPlaying;
        final owner = _musicHomeWidgetPlayback()?.owner;
        if (current != null && owner != null) {
          saveMusicHomeWidgetSong?.call(current, () {
            final playback = _musicHomeWidgetPlayback();
            return playback?.owner == owner && playback?.canSave == true;
          });
        }
    }
  }

  bool _isMusicEntry(IdedVideo? entry) => switch (entry) {
        Video() => entry.musicMetadata != null,
        DownloadedVideo() => entry.musicMetadata != null,
        _ => false,
      };

  IdedVideo? adjacentMusicEntry(
      {required bool previous, bool applyPreviousPolicy = false}) {
    if (!_inMusicQueue || state.isClosing || state.isHidden) return null;
    if (previous && applyPreviousPolicy && _musicPreviousRestartsCurrent) {
      return state.currentlyPlaying ?? state.offlineCurrentlyPlaying;
    }
    final current = openingMusicEntry;
    final activeId =
        current == null ? state.currentQueueId : playbackQueueId(current);
    final id =
        previous ? state.playedVideos.lastOrNull : _nextMusicQueueId(state);
    if (id == null || id == activeId) return null;
    final target = _queueEntry(id);
    return _isMusicEntry(target) ? target : null;
  }

  IdedVideo? _queueEntry(String id) {
    final entries =
        state.videos.isNotEmpty ? state.videos : state.offlineVideos;
    return entries.where((entry) => playbackQueueId(entry) == id).firstOrNull;
  }

  PlayerRepeat get _queueRepeatMode => hasMusicRequestSuccessor
      ? PlayerRepeat.noRepeat
      : settings.state.playerRepeatMode;

  String? _nextMusicQueueId(PlayerState snapshot) {
    if (snapshot.playQueue.isNotEmpty) return snapshot.playQueue.first;
    if (!playlistComplete || _queueRepeatMode != PlayerRepeat.repeatAll) {
      return null;
    }
    final first =
        snapshot.videos.firstOrNull ?? snapshot.offlineVideos.firstOrNull;
    return first == null ? null : playbackQueueId(first);
  }

  bool get _musicPreviousRestartsCurrent =>
      _inMusicQueue &&
      openingMusicEntry == null &&
      settings.state.musicPreviousTrackPolicy ==
          MusicPreviousTrackPolicy.restartCurrentAfterThreshold &&
      state.position >= const Duration(seconds: 3);

  bool get _keepMusicPausedOnSkip =>
      _inMusicQueue && !intendsPlayback && settings.state.musicKeepPausedOnSkip;

  bool get _pauseAtMusicRepeat =>
      _inMusicQueue &&
      settings.state.musicPauseAtRepeat &&
      (settings.state.playerRepeatMode == PlayerRepeat.repeatOne ||
          (settings.state.playerRepeatMode == PlayerRepeat.repeatAll &&
              state.playQueue.isEmpty &&
              playlistComplete));

  bool get _hasAutomaticAudioIntent =>
      state.isAudio &&
      state.currentQueueId != null &&
      !_isDisposing &&
      !isClosed &&
      !_switchingProfile &&
      !state.isHidden &&
      !state.isClosing &&
      !NetworkProxy.instance.isChanging &&
      db.profileId == _profileDatabase.profileId &&
      !_sessionTransitionPending &&
      !_backendSwitchPending &&
      intendsPlayback &&
      _sleepAtEndQueueId == null &&
      settings.state.autoplayQueue;

  bool get _hasAutomaticMusicIntent =>
      _hasAutomaticAudioIntent &&
      _inMusicQueue &&
      _queueRepeatMode != PlayerRepeat.repeatOne;

  bool get _mayAdvanceMusic => _hasAutomaticMusicIntent && !playbackInterrupted;

  PlayerRepeat? get _musicReplayMode {
    if (!_inMusicQueue) return null;
    final mode = _queueRepeatMode;
    return mode == PlayerRepeat.repeatOne ||
            (mode == PlayerRepeat.repeatAll &&
                _nextMusicQueueId(state) == state.currentQueueId)
        ? mode
        : null;
  }

  // Keep the Android playback service alive across Music's audio boundaries.
  String? get _nextMusicBoundaryId {
    if (!state.isAudio || _queueRepeatMode == PlayerRepeat.repeatOne) {
      return null;
    }
    if (hasMusicRequestSuccessor && state.playQueue.isEmpty) {
      return _musicRequestsBoundary;
    }
    final next = _nextMusicQueueId(state);
    if (next == null || next == state.currentQueueId) return null;
    final target = _queueEntry(next);
    if (target == null || (target is DownloadedVideo && !target.audioOnly)) {
      return null;
    }
    return _inMusicQueue || _isMusicEntry(target) ? next : null;
  }

  IdedVideo? get _automaticMusicTarget =>
      _mayAdvanceMusic && !_pauseAtMusicRepeat
          ? adjacentMusicEntry(previous: false)
          : null;

  bool get _hasPendingMusicHandoff =>
      _musicHandoff?.generation == _videoSwitchGeneration;

  /// The actual automatic traversal, including shuffle and a repeat-all wrap.
  /// The final track of a sleep countdown can play to its end in isolation.
  IdedVideo? get automaticMusicSuccessor =>
      state.isPlaying && state.sleepTracksRemaining != 1
          ? _automaticMusicTarget
          : null;

  /// Remains valid across EOF accounting and the incoming decoder's takeover.
  /// A manual selection, even of this same occurrence, starts another handoff.
  bool isAutomaticMusicHandoffTo(String queueId) {
    final handoff = _musicHandoff;
    if (handoff == null ||
        handoff.replay != null ||
        handoff.to != queueId ||
        !_isMusicEntry(_queueEntry(handoff.from)) ||
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
        (opening == null
            ? _inMusicQueue && state.currentQueueId == queueId
            : playbackQueueId(opening) == queueId);
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
    _musicAdvanceDeferredForFocus = false;
    if (handoff != null && endAudioWait) {
      if (handoff.replay != null && _musicEndWait == _MusicEndWait.replay) {
        _musicEndWait = null;
      }
      mapMediaEventToMediaHandler(
          const MediaEvent(state: MediaState.completed));
    }
  }

  bool _canAdvanceMusicHandoff(_MusicHandoff handoff) {
    if (handoff.from != state.currentQueueId ||
        handoff.intentRevision != _transportIntentRevision ||
        !_hasAutomaticAudioIntent) {
      return false;
    }
    final replay = handoff.replay;
    if (replay != null) return replay == _musicReplayMode;
    return handoff.to == null
        ? _hasAutomaticMusicIntent
        : handoff.to == _nextMusicBoundaryId;
  }

  void _advanceAfterSongEnd() {
    var handoff = _musicHandoff;
    if (handoff == null || handoff.generation != _videoSwitchGeneration) {
      if (_musicReplayMode == null &&
          ((intendsPlayback && !playbackInterrupted) ||
              (!_inMusicQueue && _nextMusicBoundaryId == null))) {
        playNext(userInitiated: false);
      }
      return;
    }
    if (!_canAdvanceMusicHandoff(handoff)) {
      _clearMusicHandoff(endAudioWait: true);
      return;
    }
    if (playbackInterrupted) {
      _musicAdvanceDeferredForFocus = true;
      _watchSongWaitSettings();
      return;
    }
    _musicAdvanceDeferredForFocus = false;
    if (handoff.replay != null) {
      // Seek/play and a same-entry reload both consume the stored EOF once.
      _clearMusicHandoff();
      _musicEndWait = _MusicEndWait.replay;
      unawaited(_playNextNow());
      return;
    }
    if (handoff.to == null) {
      // A playlist may have reached the end of its loaded page. Count the
      // time already spent awaiting more entries toward the requested gap.
      final target = _nextMusicBoundaryId;
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
        intentRevision: handoff.intentRevision,
        from: handoff.from,
        to: target,
        replay: null,
        elapsed: handoff.elapsed,
      );
    }
    _songGap?.cancel();
    _songGap = null;
    if (settings.state.songTransitionMode == SongTransitionMode.pause &&
        (_automaticMusicTarget != null ||
            handoff.to == _musicRequestsBoundary)) {
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
    unawaited(_playNextNow());
  }

  void _watchSongWaitSettings() {
    _gapSettings ??= settings.stream.listen((_) {
      final handoff = _musicHandoff;
      if (handoff == null || handoff.generation != _videoSwitchGeneration) {
        return;
      }
      if (!_canAdvanceMusicHandoff(handoff)) {
        _clearMusicHandoff(endAudioWait: true);
      } else if (_songGap != null) {
        // A known successor needs its configured silence recalculated.
        _advanceAfterSongEnd();
      }
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
    if (hasMusicRequestSuccessor && state.playQueue.isEmpty) {
      final generation = _videoSwitchGeneration;
      final advanced =
          await _musicRequests.advance(userInitiated: userInitiated);
      if (!advanced && generation == _videoSwitchGeneration) {
        _clearMusicHandoff(endAudioWait: true);
        if (!userInitiated) pause();
      }
      return;
    }
    final repeat = _queueRepeatMode;
    if (repeat != PlayerRepeat.repeatOne &&
        state.playQueue.isEmpty &&
        !playlistComplete) {
      // The end of a loaded page is not the end of the playlist. Keep the
      // current item until more metadata arrives or the user retries a failure.
      _waitingForPlaylist = true;
      _waitingForPlaylistUserSkip |= userInitiated;
      playlistLoadingRevision.value++;
      return;
    }
    if (state.playQueue.isEmpty && repeat == PlayerRepeat.noRepeat) return;
    final skipped = userInitiated || _waitingForPlaylistUserSkip;
    _waitingForPlaylistUserSkip = false;
    final pauseAtRepeat = !skipped && _pauseAtMusicRepeat;
    final keepPaused = skipped && _keepMusicPausedOnSkip;
    final repeatsCurrent = repeat == PlayerRepeat.repeatOne &&
        (!skipped || !_inMusicQueue || state.playQueue.isEmpty);
    if (repeatsCurrent || (pauseAtRepeat && _musicReplayMode != null)) {
      if (pauseAtRepeat) pause();
      final IdedVideo? entry =
          state.currentlyPlaying ?? state.offlineCurrentlyPlaying;
      if (entry != null && _isMusicHistoryEntry(entry)) {
        _activeHistoryWrite?.cancel();
        _activeHistoryWrite = _beginHistoryWrite(entry, fromMusic: true);
      }
      seek(Duration.zero);
      if (!pauseAtRepeat && !keepPaused) play();
    } else if (state.videos.isNotEmpty || state.offlineVideos.isNotEmpty) {
      unawaited(_finishLearning(skipped: skipped));
      if (state.playQueue.isNotEmpty || repeat == PlayerRepeat.repeatAll) {
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
            automatic: !skipped,
            playing: keepPaused ? false : null);
      } else if (repeat == PlayerRepeat.repeatAll) {
        emit(state.copyWith(playedVideos: [], playQueue: ListQueue.from([])));
        final switching = _switchQueueSuccessor(
            state.videos.isNotEmpty ? state.videos[0] : state.offlineVideos[0],
            automatic: !skipped && !pauseAtRepeat,
            playing: pauseAtRepeat || keepPaused ? false : null);
        final generation = _videoSwitchGeneration;
        await switching;
        if (isClosed || generation != _videoSwitchGeneration) return;
        generatePlayQueue();
      }
    }
  }

  Future<void> _switchQueueSuccessor(IdedVideo target,
      {required bool automatic, bool? playing}) {
    final handoff = _musicHandoff;
    if (automatic &&
        handoff != null &&
        handoff.generation == _videoSwitchGeneration &&
        handoff.to == playbackQueueId(target)) {
      return _switchToVideo(target, preserveMusicHandoff: true);
    }
    if (playing != null) {
      if (target is DownloadedVideo &&
          target.profileId != _profileDatabase.profileId) {
        return Future.value();
      }
      return _switchToVideo(target, playing: playing);
    }
    return target is Video
        ? switchToVideo(target)
        : switchToOfflineVideo(target as DownloadedVideo);
  }

  void playNext({bool userInitiated = true}) {
    if (hasMusicRequestSuccessor &&
        state.playQueue.isEmpty &&
        _musicRequests._transitioning) {
      return;
    }
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

  bool trySkipMusicAfterRetryExhaustion() {
    if (!settings.state.musicSkipAfterRetryExhaustion ||
        !_mayAdvanceMusic ||
        _preparingSelectedSong ||
        state.playQueue.isEmpty ||
        _nextMusicBoundaryId == null) {
      return false;
    }
    unawaited(_playNextNow());
    return true;
  }

  void playPrevious() {
    _cancelMusicSelection();
    _clearMusicHandoff();
    Future<void> previous() async {
      final keepPaused = _keepMusicPausedOnSkip;
      if (state.playedVideos.isNotEmpty && !_musicPreviousRestartsCurrent) {
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
        await _switchQueueSuccessor(_queueEntry(toPlay)!,
            automatic: false, playing: keepPaused ? false : null);
      } else {
        seek(Duration.zero);
        if (!keepPaused) play();
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

  bool _isMusicHistoryEntry(IdedVideo entry) =>
      isLocalMusicPlaybackId(entry.videoId) ||
      _musicHistoryEntries.contains(playbackQueueId(entry));

  PlaybackHistoryWrite? _beginHistoryWrite(IdedVideo entry, {bool? fromMusic}) {
    if (fromMusic ?? _isMusicHistoryEntry(entry)) {
      return _profileDatabase
          .beginMusicListening(musicListeningTrackId(entry.videoId));
    }
    return _profileDatabase.beginPlaybackHistory(
        PlaybackHistoryOrigin.video, entry.videoId);
  }

  void _recordMusicListeningStart() {
    final write = _activeHistoryWrite;
    if (write == null || write.origin != PlaybackHistoryOrigin.music) return;
    final online = state.currentlyPlaying;
    final offline = state.offlineCurrentlyPlaying;
    final id = online?.videoId ?? offline?.videoId;
    if (id == null || musicListeningTrackId(id) != write.videoId) return;

    // Consume this occurrence before storage yields. Native acknowledgments,
    // seek and ordinary pause/resume can all produce another play event.
    _activeHistoryWrite = null;
    final saved = isLocalMusicPlaybackId(id)
        ? null
        : offline ?? (online == null ? null : _explicitDownload(online));
    final entry = HistoryVideoCache(
      write.videoId,
      online?.title ?? offline?.title ?? '',
      online?.author ?? offline?.author,
      ImageObject.getBestThumbnail(online?.videoThumbnails ?? const [])?.url ??
          '',
      authorId: online?.authorId,
      lengthSeconds: online?.lengthSeconds ?? offline?.lengthSeconds,
      musicMetadata: online?.musicMetadata ?? offline?.musicMetadata,
      playedFromDownload: saved != null,
      downloadAccountId: saved?.accountId,
    );
    final playlist = _playlistEntries.containsKey(state.currentQueueId)
        ? _playlistReference
        : null;
    unawaited(
        write.record(entry, playlist: playlist).catchError((Object error) {
      log.fine('Could not record Music history (${error.runtimeType})');
    }));
  }

  Future<_PreparedMusicSelection?> _prepareMusicSelection(
      IdedVideo entry, Duration startAt,
      {bool? fromMusic,
      bool exactStartAt = false,
      bool Function()? canCommit}) async {
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
        identical(proxy, NetworkProxy.instance.config) &&
        (canCommit?.call() ?? true);
    try {
      var savedSponsors = const <SponsorSegment>[];
      if (entry is Video) {
        final resolved = await _resolvePlaybackVideo(entry,
            audio: true, active: current, onPrepared: (source) {
          savedSponsors = source.download.sponsorSegments;
        });
        if (!current() || resolved == null) return null;
        entry = resolved;
        if (resolved.explicitMusicDownload != null) {
          savedSponsors =
              _explicitDownload(resolved)?.sponsorSegments ?? const [];
        }
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
      final cached = entry is Video &&
              entry.explicitMusicDownload == null &&
              CachedMusicPlayback.of(entry) == null
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
      final position = skip == null || exactStartAt
          ? startAt
          : Duration(milliseconds: skip.last);
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
          if (entry is Video &&
              isLocalMusicPlaybackId(entry.videoId) &&
              (!library.acceptsSessionSelection(localSelection) ||
                  localMusicTrackForPlayback(entry.videoId) == null)) {
            throw StateError('Device music file unavailable');
          }
          return (
            entry: entry,
            position: position,
            savedSponsors: savedSponsors
          );
        } on ManualMusicSourceFailure {
          final failed = entry;
          if (failed is! Video ||
              isLocalMusicPlaybackId(failed.videoId) ||
              failed.downloadPlaybackOnly ||
              failed.explicitMusicDownload != null ||
              CachedMusicPlayback.of(failed) != null ||
              !current()) {
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
      bool songTap = false,
      bool selectedByUser = false,
      bool shuffleOnce = false,
      bool retainQueueOrder = false,
      PlaylistReference? recommendationSource,
      List<PlaylistReference?>? recommendationSources,
      bool Function()? canCommit,
      required bool audio,
      required VoidCallback bindQueue}) async {
    if (vids.isEmpty || canCommit?.call() == false) return;
    RangeError.checkValidIndex(startIndex, vids, 'startIndex');
    final isOffline = vids.first is DownloadedVideo;
    var videos =
        isOffline ? <Video>[] : assignPlaybackQueueIds(vids.cast<Video>());
    var offlineVideos = isOffline
        ? assignDownloadedQueueIds(vids.cast<DownloadedVideo>())
        : <DownloadedVideo>[];
    List<IdedVideo> entries = isOffline ? offlineVideos : videos;
    final collectionSources = {
      if (recommendationSources != null)
        for (final (index, entry) in entries.indexed)
          if (_musicRecommendationSourceKey(recommendationSources[index])
              case final sourceKey?)
            playbackQueueId(entry): sourceKey,
    };
    if (shuffleOnce) entries.shuffle();
    final selected = entries[startIndex];
    if (_playsOnlyTappedSong(songTap)) {
      // Keep the occurrence ID assigned within the original collection.
      videos = selected is Video ? [selected] : <Video>[];
      offlineVideos =
          selected is DownloadedVideo ? [selected] : <DownloadedVideo>[];
      entries = [selected];
      startIndex = 0;
    }
    final resetShuffle = songTap && !settings.state.musicRetainShuffleOnSongTap;
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
    if (canCommit?.call() == false) {
      if (prepared != null) _abandonMusicSelection();
      return;
    }
    final playingAfterPreparation = _requestedPlaying;
    if (_activeNamedMusicQueueId != null) {
      unawaited(_saveSession(state));
      _setActiveNamedMusicQueue(null);
    }
    bindQueue();
    _musicHistoryEntries.clear();
    if (fromMusic) _musicHistoryEntries.addAll(entries.map(playbackQueueId));
    _musicHistoryPlaylist = fromMusic && _playlistReference != null;
    _musicRecommendationSources.clear();
    if (fromMusic) {
      if (recommendationSources == null) {
        _assignMusicRecommendationSource(
            entries.map(playbackQueueId), recommendationSource);
      } else {
        for (final entry in entries) {
          final id = playbackQueueId(entry);
          if (collectionSources[id] case final key?) {
            _musicRecommendationSources[id] = key;
          }
        }
      }
    }
    if (prepared != null && intent != _transportIntentRevision) {
      _requestedPlaying = playingAfterPreparation;
    }
    setAudio(audio);
    final shuffleUpcoming = !shuffleOnce &&
        !retainQueueOrder &&
        !resetShuffle &&
        settings.state.playerShuffleMode;
    final previous = shuffleUpcoming
        ? <String>[]
        : entries.take(startIndex).map(playbackQueueId).toList();
    final next = entries
        .asMap()
        .entries
        .where((entry) =>
            entry.key != startIndex &&
            (shuffleUpcoming || entry.key > startIndex))
        .map((entry) => playbackQueueId(entry.value))
        .toList();
    if (shuffleUpcoming) next.shuffle();
    PlayerState installQueue(PlayerState snapshot) => snapshot.copyWith(
        offlineVideos: offlineVideos,
        videos: videos,
        startAt: startAt,
        mediaEvent: const MediaEvent(state: MediaState.loading),
        playedVideos: previous,
        playQueue: ListQueue.of(next),
        selectedFullScreenIndex: entries.length > 1 ? 3 : 0,
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
        resetShuffleOnCommit: resetShuffle,
        expandPlayer: prepared != null);
  }

  bool _playsOnlyTappedSong(bool songTap) =>
      songTap &&
      settings.state.musicSongTapQueueScope == MusicSongTapQueueScope.songOnly;

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
          playing: prepared != null || _keepMusicPausedOnSkip
              ? _requestedPlaying
              : null);
    } else {
      await _saveSession(state);
    }
  }

  DownloadedVideo? _explicitDownload(Video video) {
    final fingerprint = video.explicitMusicDownload;
    return fingerprint == null
        ? null
        : readyMusicDownload(_profileDatabase, video.videoId,
            fingerprint: fingerprint);
  }

  bool _localWatchHistory(Video? video, DownloadedVideo? offline) =>
      CachedMusicPlayback.of(video) != null ||
      (video?.explicitMusicDownload ?? offline?.explicitMusicDownload) != null;

  Future<Video?> _resolvePlaybackVideo(Video video,
      {required bool audio,
      required bool Function() active,
      bool retainOnFailure = false,
      BackendPlayback? backendRequest,
      void Function(DownloadPlaybackSource)? onPrepared,
      void Function(BackendPlayback)? onBackendRequest,
      VoidCallback? onRetry}) async {
    if (isLocalMusicPlaybackId(video.videoId)) {
      if (!active()) return null;
      final track = audio ? localMusicTrackForPlayback(video.videoId) : null;
      final current = track == null ? null : devicePlaylistVideo(track);
      if (current == null || current.videoId != video.videoId) {
        throw StateError('Device music file unavailable');
      }
      return video.copyWith(
          title: current.title,
          author: current.author,
          lengthSeconds: current.lengthSeconds,
          musicMetadata: current.musicMetadata);
    }
    if (CachedMusicPlayback.of(video) case final cached?) {
      if (!active()) return null;
      if (!audio ||
          cached.source(await db.getCurrentlySelectedServer(), video.videoId) ==
              null) {
        throw StateError('Cached song is unavailable');
      }
      return active() ? video : null;
    }
    if (video.explicitMusicDownload != null) {
      if (!active()) return null;
      final saved = audio ? _explicitDownload(video) : null;
      if (saved == null) throw StateError('Saved song unavailable');
      return video.copyWith(
          title: saved.musicMetadata!.title,
          author: saved.musicMetadata!.artist,
          musicMetadata: saved.musicMetadata,
          lengthSeconds: saved.lengthSeconds);
    }
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
      Video? resolvedVideo,
      List<SponsorSegment>? resolvedSponsors,
      bool? audio,
      bool exactStartAt = false,
      bool? historyFromMusic,
      bool Function()? canInstallQueue,
      PlayerState Function(PlayerState)? installQueue,
      bool resetShuffleOnCommit = false,
      bool expandPlayer = false}) async {
    if (isClosed || _switchingProfile || canInstallQueue?.call() == false) {
      return;
    }
    final stagedQueue = canInstallQueue != null;
    var committedQueue = false;
    if (preparedMusic != null) {
      _preparingSelectedSong = false;
      if ((_musicHandoff != null || _musicEndWait != null) &&
          !state.isPlaying &&
          shouldStartPlayback) {
        _musicEndWait = _MusicEndWait.selection;
      }
    }
    if (!preserveMusicHandoff && !stagedQueue) _clearMusicHandoff();
    final device = isLocalMusicPlaybackId(video.videoId);
    if (device) {
      final track = localMusicTrackForPlayback(video.videoId);
      if (track == null ||
          (video is DownloadedVideo
              ? video.profileId != _profileDatabase.profileId
              : video is! Video ||
                  devicePlaylistFileProof(video.videoId) == null ||
                  !state.isAudio)) {
        if (preparedMusic != null) {
          _abandonMusicSelection();
          musicSelectionFailureRevision.value++;
          _sessionTransitionPending = false;
        } else if (!stagedQueue) {
          setEvent(const MediaEvent(state: MediaState.error));
        }
        return;
      }
      // Data supplied by another caller or an obsolete queue entry grants no
      // read permission and must not supply a URI, title or artwork override.
      if (video is DownloadedVideo) {
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
          ? _beginHistoryWrite(video, fromMusic: historyFromMusic)
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
    final retainWatchAudio = _watchAudioGeneration == _videoSwitchGeneration &&
        (retainOnFailure || backendRequest != null) &&
        video is Video &&
        video.videoId == state.currentlyPlaying?.videoId &&
        playbackQueueId(video) == state.currentQueueId;
    final generation = ++_videoSwitchGeneration;
    if (retainWatchAudio) {
      _watchAudioGeneration = generation;
    } else {
      _ownWatchAudioGeneration();
    }
    _openingSong = music == null
        ? null
        : (generation: generation, entry: video, title: music.title);
    _clearPlaybackRecovery(resetBudget: true);
    bool active() => !isClosed && generation == _videoSwitchGeneration;
    final sponsorTypes = _enabledSponsorTypes;
    List<SponsorSegment>? preparedSponsorSegments;
    var savedSponsorSegments = preparedMusic?.savedSponsors ??
        resolvedSponsors ??
        const <SponsorSegment>[];
    // Start optional community metadata while source metadata and focus are
    // loading. It never delays source setup, even on a failed connection.
    final sponsorPreparation = switch (video) {
      _ when device => Future.value(const <SponsorSegment>[]),
      DownloadedVideo() => Future.value(video.sponsorSegments),
      Video(explicitMusicDownload: String()) => Future.value(
          _explicitDownload(video)?.sponsorSegments ??
              const <SponsorSegment>[]),
      Video(playbackSourceId: CachedMusicPlayback()) =>
        Future.value(const <SponsorSegment>[]),
      _ => _loadSponsorSegments(video.videoId, sponsorTypes),
    };
    unawaited(sponsorPreparation.then((segments) {
      if (active()) preparedSponsorSegments = segments;
    }));
    final podcast = activePodcast;
    if (podcast != null) await podcast.stop();
    if (!active()) return;
    _clearMetadataRetry();
    _progressGeneration++;
    _requestedBackendVideoId = video is Video && !device ? video.videoId : null;
    _backendSwitchPending = true;
    _clearBackendProgress();
    // Replacing the video disposes its controls and active gesture recognizer.
    // Settle first, because that disposal does not deliver drag end/cancel.
    videoDragCancelled();
    if (preparedMusic == null && !stagedQueue) {
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
            await (_videoFocusActivationRequired && !(audio ?? state.isAudio)
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
      if (isOffline && audio == null) {
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

      if (preparedMusic == null && !stagedQueue) {
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
            resolvedVideo ??
            await _resolvePlaybackVideo(video as Video,
                audio: audio ?? state.isAudio,
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
        if (device && localMusicTrackForPlayback(v.videoId) == null) {
          throw StateError('Device music file unavailable');
        }
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
      } else if (preparedMusic == null && !stagedQueue) {
        await _bindWatchSession(video.videoId,
            intentional: backendRequest == null && !retainOnFailure,
            localOnly:
                _localWatchHistory(currentlyPlaying, offlineCurrentlyPlaying));
      }
      if (!active() || _switchingProfile || canInstallQueue?.call() == false) {
        return;
      }
      if (stagedQueue) _clearMusicHandoff();
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
      if (initialSkip != null && preparedMusic == null && !exactStartAt) {
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
      if (currentlyPlaying != null && !stagedQueue) {
        _recordBackendRequest(
            currentlyPlaying.videoId, currentlyPlaying.backendPlayback);
      }
      // A drag can also begin while the replacement metadata is loading.
      videoDragCancelled();
      // Persist only coherent queue/current/context snapshots. A new request
      // may have changed playlist ownership or audio mode before metadata arrived.
      _sessionTransitionPending = false;
      final snapshot = installQueue?.call(state) ?? state;
      committedQueue = true;
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
          backendRecovery: preparedMusic == null && !stagedQueue
              ? snapshot.backendRecovery
              : null,
          requestedBackend: currentlyPlaying?.backendPlayback,
          offlineCurrentlyPlaying: offlineCurrentlyPlaying));
      if (expandPlayer) showBigPlayer();
      _beginLearning(_learningVideo, selectedByUser: selectedByUser);
      _savedSponsors = savedSponsorSegments.isEmpty
          ? null
          : (queueId: state.currentQueueId, segments: savedSponsorSegments);
      unawaited(_saveSession(state));
      if (resetShuffleOnCommit) {
        try {
          await settings.setShuffle(false);
        } catch (error) {
          log.fine('Could not save Shuffle state (${error.runtimeType})');
        }
        if (!active()) return;
      }
      if ((preparedMusic != null || stagedQueue) && !device) {
        try {
          await _bindWatchSession(video.videoId,
              intentional: true,
              localOnly: _localWatchHistory(
                  currentlyPlaying, offlineCurrentlyPlaying));
        } catch (error) {
          log.fine(
              'Could not record history for selected song (${error.runtimeType})');
        }
        if (!active()) return;
        if (stagedQueue) await _saveSession(state);
      }
      if (_playlistReference != null) {
        await saveProgress(resumeAt.inSeconds);
        if (!active()) return;
      }

      final historyVideo = _learningVideo;
      final historyWrite = _activeHistoryWrite;
      if (historyWrite != null &&
          historyWrite.origin == PlaybackHistoryOrigin.video &&
          historyVideo != null) {
        final saved = offlineCurrentlyPlaying ??
            (currentlyPlaying == null
                ? null
                : _explicitDownload(currentlyPlaying));
        await historyWrite.record(HistoryVideoCache(
            historyVideo.videoId,
            historyVideo.title ?? '',
            historyVideo.author,
            ImageObject.getBestThumbnail(historyVideo.videoThumbnails)?.url ??
                '',
            authorId: historyVideo.authorId,
            playedFromDownload: saved != null,
            downloadAccountId: saved?.accountId,
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
          if (active()) {
            _bindMusicMediaSave(item);
            mediaHandler.mediaItem.add(item);
            _publishQueueNavigation(state);
          }
        } catch (error, stack) {
          // Artwork/storage failures must not remove a playable queue item.
          log.warning('Could not update playback notification', error, stack);
        }
      }
    } catch (err) {
      if (!active()) return;
      if (stagedQueue && !committedQueue) {
        log.fine('Could not install saved Music queue (${err.runtimeType})');
        return;
      }
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
    } finally {
      if (stagedQueue && !committedQueue && active()) {
        _openingSong = null;
        _backendSwitchPending = false;
        _sessionTransitionPending = false;
        _requestedBackendVideoId = state.currentlyPlaying?.videoId;
        _abandonMusicSelection();
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
        video.explicitMusicDownload != null ||
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
      {int startIndex = 0,
      bool fromMusic = false,
      bool songTap = false}) async {
    if (offlineVids.isEmpty ||
        startIndex < 0 ||
        startIndex >= offlineVids.length ||
        _switchingProfile ||
        offlineVids.any(
            (video) => video.profileId != _profileDatabase.profileId)) return;
    if (offlineVids
        .any((video) => !DownloadedVideo.isSafeFileId(video.videoId))) {
      return;
    }
    log.fine('Playing ${offlineVids.length} offline videos');
    await _playVideos(offlineVids,
        fromMusic: fromMusic,
        songTap: songTap,
        startIndex: startIndex,
        audio: offlineVids[startIndex].audioOnly,
        bindQueue: _bindOfflineQueue);
  }

  void _bindOfflineQueue({String? queueTitle, String? deviceSelectionId}) {
    _queuedDeviceSelectionId = deviceSelectionId;
    _requestedPlaying = null;
    _sessionTransitionPending = true;
    _bindPlaylist(null, [], queueTitle: queueTitle);
  }

  Future<void> shuffleMusicDownloads(List<DownloadedVideo> files,
      {required bool Function() isCurrent}) async {
    final requested = List.of(files);
    List<DownloadedVideo>? resolveFiles() =>
        _resolveCompletedMusicDownloads(requested, isCurrent: isCurrent);
    final ready = resolveFiles();
    if (ready == null) return;
    await _playVideos(ready,
        audio: true,
        fromMusic: true,
        shuffleOnce: true,
        canCommit: () => resolveFiles() != null,
        bindQueue: _bindOfflineQueue);
  }

  List<DownloadedVideo>? _resolveCompletedMusicDownloads(
      List<DownloadedVideo> files,
      {bool Function()? isCurrent,
      bool allowRepeats = false}) {
    if (files.isEmpty ||
        isClosed ||
        _isDisposing ||
        _switchingProfile ||
        state.isClosing ||
        _profileDatabase.profileId != db.profileId ||
        isCurrent?.call() == false) {
      return null;
    }
    final ids = <String>{};
    final result = <DownloadedVideo>[];
    for (final file in files) {
      final saved = readyMusicDownload(_profileDatabase, file.videoId);
      if (saved == null ||
          (!allowRepeats && !ids.add(file.videoId)) ||
          !_sameSavedMusicFile(file, saved)) {
        return null;
      }
      result.add(saved);
    }
    return result;
  }

  bool get canAddMusicDownloadsToQueue {
    if (isClosed ||
        _isDisposing ||
        _switchingProfile ||
        _sessionTransitionPending ||
        _backendSwitchPending ||
        _preparingSelectedSong ||
        state.isClosing ||
        activePodcast != null ||
        _profileDatabase.profileId != db.profileId) {
      return false;
    }
    if (state.isHidden || !state.hasVideo) {
      return state.mediaEvent.state != MediaState.loading;
    }
    final current = state.currentlyPlaying ?? state.offlineCurrentlyPlaying;
    return state.isAudio &&
        _isMusicEntry(current) &&
        [...state.videos, ...state.offlineVideos]
            .any((entry) => playbackQueueId(entry) == state.currentQueueId);
  }

  Future<bool> addMusicDownloadsToQueue(List<DownloadedVideo> files,
      {required bool Function() isCurrent}) async {
    if (!canAddMusicDownloadsToQueue) return false;
    final ready = _resolveCompletedMusicDownloads(files, isCurrent: isCurrent);
    if (ready == null) return false;
    final idle = state.isHidden || !state.hasVideo;
    if (!idle && state.videos.isNotEmpty) {
      _enqueueMusicDownloadVideos(ready, next: false);
      return true;
    }
    final pinned = [
      for (final file in ready)
        file.copyWith(explicitMusicDownload: musicDownloadFingerprint(file)),
    ];
    if (idle) {
      await _playVideos(pinned,
          audio: true,
          fromMusic: true,
          retainQueueOrder: true,
          bindQueue: _bindOfflineQueue);
    } else {
      _insertOfflineMusicEntries(pinned, next: false);
    }
    return true;
  }

  void _enqueueMusicDownloadVideos(List<DownloadedVideo> files,
      {required bool next, PlaylistReference? recommendationSource}) {
    enqueueQueueCopies([
      for (final file in files)
        Video(
          videoId: file.videoId,
          queueEntryId: '${file.videoId}#1',
          title: file.musicMetadata!.title,
          author: file.musicMetadata!.artist,
          lengthSeconds: file.lengthSeconds,
          musicMetadata: file.musicMetadata,
          explicitMusicDownload: musicDownloadFingerprint(file),
        ),
    ], next: next, recommendationSource: recommendationSource);
  }

  /// Play the visible library order from the requested row. Both source types
  /// share the offline queue, but retain separate playback identities.
  Future<void> playOnDeviceMusic(List<OnDeviceMusicEntry> tracks,
      {int startIndex = 0,
      String? queueTitle,
      bool songTap = false,
      bool Function()? isCurrent}) async {
    if (startIndex < 0 || startIndex >= tracks.length) return;
    final requested = List.of(tracks);
    final library = LocalMusicLibrary.instance;
    final selection = library.selectionId;
    List<DownloadedVideo>? resolve() =>
        _resolveOnDeviceMusic(requested, selection, isCurrent: isCurrent);
    final files = resolve();
    if (files == null) {
      if (isCurrent?.call() != false) _reportUnavailableLocalMusic();
      return;
    }
    final usesDevice =
        files.any((entry) => isLocalMusicPlaybackId(entry.videoId));
    await _playVideos(_assignDeviceQueueOccurrences(files),
        startIndex: startIndex,
        audio: true,
        fromMusic: true,
        songTap: songTap,
        canCommit: () => resolve() != null,
        bindQueue: () => _bindOfflineQueue(
            queueTitle: queueTitle,
            deviceSelectionId: usesDevice ? selection : null));
  }

  List<DownloadedVideo>? _resolveOnDeviceMusic(
      List<OnDeviceMusicEntry> tracks, String? selectionId,
      {bool Function()? isCurrent}) {
    if (tracks.isEmpty ||
        isClosed ||
        _isDisposing ||
        _switchingProfile ||
        state.isClosing ||
        _profileDatabase.profileId != db.profileId ||
        isCurrent?.call() == false) {
      return null;
    }
    final library = LocalMusicLibrary.instance;
    final resolved = <DownloadedVideo>[];
    for (final entry in tracks) {
      if (entry.deviceTrack case final device?) {
        if (!library.acceptsSessionSelection(selectionId)) return null;
        final track = library.visibleTrackById(device.playbackId);
        if (track == null) return null;
        resolved
            .add(localMusicPlaybackEntry(track, _profileDatabase.profileId));
      } else {
        final download = entry.download!;
        final fingerprint =
            musicDownloadFileFingerprint(download, entry.downloadFileProof!);
        if (fingerprint == null) return null;
        final saved = readyMusicDownload(_profileDatabase, download.videoId,
            fingerprint: fingerprint);
        if (saved == null) return null;
        resolved.add(saved.copyWith(explicitMusicDownload: fingerprint));
      }
    }
    return resolved;
  }

  List<DownloadedVideo> _assignDeviceQueueOccurrences(
      List<DownloadedVideo> files,
      {Iterable<String> reserved = const []}) {
    final used = reserved.toSet();
    return files.map((entry) {
      final source = entry.videoId;
      if (!isLocalMusicPlaybackId(source) || used.add(source)) return entry;
      final id = _newLocalOccurrence(source, used.contains);
      used.add(id);
      return entry.copyWith(videoId: id);
    }).toList();
  }

  bool _canEnqueueOnDeviceMusic(List<OnDeviceMusicEntry> tracks) {
    if (activePodcast != null || _sessionTransitionPending) return false;
    if (state.isHidden || !state.hasVideo) {
      return state.mediaEvent.state != MediaState.loading;
    }
    return _canEnqueueMusicSelection(tracks) &&
        state.isAudio &&
        _isMusicEntry(state.offlineCurrentlyPlaying) &&
        state.offlineVideos
            .any((entry) => playbackQueueId(entry) == state.currentQueueId) &&
        (!state.offlineVideos
                .any((entry) => isLocalMusicPlaybackId(entry.videoId)) ||
            LocalMusicLibrary.instance
                .acceptsSessionSelection(_queuedDeviceSelectionId));
  }

  bool canEnqueueOnDeviceMusic(List<OnDeviceMusicEntry> tracks) =>
      _canEnqueueOnDeviceMusic(tracks) &&
      _resolveOnDeviceMusic(tracks, LocalMusicLibrary.instance.selectionId) !=
          null;

  Future<bool> enqueueOnDeviceMusic(List<OnDeviceMusicEntry> tracks,
      {required bool next, bool Function()? isCurrent}) async {
    if (!_canEnqueueOnDeviceMusic(tracks)) return false;
    final selection = LocalMusicLibrary.instance.selectionId;
    final files =
        _resolveOnDeviceMusic(tracks, selection, isCurrent: isCurrent);
    if (files == null) return false;
    if (state.isHidden || !state.hasVideo) {
      await playOnDeviceMusic(tracks, isCurrent: isCurrent);
    } else {
      if (files.any((entry) => isLocalMusicPlaybackId(entry.videoId))) {
        _queuedDeviceSelectionId = selection;
      }
      _insertOfflineMusicEntries(
          _assignDeviceQueueOccurrences(files,
              reserved: state.offlineVideos.map(playbackQueueId)),
          next: next);
      await _saveSession(state);
    }
    return true;
  }

  void _reportUnavailableLocalMusic() {
    if (isClosed ||
        _isDisposing ||
        _switchingProfile ||
        state.isClosing ||
        _profileDatabase.profileId != db.profileId) {
      return;
    }
    _cancelMusicSelection();
    if (_canPrepareMusicSelection) {
      musicSelectionFailureRevision.value++;
    } else {
      setEvent(const MediaEvent(state: MediaState.error));
    }
  }

  Future<void> playLocalMusic(List<LocalMusicTrack> tracks,
      {int startIndex = 0, String? queueTitle, bool songTap = false}) async {
    if (isClosed ||
        _isDisposing ||
        _switchingProfile ||
        _profileDatabase.profileId != db.profileId) return;
    final entries = <DownloadedVideo>[];
    for (final requested in tracks) {
      final track = localMusicTrackForPlayback(requested.playbackId);
      if (track == null) {
        _reportUnavailableLocalMusic();
        return;
      }
      entries.add(localMusicPlaybackEntry(track, _profileDatabase.profileId));
    }
    if (startIndex < 0 || startIndex >= entries.length) {
      _reportUnavailableLocalMusic();
      return;
    }
    await _playVideos(_assignDeviceQueueOccurrences(entries),
        startIndex: startIndex,
        audio: true,
        songTap: songTap,
        bindQueue: () => _bindOfflineQueue(
            queueTitle: queueTitle,
            deviceSelectionId: LocalMusicLibrary.instance.selectionId));
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
      state.offlineVideos.any((entry) => isLocalMusicPlaybackId(entry.videoId));

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
    if (isLocalMusicSession) {
      await enqueueLocalMusicCopies([requested], next: playNext);
      return;
    }
    if (isClosed ||
        _isDisposing ||
        _switchingProfile ||
        state.isClosing ||
        _profileDatabase.profileId != db.profileId ||
        isOtherPlaybackSession) {
      return;
    }
    final track = localMusicTrackForPlayback(requested.playbackId);
    if (track != null) await playLocalMusic([track]);
  }

  /// Adds occurrences to the current device queue in the caller's display order.
  Future<bool> enqueueLocalMusicCopies(List<LocalMusicTrack> tracks,
      {required bool next}) async {
    if (!_canEnqueueMusicSelection(tracks) ||
        activePodcast != null ||
        !isLocalMusicSession ||
        !LocalMusicLibrary.instance
            .acceptsSessionSelection(_queuedDeviceSelectionId)) {
      return false;
    }
    final entries = state.offlineVideos;
    final profileId = _profileDatabase.profileId;
    final index = entries.indexWhere((entry) =>
        playbackQueueId(entry) == state.currentQueueId &&
        entry.profileId == profileId);
    if (index < 0) return false;
    final resolved = <LocalMusicTrack>[];
    for (final requested in tracks) {
      final track = localMusicTrackForPlayback(requested.playbackId);
      if (track == null) return false;
      resolved.add(track);
    }
    final used = entries.map(playbackQueueId).toSet();
    final additions = <DownloadedVideo>[];
    for (final track in resolved) {
      final id = _newLocalOccurrence(track.playbackId, used.contains);
      used.add(id);
      additions
          .add(localMusicPlaybackEntry(track, profileId, occurrenceId: id));
    }
    final ids = additions.map(playbackQueueId);
    final updated = List<DownloadedVideo>.of(entries)
      ..insertAll(next ? index + 1 : entries.length, additions);
    _musicShuffleAnchors.addAll(ids);
    emit(state.copyWith(
        offlineVideos: updated,
        playQueue: ListQueue.of(next
            ? [...ids, ...state.playQueue]
            : [...state.playQueue, ...ids])));
    await _saveSession(state);
    return true;
  }

  /// Paired immediately with playVideo by an explicit watch command. A
  /// preview, restore or automatic advance supplies no marker.
  void noteWatchSelection(String videoId) {
    _selectedWatchVideoId = videoId;
  }

  Future<void> playCachedMusicSongs(List<CachedMusicSong> songs,
      {required int startIndex,
      required Server server,
      required String queueTitle,
      required bool Function() isCurrent}) async {
    final owner = cachedMusicOwner(server);
    if (owner == null || startIndex < 0 || startIndex >= songs.length) return;
    bool active() =>
        !isClosed &&
        !_isDisposing &&
        !_switchingProfile &&
        !state.isClosing &&
        _profileDatabase.profileId == server.profileId &&
        db.profileId == server.profileId &&
        isCurrent();
    if (!active()) return;
    final selected = await db.getCurrentlySelectedServer();
    if (!active() || cachedMusicOwner(selected) != owner) return;
    await _playVideos(
      songs.map((song) => song.playbackEntry(owner)).toList(),
      startIndex: startIndex,
      fromMusic: true,
      audio: true,
      retainQueueOrder: true,
      canCommit: active,
      bindQueue: () => _bindOfflineQueue(queueTitle: queueTitle),
    );
  }

  Future<void> playVideo(List<Video> v,
          {bool? audio,
          Duration? startAt,
          bool? playing,
          int? startIndex,
          String? queueTitle,
          PlaylistReference? recommendationSource,
          bool fromMusic = false,
          bool songTap = false}) =>
      _playVideoSelection(v,
          audio: audio,
          startAt: startAt,
          playing: playing,
          startIndex: startIndex,
          queueTitle: queueTitle,
          recommendationSource: recommendationSource,
          fromMusic: fromMusic,
          songTap: songTap);

  Future<void> playAndroidAutoMusic(List<Video> entries, int index,
          String? title, bool Function() current) =>
      _playVideoSelection(entries,
          audio: true,
          startIndex: index,
          queueTitle: title,
          fromMusic: true,
          isCurrent: current);

  Future<void> _playVideoSelection(List<Video> v,
      {bool? audio,
      Duration? startAt,
      bool? playing,
      int? startIndex,
      String? queueTitle,
      required bool fromMusic,
      PlaylistReference? recommendationSource,
      bool songTap = false,
      bool Function()? isCurrent}) async {
    if (isCurrent?.call() == false) return;
    final selected = _selectedWatchVideoId;
    _selectedWatchVideoId = null;
    if (isClosed || _switchingProfile || v.isEmpty) return;
    final library = LocalMusicLibrary.instance;
    final selection = library.selectionId;
    bool playable(Video entry) =>
        !entry.filtered &&
        (!isLocalMusicPlaybackId(entry.videoId) ||
            (fromMusic &&
                audio != false &&
                library.playlistTrackById(entry.videoId) != null));
    if (startIndex != null) {
      RangeError.checkValidIndex(startIndex, v, 'startIndex');
      if (!playable(v[startIndex])) return;
    }
    final videos = v.where(playable).toList();
    if (videos.isEmpty) return;
    final index =
        startIndex == null ? 0 : v.take(startIndex).where(playable).length;
    final deviceEntries =
        videos.where((v) => isLocalMusicPlaybackId(v.videoId));
    // TODO: find how to do this with auto router
    log.fine('Playing ${videos.length} videos');

    await _playVideos(videos,
        fromMusic: fromMusic,
        songTap: songTap,
        recommendationSource: recommendationSource,
        startAt: startAt,
        startIndex: index,
        canCommit: () =>
            isCurrent?.call() != false &&
            (deviceEntries.isEmpty ||
                (library.acceptsSessionSelection(selection) &&
                    deviceEntries.every(playable))),
        selectedByUser: selected == videos[index].videoId,
        audio: audio ?? (videos[index].musicMetadata != null),
        bindQueue: () {
          _sessionTransitionPending = true;
          _queuedDeviceSelectionId = deviceEntries.isEmpty ? null : selection;
          _bindPlaylist(null, [], queueTitle: fromMusic ? queueTitle : null);
          _requestedPlaying = playing;
        });
  }

  /// Starts a queue with no single collection's playback reference.
  /// Each optional [recommendationSources] item identifies the playlist of the
  /// input row at the same index, including separate copies of a song.
  Future<void> playMusicCollectionQueue(List<Video> tracks,
      {required String queueTitle,
      bool shuffle = false,
      bool Function()? isCurrent,
      List<PlaylistReference?>? recommendationSources}) async {
    bool current() =>
        !isClosed &&
        !_isDisposing &&
        !_switchingProfile &&
        _profileDatabase.profileId == db.profileId &&
        isCurrent?.call() != false;
    if (!current() ||
        recommendationSources != null &&
            recommendationSources.length != tracks.length) {
      return;
    }
    final library = LocalMusicLibrary.instance;
    final selection = library.selectionId;
    bool authorized(Video video) =>
        !isLocalMusicPlaybackId(video.videoId) ||
        library.playlistTrackById(video.videoId) != null;
    final playableRows = [
      for (final (index, video) in tracks.indexed)
        if (!video.filtered &&
            !video.filterHide &&
            video.isUpcoming != true &&
            authorized(video))
          (video, recommendationSources?[index]),
    ];
    final playable = [for (final (video, _) in playableRows) video];
    final deviceEntries =
        playable.where((video) => isLocalMusicPlaybackId(video.videoId));
    await _playVideos(playable,
        fromMusic: true,
        startAt: Duration.zero,
        audio: true,
        shuffleOnce: shuffle,
        retainQueueOrder: true,
        recommendationSources: recommendationSources == null
            ? null
            : [for (final (_, source) in playableRows) source],
        canCommit: () =>
            current() &&
            (deviceEntries.isEmpty ||
                (library.acceptsSessionSelection(selection) &&
                    deviceEntries.every(authorized))),
        bindQueue: () {
          _selectedWatchVideoId = null;
          _sessionTransitionPending = true;
          _queuedDeviceSelectionId = deviceEntries.isEmpty ? null : selection;
          _bindPlaylist(null, [], queueTitle: queueTitle);
          _requestedPlaying = null;
        });
  }

  /// Prepare a mix from one explicitly selected catalog recording. A newer
  /// playback intent owns the queue if it arrives during catalog lookup.
  /// Returns null for a superseded request and false for an unavailable mix.
  Future<bool?> playMusicMix(Video seed,
      {required String queueTitle,
      required Future<List<MusicTrack>> Function(bool Function() isCurrent)
          loadCandidates,
      required bool Function() isCurrent}) async {
    if (isClosed ||
        _isDisposing ||
        _switchingProfile ||
        seed.musicMetadata == null ||
        seed.filtered ||
        seed.filterHide ||
        seed.downloadPlaybackOnly ||
        seed.explicitMusicDownload != null ||
        isLocalMusicPlaybackId(seed.videoId) ||
        !isCurrent()) {
      return false;
    }
    final request = Object();
    _musicMixRequest = request;
    final selection = _musicSelectionRequestRevision;
    final occurrence = playbackOccurrenceRevision;
    final queue = playlistGeneration;
    final profile = _profileDatabase.profileId;
    final recommendations = RecommendationService.forProfile(db, profile);
    final generation = recommendations.generation(RecommendationDomain.music);
    final proxy = NetworkProxy.instance.config;
    bool current() =>
        identical(_musicMixRequest, request) &&
        !isClosed &&
        !_isDisposing &&
        !_switchingProfile &&
        db.profileId == profile &&
        !NetworkProxy.instance.isChanging &&
        identical(NetworkProxy.instance.config, proxy) &&
        recommendations.generation(RecommendationDomain.music) == generation &&
        playbackOccurrenceRevision == occurrence &&
        playlistGeneration == queue &&
        isCurrent();
    bool loading() => current() && selection == _musicSelectionRequestRevision;

    try {
      List<MusicTrack> candidates;
      try {
        candidates = await loadCandidates(loading);
      } catch (_) {
        if (!loading()) return null;
        rethrow;
      }
      if (!loading()) return null;
      final mix = MusicMix(
          seed, candidates.where((track) => track.videoId != seed.videoId));
      final initial = recommendations
          .eligibleMusic(mix.candidates)
          .take(MusicMix.upcomingLimit)
          .toList();
      if (initial.isEmpty) return false;
      var started = false;
      await _playVideos([
        seed.copyWith(queueEntryId: null),
        ...initial.map((track) => track.toVideo()),
      ],
          audio: true,
          fromMusic: true,
          selectedByUser: true,
          retainQueueOrder: true,
          canCommit: () =>
              current() &&
              recommendations.eligibleMusic(initial).length == initial.length,
          bindQueue: () {
            _sessionTransitionPending = true;
            _bindPlaylist(null, [], queueTitle: queueTitle);
            _musicMix = mix;
            _musicMixGenerated.addAll(initial.map((track) => track.videoId));
            _requestedPlaying = true;
            started = true;
          });
      if (started) return true;
      return current() ? false : null;
    } finally {
      if (identical(_musicMixRequest, request)) _musicMixRequest = null;
    }
  }

  /// Start the selected occurrence and its surrounding queue as one operation.
  /// The index refers to the supplied playlist before filtered entries are
  /// removed, so filtering cannot silently select a different video.
  /// A one-shot shuffle starts at the first shuffled occurrence and retains
  /// source order for playlist progress.
  Future<void> playPlaylist(List<Video> entries,
      {required PlaylistReference reference,
      bool fromMusic = false,
      bool songTap = false,
      int startIndex = 0,
      Duration? startAt,
      bool? audio,
      bool? playing,
      bool shuffleOnce = false,
      PlaylistLoadSession? playlistLoader}) async {
    if (isClosed || _switchingProfile) return;
    if (reference.profileId != _profileDatabase.profileId) {
      throw StateError('This playlist belongs to another profile.');
    }
    final assigned = assignPlaylistEntryIds(entries);
    bool visible(Video video) =>
        !video.filtered && !video.filterHide && video.isUpcoming != true;
    if (!shuffleOnce) {
      RangeError.checkValidIndex(startIndex, entries, 'startIndex');
    }
    final selected = shuffleOnce
        ? assigned.where(visible).firstOrNull
        : assigned[startIndex];
    if (selected == null) return;
    final audioMode = audio ?? (selected.musicMetadata != null);
    final library = LocalMusicLibrary.instance;
    final selection = library.selectionId;
    bool playable(Video video) =>
        visible(video) &&
        (!isLocalMusicPlaybackId(video.videoId) ||
            (audioMode &&
                reference.kind == PlaylistSourceKind.local &&
                library.playlistTrackById(video.videoId) != null));
    final videos = assigned.where(playable).toList();
    final index = shuffleOnce
        ? 0
        : videos.indexWhere(
            (video) => playbackQueueId(video) == playbackQueueId(selected));
    if (index < 0) {
      throw StateError('This playlist entry is not available for playback.');
    }
    if (videos.isEmpty) return;
    final deviceEntries =
        videos.where((video) => isLocalMusicPlaybackId(video.videoId));
    final loader = _playsOnlyTappedSong(songTap) ? null : playlistLoader;
    loader?.retain();
    try {
      await _playVideos(videos,
          fromMusic: fromMusic,
          songTap: songTap,
          recommendationSource: reference,
          startAt: startAt,
          startIndex: index,
          shuffleOnce: shuffleOnce,
          canCommit: () =>
              deviceEntries.isEmpty ||
              (library.acceptsSessionSelection(selection) &&
                  deviceEntries.every(playable)),
          audio: audioMode,
          bindQueue: () {
            _sessionTransitionPending = true;
            _requestedPlaying = playing;
            _queuedDeviceSelectionId = deviceEntries.isEmpty ? null : selection;
            _bindPlaylist(
                reference,
                audioMode
                    ? assigned
                    : assigned
                        .where((v) => !isLocalMusicPlaybackId(v.videoId))
                        .toList(),
                loader: loader);
          });
      if (loader != null && identical(_loader, loader)) {
        appendPlaylistVideos(loader.playlist.videos,
            reference: reference, generation: _playlistGeneration);
      }
    } finally {
      loader?.release();
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

  @visibleForTesting
  void handleMediaVolumeChange(double volume) {
    final previous = _lastMediaVolume;
    _lastMediaVolume = volume;
    if (volume != 0 ||
        previous == null ||
        previous <= 0 ||
        isClosed ||
        _isDisposing ||
        _switchingProfile ||
        db.profileId != _profileDatabase.profileId ||
        state.isHidden ||
        state.isClosing ||
        activePodcast != null ||
        !isMusicAudio ||
        !intendsPlayback ||
        !settings.state.musicPauseAtZeroVolume) {
      return;
    }
    pause();
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
      final continuing = !permanent && _interruptionOwnsTransportIntent;
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
        if (!permanent && _hasPendingMusicHandoff) {
          // A completed decoder will not send EOF again on focus gain. Keep
          // its queue handoff while reporting the interruption to Android.
          mapMediaEventToMediaHandler(
              const MediaEvent(state: MediaState.completed));
        } else {
          _clearMusicHandoff(endAudioWait: true);
        }
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
      if (event.type == AudioInterruptionType.pause &&
          _resumePlaybackAfterInterruption &&
          isMusicAudio &&
          !settings.state.musicResumeAfterAudioFocusLoss) {
        pause();
        return;
      }
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
    if (_hasPendingMusicHandoff) {
      if (event.type == AudioInterruptionType.unknown) {
        _clearMusicHandoff(endAudioWait: true);
        return;
      }
      // A playlist may still be saving the completed occurrence. Only resume
      // traversal here if its original advance has already reached a wait.
      if (_musicAdvanceDeferredForFocus ||
          _songGap != null ||
          _waitingForPlaylist) {
        _advanceAfterSongEnd();
      }
      if (_musicHandoff != null) {
        mapMediaEventToMediaHandler(
            const MediaEvent(state: MediaState.completed));
      }
      return;
    }
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
    if (_inMusicQueue) _musicShuffleAnchors.add(movedId);

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

    _musicMixGenerated.removeAll([movedId, if (beforeId != null) beforeId]);
    emit(state.copyWith(
        videos: applyOrder(state.videos),
        offlineVideos: applyOrder(state.offlineVideos),
        playQueue: ListQueue.of(order)));
  }

  List<IdedVideo> _musicQueueTimeline([PlayerState? snapshot]) {
    final queue = snapshot ?? state;
    return playbackQueueTraversal<IdedVideo>(
      queue.videos.isNotEmpty ? queue.videos : queue.offlineVideos,
      played: queue.playedVideos,
      current: queue.currentQueueId,
      upcoming: queue.playQueue,
    );
  }

  bool get _canEditMusicUpcoming =>
      !isClosed &&
      !_isDisposing &&
      !_switchingProfile &&
      !_sessionTransitionPending &&
      !_backendSwitchPending &&
      !_preparingSelectedSong &&
      !_hasPendingMusicHandoff &&
      hasOpeningMusicCrossfade?.call() != true &&
      !state.isClosing &&
      !state.isHidden &&
      state.isAudio &&
      state.currentQueueId != null &&
      _profileDatabase.profileId == db.profileId &&
      !settings.state.musicQueueLocked;

  bool get canSortMusicQueueUpcoming =>
      _canEditMusicUpcoming && state.playQueue.length > 1;

  bool get hasActiveMusicMix => _musicMix != null;

  bool get musicMixCanFocusSeedArtist => _musicMix?.hasSeedArtist == true;

  bool get canSteerMusicMix =>
      hasActiveMusicMix &&
      _canEditMusicUpcoming &&
      state.playQueue.any(_musicMixGenerated.contains);

  bool steerMusicMix(MusicMixSteering steering) {
    final mix = _musicMix;
    if (mix == null || !canSteerMusicMix) return false;
    final upcoming = state.playQueue;
    final played = {...state.playedVideos, state.currentQueueId};
    final slots = upcoming
        .where((id) => _musicMixGenerated.contains(id) && !played.contains(id))
        .toList();
    if (slots.isEmpty) return false;
    final replaceableIds = slots.toSet();
    final excluded = {
      ..._musicMixRemoved,
      for (final entry in state.videos)
        if (!replaceableIds.contains(playbackQueueId(entry))) entry.videoId,
    };
    final recommendations =
        RecommendationService.forProfile(db, _profileDatabase.profileId);
    final candidates = recommendations.eligibleMusic(
        mix.candidates.where((track) => !excluded.contains(track.videoId)));
    final ordered = mix.order(candidates, steering).take(slots.length).toList();
    if (listEquals(slots, ordered.map((track) => track.videoId).toList())) {
      return false;
    }
    final existing = {
      for (final entry in state.videos) playbackQueueId(entry): entry,
    };
    final replacements = <String, Video?>{
      for (final (index, id) in slots.indexed)
        id: index >= ordered.length
            ? null
            : existing[ordered[index].videoId] ?? ordered[index].toVideo(),
    };
    final regenerated = replacements.values.nonNulls.map(playbackQueueId);
    _musicMixGenerated
      ..removeAll(slots)
      ..addAll(regenerated);
    _musicHistoryEntries
      ..removeAll(slots)
      ..addAll(regenerated);
    emit(state.copyWith(
      videos: [
        for (final entry in state.videos)
          if (!replacements.containsKey(playbackQueueId(entry)))
            entry
          else if (replacements[playbackQueueId(entry)] case final video?)
            video,
      ],
      playQueue: ListQueue.of([
        for (final id in upcoming)
          if (!replacements.containsKey(id))
            id
          else if (replacements[id] case final entry?)
            playbackQueueId(entry),
      ]),
    ));
    return true;
  }

  /// Sort only the scheduled occurrences. The source order stays available
  /// for queue regeneration, and later playlist pages retain their append order.
  void sortMusicQueueUpcoming(MusicQueueSort sort) {
    if (!canSortMusicQueueUpcoming) return;
    final entries =
        state.videos.isNotEmpty ? state.videos : state.offlineVideos;
    final byId = {for (final entry in entries) playbackQueueId(entry): entry};
    final upcoming = state.playQueue.toList();
    if (upcoming.contains(state.currentQueueId) ||
        !upcoming.every(byId.containsKey)) {
      return;
    }
    final sorted = sort.sortUpcoming(upcoming.map((id) => byId[id]!));
    if (!listEquals(upcoming, sorted)) {
      _musicMixGenerated.removeAll(upcoming);
      emit(state.copyWith(playQueue: ListQueue.of(sorted)));
    }
  }

  bool get canShuffleMusicQueueUpcoming =>
      _inMusicQueue && canSortMusicQueueUpcoming;

  /// Shuffle the scheduled Music traversal around explicit queue edits.
  /// The resulting order is saved through the same session path as a drag.
  void shuffleMusicQueueUpcoming(MusicQueueShuffle shuffle) {
    if (!canShuffleMusicQueueUpcoming) return;
    final source = state.videos.isNotEmpty ? state.videos : state.offlineVideos;
    final byId = {
      for (final (index, entry) in source.indexed)
        playbackQueueId(entry): (index: index, entry: entry),
    };
    final upcoming = state.playQueue.toList();
    final active = state.currentQueueId;
    if (upcoming.contains(active) || !upcoming.every(byId.containsKey)) return;

    final library = LocalMusicLibrary.instance;
    final useDeviceMetadata =
        library.acceptsSessionSelection(_queuedDeviceSelectionId);
    final order = <String>[];
    final pending = <String>[];
    var previous = byId[active]?.entry;
    void shufflePending({IdedVideo? following}) {
      if (pending.isEmpty) return;
      final entries = pending.map((id) => byId[id]!).toList()
        ..sort((first, second) => first.index.compareTo(second.index));
      order.addAll(shuffle.shuffleUpcoming(
        entries: entries.map((item) => item.entry),
        previous: previous,
        following: following,
        deviceTrackForId: (id) =>
            useDeviceMetadata ? localMusicTrackForPlayback(id) : null,
      ));
      pending.clear();
    }

    for (final id in upcoming) {
      if (_musicShuffleAnchors.contains(id)) {
        final anchor = byId[id]!.entry;
        shufflePending(following: anchor);
        order.add(id);
        previous = anchor;
      } else {
        pending.add(id);
      }
    }
    shufflePending();
    if (!listEquals(upcoming, order)) {
      emit(state.copyWith(playQueue: ListQueue.of(order)));
    }
  }

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
    _musicShuffleAnchors.add(movedId);
    _musicMixGenerated.removeAll([movedId, if (beforeId != null) beforeId]);
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

  ({String recordingId, String occurrenceId, Duration position})?
      captureMusicPassage() {
    final entry = state.currentlyPlaying ?? state.offlineCurrentlyPlaying;
    final position = Duration(milliseconds: state.position.inMilliseconds);
    if (entry == null ||
        !_canUseMusicPassages ||
        !_canSeekMusicPassage(entry, position)) {
      return null;
    }
    return (
      recordingId: musicPassageRecordingId(entry),
      occurrenceId: _musicPassageOccurrence(entry),
      position: position,
    );
  }

  bool get _canUseMusicPassages =>
      !isClosed &&
      !_switchingProfile &&
      !_sessionTransitionPending &&
      !_preparingSelectedSong &&
      _profileDatabase.profileId == db.profileId &&
      state.isAudio &&
      !state.isHidden &&
      !state.isClosing &&
      switch (state.mediaEvent.state) {
        MediaState.idle || MediaState.loading || MediaState.error => false,
        _ => true,
      };

  Duration _musicPassageDuration(IdedVideo entry) {
    final track = localMusicTrackForPlayback(entry.videoId);
    final clipDuration = localMusicCueDuration(track);
    if (clipDuration != null) return clipDuration;
    if (track != null && track.durationMs > 0) {
      return Duration(milliseconds: track.durationMs);
    }
    return Duration(
      seconds: switch (entry) {
        Video() => entry.lengthSeconds ?? 0,
        DownloadedVideo() => entry.lengthSeconds,
        _ => 0,
      },
    );
  }

  bool _canSeekMusicPassage(IdedVideo entry, Duration position) {
    if (!_isMusicEntry(entry) ||
        entry is Video && (entry.liveNow == true || entry.isUpcoming == true) ||
        isLocalMusicPlaybackId(entry.videoId) &&
            localMusicTrackForPlayback(entry.videoId) == null ||
        position.isNegative) {
      return false;
    }
    final end = _musicPassageDuration(entry);
    return end > Duration.zero && position <= end;
  }

  String _musicPassageOccurrence(IdedVideo entry, {bool forceScope = false}) {
    final queueId = playbackQueueId(entry);
    final reference = _playlistReference;
    if (reference != null && _playlistEntries.containsKey(queueId)) {
      return musicPassageOccurrenceId(entry, reference.key);
    }
    final recording = isLocalMusicPlaybackId(entry.videoId)
        ? localMusicTrackId(entry.videoId)
        : entry.videoId;
    final queue = state.videos.isNotEmpty ? state.videos : state.offlineVideos;
    final queueSpecific = forceScope ||
        queueId != recording ||
        queue
                .where(
                  (item) =>
                      item.videoId == entry.videoId ||
                      isLocalMusicPlaybackId(item.videoId) &&
                          localMusicTrackId(item.videoId) == recording,
                )
                .take(2)
                .length >
            1;
    return musicPassageOccurrenceId(
      entry,
      queueSpecific ? _passageQueueId : null,
    );
  }

  bool _matchesMusicPassage(
    IdedVideo entry,
    String recordingId,
    String occurrenceId,
  ) =>
      musicPassageRecordingId(entry) == recordingId &&
      (_musicPassageOccurrence(entry) == occurrenceId ||
          _musicPassageOccurrence(entry, forceScope: true) == occurrenceId);

  IdedVideo? _musicPassageEntry(
    String recordingId,
    String occurrenceId,
    Duration position,
  ) {
    if (!_canUseMusicPassages) return null;
    final current = state.currentlyPlaying ?? state.offlineCurrentlyPlaying;
    if (current == null || musicPassageRecordingId(current) != recordingId) {
      return null;
    }
    bool matches(IdedVideo entry) =>
        _matchesMusicPassage(entry, recordingId, occurrenceId) &&
        _canSeekMusicPassage(entry, position);
    if (matches(current)) return current;
    final queue = state.videos.isNotEmpty ? state.videos : state.offlineVideos;
    return queue.where(matches).firstOrNull;
  }

  bool canJumpToMusicPassage({
    required String recordingId,
    required String occurrenceId,
    required Duration position,
  }) =>
      _musicPassageEntry(recordingId, occurrenceId, position) != null;

  Future<bool> jumpToMusicPassage({
    required String recordingId,
    required String occurrenceId,
    required Duration position,
  }) async {
    final target = _musicPassageEntry(recordingId, occurrenceId, position);
    if (target == null) return false;
    final id = playbackQueueId(target);
    if (id == state.currentQueueId) {
      seek(position);
      return true;
    }
    return _selectQueueOccurrence(
      id,
      startAt: position,
      matches: (entry) =>
          _matchesMusicPassage(entry, recordingId, occurrenceId),
    );
  }

  /// Select a row in the same timeline order displayed by the Music queue.
  Future<void> selectQueueOccurrence(String id) async {
    await _selectQueueOccurrence(id);
  }

  Future<bool> _selectQueueOccurrence(
    String id, {
    Duration? startAt,
    bool Function(IdedVideo)? matches,
  }) async {
    if (isClosed ||
        _switchingProfile ||
        _sessionTransitionPending ||
        state.currentQueueId == null) {
      return false;
    }
    _cancelMusicSelection();
    if (state.currentQueueId == id) return false;
    bool selects(IdedVideo item) =>
        playbackQueueId(item) == id && (matches?.call(item) ?? true);
    var timeline = _musicQueueTimeline();
    var index = timeline.indexWhere(selects);
    if (index < 0) return false;
    final selected = timeline[index];
    if (selected is DownloadedVideo &&
        selected.profileId != _profileDatabase.profileId) {
      return false;
    }
    final request = _musicSelectionRequestRevision;
    _PreparedMusicSelection? prepared;
    if (_isMusicEntry(selected) && _canPrepareMusicSelection) {
      prepared = await _prepareMusicSelection(
        selected,
        startAt ?? Duration.zero,
        exactStartAt: startAt != null,
      );
      if (prepared == null || request != _musicSelectionRequestRevision) {
        return false;
      }
      timeline = _musicQueueTimeline();
      index = timeline.indexWhere(selects);
      if (index < 0 || state.currentQueueId == id) {
        _abandonMusicSelection();
        return false;
      }
    }
    unawaited(_finishLearning(skipped: true));
    _sessionTransitionPending = true;
    emit(
      state.copyWith(
        playedVideos: timeline.take(index).map(playbackQueueId).toList(),
        playQueue: ListQueue.of(timeline.skip(index + 1).map(playbackQueueId)),
      ),
    );
    await _switchToVideo(
      selected,
      startAt: startAt,
      exactStartAt: startAt != null,
      selectedByUser: true,
      preparedMusic: prepared,
      playing: startAt != null
          ? requestedPlaying
          : prepared != null || _keepMusicPausedOnSkip
              ? _requestedPlaying
              : null,
    );
    final actual = state.currentlyPlaying ?? state.offlineCurrentlyPlaying;
    return actual != null &&
        selects(actual) &&
        (startAt == null || state.startAt == startAt) &&
        state.mediaEvent.state != MediaState.error;
  }

  void removeVideoFromQueue(String queueId) {
    var videos = List<Video>.from(state.videos);
    var offlineVideos = List<DownloadedVideo>.from(state.offlineVideos);
    var listToUpdate = videos.isNotEmpty ? videos : offlineVideos;
    if (!listToUpdate.any((video) => playbackQueueId(video) == queueId)) return;
    _rememberMusicMixRemovals({queueId});
    if (listToUpdate.length == 1) {
      hide();
    } else {
      _musicRecommendationSources.remove(queueId);
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
    _musicRecommendationSources
        .removeWhere((id, _) => id != current && occurrenceIds.contains(id));
    _rememberMusicMixRemovals(occurrenceIds.difference({current}));
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

  void _rememberMusicMixRemovals(Set<String> occurrenceIds) {
    if (_musicMix == null) return;
    for (final entry in state.videos) {
      final id = playbackQueueId(entry);
      if (occurrenceIds.contains(id)) {
        _musicMixGenerated.remove(id);
        _musicMixRemoved.add(entry.videoId);
      }
    }
  }

  /// Muzza QueueSelectionMenu adds new occurrences of the selected songs.
  /// Resolve copies against the current queue before exposing them to playback.
  void enqueueQueueCopies(List<Video> selection,
          {required bool next, PlaylistReference? recommendationSource}) =>
      _enqueueQueueCopies(selection,
          next: next, recommendationSource: recommendationSource);

  void _enqueueQueueCopies(List<Video> selection,
      {required bool next,
      PlaylistReference? recommendationSource,
      List<PlaylistReference?>? recommendationSources}) {
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
    // A manual copy cannot reuse the identity of an original playlist entry
    // that was removed from the active queue.
    final currentIds = state.videos.map(playbackQueueId).toSet();
    final reserved = [
      for (final entry in _playlistEntries.entries)
        if (!currentIds.contains(entry.key)) entry.value,
    ];
    final combined =
        assignPlaybackQueueIds([...reserved, ...state.videos, ...selection])
            .skip(reserved.length)
            .toList();
    final copies = combined.skip(originalLength).toList();
    final ids = copies.map(playbackQueueId);
    _musicHistoryEntries.addAll(ids);
    if (_inMusicQueue) _musicShuffleAnchors.addAll(ids);
    _assignMusicRecommendationSource(ids, recommendationSource,
        recommendationSources: recommendationSources);
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

  bool _canEnqueueMusicSelection(List<Object> selection) =>
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

  // The download store rehydrates display metadata on every read. Only the
  // completed file, its owner and its rendition identify a menu's selection.
  bool _sameSavedMusicFile(DownloadedVideo requested, DownloadedVideo saved) =>
      requested.downloadComplete &&
      !requested.downloadFailed &&
      !requested.storageFailed &&
      !requested.authenticationRequired &&
      requested.videoId == saved.videoId &&
      requested.profileId == saved.profileId &&
      requested.accountId == saved.accountId &&
      requested.folderUri == saved.folderUri &&
      requested.storageUri == saved.storageUri &&
      requested.audioOnly == saved.audioOnly &&
      requested.musicFormat == saved.musicFormat &&
      requested.container == saved.container &&
      requested.quality == saved.quality &&
      requested.audioTrackId == saved.audioTrackId &&
      requested.playbackProvenance == saved.playbackProvenance;

  DownloadedVideo? _readySavedDownload(String id) {
    if (!DownloadedVideo.isSafeFileId(id)) return null;
    try {
      final saved = _profileDatabase.getDownloadByVideoId(id);
      if (saved != null &&
          saved.videoId == id &&
          saved.downloadComplete &&
          !saved.downloadFailed &&
          !saved.storageFailed &&
          !saved.authenticationRequired &&
          saved.profileId == _profileDatabase.profileId) {
        return saved;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  List<DownloadedVideo>? _offlineMusicSelection(
      List<Video> selection, List<DownloadedVideo>? downloads) {
    if (state.offlineCurrentlyPlaying == null ||
        isLocalMusicPlaybackId(state.offlineCurrentlyPlaying?.videoId) ||
        !state.offlineVideos
            .any((video) => playbackQueueId(video) == state.currentQueueId)) {
      return null;
    }
    if (downloads != null && downloads.length != selection.length) return null;
    final explicit = <String, ListQueue<DownloadedVideo>>{};
    for (final download in downloads ?? const <DownloadedVideo>[]) {
      explicit.putIfAbsent(download.videoId, ListQueue.new).add(download);
    }
    final result = <DownloadedVideo>[];
    for (final song in selection) {
      final saved = _readySavedDownload(song.videoId);
      if (saved == null) return null;
      if (downloads != null) {
        final requested = explicit[song.videoId];
        if (requested == null ||
            requested.isEmpty ||
            !_sameSavedMusicFile(requested.removeFirst(), saved)) {
          return null;
        }
      }
      result.add(saved);
    }
    return result;
  }

  bool get _hasCurrentCatalogQueueEntry =>
      state.currentlyPlaying != null &&
      state.videos
          .any((video) => playbackQueueId(video) == state.currentQueueId);

  List<DownloadedVideo>? _catalogMusicDownloadSelection(
      List<Video> selection, List<DownloadedVideo> downloads) {
    if (!canAddMusicDownloadsToQueue || downloads.length != selection.length) {
      return null;
    }
    for (final (index, file) in downloads.indexed) {
      if (file.videoId != selection[index].videoId) return null;
    }
    return _resolveCompletedMusicDownloads(downloads, allowRepeats: true);
  }

  bool canEnqueueMusicSongs(List<Video> selection,
      {List<DownloadedVideo>? downloads}) {
    if (!_canEnqueueMusicSelection(selection)) return false;
    if (state.videos.isNotEmpty) {
      return _hasCurrentCatalogQueueEntry &&
          (downloads == null ||
              _catalogMusicDownloadSelection(selection, downloads) != null);
    }
    return _offlineMusicSelection(selection, downloads) != null;
  }

  /// Shared by Muzza-style song menus. The local lookup and insertion are
  /// synchronous so no stale queue/profile snapshot can commit after an await.
  Future<bool> enqueueMusicSongs(List<Video> selection,
          {required bool next,
          List<DownloadedVideo>? downloads,
          PlaylistReference? recommendationSource}) =>
      _enqueueMusicSongs(selection,
          next: next,
          downloads: downloads,
          recommendationSource: recommendationSource);

  /// Appends the resolved collection rows in display order. Playlist sources
  /// align with input positions rather than recording IDs.
  Future<bool> enqueueMusicCollectionQueue(List<Video> tracks,
      {List<PlaylistReference?>? recommendationSources}) {
    if (recommendationSources != null &&
        recommendationSources.length != tracks.length) {
      return Future.value(false);
    }
    final library = LocalMusicLibrary.instance;
    if (tracks.any((video) =>
        isLocalMusicPlaybackId(video.videoId) &&
        library.playlistTrackById(video.videoId) == null)) {
      return Future.value(false);
    }
    return _enqueueMusicSongs(tracks,
        next: false, recommendationSources: recommendationSources);
  }

  Future<bool> _enqueueMusicSongs(List<Video> selection,
      {required bool next,
      List<DownloadedVideo>? downloads,
      PlaylistReference? recommendationSource,
      List<PlaylistReference?>? recommendationSources}) {
    if (!_canEnqueueMusicSelection(selection)) return Future.value(false);
    if (state.videos.isNotEmpty) {
      if (!_hasCurrentCatalogQueueEntry) return Future.value(false);
      if (downloads == null) {
        _enqueueQueueCopies(selection,
            next: next,
            recommendationSource: recommendationSource,
            recommendationSources: recommendationSources);
      } else {
        final files = _catalogMusicDownloadSelection(selection, downloads);
        if (files == null) return Future.value(false);
        _enqueueMusicDownloadVideos(files,
            next: next, recommendationSource: recommendationSource);
      }
      return Future.value(true);
    }
    final files = _offlineMusicSelection(selection, downloads);
    if (files == null) return Future.value(false);
    _insertOfflineMusicEntries(files,
        next: next,
        recommendationSource: recommendationSource,
        recommendationSources: recommendationSources);
    return Future.value(true);
  }

  void _insertOfflineMusicEntries(List<DownloadedVideo> files,
      {required bool next,
      PlaylistReference? recommendationSource,
      List<PlaylistReference?>? recommendationSources}) {
    final existing = state.offlineVideos;
    final additions =
        assignDownloadedQueueIds([...existing, ...files]).skip(existing.length);
    final index = state.offlineVideos
        .indexWhere((video) => playbackQueueId(video) == state.currentQueueId);
    final ids = additions.map(playbackQueueId);
    _assignMusicRecommendationSource(ids, recommendationSource,
        recommendationSources: recommendationSources);
    _musicHistoryEntries.addAll(additions
        .where((entry) => !isLocalMusicPlaybackId(entry.videoId))
        .map(playbackQueueId));
    _musicShuffleAnchors.addAll(ids);
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
  }

  List<DownloadedVideo>? _resolveOfflineMusicEntries(
      List<DownloadedVideo> entries) {
    final library = LocalMusicLibrary.instance;
    final result = <DownloadedVideo>[];
    for (final entry in entries) {
      if (entry.profileId != _profileDatabase.profileId) return null;
      if (isLocalMusicPlaybackId(entry.videoId)) {
        final track = localMusicTrackForPlayback(entry.videoId);
        if (!library.acceptsSessionSelection(_queuedDeviceSelectionId) ||
            track == null) {
          return null;
        }
        result.add(localMusicPlaybackEntry(track, entry.profileId,
            occurrenceId: entry.videoId));
      } else {
        final fingerprint = entry.explicitMusicDownload;
        final saved = fingerprint == null
            ? _readySavedDownload(entry.videoId)
            : readyMusicDownload(_profileDatabase, entry.videoId,
                fingerprint: fingerprint);
        if (saved == null || !_sameSavedMusicFile(entry, saved)) return null;
        result.add(fingerprint == null
            ? saved
            : saved.copyWith(explicitMusicDownload: fingerprint));
      }
    }
    return result;
  }

  bool _canUseOfflineMusicEntries(List<DownloadedVideo> entries) =>
      _canEnqueueMusicSelection(entries) &&
      activePodcast == null &&
      state.isAudio &&
      state.offlineVideos
          .any((entry) => playbackQueueId(entry) == state.currentQueueId);

  bool canCopyOfflineMusicEntries(List<DownloadedVideo> entries) =>
      _canUseOfflineMusicEntries(entries) &&
      _resolveOfflineMusicEntries(entries) != null;

  Future<bool> enqueueOfflineMusicCopies(List<DownloadedVideo> entries,
      {required bool next}) async {
    if (!_canUseOfflineMusicEntries(entries)) return false;
    final files = _resolveOfflineMusicEntries(entries);
    if (files == null) return false;
    final existingIds = state.offlineVideos.map(playbackQueueId).toSet();
    final copies = [
      for (final file in files)
        if (isLocalMusicPlaybackId(file.videoId))
          file.copyWith(
              videoId: _newLocalOccurrence(
                  localMusicTrackId(file.videoId), existingIds.contains))
        else
          file,
    ];
    _insertOfflineMusicEntries(copies, next: next);
    return true;
  }

  Future<void> playOfflineMusicSelection(List<DownloadedVideo> entries) async {
    if (!_canUseOfflineMusicEntries(entries)) return;
    final files = _resolveOfflineMusicEntries(entries);
    if (files == null) return;
    final selection = _queuedDeviceSelectionId;
    await _playVideos(files,
        audio: true,
        fromMusic: true,
        retainQueueOrder: true,
        canCommit: () =>
            _queuedDeviceSelectionId == selection &&
            _profileDatabase.profileId == db.profileId &&
            _resolveOfflineMusicEntries(entries) != null,
        bindQueue: () => _bindOfflineQueue(deviceSelectionId: selection));
  }

  void videoDragged(DragUpdateDetails details) {
    if (!_playerDragActive || isClosed || state.isClosing) return;
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

  void videoDraggedEnd(DragEndDetails details, {bool compactMusic = false}) {
    if (!_playerDragActive || isClosed || state.isClosing) return;
    var showMini =
        state.dragDistance.abs() > 200 ? state.isMini : state.dragStartMini;
    if (compactMusic && state.dragStartMini) {
      final velocity = details.primaryVelocity ?? 0;
      showMini =
          !(velocity <= -550 || (velocity < 550 && state.dragDistance <= -88));
    }
    // Settle the position and drag state together. A stale absolute top must
    // never survive after the gesture ends or is interrupted by Android.
    if (showMini) {
      showMiniPlayer();
    } else {
      showBigPlayer();
    }
  }

  void videoDragCancelled() {
    _playerDragActive = false;
    if (isClosed || !state.isDragging || state.isClosing) return;
    if (state.dragStartMini) {
      showMiniPlayer();
    } else {
      showBigPlayer();
    }
  }

  void videoDragStarted(DragStartDetails details) {
    if (isClosed || state.isClosing) return;
    _playerDragActive = true;
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
    _musicMixGenerated.removeAll([
      playbackQueueId(movedItem),
      if (newItemIndex + 1 < listToUpdate.length)
        playbackQueueId(listToUpdate[newItemIndex + 1]),
    ]);
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
      _musicMixGenerated.remove(queueId);
      _musicHistoryEntries.remove(queueId);
      if (_inMusicQueue) _musicShuffleAnchors.add(queueId);
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
    final online = state.currentlyPlaying;
    final videoId = online?.videoId ?? offline?.videoId;
    final types = _enabledSponsorTypes;
    List<SponsorSegment> segments = [];
    if (videoId != null && types.isNotEmpty) {
      if (offline != null) {
        segments = offline.sponsorSegments;
      } else if (online != null && online.explicitMusicDownload != null) {
        segments = _explicitDownload(online)?.sponsorSegments ?? const [];
      } else if (CachedMusicPlayback.of(online) == null) {
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
      final device = isLocalMusicPlaybackId(source.videoId);
      if (device) {
        final track = localMusicTrackForPlayback(source.videoId);
        if (track == null) return null;
        final path = track.artPath;
        if (path != null) artwork = Uri.file(path);
      } else if (source.explicitMusicDownload != null) {
        final local = _explicitDownload(source);
        if (local?.profileId != profile) return null;
        artwork = (await local?.existingSongArtwork)?.uri;
      } else if (music != null && source.downloadPlaybackOnly) {
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
          id: device || e.explicitMusicDownload != null
              ? playbackQueueId(e)
              : e.videoId,
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
          id: playbackQueueId(e),
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
          duration: localMusicCueDuration(track) ??
              (track.durationMs > 0
                  ? Duration(milliseconds: track.durationMs)
                  : Duration(seconds: entry.lengthSeconds)),
          artUri: track.artPath == null ? null : Uri.file(track.artPath!));

  /// The document provider can omit duration tags on an otherwise seekable
  /// audio file. Publish the decoder's duration only for the admitted song.
  void reportMusicContentAdvisory({
    required String queueId,
    required int generation,
    required MusicContentAdvisory? advisory,
  }) {
    if (isClosed ||
        _isDisposing ||
        _sessionTransitionPending ||
        state.isClosing ||
        !state.isAudio ||
        state.currentQueueId != queueId ||
        backendPlaybackGeneration != generation) {
      return;
    }
    _musicContentAdvisory.value = advisory == null
        ? null
        : (queueId: queueId, generation: generation, advisory: advisory);
  }

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

  Duration get duration {
    final entry = state.currentlyPlaying ?? state.offlineCurrentlyPlaying;
    if (entry != null && isLocalMusicPlaybackId(entry.videoId)) {
      return _musicPassageDuration(entry);
    }
    return Duration(
      seconds: state.currentlyPlaying?.lengthSeconds ??
          state.offlineCurrentlyPlaying?.lengthSeconds ??
          1,
    );
  }

  double get progress {
    final length = duration.inMilliseconds;
    return length <= 0
        ? 0
        : (state.position.inMilliseconds / length).clamp(0.0, 1.0);
  }

  void switchAudio(bool value) {
    if (!value && isLocalMusicPlaybackId(state.currentlyPlaying?.videoId)) {
      return;
    }
    if (state.currentlyPlaying != null &&
        (value || CachedMusicPlayback.of(state.currentlyPlaying) == null) &&
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
    emit(state.copyWith(hasTimer: true, sleepTracksRemaining: null));

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
    emit(state.copyWith(hasTimer: true, sleepTracksRemaining: null));
  }

  bool get _hasMountedMusicTrack =>
      state.isAudio &&
      _isMusicEntry(state.currentlyPlaying ?? state.offlineCurrentlyPlaying) &&
      state.currentlyPlaying?.liveNow != true;

  bool get canSleepAfterTracks =>
      !isClosed &&
      !_isDisposing &&
      !_switchingProfile &&
      !state.isClosing &&
      !state.isHidden &&
      state.currentQueueId != null &&
      playbackStatus != MediaState.completed &&
      _hasMountedMusicTrack;

  /// Count each playback that reaches EOF, including repeats of the same
  /// occurrence. Manual navigation leaves the countdown armed.
  void sleepAfterTracks(int tracks) {
    if (tracks <= 0 || !canSleepAfterTracks) return;
    _timers.remove('video-sleep-timer')?.cancel();
    _sleepDeadline = null;
    _sleepAtEndQueueId = null;
    emit(state.copyWith(hasTimer: true, sleepTracksRemaining: tracks));
  }

  bool _countFinishedSleepTrack() {
    final remaining = state.sleepTracksRemaining;
    if (remaining == null ||
        !_hasMountedMusicTrack ||
        playbackStatus == MediaState.completed) {
      return false;
    }
    if (remaining == 1) return true;
    emit(state.copyWith(sleepTracksRemaining: remaining - 1));
    return false;
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
    emit(state.copyWith(hasTimer: false, sleepTracksRemaining: null));
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
      int? sleepTracksRemaining,
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
