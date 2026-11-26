import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../downloads/models/downloaded_video.dart';
import '../../../downloads/states/download_manager.dart';
import '../../../globals.dart' show db;
import '../../../l10n/generated/app_localizations.dart';
import '../../../player/models/local_music_playback.dart';
import '../../../utils/interfaces/db.dart';
import '../../../videos/models/video.dart';
import '../../models/local_music_track.dart';
import '../../services/cached_music.dart';
import '../../services/local_music_library.dart';
import '../../services/music_offline_collection.dart';

typedef MusicOfflineView = ({
  bool enabled,
  List<Video?>? entries,
  bool Function() isCurrent,
  VoidCallback toggle,
});

class MusicOfflineFilter extends StatefulWidget {
  const MusicOfflineFilter({
    super.key,
    required this.videos,
    required this.builder,
  });

  final List<Video> videos;
  final Widget Function(BuildContext, MusicOfflineView) builder;

  @override
  State<MusicOfflineFilter> createState() => _MusicOfflineFilterState();
}

class _MusicOfflineFilterState extends State<MusicOfflineFilter>
    with WidgetsBindingObserver {
  final _noChanges = Listenable.merge(const []);
  bool _enabled = false;
  late bool _foreground;
  int _generation = 0;
  AppState? _session;
  IDbClient? _database;
  List<DownloadedVideo>? _downloads;
  List<LocalMusicTrack?>? _deviceTracks;
  Future<List<Video?>>? _probe;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(MusicOfflineFilter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameSources(oldWidget.videos, widget.videos)) _invalidate();
  }

  // Collection rows are rebuilt from stored metadata. A new artwork or title
  // object does not change the source checked by an open selection menu.
  bool _sameSources(List<Video> before, List<Video> after) {
    if (identical(before, after)) return true;
    if (before.length != after.length) return false;
    for (final (index, first) in before.indexed) {
      final next = after[index];
      final firstCache = CachedMusicPlayback.of(first);
      final nextCache = CachedMusicPlayback.of(next);
      if (first.videoId != next.videoId ||
          first.queueEntryId != next.queueEntryId ||
          first.filtered != next.filtered ||
          first.filterHide != next.filterHide ||
          first.isUpcoming != next.isUpcoming ||
          first.liveNow != next.liveNow ||
          first.explicitMusicDownload != next.explicitMusicDownload ||
          firstCache?.owner != nextCache?.owner ||
          firstCache?.rendition != nextCache?.rendition ||
          (!listEquals(first.adaptiveFormats, next.adaptiveFormats) &&
              jsonEncode(first.adaptiveFormats) !=
                  jsonEncode(next.adaptiveFormats))) {
        return false;
      }
    }
    return true;
  }

  List<Video?> _currentEntries(List<Video?>? verified) => [
        for (final (index, video) in widget.videos.indexed)
          if (verified?[index] case final offline?)
            video.copyWith(
              explicitMusicDownload: offline.explicitMusicDownload,
              playbackSourceId:
                  CachedMusicPlayback.of(offline) ?? video.playbackSourceId,
            )
          else
            null,
      ];

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    setState(() {
      _foreground = foreground;
      _invalidate();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _invalidate() {
    _generation++;
    _probe = null;
  }

  void _toggle() => setState(() {
        _enabled = !_enabled;
        _invalidate();
      });

  @override
  Widget build(BuildContext context) {
    final deviceIds = _enabled
        ? widget.videos
            .map((video) => video.videoId)
            .where(isLocalMusicPlaybackId)
            .toSet()
        : const <String>{};
    return ListenableBuilder(
      listenable: deviceIds.isEmpty ? _noChanges : LocalMusicLibrary.instance,
      builder: (context, _) => _buildResults(
          context, deviceIds.map(localMusicTrackForPlayback).toList()),
    );
  }

  Widget _buildResults(
      BuildContext context, List<LocalMusicTrack?> deviceTracks) {
    final app = context.watch<AppCubit>();
    final session = app.state;
    final database = db;
    final downloads = context
        .select((DownloadManagerCubit? manager) => manager?.state.videos);
    if (!_enabled ||
        !_foreground ||
        session.globalLoading ||
        session.sessionRecoveryRequired ||
        database.profileId != session.profileId) {
      _invalidate();
    } else if (_probe == null ||
        _session != session ||
        !identical(_database, database) ||
        !listEquals(_downloads, downloads) ||
        !listEquals(_deviceTracks, deviceTracks)) {
      final generation = ++_generation;
      _session = session;
      _database = database;
      _downloads = downloads;
      _deviceTracks = deviceTracks;
      final videos = widget.videos;
      _probe = Future.microtask(() => resolveOfflineMusicCollection(
            database: database,
            session: session,
            videos: videos,
            isCurrent: () => _current(generation, app, session, database),
          ));
    }
    final generation = _generation;
    return FutureBuilder<List<Video?>>(
      future: _probe,
      builder: (context, state) => widget.builder(context, (
        enabled: _enabled,
        entries: state.connectionState == ConnectionState.done
            ? _currentEntries(state.data)
            : null,
        isCurrent: () =>
            _current(generation, app, session, database) &&
            listEquals(_downloads,
                context.read<DownloadManagerCubit?>()?.state.videos),
        toggle: _toggle,
      )),
    );
  }

  bool _current(
          int generation, AppCubit app, AppState session, IDbClient database) =>
      mounted &&
      _foreground &&
      _enabled &&
      generation == _generation &&
      app.state == session &&
      identical(db, database) &&
      database.profileId == session.profileId;
}

Widget musicOfflineFilterButton(BuildContext context, MusicOfflineView offline,
    {Key? key}) {
  final label = AppLocalizations.of(context)!.musicOfflineCollectionFilter;
  return IconButton(
    key: key,
    isSelected: offline.enabled,
    tooltip: label,
    onPressed: offline.toggle,
    icon: const Icon(Icons.offline_pin_outlined),
    selectedIcon: const Icon(Icons.offline_pin),
  );
}

Widget musicOfflineCollectionEmpty(
        BuildContext context, MusicOfflineView offline) =>
    Center(
      child: offline.entries == null
          ? const CircularProgressIndicator()
          : Text(AppLocalizations.of(context)!.musicOfflineCollectionEmpty),
    );
