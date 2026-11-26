import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../models/local_music_browse.dart';

class LocalMusicDetailSongSortMenu extends StatelessWidget {
  const LocalMusicDetailSongSortMenu({
    super.key,
    required this.order,
    required this.onChanged,
    this.includeArtist = false,
  });

  final LocalMusicDetailSongOrder order;
  final ValueChanged<LocalMusicDetailSongOrder> onChanged;
  final bool includeArtist;

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    String label(LocalMusicDetailSongSort field) => switch (field) {
          LocalMusicDetailSongSort.source => locals.musicDownloadsDefaultOrder,
          LocalMusicDetailSongSort.title => locals.musicLibraryTitleOrder,
          LocalMusicDetailSongSort.artist => locals.localMusicSortArtist,
          LocalMusicDetailSongSort.album => locals.localMusicSortAlbum,
          LocalMusicDetailSongSort.releaseDate =>
            locals.localMusicTagReleaseDate,
          LocalMusicDetailSongSort.duration => locals.searchDuration,
        };
    return PopupMenuButton<LocalMusicDetailSongOrder>(
      tooltip: locals.searchSortBy,
      icon: const Icon(Icons.sort),
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final field in LocalMusicDetailSongSort.values)
          if (includeArtist || field != LocalMusicDetailSongSort.artist)
            CheckedPopupMenuItem(
              checked: field == order.field,
              value: LocalMusicDetailSongOrder(
                  field: field, descending: order.descending),
              child: Text(label(field)),
            ),
        const PopupMenuDivider(),
        for (final descending in [false, true])
          CheckedPopupMenuItem(
            enabled: order.isSorted,
            checked: order.isSorted && descending == order.descending,
            value: LocalMusicDetailSongOrder(
                field: order.field, descending: descending),
            child: Text(descending
                ? locals.localMusicDescending
                : locals.localMusicAscending),
          ),
      ],
    );
  }
}
