import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../content_filter/community_filter.dart';
import '../../../downloads/models/downloaded_video.dart';
import '../../../globals.dart' show db;
import '../../../l10n/generated/app_localizations.dart';
import '../../../network/network_proxy.dart';
import '../../../player/models/local_music_playback.dart';
import '../../../player/states/player.dart';
import '../../../settings/states/settings.dart';
import '../../../utils/motion.dart';
import '../../../videos/models/music_metadata.dart';
import '../../../videos/models/video.dart';
import '../../models/music_cover_corners.dart';
import '../../models/music_lyrics.dart';
import '../../services/local_music_library.dart';
import '../../services/local_music_video_pairings.dart';
import '../../services/music_catalog_service.dart';
import '../../services/music_video_match.dart';
import 'music_lyrics_button.dart';
import 'music_playback_artwork.dart';
import 'music_track_swipe.dart';
import 'music_video_surface.dart';

typedef MusicVideoSurfaceBuilder = Widget Function(
    Video video, VoidCallback onUnavailable);

typedef _LocalVideoSource = ({
  LocalMusicVideoOwner owner,
  Object database,
  int sessionRevision,
  int occurrenceRevision,
});

class MusicPlayerArtwork extends StatefulWidget {
  final MusicMetadata music;
  final Video? video;
  final DownloadedVideo? offline;
  final double size;
  final bool active;
  final bool localVideoActive;
  final bool interactive;
  final bool scaleWithPlayback;
  final ValueChanged<bool>? onSeekStep;
  final MusicLyricsLoader? lyricsLoader;
  final MusicVideoSurfaceBuilder? videoSurfaceBuilder;

  const MusicPlayerArtwork({
    super.key,
    required this.music,
    required this.video,
    required this.offline,
    required this.size,
    required this.active,
    this.localVideoActive = false,
    this.interactive = true,
    this.scaleWithPlayback = true,
    this.onSeekStep,
    required this.lyricsLoader,
    this.videoSurfaceBuilder,
  });

  @override
  State<MusicPlayerArtwork> createState() => _MusicPlayerArtworkState();
}

