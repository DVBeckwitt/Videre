import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/local_music_album.dart';
import 'package:clipious/music/models/local_music_artist.dart';
import 'package:clipious/music/models/on_device_music_entry.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/utils.dart' show selectKeys;
import 'package:clipious/utils/views/tv/components/tv_overscan.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../components/music_collection_panes.dart';
import 'music.dart';
import 'music_device_album.dart';

class MusicDeviceArtistIndexPage extends StatelessWidget {
  const MusicDeviceArtistIndexPage({super.key, this.selectionId, this.library});

  final String? selectionId;
  final LocalMusicLibrary? library;

  @override
  Widget build(BuildContext context) =>
      MusicDeviceArtistPage._(selectionId: selectionId, library: library);
}

/// Browses an artist's contributions within the active device music source.
class MusicDeviceArtistPage extends StatefulWidget {
  const MusicDeviceArtistPage({
    super.key,
    required this.selectionId,
    required String this.artistKey,
    this.anchorId,
    this.library,
  });

  const MusicDeviceArtistPage._({this.selectionId, this.library})
      : artistKey = null,
        anchorId = null;

  final String? selectionId;
  final String? artistKey;
  final String? anchorId;
  final LocalMusicLibrary? library;

  @override
  State<MusicDeviceArtistPage> createState() => _MusicDeviceArtistPageState();
}

class _MusicDeviceArtistPageState extends State<MusicDeviceArtistPage> {
  late final AppCubit _app;
  late final AppState _session;
  bool _checking = true;
  int _request = 0;

  LocalMusicLibrary get _library =>
      widget.library ?? LocalMusicLibrary.instance;

  bool get _isCurrent {
    if (!mounted ||
        _app.isClosed ||
        !identical(_app, context.read<AppCubit>())) {
      return false;
    }
    final current = _app.state;
    return !current.globalLoading &&
        !current.sessionRecoveryRequired &&
        current.profileId == _session.profileId &&
        db.profileId == _session.profileId &&
        current.sessionRevision == _session.sessionRevision &&
        current.server == _session.server;
  }

  bool get _sourceCurrent =>
      _isCurrent && _library.acceptsSessionSelection(widget.selectionId);

  LocalMusicArtist? get _currentArtist {
    final key = widget.artistKey;
    if (!_sourceCurrent || key == null) return null;
    if (widget.anchorId case final anchorId?) {
      final anchor = _library.trackById(anchorId);
      if (anchor == null || localMusicArtistCredit(anchor, key) == null) {
        return null;
      }
    }
    return findLocalMusicArtist(_library.visibleTracks, key);
  }

  @override
  void initState() {
    super.initState();
    _app = context.read<AppCubit>();
    _session = _app.state;
    _load();
  }

