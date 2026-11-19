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
import '../../../videos/models/music_metadata.dart';
import '../../../videos/models/video.dart';
import '../../models/music_lyrics.dart';
import '../../services/music_catalog_service.dart';
import '../../services/music_video_match.dart';
import 'music_lyrics_button.dart';
import 'music_playback_artwork.dart';
import 'music_track_swipe.dart';
import 'music_video_surface.dart';

typedef MusicVideoSurfaceBuilder = Widget Function(
    Video video, VoidCallback onUnavailable);

class MusicPlayerArtwork extends StatefulWidget {
  final MusicMetadata music;
  final Video? video;
  final DownloadedVideo? offline;
  final double size;
  final bool active;
  final MusicLyricsLoader lyricsLoader;
  final MusicVideoSurfaceBuilder? videoSurfaceBuilder;

  const MusicPlayerArtwork({
    super.key,
    required this.music,
    required this.video,
    required this.offline,
    required this.size,
    required this.active,
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
  Object? _source;
  Object? _request;
  Video? _match;
  bool _checked = false;
  bool _showVideo = false;
  Object? _display;
  late bool _foreground;
  final _filterChanges = communityFilters.changes;
  bool _needsFilterCheck = true;
  bool _songAllowed = true;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _filterChanges.addListener(_filtersChanged);
    NetworkProxy.instance.addBeforeApply(_proxyChanging);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    setState(() {
      _foreground = foreground;
      if (!foreground) {
        _request = null;
        _display = null;
        _needsFilterCheck = true;
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
    _filterChanges.removeListener(_filtersChanged);
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

  bool get _visible {
    if (!_foreground ||
        !widget.active ||
        !TickerMode.of(context) ||
        ModalRoute.isCurrentOf(context) == false) {
      return false;
    }
    final state = context.read<PlayerCubit>().state;
    return !state.isHidden && !state.isMini && !state.isClosing;
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

  @override
  Widget build(BuildContext context) {
    context.watch<AppCubit>();
    final source = _currentSource();
    if (source != _source) _reset(source);
    final active = _visible && source != null;
    if (!active) {
      _request = null;
      _display = null;
      _needsFilterCheck = true;
    } else {
      if (_needsFilterCheck) _recheckFilters();
      if (_songAllowed && !_checked && _request == null) {
        _prepare(source, widget.video!);
      }
    }
    final match = active ? _match : null;
    final showing = match != null && _showVideo;
    final display = showing ? (_display ??= Object()) : null;
    final locals = AppLocalizations.of(context)!;
    final border = BorderRadius.circular(showing ? 12 : widget.size * 0.2);
    void unavailable() {
      if (!mounted ||
          display == null ||
          !identical(_display, display) ||
          !_visible ||
          _currentSource() != source) {
        return;
      }
      setState(() {
        _showVideo = false;
        _display = null;
      });
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(locals.musicVideoUnavailable)));
    }

    void toggle() {
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

    return Center(
        child: Stack(children: [
      MusicTrackSwipe(
          child: Container(
        key: const ValueKey('music-player-artwork'),
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(borderRadius: border, boxShadow: const [
          BoxShadow(
              color: Colors.black38, blurRadius: 24, offset: Offset(0, 12)),
        ]),
        child: ClipRRect(
            borderRadius: border,
            child: showing
                ? KeyedSubtree(
                    key: _videoSurface,
                    child: ColoredBox(
                        key: const ValueKey('music-player-video'),
                        color: Colors.black,
                        child: widget.videoSurfaceBuilder
                                ?.call(match, unavailable) ??
                            MusicVideoSurface(
                                video: match, onUnavailable: unavailable)))
                : Semantics(
                    image: true,
                    label: widget.music.album ?? widget.music.title,
                    child: MusicPlaybackArtwork(
                        music: widget.music,
                        video: widget.video,
                        offline: widget.offline,
                        allowCommunityLookup: widget.active))),
      )),
      if (!isLocalMusicPlaybackId(
          widget.video?.videoId ?? widget.offline?.videoId))
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
                if (match != null)
                  if (widget.size >=
                      MediaQuery.textScalerOf(context).scale(218))
                    Tooltip(
                        message: showing
                            ? locals.musicShowCover
                            : locals.musicShowVideo,
                        child: FilledButton.tonalIcon(
                            key: const ValueKey('music-player-video-toggle'),
                            onPressed: toggle,
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
                        onPressed: toggle,
                        icon: Icon(showing
                            ? Icons.album_outlined
                            : Icons.music_video_outlined)),
                MusicLyricsButton(loader: widget.lyricsLoader),
              ],
            )),
    ]));
  }
}
