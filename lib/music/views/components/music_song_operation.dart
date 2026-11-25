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
  final bool Function() isCurrent;
  final Stream<Object?> sessionChanges;

  const MusicSongOperation({
    super.key,
    required this.song,
    required this.player,
    required this.preview,
    required this.isCurrent,
    required this.sessionChanges,
  });

  @override
  State<MusicSongOperation> createState() => _MusicSongOperationState();
}

class _MusicSongOperationState extends State<MusicSongOperation>
    with WidgetsBindingObserver {
  static const _previewLimit = Duration(seconds: 15);
  final _proxy = NetworkProxy.instance;
  final _subscriptions = <StreamSubscription<Object?>>[];
  late final _initialProxy = _proxy.config;
  late final int _occurrence;
  late final int _selection;
  late int _transport;
  ModalRoute<dynamic>? _route;
  audio.AudioPlayer? _decoder;
  Future<void>? _release;
  AudioSession? _audioSession;
  bool _ownsFocus = false;
  bool _resumeMusic = false;
  bool _cancelled = false;
  bool _started = false;
  bool _playing = false;
  bool _failed = false;
  bool _empty = false;

  bool get _sameTransport =>
      !widget.player.isClosed &&
      widget.player.playbackOccurrenceRevision == _occurrence &&
      widget.player.musicSelectionRequestRevision == _selection &&
      widget.player.transportIntentRevision == _transport;

  bool get _current =>
      mounted &&
      !_cancelled &&
      _route?.isCurrent == true &&
      !_proxy.isChanging &&
      identical(_initialProxy, _proxy.config) &&
      widget.isCurrent() &&
      _sameTransport &&
      (!widget.preview || widget.player.canPreviewMusic);

  @override
  void initState() {
    super.initState();
    _occurrence = widget.player.playbackOccurrenceRevision;
    _selection = widget.player.musicSelectionRequestRevision;
    _transport = widget.player.transportIntentRevision;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    if (_started) {
      if (_route?.isCurrent != true && !_cancelled) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_cancelled && _route?.isCurrent != true) {
            unawaited(_stop());
            _finish();
          }
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
    if (mounted && !_cancelled && _route?.isCurrent == true && !_current) {
      unawaited(_invalidate());
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

  Future<void> _invalidate() {
    if (_cancelled) return _stop();
    _resumeMusic = false;
    final release = _stop();
    if (mounted) _finish();
    return release;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_invalidate());
  }

  Future<void> _stop() {
    _cancelled = true;
    return _release ??= _releaseAudio();
  }

  Future<void> _releaseAudio() async {
    try {
      await _decoder?.dispose();
      if (_resumeMusic &&
          _sameTransport &&
          widget.isCurrent() &&
          widget.player.canPreviewMusic) {
        widget.player.play();
      } else if (_ownsFocus && _sameTransport && widget.isCurrent()) {
        await _audioSession?.setActive(false);
      }
    } catch (_) {
      // A detached native decoder or session has no pending playback to resume.
    }
  }

  Future<void> _run() async {
    if (widget.preview && !widget.player.canPreviewMusic) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (!_current) return unawaited(_invalidate());
    try {
      if (widget.preview) {
        await _playPreview();
      } else {
        final recommendations =
            RecommendationService.forProfile(db, db.profileId);
        final songs = await loadMusicSongRadio(widget.song,
            isCurrent: () => _current, eligible: recommendations.eligibleMusic);
        if (!_current) return await _invalidate();
        if (songs.isEmpty) {
          setState(() => _empty = true);
        } else {
          _finish(songs);
        }
      }
    } catch (_) {
      if (!_current) {
        await _invalidate();
        return;
      }
      await _stop();
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _playPreview() async {
    final song = widget.song;
    final track = await musicCatalogService.getSong(song.videoId,
        loadObserver:
            VideoLoadObserver(isCurrent: () => _current, onRetry: () {}));
    if (!_current) return _invalidate();
    final resolved = track.playbackVideo?.preservingMusicMetadataFrom(song);
    if (resolved == null || !canUseOnlineMusicSong(resolved)) {
      throw StateError('Preview unavailable');
    }
    final plan = await resolveAudioPlaybackSources(
        video: resolved,
        offlineVideo: null,
        sessionId: 'music-preview:${identityHashCode(this)}',
        isCurrent: () => _current,
        skipDownload: true);
    if (!_current) return _invalidate();
    final source = plan?.sources.whereType<audio.UriAudioSource>().firstOrNull;
    final route = plan?.playbackRoute;
    if (source == null ||
        route == null ||
        !audioPlaybackRouteIsCurrent(route)) {
      throw StateError('Preview source unavailable');
    }
    final decoder = _decoder = audio.AudioPlayer(
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
    if (!_current) return _invalidate();

    final session = _audioSession = await AudioSession.instance;
    if (!_current) return _invalidate();
    _subscriptions.addAll([
      session.interruptionEventStream.listen((event) {
        if (event.begin) unawaited(_invalidate());
      }),
      session.becomingNoisyEventStream.listen((_) => unawaited(_invalidate())),
      decoder.processingStateStream.listen((state) {
        if (!_cancelled && state == audio.ProcessingState.completed) {
          unawaited(_stop());
          _finish();
        }
      }),
      decoder.errorStream.listen((_) {
        if (!_current) return;
        unawaited(_stop());
        setState(() => _failed = true);
      }),
    ]);
    final player = widget.player;
    if (player.state.isPlaying) {
      _resumeMusic = true;
      player.pause();
      _transport = player.transportIntentRevision;
      if (player.state.isPlaying) {
        await player.stream
            .timeout(const Duration(seconds: 2))
            .firstWhere((state) => !state.isPlaying || !_current);
      }
    }
    if (!_current) return _invalidate();
    if (!audioPlaybackRouteIsCurrent(route)) {
      throw StateError('Preview source changed');
    }
    await decoder.setVolume(player.state.muted ? 0 : 1);
    if (!_current) return _invalidate();
    _ownsFocus = await session.setActive(true);
    if (!_current) {
      if (_ownsFocus && _sameTransport && widget.isCurrent()) {
        await session.setActive(false);
      }
      return;
    }
    if (!_ownsFocus) throw StateError('Preview audio focus denied');
    setState(() => _playing = true);
    await decoder.play();
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

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final material = MaterialLocalizations.of(context);
    return PlayerModalBackHandler(
      priority: 5,
      onBack: () => _finish(),
      child: PopScope<List<Video>>(
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) unawaited(_stop());
        },
        child: AlertDialog(
          title: Text(widget.preview
              ? locals.musicPreviewSong
              : locals.musicRadioStart),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(widget.song.musicMetadata!.title),
            const SizedBox(height: 12),
            if (_failed)
              Text(widget.preview
                  ? locals.musicPreviewUnavailable
                  : locals.musicRadioUnavailable)
            else if (_empty)
              Text(locals.musicRadioEmpty)
            else if (_playing)
              Text(locals.musicPreviewPlaying)
            else
              CircularProgressIndicator(
                  semanticsLabel: widget.preview
                      ? locals.musicPreviewSong
                      : locals.musicRadioStart),
          ]),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => _finish(),
              child: Text(_failed || _empty || _playing
                  ? material.closeButtonLabel
                  : material.cancelButtonLabel),
            ),
          ],
        ),
      ),
    );
  }
}
