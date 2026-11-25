import 'dart:math' as math;

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/local_music_album.dart';
import 'package:clipious/music/models/local_music_artist.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/utils.dart' show selectKeys;
import 'package:clipious/utils/views/tv/components/tv_overscan.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../components/music_collection_panes.dart';
import 'music.dart';
import 'music_device_artist.dart';

/// Opens an exact device album, optionally centered on the playing file.
class MusicDeviceAlbumPage extends StatefulWidget {
  const MusicDeviceAlbumPage({
    super.key,
    required this.selectionId,
    required this.albumKey,
    this.playbackId,
    this.library,
  });

  final String? selectionId;
  final String? playbackId;
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

  ({
    String? title,
    String? albumArtist,
    String? releaseDate,
    String? originalReleaseDate,
    List<LocalMusicTrack> tracks,
  })? get _album {
    if (_checking ||
        !_current ||
        !_library.acceptsSessionSelection(widget.selectionId)) {
      return null;
    }
    final id = widget.playbackId;
    final anchor = id == null ? null : _library.trackById(id);
    if (id != null && anchor?.albumKey != widget.albumKey) return null;
    final album = findLocalMusicAlbum(_library.visibleTracks, widget.albumKey);
    if (album == null && anchor == null) return null;
    return (
      title: album?.title ?? anchor?.album,
      albumArtist: album?.albumArtist ?? anchor?.albumArtist,
      releaseDate: album == null ? anchor?.releaseDate : album.releaseDate,
      originalReleaseDate: album == null
          ? anchor?.originalReleaseDate
          : album.originalReleaseDate,
      tracks: album?.tracks ?? const [],
    );
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

  Future<void> _play(String? id) async {
    final album = _album;
    if (album == null || album.tracks.isEmpty) return;
    final tracks = album.tracks;
    final index =
        id == null ? 0 : tracks.indexWhere((track) => track.playbackId == id);
    if (index < 0) return;
    try {
      await MusicScreen.playLocalTracks(context, tracks,
          startIndex: index, queueTitle: album.title);
    } catch (_) {
      if (mounted && _album != null) {
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
          final album = _album;
          final Widget body;
          if (!_current) {
            body = Center(child: Text(locals.musicNoResults));
          } else if (_checking) {
            body = const Center(child: CircularProgressIndicator());
          } else if (album == null) {
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
            final tracks = album.tracks;
            final artist = album.albumArtist;
            final artistKey = localMusicArtistKey(artist);
            final releaseDate = album.releaseDate;
            final originalReleaseDate = album.originalReleaseDate;
            final details = Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      if (artist != null ||
                          releaseDate != null ||
                          originalReleaseDate != null)
                        Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (artist != null)
                                artistKey == null
                                    ? Text(artist,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium)
                                    : Tooltip(
                                        message:
                                            locals.musicOpenNamedArtist(artist),
                                        child: TextButton(
                                          style: TextButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 4),
                                            alignment: AlignmentDirectional
                                                .centerStart,
                                          ),
                                          onPressed: () {
                                            if (localMusicArtistKey(
                                                    _album?.albumArtist) !=
                                                artistKey) {
                                              return;
                                            }
                                            MusicScreen.openDeviceCollection(
                                              context,
                                              MusicDeviceArtistPage(
                                                selectionId: widget.selectionId,
                                                artistKey: artistKey,
                                                library: _library,
                                              ),
                                            );
                                          },
                                          child: Text(artist),
                                        ),
                                      ),
                              if (releaseDate != null) Text(releaseDate),
                              if (originalReleaseDate != null &&
                                  originalReleaseDate != releaseDate)
                                Text(locals.localMusicOriginalReleaseDate(
                                    originalReleaseDate)),
                            ]),
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
            appBar:
                AppBar(title: Text(album?.title ?? locals.localMusicSortAlbum)),
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
  final String? anchorId;
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
    final anchorId = widget.anchorId;
    final anchorIndex = anchorId == null
        ? -1
        : widget.tracks.indexWhere((track) => track.playbackId == anchorId);
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
          final discNumber = track.discNumber;
          final trackNumber = track.trackNumber;
          return ListTile(
            key: ValueKey(track.playbackId),
            selected: selected,
            autofocus: isTv && index == math.max(anchorIndex, 0),
            leading: SizedBox(
                width: 40,
                child: trackNumber == null
                    ? Icon(
                        selected ? Icons.music_note : Icons.audiotrack_outlined)
                    : Text(
                        discNumber == null
                            ? '$trackNumber'
                            : '$discNumber.$trackNumber',
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis)),
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
