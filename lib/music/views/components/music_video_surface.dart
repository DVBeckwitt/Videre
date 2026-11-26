import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:river_player/river_player.dart' as river;

import '../../../globals.dart';
import '../../../network/network_proxy.dart';
import '../../../player/models/backend_playback.dart';
import '../../../player/models/media_command.dart';
import '../../../player/models/media_event.dart';
import '../../../player/states/player.dart';
import '../../../videos/models/video.dart';
import '../../services/music_video_source.dart';

/// Displays a silent video alongside the song's existing audio decoder.
class MusicVideoSurface extends StatefulWidget {
  final Video? video;
  final String? _localUri;
  final Duration _offset;
  final VoidCallback onUnavailable;

  const MusicVideoSurface({
    super.key,
    required Video this.video,
    required this.onUnavailable,
  })  : _localUri = null,
        _offset = Duration.zero;

  /// Positions the video at the current recording position plus [offset].
  const MusicVideoSurface.local({
    super.key,
    required String uri,
    required Duration offset,
    required this.onUnavailable,
  })  : video = null,
        _localUri = uri,
        _offset = offset;

  @override
  State<MusicVideoSurface> createState() => _MusicVideoSurfaceState();
}

class _MusicVideoSurfaceState extends State<MusicVideoSurface>
    with WidgetsBindingObserver {
  late List<river.DataSource> _sources;
  int _index = 0;
  bool _foreground = true;
  int _foregroundVisit = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _selectSources();
  }

  void _selectSources() {
    final video = widget.video;
    final uri = Uri.tryParse(widget._localUri ?? '');
    final sources = _sources = video != null
        ? musicVideoSources(video)
        : [
            if (uri != null &&
                uri.scheme == 'content' &&
                uri.authority.isNotEmpty)
              river.DataSource(
                  sourceType: river.DataSourceType.file,
                  uri: widget._localUri,
                  formatHint: river.VideoFormat.other),
          ];
    _index = 0;
    if (sources.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(sources, _sources)) widget.onUnavailable();
      });
    }
  }

  @override
  void didUpdateWidget(MusicVideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.video != oldWidget.video ||
        widget._localUri != oldWidget._localUri ||
        widget._offset != oldWidget._offset) {
      _selectSources();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    setState(() {
      _foreground = foreground;
      if (foreground) _foregroundVisit++;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showing = context.select<PlayerCubit, bool>((player) {
      final state = player.state;
      return state.isAudio &&
          !state.isMini &&
          !state.isHidden &&
          !state.isClosing;
    });
    if (!_foreground ||
        !showing ||
        !TickerMode.of(context) ||
        _index >= _sources.length) {
      return const SizedBox.shrink();
    }
    final source = _sources[_index];
    final video = widget.video;
    return _SongVideoTexture(
      key: ValueKey((source, _foregroundVisit)),
      connection: video?.backendPlayback ?? video?.playbackConnection,
      source: source,
      offset: widget._offset,
      onError: (tryNext) {
        if (!mounted ||
            _index >= _sources.length ||
            !identical(source, _sources[_index])) {
          return;
        }
        setState(() => _index = tryNext ? _index + 1 : _sources.length);
        if (_index == _sources.length) widget.onUnavailable();
      },
    );
  }
}

class _SongVideoTexture extends StatefulWidget {
  final BackendPlayback? connection;
  final river.DataSource source;
  final Duration offset;
  final ValueChanged<bool> onError;

  const _SongVideoTexture({
    super.key,
    required this.connection,
    required this.source,
    required this.offset,
    required this.onError,
  });

  @override
  State<_SongVideoTexture> createState() => _SongVideoTextureState();
}

class _SongVideoTextureState extends State<_SongVideoTexture>
    with WidgetsBindingObserver {
  final _platform = river.initializedVideoPlayerPlatform;
  late final PlayerCubit _player;
  Future<int?>? _allocation;
  Future<void>? _release;
  int? _texture;
  StreamSubscription<river.VideoEvent>? _events;
  Timer? _timeout;
  Timer? _startTimer;
  Duration? _duration;
  Size? _size;
  bool _buffering = true;
  bool _syncing = false;
  bool _dirty = false;
  bool _seek = false;
  bool _newSample = false;
  MediaCommand? _lastCommand;
  bool _playing = false;
  bool _beforeStart = false;
  bool _atEnd = false;
  double _speed = 1;
  final _clock = WidgetsBinding.instance.samplingClock.stopwatch()..start();
  Duration? _reportedPosition;
  Duration _audioPosition = Duration.zero;
  Duration _sampleTime = Duration.zero;
  double _audioRate = 1;
  bool _audioRunning = false;
  Duration? _lastVideoSample;
  int _movingSamples = 0;
  Duration _nextHardCorrection = Duration.zero;
  double _rateAdjustment = 1;

  bool get _active => mounted && _release == null;

  @override
  void initState() {
    super.initState();
    _player = context.read<PlayerCubit>();
    _lastCommand = _player.state.mediaCommand;
    _observeSong(_player.state);
    WidgetsBinding.instance.addObserver(this);
    if (widget.connection != null) {
      NetworkProxy.instance.addBeforeApply(_profileChanging);
    }
    unawaited(_open());
  }

  Future<bool> _validateConnection(BackendPlayback connection) async {
    final selected = await db.getCurrentlySelectedServer();
    if (!_active) return false;
    if (!NetworkProxy.instance.isChanging && connection.matches(selected)) {
      return true;
    }
    await _fail(tryNext: false);
    return false;
  }

  Future<void> _open() async {
    try {
      final connection = widget.connection;
      if (connection != null && !await _validateConnection(connection)) return;
      if (!_active) return;
      final texture = await (_allocation = _platform.create());
      if (!_active) return;
      if (texture == null) throw StateError('Missing video texture');
      _texture = texture;
      await _platform.setVolume(texture, 0);
      if (!_active) return;
      await _platform.setMixWithOthers(texture, true);
      if (!_active) return;
      if (connection != null && !await _validateConnection(connection)) return;
      if (!_active) return;
      _events = _platform
          .videoEventsFor(texture)
          .listen(_event, onError: (Object _) => unawaited(_fail()));
      _watchBuffering();
      // Starting at zero and seeking after READY forces a second round of
      // buffering, particularly expensive over a proxied range request.
      final source = widget.source;
      final position = _videoPosition(_clock.elapsed);
      _beforeStart = position.isNegative;
      await _platform.setDataSource(
          texture,
          river.DataSource(
            sourceType: source.sourceType,
            uri: source.uri,
            headers: source.headers,
            formatHint: source.formatHint,
            videoOnly: true,
            initialPosition: _boundedVideoPosition(position),
          ));
    } catch (_) {
      await _fail();
    }
  }

  void _watchBuffering() {
    _timeout ??= Timer(const Duration(seconds: 15), () => unawaited(_fail()));
  }

  void _event(river.VideoEvent event) {
    if (!_active) return;
    switch (event.eventType) {
      case river.VideoEventType.initialized:
        final size = event.size;
        if (size == null ||
            size.isEmpty ||
            size.width <= 0 ||
            size.height <= 0) {
          unawaited(_fail());
          return;
        }
        _duration = event.duration;
        setState(() {
          _size = size;
          _buffering = false;
        });
        _timeout?.cancel();
        _timeout = null;
        _scheduleSync();
      case river.VideoEventType.bufferingStart:
        _watchBuffering();
        _resetVideoSamples();
        if (!_buffering) setState(() => _buffering = true);
      case river.VideoEventType.bufferingEnd:
        if (_size != null) {
          _timeout?.cancel();
          _timeout = null;
          if (_buffering) setState(() => _buffering = false);
          _scheduleSync();
        }
      default:
        break;
    }
  }

  void _scheduleSync({bool seek = false}) {
    _seek |= seek;
    _dirty = true;
    if (!_syncing && _active && _size != null) unawaited(_sync());
  }

  Duration _songPosition(Duration now) => _audioRunning
      ? _audioPosition + (now - _sampleTime) * _audioRate
      : _audioPosition;

  Duration _videoPosition(Duration now) => _songPosition(now) + widget.offset;

  Duration _boundedVideoPosition(Duration position) {
    if (position.isNegative) return Duration.zero;
    final duration = _duration;
    return duration != null && duration > Duration.zero && position > duration
        ? duration
        : position;
  }

  void _scheduleStart(Duration position) {
    _startTimer?.cancel();
    _startTimer = null;
    if (position.isNegative && _audioRunning && _audioRate > 0) {
      final delay = Duration(
          microseconds: (position.abs().inMicroseconds / _audioRate).ceil());
      _startTimer = Timer(delay, _scheduleSync);
    }
  }

  void _observeSong(PlayerState state, {bool seek = false}) {
    final now = _clock.elapsed;
    final moved = state.position != _reportedPosition;
    _audioPosition = moved || seek ? state.position : _songPosition(now);
    _sampleTime = now;
    _reportedPosition = state.position;
    _audioRate = state.speed;
    final status = _player.playbackStatus;
    _audioRunning = state.isPlaying &&
        (status == MediaState.playing || status == MediaState.ready);
    _newSample |= moved && !seek;
  }

  void _resetVideoSamples() {
    _lastVideoSample = null;
    _movingSamples = 0;
    _rateAdjustment = 1;
  }

  Future<void> _sync() async {
    _syncing = true;
    try {
      while (_dirty && _active) {
        _dirty = false;
        final texture = _texture!;
        final newSample = _newSample;
        _newSample = false;
        final requestedSeek = _seek;
        _seek = false;
        final position = _videoPosition(_clock.elapsed);
        final beforeStart = position.isNegative;
        final duration = _duration;
        final atEnd = duration != null &&
            duration > Duration.zero &&
            position >= duration;
        final local = widget.connection == null;
        final crossedBoundary =
            local && (beforeStart != _beforeStart || atEnd != _atEnd);
        _beforeStart = beforeStart;
        _atEnd = atEnd;
        if (local) _scheduleStart(position);
        if (requestedSeek || crossedBoundary) {
          _resetVideoSamples();
          _nextHardCorrection = _clock.elapsed + const Duration(seconds: 12);
          await _platform.seekTo(texture, _boundedVideoPosition(position));
          if (!_active) return;
        }
        final playing = _audioRunning && !beforeStart && !atEnd;
        if (playing != _playing) {
          _playing = playing;
          _resetVideoSamples();
          if (playing) {
            await _platform.play(texture);
          } else {
            await _platform.pause(texture);
          }
          if (!_active) return;
        }
        // READY after a seek does not advance either clock. Only compare on a
        // fresh song sample, once the native renderer has had time to move.
        if (newSample &&
            !requestedSeek &&
            !crossedBoundary &&
            !_buffering &&
            _playing) {
          final actual = await _platform.getPosition(texture);
          if (!_active) return;
          if (_dirty || _buffering) continue;
          final previous = _lastVideoSample;
          _lastVideoSample = actual;
          _movingSamples =
              previous != null && actual > previous ? _movingSamples + 1 : 0;
          final now = _clock.elapsed;
          final target = _boundedVideoPosition(_videoPosition(now));
          final drift = target - actual;
          if (_movingSamples >= 3 &&
              now >= _nextHardCorrection &&
              drift.abs() >= const Duration(seconds: 3)) {
            _resetVideoSamples();
            _nextHardCorrection = now + const Duration(seconds: 12);
            await _platform.seekTo(texture, target);
            if (!_active) return;
          } else if (_movingSamples > 0) {
            // Trim small steady differences without flushing Media3's buffers.
            _rateAdjustment = drift.abs() < const Duration(milliseconds: 300)
                ? 1
                : drift.isNegative
                    ? 0.95
                    : 1.05;
          }
        }
        final speed = _audioRate * _rateAdjustment;
        if (_speed != speed) {
          await _platform.setSpeed(texture, speed);
          if (!_active) return;
          _speed = speed;
        }
      }
    } catch (_) {
      await _fail();
    } finally {
      _syncing = false;
    }
  }

  Future<void> _profileChanging() => _release ?? _fail(tryNext: false);

  Future<void> _fail({bool tryNext = true}) async {
    if (!_active) return;
    await _close();
    if (mounted) widget.onError(tryNext);
  }

  Future<void> _close() => _release ??= _disposeNative();

  Future<void> _disposeNative() async {
    _timeout?.cancel();
    _startTimer?.cancel();
    try {
      final cancel = _events?.cancel();
      final texture = await _allocation;
      if (texture != null) await _platform.dispose(texture);
      await cancel;
    } catch (_) {
      // An allocation which failed never handed a texture to this view.
    } finally {
      if (widget.connection != null) {
        NetworkProxy.instance.removeBeforeApply(_profileChanging);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Flutter can stop producing frames as soon as Android backgrounds the
    // Activity. Release the decoder even if the next build is delayed.
    if (state != AppLifecycleState.resumed) unawaited(_close());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = _size;
    return BlocListener<PlayerCubit, PlayerState>(
      listenWhen: (previous, next) =>
          previous.position != next.position ||
          previous.isPlaying != next.isPlaying ||
          previous.speed != next.speed ||
          previous.mediaEvent.state != next.mediaEvent.state ||
          (previous.mediaCommand != next.mediaCommand &&
              next.mediaCommand?.type == MediaCommandType.seek),
      listener: (_, state) {
        final command = state.mediaCommand;
        final requestedSeek = command?.type == MediaCommandType.seek &&
            !identical(command, _lastCommand);
        _lastCommand = command;
        _observeSong(state, seek: requestedSeek);
        _scheduleSync(seek: requestedSeek);
      },
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          alignment: Alignment.center,
          fit: StackFit.expand,
          children: [
            if (size != null)
              Center(
                  child: AspectRatio(
                      aspectRatio: size.aspectRatio,
                      child: _platform.buildView(_texture))),
            if (_buffering) const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    );
  }
}
