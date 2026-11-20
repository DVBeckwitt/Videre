import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as audio;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import '../models/podcast.dart';
import 'podcast_progress_store.dart';
import 'podcast_url.dart';

/// Publisher audio has its own model and transport: it never enters the
/// Invidious metadata, watch-history, or SponsorBlock paths.
class PodcastPlayer extends ChangeNotifier {
  final Future<void> Function() beforeStart;
  final String Function() profileId;
  final bool Function() canPlay;
  final BaseAudioHandler? Function() mediaHandler;
  final audio.AudioPlayer Function() _createAudioPlayer;
  final PodcastProgressStore Function(String)? _progressForProfile;
  final DateTime Function() _clock;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  audio.AudioPlayer? _audio;
  Future<void> _disposal = Future.value();
  Future<void> _checkpointWrite = Future.value();
  PodcastProgressStore? _progressStore;
  DateTime? _lastCheckpoint;
  bool _hasCheckpointPosition = false;
  bool _completed = false;
  int _seekRevision = 0;
  PodcastEpisode? _episode;
  String _feedTitle = '';
  String? _owner;
  String? _localPath;
  int _generation = 0;
  bool _disposed = false;
  bool _loading = false;
  bool _playing = false;
  bool _wantsToPlay = false;
  bool _interrupted = false;
  bool _sourceReady = false;
  String? _error;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  Duration? _pendingSeek;
  double _speed = 1;
  audio.ProcessingState _processing = audio.ProcessingState.idle;

  PodcastPlayer({
    required this.beforeStart,
    required this.profileId,
    required this.canPlay,
    required this.mediaHandler,
    audio.AudioPlayer Function()? createAudioPlayer,
    PodcastProgressStore Function(String)? progressForProfile,
    DateTime Function()? clock,
  })  : _progressForProfile = progressForProfile,
        _clock = clock ?? DateTime.now,
        _createAudioPlayer = createAudioPlayer ??
            (() => audio.AudioPlayer(useProxyForRequestHeaders: false));

  bool get active => _episode != null;
  bool get playing => _playing;
  bool get loading => _loading;
  bool get offline => _localPath != null;
  Duration get position => _position;
  Duration get duration => _duration;
  double get speed => _speed;
  String? get error => _error;
  int get generation => _generation;
  PodcastEpisode? get episode => _episode;
  String get feedTitle => _feedTitle;

  bool _current(int generation) =>
      !_disposed &&
      generation == _generation &&
      _owner == profileId() &&
      canPlay();

  Future<void> playEpisode({
    required PodcastEpisode episode,
    required String feedTitle,
    required String profileId,
    String? localPath,
  }) =>
      _start(episode, feedTitle, profileId, localPath, null);

