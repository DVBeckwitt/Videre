import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../playlists/models/playlist_reference.dart';
import '../../../settings/states/settings.dart';
import '../../models/music_collection_order.dart';
import '../../services/music_listening_history.dart';
import 'music_library_actions.dart';

class MusicPlaylistOrderBuilder extends StatelessWidget {
  const MusicPlaylistOrderBuilder({
    super.key,
    required this.reference,
    required this.builder,
  });

  final PlaylistReference reference;
  final Widget Function(BuildContext context, MusicCollectionOrder order,
      MusicPlaylistSortValue sortValue) builder;

  static final _noChanges = Listenable.merge(const []);

  @override
  Widget build(BuildContext context) {
    final order = MusicCollectionSortMenu.playlistOrder(context, reference);
    final history = order.field == MusicCollectionSortField.listeningTime &&
            db.profileId == reference.profileId
        ? MusicListeningHistory.forProfile(db, reference.profileId)
        : null;
    return ListenableBuilder(
      listenable: history?.changes ?? _noChanges,
      builder: (context, _) {
        final totals = history != null && db.profileId == reference.profileId
            ? history.listenedTimeByTrack()
            : const <String, Duration>{};
        return builder(
            context,
            order,
            (song, field) => field == MusicCollectionSortField.listeningTime
                ? totals[musicListeningTrackId(song.videoId)]
                : musicPlaylistTrackSortValue(song, field));
      },
    );
  }
}

class MusicCollectionSortMenu extends StatelessWidget {
  const MusicCollectionSortMenu({
    super.key,
    required this.settingName,
    required this.order,
    required this.compact,
    required this.isCurrent,
    this.fields = standardFields,
    this.savedOrder = false,
    this.onChanged,
  });

  MusicCollectionSortMenu.playlist({
    required PlaylistReference reference,
    required MusicCollectionOrder order,
    required bool compact,
    required bool Function() isCurrent,
    VoidCallback? onChanged,
  }) : this(
          key: const ValueKey('music-playlist-sort'),
          settingName: playlistSettingName(reference),
          order: order,
          compact: compact,
          isCurrent: isCurrent,
          fields: MusicCollectionSortField.values,
          onChanged: onChanged,
        );

  final String settingName;
  final MusicCollectionOrder order;
  final bool compact;
  final bool Function() isCurrent;
  final List<MusicCollectionSortField> fields;
  final bool savedOrder;
  final VoidCallback? onChanged;

  static const standardFields = [
    MusicCollectionSortField.source,
    MusicCollectionSortField.title,
    MusicCollectionSortField.artist,
    MusicCollectionSortField.album,
    MusicCollectionSortField.duration,
  ];

  static String playlistSettingName(PlaylistReference reference) =>
      'music-collection-playlist-order:${reference.key}';

  static MusicCollectionOrder playlistOrder(
          BuildContext context, PlaylistReference reference) =>
      readOrder(context, playlistSettingName(reference));

  static MusicCollectionOrder readOrder(
      BuildContext context, String settingName) {
    final value = context.select((SettingsCubit? settings) =>
        settings?.state.settings[settingName]?.value);
    return MusicCollectionOrder.decode(value);
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final settings = context.read<SettingsCubit?>();
    String label(MusicCollectionSortField field) => switch (field) {
          MusicCollectionSortField.source => savedOrder
              ? locals.musicLibrarySavedOrder
              : locals.musicDownloadsDefaultOrder,
          MusicCollectionSortField.title => locals.musicLibraryTitleOrder,
          MusicCollectionSortField.artist => locals.localMusicSortArtist,
          MusicCollectionSortField.album => locals.localMusicSortAlbum,
          MusicCollectionSortField.duration => locals.searchDuration,
          MusicCollectionSortField.listeningTime =>
            locals.musicListeningTimeOrder,
        };
    return PopupMenuButton<Future<void> Function()>(
      enabled: settings != null,
      tooltip: locals.searchSortBy,
      onSelected: (change) => unawaited(change()),
      itemBuilder: (_) {
        final session = MusicLibrarySession(context.read<AppCubit>());
        bool canApply() =>
            context.mounted &&
            session.isCurrent &&
            isCurrent() &&
            identical(context.read<SettingsCubit?>(), settings) &&
            settings?.isClosed == false;

        Future<void> change(
            {MusicCollectionSortField? field, bool? descending}) async {
          if (!canApply()) return;
          try {
            await settings!.updateMusicCollectionOrder(settingName,
                field: field, descending: descending);
            if (canApply()) onChanged?.call();
          } catch (_) {
            if (context.mounted && canApply()) {
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(locals.musicLibraryActionError)));
            }
          }
        }

        return [
          for (final field in fields)
            CheckedPopupMenuItem(
              checked: field == order.field,
              value: () => change(
                  field: field,
                  descending: field == MusicCollectionSortField.listeningTime &&
                          field != order.field
                      ? true
                      : null),
              child: Text(label(field)),
            ),
          const PopupMenuDivider(),
          for (final descending in [false, true])
            CheckedPopupMenuItem(
              checked: descending == order.descending,
              value: () => change(descending: descending),
              child: Text(descending
                  ? locals.localMusicDescending
                  : locals.localMusicAscending),
            ),
        ];
      },
      icon: compact ? const Icon(Icons.sort) : null,
      child: compact
          ? null
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                  child: Text(label(order.field),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                const SizedBox(width: 8),
                Icon(
                    order.descending
                        ? Icons.arrow_downward_rounded
                        : Icons.arrow_upward_rounded,
                    size: 16),
              ]),
            ),
    );
  }
}
