import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../globals.dart';
import '../../../network/network_proxy.dart';
import '../../../videos/models/music_metadata.dart';
import '../../services/music_artwork_cache.dart';
import '../../services/music_community_cover_cache.dart';
import '../../services/music_community_cover_preferences.dart';

/// Uses the profile's local Community artwork when opted in. Catalog and
/// background surfaces can reuse a file without triggering provider lookups.
class CommunityMusicArtwork extends StatefulWidget {
  final String? videoId;
  final MusicMetadata? music;
  final int? durationSeconds;
  final Widget fallback;
  final bool allowLookup;
  final MusicCommunityCoverCache? cache;

  const CommunityMusicArtwork({
    super.key,
    required this.videoId,
    this.music,
    this.durationSeconds,
    required this.fallback,
    this.allowLookup = false,
    this.cache,
  });

  @override
  State<CommunityMusicArtwork> createState() => _CommunityMusicArtworkState();
}

class _CommunityMusicArtworkState extends State<CommunityMusicArtwork>
    with WidgetsBindingObserver {
  Object? _request;
  int _generation = 0;
  String? _profile;
  (String, String)? _suppressed;
  int _cacheRevision = 0;
  Future<File?>? _cover;
  bool _foreground = true;

  MusicCommunityCoverCache get _cache =>
      widget.cache ?? communityMusicCoverCache;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _cache.savedCover.addListener(_coverWasSaved);
    _cache.invalidated.addListener(_coverWasRemoved);
  }

  @override
  void didUpdateWidget(CommunityMusicArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.cache != oldWidget.cache) {
      final old = oldWidget.cache ?? communityMusicCoverCache;
      old.savedCover.removeListener(_coverWasSaved);
      old.invalidated.removeListener(_coverWasRemoved);
      _cache.savedCover.addListener(_coverWasSaved);
      _cache.invalidated.addListener(_coverWasRemoved);
      _suppressed = null;
      _cover = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (widget.allowLookup) {
      setState(() {
        _generation++;
        _cover = null;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cache.savedCover.removeListener(_coverWasSaved);
    _cache.invalidated.removeListener(_coverWasRemoved);
    super.dispose();
  }

  void _coverWasSaved() {
    if (_cover != null &&
        _cache.savedCover.value == (_profile, widget.videoId)) {
      setState(() => _cover = null);
    }
  }

  void _coverWasRemoved() {
    final removed = _cache.invalidated.value;
    final id = widget.videoId;
    if (removed == null ||
        removed.$1 != _profile ||
        id == null ||
        (removed.$2 != null && removed.$2 != id)) {
      return;
    }
    setState(() {
      // Keep this mounted track on its fallback after eviction. Selecting a
      // different song can start its normally authorized foreground lookup.
      _suppressed = (removed.$1, id);
      _generation++;
      _cacheRevision++;
      _cover = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppCubit?>();
    final visible =
        TickerMode.of(context) && (ModalRoute.isCurrentOf(context) ?? true);
    return ValueListenableBuilder(
      valueListenable: communityCoverArtPreferenceRevision,
      builder: (context, consent, _) {
        final id = widget.videoId;
        final state = app?.state;
        if (app == null ||
            state == null ||
            id == null ||
            state.globalLoading ||
            state.sessionRecoveryRequired ||
            state.profileId != db.profileId ||
            !isCommunityCoverArtEnabled()) {
          _request = null;
          _cover = null;
          _profile = null;
          _suppressed = null;
          return widget.fallback;
        }
        final owner = db;
        final profile = state.profileId;
        if (identical(_cache, communityMusicCoverCache)) {
          (context.read<MusicArtworkCache?>() ?? musicArtworkCache)
              .trackProfile(profile);
        }
        final session = state.sessionRevision;
        final music = widget.music;
        final duration = widget.durationSeconds;
        final proxy = NetworkProxy.instance;
        final network = proxy.config;
        if (_suppressed != (profile, id)) _suppressed = null;
        final lookup = _suppressed == null &&
            widget.allowLookup &&
            visible &&
            _foreground &&
            music != null;
        final request = (
          owner,
          profile,
          id,
          session,
          consent,
          lookup,
          music?.title,
          music?.artist,
          music?.album,
          duration,
          network,
          _cacheRevision
        );
        if (request != _request || _cover == null) {
          _request = request;
          final generation = ++_generation;
          _profile = profile;
          bool current() =>
              mounted &&
              !app.isClosed &&
              _generation == generation &&
              _request == request &&
              widget.videoId == id &&
              identical(db, owner) &&
              db.profileId == profile &&
              app.state.profileId == profile &&
              app.state.sessionRevision == session &&
              !app.state.globalLoading &&
              !app.state.sessionRecoveryRequired &&
              communityCoverArtPreferenceRevision.value == consent &&
              isCommunityCoverArtEnabled();
          _cover = lookup
              ? _cache.load(profile, id, music, duration,
                  isCurrent: () =>
                      current() &&
                      _foreground &&
                      !proxy.isChanging &&
                      identical(proxy.config, network))
              : _cache.read(profile, id, isCurrent: current);
        }
        return FutureBuilder<File?>(
          key: ValueKey(request),
          future: _cover,
          builder: (context, snapshot) {
            final cover = snapshot.data;
            if (cover == null) return widget.fallback;
            return Image.file(
              cover,
              fit: BoxFit.cover,
              frameBuilder: (context, child, frame, synchronous) =>
                  synchronous || frame != null ? child : widget.fallback,
              errorBuilder: (context, error, stack) => widget.fallback,
            );
          },
        );
      },
    );
  }
}
