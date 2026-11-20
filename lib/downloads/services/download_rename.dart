import 'dart:async';

import '../../globals.dart';
import '../../utils/interfaces/db.dart';
import '../../utils/sembast_sqflite_database.dart';

final _downloadRenames =
    StreamController<({IDbClient database, Set<String> profiles})>.broadcast();

/// Changes to the device-local download references after a provider rename.
Stream<({IDbClient database, Set<String> profiles})>
    get localMusicDownloadRenames => _downloadRenames.stream;

/// Invoked for a committed native rename, including journal recovery on startup.
Future<void> reconcileLocalMusicDownloadRename(
    String oldUri, String newUri) async {
  if (oldUri == newUri) return;
  final database = db;
  if (database is! SembastSqfDb) return;
  final profiles =
      await database.reconcileDownloadedDocumentRename(oldUri, newUri);
  if (profiles.isNotEmpty) {
    _downloadRenames.add((database: database, profiles: profiles));
  }
}
