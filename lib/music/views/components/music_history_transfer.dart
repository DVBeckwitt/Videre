import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/motion.dart';
import '../../services/music_history_transfer.dart';
import '../../services/music_listening_history.dart';
import 'music_library_actions.dart';

enum _Transfer { import, export }

Future<void> showMusicHistoryTransfer(BuildContext context) async {
  final session = MusicLibrarySession(context.read<AppCubit>());
  if (!session.isCurrent) return;
  final history = MusicListeningHistory.forProfile(db, db.profileId);
  final locals = AppLocalizations.of(context)!;
  final route = ModalRoute.of(context);
  bool active() =>
      context.mounted && session.isCurrent && (route?.isCurrent ?? true);

  final action = await showDialog<_Transfer>(
    context: context,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (context) => SimpleDialog(
      title: Text(locals.musicHistoryTransfer),
      children: [
        ListTile(
          leading: const Icon(Icons.file_upload_outlined),
          title: Text(locals.musicHistoryImport),
          onTap: () => Navigator.pop(context, _Transfer.import),
        ),
        ListTile(
          leading: const Icon(Icons.file_download_outlined),
          title: Text(locals.musicHistoryExport),
          onTap: () => Navigator.pop(context, _Transfer.export),
        ),
      ],
    ),
  );
  if (action == null || !active()) return;

  void notify(String message) {
    if (active()) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  const files = MethodChannel('videre/files');
  try {
    if (action == _Transfer.export) {
      final text = await compute(MusicHistoryTransfer.encode, history.events());
      if (!active()) return;
      final date = DateTime.now().toIso8601String().split('T').first;
      final saved = await files.invokeMethod<bool>('save', {
        'name': 'videre-music-history-$date.json',
        'text': text,
      });
      if (saved == true) notify(locals.musicHistoryExported);
      return;
    }

    final text = await files.invokeMethod<String>('open');
    if (text == null || !active()) return;
    final events = await compute(MusicHistoryTransfer.decode, text);
    if (!context.mounted || !active()) return;
    if (events.isEmpty) {
      notify(locals.musicHistoryFileEmpty);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (context) => AlertDialog(
        title: Text(locals.musicHistoryImport),
        content: Text(locals.musicHistoryImportPreview(events.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(locals.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(locals.musicHistoryImport),
          ),
        ],
      ),
    );
    if (confirmed != true || !active()) return;
    final added = await history.merge(events);
    notify(locals.musicHistoryImported(added, events.length - added));
  } on MusicHistoryFileTooLarge {
    notify(locals.musicHistoryFileTooLarge);
  } on FormatException {
    notify(locals.musicHistoryFileInvalid);
  } on PlatformException catch (error) {
    notify(switch (error.code) {
      'FILE_TOO_LARGE' => locals.musicHistoryFileTooLarge,
      'INVALID_UTF8' => locals.musicHistoryFileInvalid,
      _ => locals.musicHistoryTransferFailed,
    });
  } catch (_) {
    notify(locals.musicHistoryTransferFailed);
  }
}
