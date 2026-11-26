import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../settings/states/settings.dart';
import '../../models/local_music_browse.dart';

class LocalMusicCategorySortMenu extends StatelessWidget {
  const LocalMusicCategorySortMenu({
    super.key,
    required this.settingName,
    required this.order,
    required this.isCurrent,
  });

  final String settingName;
  final LocalMusicCategoryOrder order;
  final bool Function() isCurrent;

  static LocalMusicCategoryOrder readOrder(
      BuildContext context, String settingName) {
    final value = context.select((SettingsCubit? settings) =>
        settings?.state.settings[settingName]?.value);
    return LocalMusicCategoryOrder.fromValue(value);
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final settings = context.read<SettingsCubit?>();
    return PopupMenuButton<Future<void> Function()>(
      enabled: settings != null && isCurrent(),
      icon: const Icon(Icons.sort),
      tooltip: locals.searchSortBy,
      onSelected: (apply) => unawaited(apply()),
      itemBuilder: (_) {
        if (settings == null) return [];
        final app = settings.appCubit;
        final revision = app.state.sessionRevision;
        bool canApply() =>
            context.mounted &&
            isCurrent() &&
            identical(context.read<SettingsCubit?>(), settings) &&
            !settings.isClosed &&
            !app.isClosed &&
            !app.state.globalLoading &&
            !app.state.sessionRecoveryRequired &&
            app.state.sessionRevision == revision;

        Future<void> change(
            {LocalMusicCategorySort? field, bool? descending}) async {
          if (!canApply()) return;
          try {
            await settings.updateLocalMusicCategoryOrder(settingName,
                field: field, descending: descending);
          } catch (_) {
            if (context.mounted && canApply()) {
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(locals.musicLibraryActionError)));
            }
          }
        }

        return [
          for (final field in LocalMusicCategoryOrder.fields)
            CheckedPopupMenuItem(
              checked: field == order.field,
              value: () => change(field: field),
              child: Text(switch (field) {
                LocalMusicCategorySort.name => locals.localMusicSortName,
                LocalMusicCategorySort.trackCount =>
                  locals.localMusicSortSongCount,
                LocalMusicCategorySort.duration => locals.searchDuration,
                LocalMusicCategorySort.size => locals.localMusicFileSize,
              }),
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
    );
  }
}