  Future<void> _start(PodcastEpisode episode, String feedTitle, String owner,
      String? localPath, Duration? startAt) async {
    if (_disposed || owner != profileId() || !canPlay()) return;
    final saving = saveProgress();
    final generation = ++_generation;
    final stopping = _detachAudio();
    _episode = episode;
    _feedTitle = feedTitle;
    _owner = owner;
    _localPath = localPath;
    _position = startAt ?? Duration.zero;
    _duration = Duration(seconds: episode.durationSeconds ?? 0);
    _buffered = Duration.zero;
    _pendingSeek = null;
    _seekRevision++;
    _progressStore = null;
    _hasCheckpointPosition = false;
    _completed = false;
    _lastCheckpoint = null;
    _error = null;
    _loading = true;
    _playing = false;
    _wantsToPlay = true;
    _interrupted = false;
    _sourceReady = false;
    _processing = audio.ProcessingState.loading;
    _publish(metadata: true);
    try {
      // Capture the fixed profile immediately so an explicit seek followed by
      // Stop can save even while takeover or native disposal is still pending.
      final progressStore = _progressStore = _progressForProfile?.call(owner);
      await Future.wait([stopping, saving]);
      if (!_current(generation)) return;
      // Stop the existing decoder before allocating another one. This also
      // invalidates an in-flight video metadata request and its future autoplay.
      await beforeStart();
      if (!_current(generation)) return;
      // The previous controller's Stop must finish before reading this episode:
      // TV route players and the home player can take over the same local item.
      final saved = await progressStore?.read(episode.id);
      if (!_current(generation)) return;
      startAt ??= saved?.completed == true
          ? Duration.zero
          : saved?.position ?? Duration.zero;
      _position = _pendingSeek ?? startAt;
      _publish();
      final uri = localPath == null
          ? PodcastUrlPolicy.validate(Uri.parse(episode.mediaUrl))
          : null;
      if (localPath != null &&
          (!path.isAbsolute(localPath) ||
              !await File(localPath).exists() ||
              await File(localPath).length() <= 0)) {
        throw const FileSystemException('The downloaded episode is missing.');
      }
      if (!_current(generation)) return;
      final session = await AudioSession.instance;
      if (!_current(generation)) return;
      final current = _audio = _createAudioPlayer();
      bool ownsAudio() =>
          _current(generation) && identical(current, _audio) && _error == null;
      _subscriptions.addAll([
        current.playerStateStream.listen((state) {
          if (!ownsAudio()) return;
          _processing = state.processingState;
          _playing = state.playing &&
              _sourceReady &&
              state.processingState != audio.ProcessingState.completed;
          if (state.processingState == audio.ProcessingState.completed) {
            if (_sourceReady && _pendingSeek == null) {
              _wantsToPlay = false;
              _completed = true;
              _position = _duration;
              unawaited(saveProgress());
            }
          } else if (_sourceReady && !state.playing) {
            // Includes headphone removal and native audio-focus pauses.
            unawaited(saveProgress());
          }
          _loading = !_sourceReady ||
              state.processingState == audio.ProcessingState.loading ||
              state.processingState == audio.ProcessingState.buffering;
          _publish();
        }),
        current.errorStream.listen((_) {
          if (ownsAudio()) _fail();
        }),
        current.positionStream.listen((value) {
          if (!ownsAudio() ||
              !_sourceReady ||
              _pendingSeek != null ||
              current.playbackEvent.errorCode != null) {
            return;
          }
          _position = value;
          final now = _clock();
          if (_playing &&
              !_completed &&
              (_lastCheckpoint == null ||
                  now.difference(_lastCheckpoint!) >=
                      const Duration(seconds: 5))) {
            unawaited(saveProgress());
          }
          _publish();
        }),
        current.durationStream.listen((value) {
          if (!ownsAudio() || value == null) return;
          _duration = value;
          _publish(metadata: true);
        }),
        current.bufferedPositionStream.listen((value) {
          if (!ownsAudio()) return;
          _buffered = value;
        }),
        session.becomingNoisyEventStream.listen((_) {
          if (ownsAudio()) unawaited(pause());
        }),
        session.interruptionEventStream.listen((event) {
          if (ownsAudio()) handleAudioInterruption(event);
        }),
      ]);
      await current.setAudioSource(
          localPath == null
              ? audio.PodcastAudioSource(uri!)
              : audio.AudioSource.file(localPath),
          initialPosition: _pendingSeek ?? startAt);
      if (!ownsAudio()) return;
      // RSS duration can be stale. Only the loaded decoder may shorten a saved
      // offset; an offset already past its actual EOF starts over safely.
      final actualDuration = current.duration;
      if (_pendingSeek == null &&
          actualDuration != null &&
          actualDuration > Duration.zero &&
          startAt >= actualDuration) {
        await current.seek(Duration.zero);
        if (!ownsAudio()) return;
      }
      while (true) {
        final requestedSpeed = _speed;
        await current.setSpeed(requestedSpeed);
        if (!ownsAudio()) return;
        while (_pendingSeek != null) {
          final target = _boundedPosition(_pendingSeek!, current.duration);
          _pendingSeek = null;
          await current.seek(target);
          if (!ownsAudio()) return;
        }
        // Controls remain available during setup. A speed change can arrive
        // while either native operation is pending and must reach the decoder.
        if (_speed == requestedSpeed) break;
      }
      _sourceReady = true;
      _hasCheckpointPosition = true;
      _completed = false;
      _loading = false;
      _position = current.position;
      unawaited(saveProgress());
      _publish();
      if (_wantsToPlay && !_interrupted) {
        unawaited(_play(current, generation));
      }
    } catch (_) {
      if (_current(generation)) _fail();
    }
  }

