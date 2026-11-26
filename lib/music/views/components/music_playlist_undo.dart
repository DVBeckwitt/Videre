import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

import 'music_library_actions.dart';

void showMusicPlaylistUndo(
  BuildContext context,
  MusicLibrarySession session, {
  required String message,
  required Future<bool> Function() undo,
}) {
  if (!session.isCurrent) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final locals = AppLocalizations.of(context)!;

  Future<void> restore() async {
    if (!session.isCurrent) return;
    var error = locals.musicPlaylistUndoUnavailable;
    try {
      if (await undo()) {
        session.library.notifyChanged();
        return;
      }
    } catch (_) {
      error = locals.musicLibraryActionError;
    }
    if (messenger.mounted && session.isCurrent) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
    }
  }

  messenger
    ..removeCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      action:
          SnackBarAction(label: locals.musicPlaylistUndo, onPressed: restore),
    ));
}
