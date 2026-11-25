import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../utils.dart' show selectKeys;
import '../../models/local_music_album.dart';
import '../../services/local_music_library.dart';
import '../screens/music_device_album.dart';
import 'device_music_artwork.dart';

Future<void> showLocalMusicAlbums(
    BuildContext context, LocalMusicLibrary library) async {
  final selection = library.selectionId;
  final profile = library.visibilityProfile;
  bool current() =>
      library.visibilityProfile == profile &&
      library.acceptsSessionSelection(selection);

  if (!current()) return;
  final albumKey = await showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    builder: (context) => Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent(),
      },
      child: ListenableBuilder(
        listenable: library,
        builder: (context, _) {
          final locals = AppLocalizations.of(context)!;
          final albums = current()
              ? groupLocalMusicAlbums(library.visibleTracks).toList()
              : <LocalMusicAlbum>[];
          albums.sort((a, b) {
            final title =
                a.title.toLowerCase().compareTo(b.title.toLowerCase());
            if (title != 0) return title;
            final artist = (a.albumArtist ?? '')
                .toLowerCase()
                .compareTo((b.albumArtist ?? '').toLowerCase());
            return artist == 0 ? a.key.compareTo(b.key) : artist;
          });
          final titleCounts = <({String title, String? artist}), int>{};
          for (final album in albums) {
            final label = (title: album.title, artist: album.albumArtist);
            titleCounts.update(label, (count) => count + 1, ifAbsent: () => 1);
          }
          return Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
                title: Text(locals.localMusicBrowseAlbums,
                    style: Theme.of(context).textTheme.titleLarge)),
            if (albums.isEmpty) ListTile(title: Text(locals.musicNoResults)),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: albums.length,
                itemBuilder: (context, index) {
                  final album = albums[index];
                  final duplicate = titleCounts[(
                        title: album.title,
                        artist: album.albumArtist
                      )]! >
                      1;
                  final subtitles = [
                    album.albumArtist,
                    album.releaseDate,
                    if (duplicate) _commonFolderLabel(album),
                    locals.musicTrackCount(album.tracks.length),
                  ].nonNulls;
                  return ListTile(
                    key: ValueKey(album.key),
                    autofocus: isTv && index == 0,
                    leading: SizedBox.square(
                      dimension: 44,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: DeviceMusicArtwork.album(
                          tracks: album.tracks,
                          placeholder: const Icon(Icons.album_outlined),
                          thumbnail: true,
                        ),
                      ),
                    ),
                    title: Text(album.title),
                    subtitle: Text(subtitles.join(' · ')),
                    onTap: () => Navigator.of(context).pop(album.key),
                  );
                },
              ),
            ),
          ]);
        },
      ),
    ),
  );
  if (!context.mounted || albumKey == null || !current()) return;
  await Navigator.of(context).push<void>(MaterialPageRoute(
    builder: (context) => MusicDeviceAlbumPage(
        selectionId: selection, albumKey: albumKey, library: library),
  ));
}

String? _commonFolderLabel(LocalMusicAlbum album) {
  final folder = album.tracks.first.folderLocations.lastOrNull;
  if (folder == null ||
      album.tracks.any(
          (track) => track.folderLocations.lastOrNull?.key != folder.key)) {
    return null;
  }
  return folder.label;
}