  @visibleForTesting
  void handleAudioInterruption(AudioInterruptionEvent event) {
    if (!active || !_current(_generation)) return;
    final endingDuck = !event.begin && event.type == AudioInterruptionType.duck;
    if (event.type == AudioInterruptionType.duck &&
        (!endingDuck || !_interrupted)) {
      return;
    }
    if (event.begin) {
      _interrupted = event.type == AudioInterruptionType.pause;
      if (event.type == AudioInterruptionType.unknown) _wantsToPlay = false;
      return;
    }
    final shouldResume = _interrupted && _wantsToPlay && _sourceReady;
    _interrupted = false;
    // just_audio owns ordinary audio focus. A source loaded while interrupted
    // needs its deferred Play released, including pause followed by duck/gain.
    if (shouldResume) unawaited(resume());
  }

  void _fail() {
    unawaited(saveProgress(useNativePosition: false));
    _error = offline
        ? 'Could not play the downloaded episode. Download it again.'
        : 'Could not play this episode. Check the connection and try again.';
    _loading = false;
    _playing = false;
    _wantsToPlay = false;
    _processing = audio.ProcessingState.ready;
    unawaited(_audio?.pause().catchError((Object _) {}) ?? Future.value());
    _publish();
  }

  Future<void> _play(audio.AudioPlayer current, int generation) async {
    try {
      await current.play();
    } catch (_) {
      if (_current(generation) && identical(current, _audio)) _fail();
    }
  }

  Future<void> resume() async {
    if (!active || !_current(_generation)) return;
    if (_error != null) {
      await _start(_episode!, _feedTitle, _owner!, _localPath, _position);
      return;
    }
    _wantsToPlay = true;
    if (!_sourceReady || _interrupted) return;
    final generation = _generation;
    final current = _audio;
    if (_processing == audio.ProcessingState.completed) {
      await seek(Duration.zero);
    }
    // Replay seeks can outlive a later Pause, interruption, or replacement.
    if (current == null ||
        !_current(generation) ||
        !identical(current, _audio) ||
        !_wantsToPlay ||
        !_sourceReady ||
        _interrupted ||
        _error != null) {
      return;
    }
    unawaited(_play(current, generation));
  }

  Future<void> pause() async {
    final saving = saveProgress();
    _wantsToPlay = false;
    _playing = false;
    final generation = _generation;
    try {
      await _audio?.pause();
    } catch (_) {
      if (_current(generation)) _fail();
    }
    if (_current(generation)) {
      _publish();
      await saveProgress();
    } else {
      await saving;
    }
  }

  Future<void> seek(Duration target) async {
    if (!active || !_current(_generation)) return;
    final bounded = _boundedPosition(target, _duration);
    _position = bounded;
    _pendingSeek = bounded;
    _completed = false;
    _hasCheckpointPosition = true;
    final revision = ++_seekRevision;
    final saving = saveProgress(useNativePosition: false);
    if (!_sourceReady) {
      _publish();
      await saving;
      return;
    }
    final generation = _generation;
    try {
      await _audio?.seek(bounded);
      if (_current(generation) && revision == _seekRevision) {
        _pendingSeek = null;
        _publish();
      }
    } catch (_) {
      if (_current(generation) && revision == _seekRevision) _fail();
    }
    await saving;
  }

  static Duration _boundedPosition(Duration value, Duration? duration) {
    final maximum = duration != null && duration > Duration.zero
        ? duration.inMicroseconds
        : value.inMicroseconds.clamp(0, const Duration(days: 7).inMicroseconds);
    return Duration(microseconds: value.inMicroseconds.clamp(0, maximum));
  }