  @override
  void didUpdateWidget(MusicDeviceArtistPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library ||
        oldWidget.selectionId != widget.selectionId) {
      _load();
    }
  }

  Future<void> _load({bool refresh = false}) async {
    final request = ++_request;
    final library = _library;
    bool active() => request == _request && _isCurrent;
    if (!active()) return;
    if (!_checking) setState(() => _checking = true);
    try {
      await library.initialize();
      if (!active() || library.selectionId != widget.selectionId) return;
      await library.revalidate();
      if (!active() || !_sourceCurrent) return;
      if (refresh || !library.loaded) await library.refresh();
    } finally {
      if (mounted && request == _request) setState(() => _checking = false);
    }
  }

  Widget _unavailable(AppLocalizations locals) {
    final library = _library;
    final message = !_sourceCurrent
        ? (library.isSystem && library.selectionId == widget.selectionId
            ? locals.localMusicAndroidLibraryUnavailable
            : locals.localMusicFolderUnavailable)
        : (library.error == null
            ? locals.musicNoResults
            : library.isSystem
                ? locals.localMusicAndroidLibraryError
                : locals.localMusicFolderError);
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(message, textAlign: TextAlign.center),
        ),
        TextButton(
          autofocus: isTv,
          onPressed: () => _load(refresh: true),
          child: Text(locals.retry),
        ),
      ]),
    );
  }

  Future<void> _play(String? id) async {
    final artist = _checking ? null : _currentArtist;
    if (artist == null) return;
    final tracks = artist.tracks;
    final index = id == null ? 0 : tracks.indexWhere((t) => t.playbackId == id);
    if (index < 0) return;
    final library = _library;
    final selection = widget.selectionId;
    bool current() =>
        _sourceCurrent &&
        library == _library &&
        selection == widget.selectionId &&
        artist.key == widget.artistKey &&
        tracks.every((track) =>
            identical(library.visibleTrackById(track.playbackId), track));
    try {
      await MusicScreen.playOnDeviceTracks(
        context,
        tracks.map(OnDeviceMusicEntry.device).toList(),
        startIndex: index,
        queueTitle: artist.name,
        isCurrent: current,
      );
    } catch (_) {
      if (mounted && current()) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.musicPlaybackError)));
      }
    }
  }

  ListView _index(List<LocalMusicArtist> artists) {
    return ListView.builder(
      itemCount: artists.length,
      itemBuilder: (context, index) {
        final artist = artists[index];
        return ListTile(
          key: ValueKey(artist.key),
          autofocus: isTv && index == 0,
          leading: const Icon(Icons.person_outline),
          title:
              Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            if (!_sourceCurrent) return;
            MusicScreen.openDeviceCollection(
              context,
              MusicDeviceArtistPage(
                artistKey: artist.key,
                selectionId: widget.selectionId,
                library: _library,
              ),
            );
          },
        );
      },
    );
  }

  Widget _artist(AppLocalizations locals, LocalMusicArtist artist) {
    final members = artist.tracks;
    final albums = groupLocalMusicAlbums(members);
    final playAll = Padding(
      padding: const EdgeInsets.all(16),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: FilledButton.icon(
          onPressed: () => _play(null),
          icon: const Icon(Icons.play_arrow),
          label: Text(locals.musicPlayAll),
        ),
      ),
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        playAll,
        if (albums.isNotEmpty)
          ExpansionTile(
            title: Text(locals.musicArtistReleases),
            leading: const Icon(Icons.album_outlined),
            children: [
              for (final album in albums)
                ListTile(
                  key: ValueKey(album.key),
                  title: Text(album.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: _releaseByline(album),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    if (!_sourceCurrent) return;
                    MusicScreen.openDeviceCollection(
                      context,
                      MusicDeviceAlbumPage(
                        selectionId: widget.selectionId,
                        albumKey: album.key,
                        library: _library,
                      ),
                    );
                  },
                ),
            ],
          ),
      ],
    );
    return MusicCollectionPanes(
      details: details,
      buildTracks: (context, split) => ListView.builder(
        key: PageStorageKey((
          'music-device-artist-tracks',
          widget.selectionId,
          widget.artistKey,
        )),
        itemCount: members.length + (split ? 0 : 1),
        itemBuilder: (context, index) {
          if (!split && index == 0) return details;
          final trackIndex = split ? index : index - 1;
          final track = members[trackIndex];
          final selected = track.playbackId == widget.anchorId;
          return ListTile(
            key: ValueKey(track.playbackId),
            autofocus: isTv && trackIndex == 0,
            selected: selected,
            leading:
                Icon(selected ? Icons.music_note : Icons.audiotrack_outlined),
            title:
                Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                ...localMusicArtistCredit(track, artist.key)!
                    .roles
                    .map((role) => localMusicArtistRoleLabel(locals, role)),
                if (track.album case final album?) album,
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _play(track.playbackId),
          );
        },
      ),
    );
  }

  Widget? _releaseByline(LocalMusicAlbum album) {
    final labels = [album.albumArtist, album.releaseDate].nonNulls.join(' · ');
    return labels.isEmpty
        ? null
        : Text(labels, maxLines: 1, overflow: TextOverflow.ellipsis);
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppCubit>();
    final locals = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: _library,
      builder: (context, _) {
        final index = widget.artistKey == null;
        final artist = _checking ? null : _currentArtist;
        final title = artist?.name ?? locals.localMusicBrowseArtists;
        final Widget body;
        if (!_isCurrent) {
          body = Center(child: Text(locals.musicSourceUnavailable));
        } else if (_checking) {
          body = const Center(child: CircularProgressIndicator());
        } else if (artist != null) {
          body = _artist(locals, artist);
        } else if (index && _sourceCurrent && _library.error == null) {
          final artists = groupLocalMusicArtists(_library.visibleTracks)
            ..sort((a, b) => a.key.compareTo(b.key));
          body = artists.isEmpty
              ? Center(child: Text(locals.musicNoResults))
              : _index(artists);
        } else {
          body = _unavailable(locals);
        }
        final page = Scaffold(
          appBar: AppBar(title: Text(title)),
          body: SafeArea(child: body),
        );
        return Shortcuts(
          shortcuts: {
            for (final key in selectKeys)
              SingleActivator(key): const ActivateIntent(),
          },
          child: isTv ? TvOverscan(child: page) : page,
        );
      },
    );
  }
}

String localMusicArtistRoleLabel(
        AppLocalizations locals, LocalMusicArtistRole role) =>
    switch (role) {
      LocalMusicArtistRole.trackArtist => locals.localMusicTrackArtistCredit,
      LocalMusicArtistRole.albumArtist => locals.localMusicAlbumArtistCredit,
    };
