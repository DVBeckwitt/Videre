import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_song_radio.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/player/audio_playback_sources.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/service.dart' show VideoLoadObserver;
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart' as audio;

class MusicSongOperation extends StatefulWidget {
  final Video song;
  final PlayerCubit player;
  final bool preview;
  final bool Function() isSessionCurrent;
  final bool Function() isCurrent;
  final Stream<Object?> sessionChanges;
  final Widget Function(Video song, bool Function() isCurrent)?
      previewSaveAction;
  final void Function(Video song, bool Function() isCurrent)? onPlayFullSong;

  const MusicSongOperation({
    super.key,
    required this.song,
    required this.player,
    required this.preview,
    required this.isSessionCurrent,
    required this.isCurrent,
    required this.sessionChanges,
    this.previewSaveAction,
    this.onPlayFullSong,
  });

  @override
  State<MusicSongOperation> createState() => _MusicSongOperationState();
}

class _PreviewSample {
  audio.AudioPlayer? decoder;
}

enum _PreviewState { loading, playing, ended, failed }

class _MusicSongOperationState extends State<MusicSongOperation>
    with WidgetsBindingObserver {
  static const _previewLimit = Duration(seconds: 15);
  final _proxy = NetworkProxy.instance;
  final _subscriptions = <StreamSubscription<Object?>>[];
  late final _initialProxy = _proxy.config;
  late final int _occurrence;
  late final int _selection;
  late final int _positionGeneration;
  late int _transport;
  late List<Video> _songs = [widget.song];
  int _songIndex = 0;
  int _previewSelectionRevision = 0;
  double _dragDistance = 0;
  ModalRoute<dynamic>? _route;
  _PreviewSample? _sample;
  _PreviewState _previewState = _PreviewState.loading;
  Future<void> _audioIdle = Future<void>.value();
  Future<void>? _release;
  AudioSession? _audioSession;
  Future<bool>? _focusActivation;
  bool _resumeMusic = false;
  bool _sessionInvalidated = false;
  bool _dismissRequested = false;
  bool _cancelled = false;
  bool _started = false;
  bool _failed = false;
  bool _empty = false;

  Video get _currentSong => _songs[_songIndex];

  bool get _sameTransport =>
      !widget.player.isClosed &&
      widget.player.playbackOccurrenceRevision == _occurrence &&
      widget.player.musicSelectionRequestRevision == _selection &&
      widget.player.playbackPositionGeneration == _positionGeneration &&
      widget.player.transportIntentRevision == _transport;

  bool get _playbackContextCurrent =>
      !_sessionInvalidated &&
      !_proxy.isChanging &&
      identical(_initialProxy, _proxy.config) &&
      widget.isSessionCurrent() &&
      _sameTransport;

  // A save can remove the originating discovery row while its preview is open.
  bool get _sessionCurrent =>
      _playbackContextCurrent && (widget.preview || widget.isCurrent());

  bool get _presentationCurrent =>
      mounted && !_dismissRequested && _route?.isCurrent == true;

  bool get _current => _presentationCurrent && !_cancelled && _sessionCurrent;

  @override
  void initState() {
    super.initState();
    _occurrence = widget.player.playbackOccurrenceRevision;
    _selection = widget.player.musicSelectionRequestRevision;
    _positionGeneration = widget.player.playbackPositionGeneration;
    _transport = widget.player.transportIntentRevision;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    if (_started) {
      if (_route?.isCurrent != true && !_dismissRequested) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _route?.isCurrent != true) unawaited(_close());
        });
      }
      return;
    }
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _proxy.addBeforeApply(_invalidate);
    widget.player.addBeforeProfileSwitch(_invalidate);
    _subscriptions.addAll([
      widget.sessionChanges.listen(_checkCurrent),
      widget.player.stream.listen(_checkCurrent),
    ]);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_run());
    });
  }

  void _checkCurrent(Object? _) {
    if (mounted && !_dismissRequested && !_sessionCurrent) {
      unawaited(_close());
    }
  }

  void _finish([List<Video>? result]) {
    final route = _route;
    if (route?.isCurrent == true) {
      route!.navigator!.pop(result);
    } else if (route?.isActive == true) {
      route!.navigator!.removeRoute(route);
    }
  }

  Future<void> _close({bool restore = true}) async {
    _dismissRequested = true;
    await _stop(restore: restore);
    if (mounted) _finish();
  }

  Future<void> _playFullSong() async {
    final onPlay = widget.onPlayFullSong;
    if (onPlay == null || !_current) return;
    final song = _currentSong;
    final resumeIfDismissed = _resumeMusic;
    late final Future<void> release;
    setState(() {
      release = _stop(restore: false);
    });
    await release;
    if (!mounted) return;
    if (_dismissRequested) {
      // Close or Back can cancel the transfer while the decoder shuts down.
      if (resumeIfDismissed &&
          _playbackContextCurrent &&
          widget.player.canPreviewMusic) {
        widget.player.play();
        _transport = widget.player.transportIntentRevision;
      }
      return;
    }
    if (!_presentationCurrent || !_sessionCurrent) return _invalidate();
    onPlay(song, () => _sessionCurrent);
    _finish();
  }

  Future<void> _invalidate() {
    _sessionInvalidated = true;
    return _close(restore: false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_invalidate());
  }

  Future<void> _stop({bool restore = true}) {
    _cancelled = true;
    if (!restore) _resumeMusic = false;
    if (_release case final release?) return release;
    _retirePreview();
    return _release = _audioIdle = _audioIdle.then((_) => _releaseAudio());
  }

  void _retirePreview() {
    final decoder = _sample?.decoder;
    _sample = null;
    if (decoder == null) return;
    // Begin teardown immediately even if the next song's lookup is still pending.
    _audioIdle = Future.wait([_audioIdle, _disposeDecoder(decoder)]);
  }

  Future<void> _disposeDecoder(audio.AudioPlayer decoder) async {
    try {
      await decoder.dispose();
    } catch (_) {
      // A detached decoder cannot continue preview playback.
    }
  }

  Future<void> _releaseAudio() async {
    final activation = _focusActivation;
    _focusActivation = null;
    try {
      final ownsFocus = await activation?.onError((_, __) => false) ?? false;
      final resume = _resumeMusic;
      _resumeMusic = false;
      if (resume && _playbackContextCurrent && widget.player.canPreviewMusic) {
        widget.player.play();
        _transport = widget.player.transportIntentRevision;
      } else if (ownsFocus && _sameTransport && widget.isSessionCurrent()) {
        await _audioSession?.setActive(false);
      }
    } catch (_) {
      // Audio focus can disappear while the app or output is being detached.
    }
  }

  Future<void> _run() async {
    if (!_continueOperation()) return;
    if (widget.preview && !widget.player.canPreviewMusic) {
      setState(() => _previewState = _PreviewState.failed);
      return;
    }
    if (widget.preview) _startSample();
    try {
      final recommendations =
          RecommendationService.forProfile(db, db.profileId);
      final songs = await loadMusicSongRadio(widget.song,
          isCurrent: () => _current, eligible: recommendations.eligibleMusic);
      if (!_continueOperation()) return;
      if (widget.preview) {
        if (songs.isNotEmpty) setState(() => _songs = songs);
      } else if (songs.isEmpty) {
        setState(() => _empty = true);
      } else {
        _finish(songs);
      }
    } catch (_) {
      if (_continueOperation() && !widget.preview) {
        setState(() => _failed = true);
      }
    }
  }

  bool _continueOperation() {
    if (_current) return true;
    // An opening row can become stale without an AppCubit or PlayerCubit event.
    if (mounted && !_cancelled) unawaited(_close());
    return false;
  }

  void _movePreview(int offset) {
    final next = _songIndex + offset;
    if (!_continueOperation() || next < 0 || next >= _songs.length) return;
    _retirePreview();
    setState(() {
      _songIndex = next;
      _previewSelectionRevision++;
      _previewState = _PreviewState.loading;
    });
    _startSample();
  }

  void _startSample() {
    final sample = _sample = _PreviewSample();
    unawaited(_playPreview(sample, _currentSong));
  }

  bool _sampleIsCurrent(_PreviewSample sample) =>
      identical(_sample, sample) && _current;

  void _settleSample(_PreviewSample sample, _PreviewState state) {
    if (!identical(_sample, sample) || !_continueOperation()) return;
    _retirePreview();
    setState(() => _previewState = state);
    _audioIdle = _audioIdle.then((_) async {
      if (_sample == null) await _releaseAudio();
    });
  }

  Future<void> _playPreview(_PreviewSample sample, Video song) async {
    bool current() => _sampleIsCurrent(sample);
    bool stillSelected() => identical(_sample, sample) && _continueOperation();

    try {
      final track = await musicCatalogService.getSong(song.videoId,
          loadObserver: VideoLoadObserver(isCurrent: current, onRetry: () {}));
      if (!stillSelected()) return;
      final resolved = track.playbackVideo?.preservingMusicMetadataFrom(song);
      if (resolved == null ||
          resolved.videoId != song.videoId ||
          !canUseOnlineMusicSong(resolved)) {
        throw StateError('Preview unavailable');
      }
      final plan = await resolveAudioPlaybackSources(
          video: resolved,
          offlineVideo: null,
          sessionId: 'music-preview:${identityHashCode(sample)}',
          isCurrent: current,
          skipDownload: true);
      await _audioIdle;
      if (!stillSelected()) return;
      final source =
          plan?.sources.whereType<audio.UriAudioSource>().firstOrNull;
      final route = plan?.playbackRoute;
      if (source == null ||
          route == null ||
          !audioPlaybackRouteIsCurrent(route)) {
        throw StateError('Preview source unavailable');
      }
      final decoder = sample.decoder = audio.AudioPlayer(
          handleInterruptions: false,
          handleAudioSessionActivation: false,
          useProxyForRequestHeaders:
              kIsWeb || defaultTargetPlatform != TargetPlatform.android);
      final length = resolved.lengthSeconds ?? 0;
      final end = length > 0 && length < _previewLimit.inSeconds
          ? Duration(seconds: length)
          : _previewLimit;
      await decoder.setAudioSource(audio.ClippingAudioSource(
          child: source, start: Duration.zero, end: end));
      if (!stillSelected()) return;

      final session = _audioSession ?? await AudioSession.instance;
      if (!stillSelected()) return;
      if (_audioSession == null) {
        _audioSession = session;
        _subscriptions.addAll([
          session.interruptionEventStream.listen((event) {
            if (event.begin) unawaited(_invalidate());
          }),
          session.becomingNoisyEventStream
              .listen((_) => unawaited(_invalidate())),
        ]);
      }
      decoder.processingStateStream.listen((state) {
        if (state == audio.ProcessingState.completed) {
          _settleSample(sample, _PreviewState.ended);
        }
      });
      decoder.errorStream.listen((_) {
        _settleSample(sample, _PreviewState.failed);
      });
      final player = widget.player;
      if (!player.canPreviewMusic) throw StateError('Preview unavailable');
      if (player.state.isPlaying && player.requestedPlaying) {
        _resumeMusic = true;
        player.pause();
        _transport = player.transportIntentRevision;
      }
      if (player.state.isPlaying) {
        await player.stream
            .timeout(const Duration(seconds: 2))
            .firstWhere((state) => !state.isPlaying || !current());
      }
      if (!stillSelected()) return;
      if (!audioPlaybackRouteIsCurrent(route)) {
        throw StateError('Preview source changed');
      }
      await decoder.setVolume(player.state.muted ? 0 : 1);
      if (!stillSelected()) return;
      final ownsFocus = await (_focusActivation ??= session.setActive(true));
      if (!stillSelected()) return;
      if (!audioPlaybackRouteIsCurrent(route)) {
        throw StateError('Preview source changed');
      }
      if (!ownsFocus) throw StateError('Preview audio focus denied');
      setState(() => _previewState = _PreviewState.playing);
      await decoder.play();
    } catch (_) {
      _settleSample(sample, _PreviewState.failed);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _proxy.removeBeforeApply(_invalidate);
    widget.player.removeBeforeProfileSwitch(_invalidate);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_stop());
    super.dispose();
  }

  Widget _previewContent(BuildContext context, AppLocalizations locals) {
    final song = _currentSong.musicMetadata!;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onHorizontalDragStart: (_) => _dragDistance = 0,
      onHorizontalDragUpdate: (event) => _dragDistance += event.primaryDelta!,
      onHorizontalDragEnd: (event) {
        if (_dragDistance.abs() < 36) return;
        _movePreview((_dragDistance > 0) == rtl ? 1 : -1);
      },
      child: Semantics(
        liveRegion: true,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(song.title),
          if (song.artist.isNotEmpty) Text(song.artist),
          const SizedBox(height: 12),
          switch (_previewState) {
            _PreviewState.loading => CircularProgressIndicator(
                semanticsLabel: locals.musicPreviewSong),
            _PreviewState.playing => Text(locals.musicPreviewPlaying),
            _PreviewState.ended => Text(locals.musicPreviewEnded),
            _PreviewState.failed => Text(locals.musicPreviewUnavailable),
          },
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final material = MaterialLocalizations.of(context);
    final song = _currentSong;
    final selection = _previewSelectionRevision;
    final saveAction = widget.preview ? widget.previewSaveAction : null;
    return PlayerModalBackHandler(
      priority: 5,
      onBack: () => unawaited(_close()),
      child: PopScope<List<Video>>(
        canPop: !widget.preview,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            unawaited(_stop());
          } else if (widget.preview) {
            unawaited(_close());
          }
        },
        child: AlertDialog(
          title: Text(widget.preview
              ? locals.musicPreviewSong
              : locals.musicRadioStart),
          content: widget.preview
              ? _previewContent(context, locals)
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(widget.song.musicMetadata!.title),
                  const SizedBox(height: 12),
                  if (_failed)
                    Text(locals.musicRadioUnavailable)
                  else if (_empty)
                    Text(locals.musicRadioEmpty)
                  else
                    CircularProgressIndicator(
                        semanticsLabel: locals.musicRadioStart),
                ]),
          actions: [
            if (widget.preview && _songs.length > 1) ...[
              IconButton(
                tooltip: locals.musicPreviewPrevious,
                onPressed: _songIndex > 0 ? () => _movePreview(-1) : null,
                icon: const BackButtonIcon(),
              ),
              IconButton(
                tooltip: locals.musicPreviewNext,
                onPressed: _songIndex < _songs.length - 1
                    ? () => _movePreview(1)
                    : null,
                icon: Icon(
                  Directionality.of(context) == TextDirection.ltr
                      ? Icons.arrow_forward
                      : Icons.arrow_back,
                ),
              ),
            ],
            if (saveAction != null)
              saveAction(
                  song,
                  () =>
                      _current &&
                      _previewSelectionRevision == selection &&
                      identical(_currentSong, song)),
            if (widget.preview && widget.onPlayFullSong != null)
              TextButton(
                onPressed: _cancelled ? null : _playFullSong,
                child: Text(locals.musicPlayFullSong),
              ),
            TextButton(
              autofocus: true,
              onPressed: () => unawaited(_close()),
              child: Text(_failed ||
                      _empty ||
                      (widget.preview && _previewState != _PreviewState.loading)
                  ? material.closeButtonLabel
                  : material.cancelButtonLabel),
            ),
          ],
        ),
      ),
    );
  }
}