  /// Capture the original owner before any asynchronous write or session reset.
  /// The final profile-switch save must work after admission has been closed.
  Future<void> saveProgress({bool useNativePosition = true}) {
    final store = _progressStore;
    final currentEpisode = _episode;
    if (store == null || currentEpisode == null || !_hasCheckpointPosition) {
      return _checkpointWrite;
    }
    if (useNativePosition &&
        _sourceReady &&
        _pendingSeek == null &&
        !_completed &&
        _error == null &&
        _audio?.playbackEvent.errorCode == null) {
      _position = _audio?.position ?? _position;
    }
    final progress = PodcastProgress(
        position: _completed ? Duration.zero : _position,
        duration: _duration,
        completed: _completed);
    _lastCheckpoint = _clock();
    return _checkpointWrite =
        store.save(currentEpisode.id, progress).catchError((Object error) {
      Logger('PodcastPlayer')
          .warning('Could not save podcast position (${error.runtimeType}).');
    });
  }

  Future<void> setSpeed(double value) async {
    if (!value.isFinite || value < 0.5 || value > 3 || _disposed) return;
    _speed = value;
    final generation = _generation;
    try {
      if (_sourceReady) await _audio?.setSpeed(value);
      if (_current(generation)) _publish();
    } catch (_) {
      if (_current(generation)) _fail();
    }
  }

  /// Also used when audio_service finishes initialization after the screen.
  void publishMediaSession() {
    if (active && !_disposed) _publish(metadata: true);
  }

  void _publish({bool metadata = false}) {
    if (_disposed || !active) return;
    final handler = mediaHandler();
    if (handler != null) {
      if (metadata) {
        final item = MediaItem(
            id: 'podcast:${_episode!.id}',
            title: _episode!.title,
            artist: _feedTitle,
            album: _feedTitle,
            duration: _duration);
        handler.mediaItem.add(item);
        handler.queue.add([item]);
        handler.queueTitle.add(_feedTitle);
      }
      final processing = _loading
          ? AudioProcessingState.buffering
          : _processing == audio.ProcessingState.completed
              ? AudioProcessingState.completed
              : AudioProcessingState.ready;
      handler.playbackState.add(PlaybackState(
        controls: [
          MediaControl.rewind,
          _playing ? MediaControl.pause : MediaControl.play,
          MediaControl.stop,
          MediaControl.fastForward,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.setSpeed,
        },
        androidCompactActionIndices: const [0, 1, 3],
        processingState: processing,
        playing: _playing,
        updatePosition: _position,
        bufferedPosition: _buffered,
        speed: _speed,
        queueIndex: 0,
      ));
    }
    notifyListeners();
  }

  Future<void> _detachAudio() {
    final current = _audio;
    _audio = null;
    final subscriptions = List.of(_subscriptions);
    _subscriptions.clear();
    if (current == null && subscriptions.isEmpty) return _disposal;
    final previous = _disposal;
    return _disposal = () async {
      await previous.catchError((Object _) {});
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await current?.dispose();
    }();
  }

  Future<void> stop({bool clearMediaSession = true}) async {
    if (_disposed) return;
    final saving = saveProgress();
    final wasActive = active;
    _generation++;
    _episode = null;
    _owner = null;
    _localPath = null;
    _feedTitle = '';
    _loading = false;
    _playing = false;
    _wantsToPlay = false;
    _sourceReady = false;
    _error = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _pendingSeek = null;
    _hasCheckpointPosition = false;
    _progressStore = null;
    final stopping = _detachAudio();
    if (wasActive) {
      final handler = clearMediaSession ? mediaHandler() : null;
      handler?.playbackState.add(PlaybackState());
      handler?.queue.add(const []);
      handler?.queueTitle.add('');
      handler?.mediaItem.add(const MediaItem(id: '', title: ''));
      handler?.mediaItem.add(null);
      notifyListeners();
    }
    try {
      await Future.wait([stopping, saving]);
    } catch (_) {
      // Stop must remain usable after a native decoder error.
    }
  }

  Future<void> close() async {
    await stop();
    dispose();
  }

  @override
  void dispose() {
    if (_disposed) return;
    unawaited(saveProgress());
    _disposed = true;
    _generation++;
    unawaited(_detachAudio().catchError((Object _) {}));
    super.dispose();
  }
}
