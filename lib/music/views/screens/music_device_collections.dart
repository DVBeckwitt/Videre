import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../utils.dart' show selectKeys;
import '../../../utils/views/tv/components/tv_overscan.dart';
import '../../models/local_music_track.dart';
import '../../services/local_music_library.dart';
import 'music.dart';

enum MusicDeviceCollection {
  genres,
  playlists;

  String _label(AppLocalizations locals) => switch (this) {
        genres => locals.localMusicGenres,
        playlists => locals.localMusicDevicePlaylists,
      };
}

void openMusicDeviceCollections(BuildContext context, LocalMusicLibrary library,
    MusicDeviceCollection kind) {
  final profile = library.visibilityProfile;
  final selectionId = library.selectionId;
  Navigator.of(context).push<void>(MaterialPageRoute(
    builder: (_) => _DeviceCollectionPage(
        library: library,
        profile: profile,
        selectionId: selectionId,
        kind: kind),
  ));
}

class _DeviceCollectionPage extends StatelessWidget {
  const _DeviceCollectionPage({
    required this.library,
    required this.profile,
    required this.selectionId,
    required this.kind,
    this.collectionKey,
  });

  final LocalMusicLibrary library;
  final Object? profile;
  final String? selectionId;
  final MusicDeviceCollection kind;
  final Object? collectionKey;

  bool get _active =>
      library.visibilityProfile == profile &&
      library.acceptsSessionSelection(selectionId);

  List<LocalMusicTrack> _members(Object key) {
    if (!_active) return const [];
    if (kind == MusicDeviceCollection.genres) {
      return [
        for (final track in library.visibleTracks)
          if (track.genre?.toLowerCase() == key) track
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
          startIndex: index, queueTitle: title);
    } catch (_) {
      if (!context.mounted || !_active) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context)!.musicPlaybackError)));
    }
  }

  Map<Object, String> _labels() {
    if (!_active) return const {};
    if (kind == MusicDeviceCollection.playlists) {
      return {
        for (final playlist in library.indexedPlaylists)
          playlist.id: playlist.name
      };
    }
    final labels = <Object, String>{};
    for (final track in library.visibleTracks) {
      if (track.genre case final genre?) {
        labels.putIfAbsent(genre.toLowerCase(), () => genre);
      }
    }
    return labels;
  }

  Widget _browse(AppLocalizations locals, Map<Object, String> labels) {
    if (labels.isEmpty) return Center(child: Text(locals.musicNoResults));
    final collections = labels.entries.toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    return ListView.builder(
      itemCount: collections.length,
      itemBuilder: (context, index) {
        final collection = collections[index];
        return ListTile(
          key: ValueKey(collection.key),
          autofocus: isTv && index == 0,
          title: Text(collection.value),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            if (!_active) return;
            Navigator.of(context).push<void>(MaterialPageRoute(
              builder: (_) => _DeviceCollectionPage(
                library: library,
                profile: profile,
                selectionId: selectionId,
                kind: kind,
                collectionKey: collection.key,
              ),
            ));
          },
        );
      },
    );
  }

  Widget _trackList(
      BuildContext context, AppLocalizations locals, Object key, String title) {
    final tracks = _members(key);
    if (tracks.isEmpty) return Center(child: Text(locals.musicNoResults));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              autofocus: isTv,
              onPressed: () => _play(context, key, title),
              icon: const Icon(Icons.play_arrow),
              label: Text(locals.musicPlayAll),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: tracks.length,
            itemBuilder: (context, index) {
              final track = tracks[index];
              return ListTile(
                key: ValueKey((track.playbackId, index)),
                leading: const Icon(Icons.music_note_outlined),
                title: Text(track.title,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: track.artist == null ? null : Text(track.artist!),
                onTap: () => _play(context, key, title,
                    index: index, expectedTrackId: track.playbackId),
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final key = collectionKey;
        final labels = _labels();
        final title = labels[key] ?? kind._label(locals);
        final page = Scaffold(
          appBar: AppBar(title: Text(title)),
          body: SafeArea(
            child: key == null
                ? _browse(locals, labels)
                : _trackList(context, locals, key, title),
          ),
        );
        return Shortcuts(shortcuts: {
          for (final key in selectKeys)
            SingleActivator(key): const ActivateIntent(),
        }, child: isTv ? TvOverscan(child: page) : page);
      },
    );
  }
}
