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
import '../../services/spotify_music_history_candidates.dart';
import '../../services/spotify_music_history_import.dart';
import 'music_library_actions.dart';
import 'music_spotify_history_preview.dart';

enum _Transfer { import, export, importSpotify, exportCsv }

Future<void> showMusicHistoryTransfer(BuildContext context) async {
  final session = MusicLibrarySession(context.read<AppCubit>());
  if (!session.isCurrent) return;
  final database = db;
  final owner = database.forProfile(database.profileId);
  final history = MusicListeningHistory.forProfile(database, owner.profileId);
  final locals = AppLocalizations.of(context)!;
  final route = ModalRoute.of(context);
  bool sessionCurrent() => identical(db, database) && session.isCurrent;
  bool active() =>
      context.mounted && sessionCurrent() && (route?.isCurrent ?? true);

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
          leading: const Icon(Icons.file_upload_outlined),
          title: Text(locals.musicSpotifyHistoryImport),
          onTap: () => Navigator.pop(context, _Transfer.importSpotify),
        ),
        ListTile(
          leading: const Icon(Icons.file_download_outlined),
          title: Text(locals.musicHistoryExport),
          onTap: () => Navigator.pop(context, _Transfer.export),
        ),
        ListTile(
          leading: const Icon(Icons.file_download_outlined),
          title: Text(locals.musicHistoryExportPlayCounts),
          onTap: () => Navigator.pop(context, _Transfer.exportCsv),
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
    if (action == _Transfer.export || action == _Transfer.exportCsv) {
      final isCsv = action == _Transfer.exportCsv;
      final text = await compute(
        isCsv
            ? MusicHistoryTransfer.encodePlayCountsCsv
            : MusicHistoryTransfer.encode,
        history.events(),
      );
      if (!active()) return;
      final date = DateTime.now().toIso8601String().split('T').first;
      final saved = await files.invokeMethod<bool>('save', {
        'name': isCsv
            ? 'videre-music-play-counts-$date.csv'
            : 'videre-music-history-$date.json',
        'text': text,
        if (isCsv) 'mimeType': 'text/csv',
      });
      if (saved == true) {
        notify(
          isCsv
              ? locals.musicHistoryPlayCountsExported
              : locals.musicHistoryExported,
        );
      }
      return;
    }

    final text = await files.invokeMethod<String>('open');
    if (!context.mounted || text == null || !active()) return;
    if (action == _Transfer.importSpotify) {
      Future<SpotifyMusicHistoryPreview> preparePreview() async {
        final events = history.events();
        final candidates = await spotifyMusicHistoryCandidates(
          owner,
          session.library,
          events: events,
          isCurrent: sessionCurrent,
        );
        if (!sessionCurrent()) throw StateError('The active profile changed.');
        return compute(SpotifyMusicHistoryImport.preview, (
          text: text,
          candidates: candidates,
          existingEventIds: events.map((event) => event.id).toSet(),
        ));
      }

      final approved = await showMusicSpotifyHistoryPreview(
        context,
        session.app,
        sessionCurrent,
        preparePreview,
      );
      if (approved == null || !active()) return;
      final added = await history.merge(approved);
      notify(locals.musicHistoryImported(added, approved.length - added));
      return;
    }
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
      'INVALID_UTF8' => action == _Transfer.importSpotify
          ? locals.musicSpotifyHistoryInvalidFile
          : locals.musicHistoryFileInvalid,
      _ => locals.musicHistoryTransferFailed,
    });
  } catch (_) {
    notify(locals.musicHistoryTransferFailed);
  }
}
