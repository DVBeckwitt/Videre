import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../utils.dart' show selectKeys;
import '../../../utils/views/tv/components/tv_overscan.dart';
import '../../models/local_music_browse.dart';
import '../../models/local_music_artist.dart';
import '../../models/local_music_genre.dart';
import '../../models/local_music_track.dart';
import '../../services/local_music_library.dart';
import '../components/device_music_collection_queue_menu.dart';
import '../components/local_music_category_sort_menu.dart';
import '../components/device_music_artwork.dart';
import '../components/device_music_song_selection.dart';
import '../components/music_collection_panes.dart';
import '../components/music_library_actions.dart';
import 'music.dart';
import 'music_device_artist.dart';

typedef _BrowseCollection = ({String label, List<LocalMusicTrack> tracks});

enum MusicDeviceCollection {
  genres,
  playlists;

  String _label(AppLocalizations locals) => switch (this) {
        genres => locals.localMusicGenres,
        playlists => locals.localMusicDevicePlaylists,
      };
}

Future<void> openMusicDeviceCollections(
    BuildContext context, LocalMusicLibrary library, MusicDeviceCollection kind,
    {Object? collectionKey}) {
  final profile = library.visibilityProfile;
  final selectionId = library.selectionId;
  final session = MusicLibrarySession(context.read<AppCubit>());
  if (!session.isCurrent) return Future.value();
  return MusicScreen.openDeviceCollection(
      context,
      _DeviceCollectionPage(
        library: library,
        profile: profile,
        selectionId: selectionId,
        session: session,
        kind: kind,
        collectionKey: collectionKey,
      ));
}

class _DeviceCollectionPage extends StatelessWidget {
  static const _genreOrderSetting = 'music-device-genre-index-order';

  const _DeviceCollectionPage({
    required this.library,
    required this.profile,
    required this.selectionId,
    required this.session,
    required this.kind,
    this.collectionKey,
  });

  final LocalMusicLibrary library;
  final Object? profile;
  final String? selectionId;
  final MusicLibrarySession session;
  final MusicDeviceCollection kind;
  final Object? collectionKey;

  bool get _active =>
      session.isCurrent &&
      library.visibilityProfile == profile &&
      library.acceptsSessionSelection(selectionId);

  List<LocalMusicTrack> _members(Object key) {
    if (!_active) return const [];
    if (kind == MusicDeviceCollection.genres) {
      return [
        for (final track in library.visibleTracks)
          if (track.genres.any((genre) => localMusicGenreNameKey(genre) == key))
            track
      ];
    }
    final playlist = library.indexedPlaylists
        .where((playlist) => playlist.id == key)
        .firstOrNull;
    return playlist == null
        ? const []
        : library.indexedPlaylistTracks(playlist);
  }