class _MusicPlayerArtworkState extends State<MusicPlayerArtwork>
    with WidgetsBindingObserver {
  // A resize or queue edit resets the swipe gesture without restarting video.
  final _videoSurface = GlobalKey();
  final _lyricsToggleFocus = FocusNode(debugLabel: 'In-player lyrics');
  ({Object session, Widget reader})? _inlineLyrics;
  Object? _source;
  Object? _request;
  Video? _match;
  bool _checked = false;
  bool _showVideo = false;
  Object? _display;
  late bool _foreground;
  int _gestureRevision = 0;
  (Object, bool)? _doubleTap;
  (Object, bool)? _seekFeedback;
  Timer? _feedbackTimer;
  final _filterChanges = communityFilters.changes;
  bool _needsFilterCheck = true;
  bool _songAllowed = true;
  _LocalVideoSource? _localSource;
  LocalMusicVideoPairing? _localPairing;
  Object? _localLookup;
  Object? _localOpen;
  bool _localChecked = false;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _filterChanges.addListener(_filtersChanged);
    LocalMusicLibrary.instance.addListener(_deviceLibraryChanged);
    LocalMusicVideoPairings.changes.addListener(_localPairingChanged);
    MusicCoverCorners.revision.addListener(_coverCornersChanged);
    NetworkProxy.instance.addBeforeApply(_proxyChanging);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    setState(() {
      _foreground = foreground;
      _gestureRevision++;
      if (!foreground) {
        _request = null;
        _display = null;
        _needsFilterCheck = true;
        _localOpen = null;
      }
    });
  }

  Future<void> _proxyChanging() async {
    if (mounted) setState(() => _reset(null));
  }

  void _filtersChanged() {
    setState(() {
      _request = null;
      _needsFilterCheck = true;
      if (_match == null) _checked = false;
    });
  }

  void _recheckFilters() {
    _needsFilterCheck = false;
    final song = widget.video!;
    _songAllowed = musicVideoAllowed(song);
    final match = _match;
    if (!_songAllowed ||
        (match != null &&
            !identical(match, song) &&
            !musicVideoAllowed(match))) {
      _match = null;
      _showVideo = false;
      _display = null;
      _checked = false;
    }
  }

  @override
  void dispose() {
    _feedbackTimer?.cancel();
    _lyricsToggleFocus.dispose();
    _filterChanges.removeListener(_filtersChanged);
    LocalMusicLibrary.instance.removeListener(_deviceLibraryChanged);
    LocalMusicVideoPairings.changes.removeListener(_localPairingChanged);
    MusicCoverCorners.revision.removeListener(_coverCornersChanged);
    NetworkProxy.instance.removeBeforeApply(_proxyChanging);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _reset(Object? source) {
    _source = source;
    _request = null;
    _display = null;
    _checked = false;
    _showVideo = false;
    _match = null;
    _needsFilterCheck = true;
  }

  Object? _currentSource() {
    final song = widget.video;
    if (song == null ||
        song.downloadPlaybackOnly ||
        song.explicitMusicDownload != null ||
        widget.offline != null ||
        isLocalMusicPlaybackId(song.videoId)) {
      return null;
    }
    final session = context.read<AppCubit>().state;
    final player = context.read<PlayerCubit>();
    final state = player.state;
    final server = session.server;
    final connection = song.backendPlayback ?? song.playbackConnection;
    if (server == null ||
        session.globalLoading ||
        session.sessionRecoveryRequired ||
        db.profileId != session.profileId ||
        NetworkProxy.instance.isChanging ||
        !state.isAudio ||
        state.currentlyPlaying?.videoId != song.videoId ||
        state.currentlyPlaying?.downloadPlaybackOnly == true ||
        state.currentlyPlaying?.explicitMusicDownload != null ||
        connection == null ||
        !connection.matches(server)) {
      return null;
    }
    return (
      db,
      session.profileId,
      session.sessionRevision,
      connection,
      server,
      NetworkProxy.instance.config,
      player.backendPlaybackGeneration,
      state.currentQueueId,
      song.videoId
    );
  }

  bool get _visible => widget.active && _artworkVisible;

  bool get _artworkVisible {
    if (_inlineLyrics != null ||
        !_foreground ||
        !TickerMode.of(context) ||
        ModalRoute.isCurrentOf(context) == false) {
      return false;
    }
    final state = context.read<PlayerCubit>().state;
    return !state.isHidden && !state.isMini && !state.isClosing;
  }

  _LocalVideoSource? _currentLocalSource() {
    if (!widget.localVideoActive || !LocalMusicVideoPairings.supported) {
      return null;
    }
    final entry = widget.offline;
    final session = context.read<AppCubit>().state;
    final player = context.read<PlayerCubit>();
    if (entry == null ||
        !player.state.isAudio ||
        player.openingMusicEntry != null ||
        player.state.offlineCurrentlyPlaying?.videoId != entry.videoId ||
        entry.profileId != session.profileId ||
        db.profileId != session.profileId ||
        session.globalLoading ||
        session.sessionRecoveryRequired) {
      return null;
    }
    final track = localMusicTrackForPlayback(entry.videoId);
    if (track == null) return null;
    return (
      owner: (profileId: session.profileId, recordingId: track.playbackId),
      database: db,
      sessionRevision: session.sessionRevision,
      occurrenceRevision: player.playbackOccurrenceRevision,
    );
  }

  void _resetLocalPairing() {
    _localLookup = null;
    _localOpen = null;
    _localPairing = null;
    _localChecked = false;
    _showVideo = false;
    _display = null;
  }

  void _deviceLibraryChanged() {
    if (widget.localVideoActive) setState(() {});
  }

  void _localPairingChanged() {
    if (_localSource?.owner == LocalMusicVideoPairings.changes.value?.$1) {
      setState(_resetLocalPairing);
    }
  }

  void _loadLocalPairing(_LocalVideoSource source) {
    final request = _localLookup = Object();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      LocalMusicVideoPairing? pairing;
      try {
        if (!mounted || _localLookup != request) return;
        pairing = await LocalMusicVideoPairings.get(source.owner);
      } catch (_) {
        // Artwork remains available if the optional pairing store cannot load.
      }
      if (!mounted ||
          _localLookup != request ||
          _currentLocalSource() != source) {
        return;
      }
      setState(() {
        _localLookup = null;
        _localChecked = true;
        _localPairing = pairing;
      });
    });
  }

  Future<void> _openLocalPairing(
      _LocalVideoSource source, LocalMusicVideoPairing pairing) async {
    final request = Object();
    setState(() => _localOpen = request);
    var readable = false;
    try {
      readable = await LocalMusicVideoPairings.open(source.owner, pairing);
    } catch (_) {
      // A missing file or revoked grant leaves song playback in place.
    }
    if (!mounted || _localOpen != request) return;
    final current = _artworkVisible && _currentLocalSource() == source;
    setState(() {
      _localOpen = null;
      if (current && readable) _showVideo = true;
    });
    if (current && !readable) _showVideoUnavailable(local: true);
  }

  void _showVideoUnavailable({required bool local}) {
    final locals = AppLocalizations.of(context)!;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(local
            ? locals.localMusicVideoUnavailable
            : locals.musicVideoUnavailable)));
  }

  void _prepare(Object source, Video song) {
    final token = _request = Object();
    bool current() =>
        mounted &&
        identical(_request, token) &&
        _visible &&
        _currentSource() == source;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!current()) return;
        final match =
            await musicCatalogService.findMusicVideo(song, isCurrent: current);
        if (current()) {
          setState(() {
            _match = match;
            _recheckFilters();
            _checked = _songAllowed;
          });
        }
      } catch (_) {
        // Availability is optional. The original song and its controls stay usable.
        if (current()) setState(() => _checked = true);
      } finally {
        if (identical(_request, token)) _request = null;
      }
    });
  }

  void _coverCornersChanged() => setState(() {});

  void _setInlineLyrics(({Object session, Widget reader})? lyrics) {
    final restoreFocus = _lyricsToggleFocus.hasFocus;
    setState(() {
      _inlineLyrics = lyrics;
      _showVideo = false;
      _display = null;
      _localOpen = null;
      _doubleTap = null;
      _seekFeedback = null;
    });
    if (restoreFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _inlineLyrics == lyrics) {
          _lyricsToggleFocus.requestFocus();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppCubit>().state;
    final sessionKey = (db, session.profileId, session.sessionRevision);
    final player = context.read<PlayerCubit>();
    final playing =
        context.select((PlayerCubit player) => player.state.isPlaying);
    final locals = AppLocalizations.of(context)!;
    if (_inlineLyrics case final lyrics?) {
      if (lyrics.session == sessionKey &&
          !session.globalLoading &&
          !session.sessionRecoveryRequired) {
        final colors = Theme.of(context).colorScheme;
        return Center(
          child: SizedBox(
            key: const ValueKey('music-player-inline-lyrics-pane'),
            width: double.infinity,
            height: widget.size,
            child: Material(
              color: colors.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: Row(
                children: [
                  Expanded(child: lyrics.reader),
                  Align(
                    alignment: Alignment.topCenter,
                    child: IconButton(
                      key: const ValueKey('music-player-inline-lyrics-close'),
                      focusNode: _lyricsToggleFocus,
                      tooltip: locals.musicShowCover,
                      onPressed: () => _setInlineLyrics(null),
                      icon: const Icon(Icons.album_outlined),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      _inlineLyrics = null;
    }

    final queueId = player.state.currentQueueId;
    final source = _currentSource();
    if (source != _source) _reset(source);
    final localSource = _currentLocalSource();
    if (localSource != _localSource) {
      _localSource = localSource;
      _resetLocalPairing();
    }
    final active = _visible && source != null;
    final localActive = _artworkVisible && localSource != null;
    if (localActive && !_localChecked && _localLookup == null) {
      _loadLocalPairing(localSource);
    }
    if (!active) {
      _request = null;
      if (!localActive) _display = null;
      _needsFilterCheck = true;
    } else {
      if (_needsFilterCheck) _recheckFilters();
      if (_songAllowed && !_checked && _request == null) {
        _prepare(source, widget.video!);
      }
    }
    final match = active ? _match : null;
    final localPairing = localActive ? _localPairing : null;
    final showing = (match != null || localPairing != null) && _showVideo;
    final display = showing ? (_display ??= Object()) : null;
    final coverCorners = MusicCoverCorners.forDatabase(db);
    final border = showing
        ? BorderRadius.circular(12)
        : switch (coverCorners) {
            MusicCoverCorners.rounded =>
              BorderRadius.circular(widget.size * 0.2),
            MusicCoverCorners.square => BorderRadius.zero,
          };
    void unavailable() {
      if (!mounted ||
          display == null ||
          !identical(_display, display) ||
          !(localPairing != null ? _artworkVisible : _visible) ||
          _currentSource() != source ||
          _currentLocalSource() != localSource) {
        return;
      }
      setState(() {
        _showVideo = false;
        _display = null;
      });
      _showVideoUnavailable(local: localPairing != null);
    }

    void toggle() {
      if (localPairing != null && localSource != null) {
        if (!_artworkVisible || _currentLocalSource() != localSource) return;
        if (_showVideo) {
          setState(() {
            _showVideo = false;
            _display = null;
          });
        } else if (_localOpen == null) {
          unawaited(_openLocalPairing(localSource, localPairing));
        }
        return;
      }
      if (!_visible ||
          _currentSource() != source ||
          !identical(_match, match)) {
        return;
      }
      setState(() {
        _recheckFilters();
        if (_match == null) return;
        _showVideo = !_showVideo;
        _display = null;
      });
    }

    final canTapCover = !showing &&
        widget.interactive &&
        _foreground &&
        TickerMode.of(context) &&
        ModalRoute.isCurrentOf(context) != false &&
        !player.state.isHidden &&
        !player.state.isMini &&
        player.openingMusicEntry == null &&
        !player.state.isClosing &&
        !session.globalLoading &&
        !session.sessionRecoveryRequired;
    final seekStep = widget.onSeekStep;
    final canSeekCover = canTapCover &&
        seekStep != null &&
        context.select((SettingsCubit? settings) =>
            settings?.state.musicArtworkDoubleTapSeek == true);
    final generation = player.playlistGeneration;
    final gestureRevision = _gestureRevision;
    final tapOwner = (
      session.profileId,
      session.sessionRevision,
      queueId,
      generation,
      gestureRevision,
      widget.size,
      canTapCover,
      canSeekCover,
    );
    bool currentCover() {
      if (!mounted || player.isClosed) return false;
      final current = context.read<AppCubit>().state;
      return widget.interactive &&
          _foreground &&
          _gestureRevision == gestureRevision &&
          TickerMode.of(context) &&
          ModalRoute.isCurrentOf(context) != false &&
          !_showVideo &&
          !player.state.isClosing &&
          !player.state.isHidden &&
          !player.state.isMini &&
          player.state.currentQueueId == queueId &&
          player.playlistGeneration == generation &&
          player.openingMusicEntry == null &&
          !current.globalLoading &&
          !current.sessionRecoveryRequired &&
          current.profileId == session.profileId &&
          current.sessionRevision == session.sessionRevision;
    }

    void tapCover() {
      if (currentCover()) player.togglePlaying();
    }

    void doubleTapDown(TapDownDetails details) {
      final offset = details.localPosition.dx - widget.size / 2;
      _doubleTap = offset == 0 ? null : (tapOwner, offset < 0);
    }

    void doubleTapCover() {
      final tap = _doubleTap;
      _doubleTap = null;
      if (tap == null ||
          tap.$1 != tapOwner ||
          seekStep == null ||
          !currentCover() ||
          context.read<SettingsCubit?>()?.state.musicArtworkDoubleTapSeek !=
              true) {
        return;
      }
      seekStep(tap.$2);
      setState(() => _seekFeedback = tap);
      _feedbackTimer?.cancel();
      _feedbackTimer = Timer(const Duration(milliseconds: 500),
          () => setState(() => _seekFeedback = null));
    }

    final feedback = _seekFeedback;
    final scale = playing ? 1.0 : 0.92;
    final scaleDuration =
        AppMotion.duration(context, const Duration(milliseconds: 220));
    Widget scaleVisual(Widget child, {Key? key}) {
      if (!widget.scaleWithPlayback) return child;
      return TweenAnimationBuilder<double>(
        // Also snap when reduced motion is turned on mid-transition.
        key: ValueKey(scaleDuration == Duration.zero),
        tween: Tween(end: scale),
        duration: scaleDuration,
        curve: Curves.easeOutCubic,
        child: child,
        builder: (context, value, child) => Transform.scale(
          key: key,
          scale: value,
          transformHitTests: false,
          child: child,
        ),
      );
    }

    final cover = MusicPlaybackArtwork(
        music: widget.music,
        video: widget.video,
        offline: widget.offline,
        allowCommunityLookup: widget.active);
    final decoration = BoxDecoration(borderRadius: border, boxShadow: const [
      BoxShadow(color: Colors.black38, blurRadius: 24, offset: Offset(0, 12)),
    ]);
    final scaleCover = widget.scaleWithPlayback && !showing;
    final artwork = Stack(children: [
      Container(
          key: const ValueKey('music-player-artwork'),
          width: widget.size,
          height: widget.size,
          decoration:
              scaleCover ? BoxDecoration(borderRadius: border) : decoration,
          child:
              Stack(fit: StackFit.expand, clipBehavior: Clip.none, children: [
            if (scaleCover)
              IgnorePointer(
                  child: scaleVisual(DecoratedBox(decoration: decoration))),
            MusicTrackSwipe(
              buildPreview: showing
                  ? null
                  : (entry) {
                      final video = entry is Video ? entry : null;
                      final offline = entry is DownloadedVideo ? entry : null;
                      return scaleVisual(
                          ClipRRect(
                              borderRadius: border,
                              child: MusicPlaybackArtwork(
                                  video: video,
                                  offline: offline,
                                  music: video?.musicMetadata ??
                                      offline?.musicMetadata)),
                          key: const ValueKey(
                              'music-player-adjacent-cover-scale'));
                    },
              child: ClipRRect(
                  borderRadius: border,
                  child: showing
                      ? KeyedSubtree(
                          key: _videoSurface,
                          child: ColoredBox(
                              key: const ValueKey('music-player-video'),
                              color: Colors.black,
                              child: localPairing != null
                                  ? MusicVideoSurface.local(
                                      uri: localPairing.uri,
                                      offset: localPairing.offset,
                                      onUnavailable: unavailable)
                                  : widget.videoSurfaceBuilder
                                          ?.call(match!, unavailable) ??
                                      MusicVideoSurface(
                                          video: match!,
                                          onUnavailable: unavailable)))
                      : Semantics(
                          image: true,
                          button: canTapCover,
                          label: widget.music.album ?? widget.music.title,
                          onTapHint:
                              playing ? locals.musicPause : locals.musicPlay,
                          onTap: canTapCover ? tapCover : null,
                          child: Stack(fit: StackFit.expand, children: [
                            if (scaleCover)
                              scaleVisual(
                                  ClipRRect(borderRadius: border, child: cover),
                                  key: const ValueKey(
                                      'music-player-cover-scale'))
                            else
                              cover,
                            if (feedback != null && feedback.$1 == tapOwner)
                              Align(
                                alignment: feedback.$2
                                    ? Alignment.centerLeft
                                    : Alignment.centerRight,
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: ExcludeSemantics(
                                    child: CircleAvatar(
                                      backgroundColor: Colors.black54,
                                      child: Icon(
                                        feedback.$2
                                            ? Icons.fast_rewind_rounded
                                            : Icons.fast_forward_rounded,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            GestureDetector(
                              key: ValueKey(tapOwner),
                              behavior: HitTestBehavior.opaque,
                              excludeFromSemantics: true,
                              onTap: canTapCover ? tapCover : null,
                              onDoubleTapDown:
                                  canSeekCover ? doubleTapDown : null,
                              onDoubleTap: canSeekCover ? doubleTapCover : null,
                              onDoubleTapCancel:
                                  canSeekCover ? () => _doubleTap = null : null,
                            ),
                          ]))),
            ),
          ])),
      PositionedDirectional(
          start: 8,
          end: 8,
          bottom: 8,
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 2,
            children: [
              if (match != null || localPairing != null)
                if (widget.size >= MediaQuery.textScalerOf(context).scale(218))
                  Tooltip(
                      message: showing
                          ? locals.musicShowCover
                          : locals.musicShowVideo,
                      child: FilledButton.tonalIcon(
                          key: const ValueKey('music-player-video-toggle'),
                          onPressed: _localOpen == null ? toggle : null,
                          icon: Icon(
                              showing
                                  ? Icons.album_outlined
                                  : Icons.music_video_outlined,
                              size: 20),
                          label: Text(showing
                              ? locals.musicCoverLabel
                              : locals.musicVideoLabel)))
                else
                  IconButton.filledTonal(
                      key: const ValueKey('music-player-video-toggle'),
                      tooltip: showing
                          ? locals.musicShowCover
                          : locals.musicShowVideo,
                      onPressed: _localOpen == null ? toggle : null,
                      icon: Icon(showing
                          ? Icons.album_outlined
                          : Icons.music_video_outlined)),
              MusicLyricsButton(loader: widget.lyricsLoader),
            ],
          )),
    ]);
    return Center(
      child: SizedBox(
        width: double.infinity,
        height: widget.size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            artwork,
            if (widget.interactive)
              PositionedDirectional(
                top: 0,
                end: 0,
                child: MusicLyricsButton(
                  loader: widget.lyricsLoader,
                  focusNode: _lyricsToggleFocus,
                  onShowInline: (reader) =>
                      _setInlineLyrics((session: sessionKey, reader: reader)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
