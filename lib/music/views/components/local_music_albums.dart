import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../utils.dart' show selectKeys;
import '../../models/local_music_album.dart';
import '../../models/local_music_album_editions.dart';
import '../../services/local_music_library.dart';
import '../screens/music_device_album.dart';
import 'device_music_artwork.dart';
import 'local_music_album_editions_dialog.dart';

Future<void> showLocalMusicAlbums(
    BuildContext context, LocalMusicLibrary library) async {
  final selection = library.selectionId;
  final profile = library.visibilityProfile;
  final app = context.read<AppCubit?>();
  final session = app?.state;
  bool current() {
    if (!context.mounted || !library.acceptsSessionSelection(selection)) {
      return false;
    }
    if (app != null && session != null) {
      final active = app.state;
      if (app.isClosed ||
          active.globalLoading ||
          active.sessionRecoveryRequired ||
          active.profileId != session.profileId ||
          active.sessionRevision != session.sessionRevision ||
          active.server != session.server) {
        return false;
      }
    }
    return library.visibilityProfile == profile;
  }

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
        builder: (sheetContext, _) {
          final locals = AppLocalizations.of(sheetContext)!;
          final active = current();
          final allAlbums = active
              ? groupLocalMusicAlbums(library.visibleTracks)
              : const <LocalMusicAlbum>[];
          final groups = active
              ? library.albumEditionGroups
              : const <LocalMusicAlbumEditionGroup>[];
          final albums =
              browseLocalMusicAlbumEditions(allAlbums, groups).toList();
          albums.sort((a, b) {
            final title =
                a.title.toLowerCase().compareTo(b.title.toLowerCase());
            if (title != 0) return title;
            final artist = (a.albumArtist ?? '')
                .toLowerCase()
                .compareTo((b.albumArtist ?? '').toLowerCase());
            return artist == 0 ? a.key.compareTo(b.key) : artist;
          });
          final titleCounts = <(String, String?), int>{};
          for (final album in allAlbums) {
            final label = _albumLabel(album);
            titleCounts.update(label, (count) => count + 1, ifAbsent: () => 1);
          }
          final byKey = {
            for (final group in groups)
              for (final key in group.albumKeys) key: group,
          };
          return Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
                title: Text(locals.localMusicBrowseAlbums,
                    style: Theme.of(sheetContext).textTheme.titleLarge)),
            if (albums.isEmpty) ListTile(title: Text(locals.musicNoResults)),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: albums.length,
                itemBuilder: (context, index) {
                  final album = albums[index];
                  final group = byKey[album.key];
                  final subtitles = [
                    localMusicAlbumDetails(locals, library, album,
                        includeLocation: titleCounts[_albumLabel(album)]! > 1),
                    if (group != null)
                      group.preferredKey == album.key
                          ? locals.localMusicPreferredEdition
                          : locals.localMusicEditionFallback,
                  ];
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
                    trailing: library.canManageAlbumEditions &&
                            (allAlbums.length > 1 || group != null)
                        ? IconButton(
                            tooltip: locals.localMusicManageEditions,
                            icon: const Icon(Icons.library_music_outlined),
                            onPressed: () async {
                              if (!current()) return;
                              final key = await showLocalMusicAlbumEditions(
                                sheetContext,
                                library: library,
                                anchorKey: album.key,
                                group: group,
                                isCurrent: current,
                              );
                              if (key != null &&
                                  sheetContext.mounted &&
                                  current()) {
                                Navigator.of(sheetContext).pop(key);
                              }
                            },
                          )
                        : null,
                    onTap: () {
                      if (current()) Navigator.of(sheetContext).pop(album.key);
                    },
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

(String, String?) _albumLabel(LocalMusicAlbum album) =>
    (album.title.toLowerCase(), album.albumArtist?.toLowerCase());