  Future<void> _play(BuildContext context, Object key, String title,
      {int index = 0, String? expectedTrackId}) async {
    final tracks = _members(key);
    if (index >= tracks.length ||
        (expectedTrackId != null &&
            tracks[index].playbackId != expectedTrackId)) {
      return;
    }
    try {
      await MusicScreen.playLocalTracks(context, tracks,
          startIndex: index,
          queueTitle: title,
          songTap: expectedTrackId != null,
          collectionDetail: kind == MusicDeviceCollection.playlists);
    } catch (_) {
      if (!context.mounted || !_active) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context)!.musicPlaybackError)));
    }
  }

  String? _labelFor(Object key) {
    if (!_active) return null;
    if (kind == MusicDeviceCollection.playlists) {
      return library.indexedPlaylists
          .where((playlist) => playlist.id == key)
          .firstOrNull
          ?.name;
    }
    for (final track in library.visibleTracks) {
      for (final genre in track.genres) {
        if (localMusicGenreNameKey(genre) == key) return genre.trim();
      }
    }
    return null;
  }

  Map<Object, _BrowseCollection> _indexCollections(
      LocalMusicCategoryOrder? genreOrder) {
    if (!_active) return const {};
    if (genreOrder == null) {
      final labels = <Object, _BrowseCollection>{
        for (final playlist in library.indexedPlaylists)
          playlist.id: (label: playlist.name, tracks: const []),
      };
      final entries = labels.entries.toList()
        ..sort((a, b) =>
            a.value.label.toLowerCase().compareTo(b.value.label.toLowerCase()));
      return Map.fromEntries(entries);
    }
    final groups = <String, _BrowseCollection>{};
    for (final track in library.visibleTracks) {
      final seen = <String>{};
      for (final genre in track.genres) {
        final key = localMusicGenreNameKey(genre);
        if (key.isEmpty || !seen.add(key)) continue;
        final group =
            groups.putIfAbsent(key, () => (label: genre.trim(), tracks: []));
        group.tracks.add(track);
      }
    }
    final genres = genreOrder.order(
      groups.entries,
      name: (group) => group.value.label,
      key: (group) => group.key,
      tracks: (group) => group.value.tracks,
    );
    return {for (final group in genres) group.key: group.value};
  }

  Widget _browse(
      AppLocalizations locals, Map<Object, _BrowseCollection> labels) {
    if (labels.isEmpty) return Center(child: Text(locals.musicNoResults));
    final collections = labels.entries.toList();
    final indexes = {
      for (final (index, collection) in collections.indexed)
        ValueKey(collection.key): index,
    };
    return ListView.builder(
      itemCount: collections.length,
      findChildIndexCallback: (key) => indexes[key],
      itemBuilder: (context, index) {
        final collection = collections[index];
        return ListTile(
          key: ValueKey(collection.key),
          autofocus: isTv && index == 0,
          leading: kind == MusicDeviceCollection.genres
              ? DeviceMusicCoverMosaic(
                  tracks: collection.value.tracks,
                  fallbackIcon: Icons.library_music_outlined,
                )
              : null,
          title: Text(collection.value.label),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            if (!_active) return;
            MusicScreen.openDeviceCollection(
              context,
              _DeviceCollectionPage(
                library: library,
                profile: profile,
                selectionId: selectionId,
                session: session,
                kind: kind,
                collectionKey: collection.key,
              ),
            );
          },
        );
      },
    );
  }

  void _openArtist(BuildContext context, Object key, LocalMusicArtist artist) {
    if (!_members(key)
        .any((track) => localMusicArtistCredit(track, artist.key) != null)) {
      return;
    }
    MusicScreen.openDeviceCollection(
      context,
      MusicDeviceArtistPage(
        artistKey: artist.key,
        selectionId: selectionId,
        library: library,
      ),
    );
  }

  Widget _trackList(
      BuildContext context,
      AppLocalizations locals,
      Object key,
      String title,
      List<LocalMusicTrack> tracks,
      DeviceMusicSongSelectionState selection) {
    final artists = kind == MusicDeviceCollection.genres
        ? (groupLocalMusicArtists(tracks)
          ..sort((a, b) => a.key.compareTo(b.key)))
        : const <LocalMusicArtist>[];
    final songStart = artists.isEmpty ? 0 : artists.length + 2;
    final playAll = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              FilledButton.icon(
                autofocus: isTv,
                onPressed: () => _play(context, key, title),
                icon: const Icon(Icons.play_arrow),
                label: Text(locals.musicPlayAll),
              ),
              if (kind == MusicDeviceCollection.genres)
                DeviceMusicCollectionQueueMenu(
                  currentTracks: () => _members(key),
                ),
            ],
        ),
      ),
    );
    final songList = tracks.isEmpty
        ? Center(child: Text(locals.musicNoResults))
        : ListView.builder(
            key: PageStorageKey((kind, key)),
            itemCount: songStart + tracks.length,
            itemBuilder: (context, index) {
              if (index < songStart) {
                if (index == 0 || index == songStart - 1) {
                  return Padding(
                    padding:
                        const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 4),
                    child: Semantics(
                      header: true,
                      child: Text(
                        index == 0
                            ? locals.localMusicBrowseArtists
                            : locals.musicSongs,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  );
                }
                final artist = artists[index - 1];
                return ListTile(
                  key: ValueKey(artist.key),
                  leading: const Icon(Icons.person_outline),
                  title: Text(artist.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openArtist(context, key, artist),
                );
              }
              final songIndex = index - songStart;
              final track = tracks[songIndex];
              final selected = selection.contains(songIndex);
              return ListTile(
                key: ValueKey((track.playbackId, songIndex)),
                selected: selected,
                leading: Icon(selection.active
                    ? (selected
                        ? Icons.check_box
                        : Icons.check_box_outline_blank)
                    : Icons.music_note_outlined),
                title: Text(track.title,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: track.artist == null ? null : Text(track.artist!),
                onTap: selection.active
                    ? () => selection.toggle(songIndex)
                    : () => _play(context, key, title,
                        index: songIndex, expectedTrackId: track.playbackId),
                onLongPress: () => selection.start(songIndex),
              );
            },
          );
    return MusicCollectionPanes(
      details: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Semantics(
              header: true,
              child:
                  Text(title, style: Theme.of(context).textTheme.headlineSmall),
            ),
          ),
          if (tracks.isNotEmpty) playAll,
        ],
      ),
      buildTracks: (_, split) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!split && tracks.isNotEmpty) playAll,
          Expanded(
            key: const ValueKey('music-device-collection-tracks'),
            child: songList,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return BlocBuilder<AppCubit, AppState>(
      bloc: session.app,
      builder: (context, _) => ListenableBuilder(
        listenable: library,
        builder: (context, _) {
          final key = collectionKey;
          final order = key == null && kind == MusicDeviceCollection.genres
              ? LocalMusicCategorySortMenu.readOrder(
                  context, _genreOrderSetting)
              : null;
          final categoryTitle = kind._label(locals);
          final collectionTitle = key == null ? null : _labelFor(key);
          final tracks =
              key == null ? const <LocalMusicTrack>[] : _members(key);
          return DeviceMusicSongSelection(
            library: library,
            tracks: tracks,
            source: (library, selectionId, profile, kind, key),
            currentTracks: () => key == null || !_active ? null : _members(key),
            builder: (context, selection) {
              final page = LayoutBuilder(builder: (context, constraints) {
                final contentWidth = constraints.maxWidth - MediaQuery.paddingOf(context).horizontal;
                final split = MusicCollectionPanes.shouldSplit(contentWidth);
                return Scaffold(
                appBar: AppBar(
                  title: Text(split ? categoryTitle : collectionTitle ?? categoryTitle),
                  actions: [
                    if (selection.selectButton case final button?) button,
                    if (order != null)
                      LocalMusicCategorySortMenu(
                        settingName: _genreOrderSetting,
                        order: order,
                        isCurrent: () => _active,
                      ),
                  ],
                ),
                body: SafeArea(
                  child: Column(children: [
                    if (selection.toolbar case final toolbar?) toolbar,
                    Expanded(
                      child: key == null
                          ? _browse(locals, _indexCollections(order))
                          : collectionTitle == null ? Center(child: Text(locals.musicNoResults)) : _trackList(
                              context, locals, key, collectionTitle, tracks, selection),
                    ),
                  ]),
                ),
              );
              });
              return Shortcuts(shortcuts: {
                for (final key in selectKeys)
                  SingleActivator(key): const ActivateIntent(),
              }, child: isTv ? TvOverscan(child: page) : page);
            },
          );
        },
      ),
    );
  }
}
