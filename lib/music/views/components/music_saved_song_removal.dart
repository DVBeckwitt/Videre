import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../services/music_library_service.dart';

Future<bool> confirmMusicSavedSongRemoval(
  BuildContext context,
  MusicLibraryService library,
  List<String> ids, {
  required bool Function() isCurrent,
}) async {
  if (ids.isEmpty || !isCurrent()) return false;
  final locals = AppLocalizations.of(context)!;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(locals.musicRemoveSelectedSavedSongsConfirm(ids.length)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(locals.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(locals.musicRemoveSelectedSavedSongs),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted || !isCurrent()) return false;
  return library.removeSavedSongs(ids, isCurrent: isCurrent);
}
