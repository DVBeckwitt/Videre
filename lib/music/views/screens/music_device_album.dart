import 'dart:math' as math;

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/utils.dart' show selectKeys;
import 'package:clipious/utils/views/tv/components/tv_overscan.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../components/music_collection_panes.dart';
import 'music.dart';

/// Opens the device album containing a particular file in the selected source.
class MusicDeviceAlbumPage extends StatefulWidget {
  const MusicDeviceAlbumPage({
    super.key,
    required this.selectionId,
    required this.playbackId,
    required this.albumKey,
    this.library,
  });

  final String? selectionId;
  final String playbackId;
  final String albumKey;
  final LocalMusicLibrary? library;

  @override
  State<MusicDeviceAlbumPage> createState() => _MusicDeviceAlbumPageState();
}

class _MusicDeviceAlbumPageState extends State<MusicDeviceAlbumPage> {
  late final AppCubit _app;
  late final AppState _session;
  bool _checking = true;
  int _request = 0;

  LocalMusicLibrary get _library =>
      widget.library ?? LocalMusicLibrary.instance;

  bool get _current {
    if (!mounted ||
        _app.isClosed ||
        !identical(_app, context.read<AppCubit>())) {
      return false;
    }
    final active = _app.state;
    return !active.globalLoading &&
        !active.sessionRecoveryRequired &&
        active.profileId == _session.profileId &&
        db.profileId == _session.profileId &&
        active.sessionRevision == _session.sessionRevision &&
        active.server == _session.server;
  }

  LocalMusicTrack? get _anchor {
    if (!_current || !_library.acceptsSessionSelection(widget.selectionId)) {
      return null;
    }
    final track = _library.trackById(widget.playbackId);
    return track?.albumKey == widget.albumKey ? track : null;
  }

  @override
  void initState() {
    super.initState();
    _app = context.read<AppCubit>();
    _session = _app.state;
    _load();
  }

  @override
  void didUpdateWidget(MusicDeviceAlbumPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library ||
        oldWidget.selectionId != widget.selectionId ||
        oldWidget.playbackId != widget.playbackId ||
        oldWidget.albumKey != widget.albumKey) {
      _load();
    }
  }

  Future<void> _load({bool refresh = false}) async {
    final request = ++_request;
    final library = _library;
    bool active() => mounted && request == _request && _current;
    if (!active()) return;
    if (!_checking) setState(() => _checking = true);
    try {
      await library.initialize();
      if (!active() || library.selectionId != widget.selectionId) return;
      await library.revalidate();
      if (!active() || !library.acceptsSessionSelection(widget.selectionId)) {
        return;
      }
      if (refresh || !library.loaded) await library.refresh();
    } finally {
      if (mounted && request == _request) setState(() => _checking = false);
    }
  }

  List<LocalMusicTrack> _members() => [
        for (final track in _library.visibleTracks)
          if (track.albumKey == widget.albumKey) track,
      ];

  Future<void> _play(String? id) async {
    final anchor = _anchor;
    if (_checking || anchor == null) return;
    final tracks = _members();
    final index =
        id == null ? 0 : tracks.indexWhere((track) => track.playbackId == id);
    if (index < 0 || tracks.isEmpty) return;
    try {
      await MusicScreen.playLocalTracks(context, tracks,
          startIndex: index, queueTitle: anchor.album);
    } catch (_) {
      if (mounted && _anchor != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.musicPlaybackError)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppCubit>();
    final locals = AppLocalizations.of(context)!;
    return ListenableBuilder(
        listenable: _library,
        builder: (context, _) {
          final anchor = _checking ? null : _anchor;
          final Widget body;
          if (!_current) {
            body = Center(child: Text(locals.musicNoResults));
          } else if (_checking) {
            body = const Center(child: CircularProgressIndicator());
          } else if (anchor == null) {
            final message =
                !_library.acceptsSessionSelection(widget.selectionId)
                    ? (_library.isSystem &&
                            _library.selectionId == widget.selectionId
                        ? locals.localMusicAndroidLibraryUnavailable
                        : locals.localMusicFolderUnavailable)
                    : (_library.error == null
                        ? locals.musicNoResults
                        : locals.localMusicFolderError);
            body = Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(message, textAlign: TextAlign.center)),
              TextButton(
                  autofocus: isTv,
                  onPressed: () => _load(refresh: true),
                  child: Text(locals.retry)),
            ]));
          } else {
            final tracks = _members();
            final details = Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      if (anchor.albumArtist case final artist?)
                        Text(artist,
                            style: Theme.of(context).textTheme.titleMedium),
                      FilledButton.icon(
                          onPressed: tracks.isEmpty ? null : () => _play(null),
                          icon: const Icon(Icons.play_arrow),
                          label: Text(locals.musicPlayAll)),
                    ]));
            body = MusicCollectionPanes(
              details: details,
              buildTracks: (context, split) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!split) details,
                  Expanded(
                      key: const ValueKey('music-device-album-tracks'),
                      child: tracks.isEmpty
                          ? Center(child: Text(locals.localMusicNoVisibleFiles))
                          : _AlbumTracks(
                              key: ValueKey((
                                widget.selectionId,
                                widget.playbackId,
                                widget.albumKey
                              )),
                              tracks: tracks,
                              anchorId: widget.playbackId,
                              play: _play)),
                ],
              ),
            );
          }
          final page = Scaffold(
            appBar: AppBar(
                title: Text(anchor?.album ?? locals.localMusicSortAlbum)),
            body: SafeArea(child: body),
          );
          return Shortcuts(shortcuts: {
            for (final key in selectKeys)
              SingleActivator(key): const ActivateIntent(),
          }, child: isTv ? TvOverscan(child: page) : page);
        });
  }
}

class _AlbumTracks extends StatefulWidget {
  const _AlbumTracks(
      {super.key,
      required this.tracks,
      required this.anchorId,
      required this.play});

  final List<LocalMusicTrack> tracks;
  final String anchorId;
  final ValueChanged<String> play;

  @override
  State<_AlbumTracks> createState() => _AlbumTracksState();
}

class _AlbumTracksState extends State<_AlbumTracks> {
  ScrollController? _scroll;

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final extent =
        math.max(72.0, 24 + scaler.scale(16) * 1.5 + scaler.scale(14) * 1.5);
    final anchorIndex = widget.tracks
        .indexWhere((track) => track.playbackId == widget.anchorId);
    return LayoutBuilder(builder: (context, size) {
      if (_scroll == null) {
        final maxOffset =
            math.max(0.0, extent * widget.tracks.length - size.maxHeight);
        final offset = ((anchorIndex + 0.5) * extent - size.maxHeight / 2)
            .clamp(0.0, maxOffset);
        _scroll = ScrollController(
            initialScrollOffset: offset.toDouble(), keepScrollOffset: false);
      }
      return ListView.builder(
        controller: _scroll,
        primary: false,
        itemCount: widget.tracks.length,
        itemExtent: extent,
        itemBuilder: (context, index) {
          final track = widget.tracks[index];
          final selected = index == anchorIndex;
          return ListTile(
            key: ValueKey(track.playbackId),
            selected: selected,
            autofocus: isTv && index == math.max(anchorIndex, 0),
            leading:
                Icon(selected ? Icons.music_note : Icons.audiotrack_outlined),
            title:
                Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: track.artist == null
                ? null
                : Text(track.artist!,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => widget.play(track.playbackId),
          );
        },
      );
    });
  }
}
