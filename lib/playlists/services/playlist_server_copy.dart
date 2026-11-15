import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../globals.dart' as globals;
import '../../service.dart';
import '../../settings/models/db/server.dart';
import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';
import '../../utils/sembast_sqflite_database.dart';
import '../../videos/services/watch_history.dart';
import '../models/playlist.dart';
import '../models/playlist_reference.dart';
import 'playlist_load_session.dart';

class PlaylistCreationUnconfirmed implements Exception {}

/// A copy resumes against the server's actual prefix after a lost response.
/// Its checkpoint contains only playlist identities, never credentials.
class PlaylistServerCopy {
  static final _writes = Expando<Map<String, Future<void>>>();
  final IDbClient database;
  final Service client;
  final Playlist playlist;
  final PlaylistReference reference;
  final Server server;
  final bool Function() ownerIsActive;

  PlaylistServerCopy({
    required this.database,
    required this.client,
    required this.playlist,
    required this.reference,
    required this.server,
    bool Function()? ownerIsActive,
  }) : ownerIsActive =
            ownerIsActive ?? (() => globals.db.profileId == database.profileId);

  String get _checkpointKey => 'playlist-server-copy:${jsonEncode([
            reference.key,
            server.accountId,
            Uri.parse(server.url).origin,
          ])}';

  Future<void> _assertCurrent() async {
    if (!ownerIsActive() ||
        !hasHistoryAccount(server) ||
        database.profileId != server.profileId ||
        reference.profileId != database.profileId ||
        reference.playlistId != playlist.playlistId) {
      throw StateError('The playlist account is unavailable');
    }
    final current = await database.getCurrentlySelectedServer();
    if (!ownerIsActive() ||
        current.accountId != server.accountId ||
        current.url != server.url ||
        current.profileId != server.profileId ||
        current.authToken != server.authToken ||
        current.sidCookie != server.sidCookie) {
      throw StateError('The playlist account has changed');
    }
  }

  Future<String> save({void Function(int, int)? onProgress}) async {
    final db = database;
    final key = db is SembastSqfDb ? db.db : db;
    final writes = _writes[key] ??= {};
    final previous = writes[_checkpointKey];
    final complete = Completer<void>();
    writes[_checkpointKey] = complete.future;
    try {
      await previous;
      await _assertCurrent();
      final ids = playlist.videos.map((video) => video.videoId).toList();
      if (ids.length != playlist.videoCount) {
        throw StateError('Load every playlist video before saving a copy');
      }
      final stored = database.getSettings(_checkpointKey)?.value;
      final record = stored == null ? null : jsonDecode(stored);
      String? destination;
      if (record is Map &&
          record['title'] == playlist.title &&
          record['videos'] is List &&
          listEquals(record['videos'] as List, ids)) {
        destination = record['playlistId'] as String?;
      }
      if (destination == null) {
        await _assertCurrent();
        try {
          destination = await client.createServerPlaylist(
              playlist.title, 'private', server);
        } catch (_) {
          // POST creation has no idempotency key. Do not automatically retry it.
          throw PlaylistCreationUnconfirmed();
        }
        await database.saveSetting(SettingsValue(
            _checkpointKey,
            jsonEncode({
              'title': playlist.title,
              'videos': ids,
              'playlistId': destination,
            })));
      }
      await _assertCurrent();
      final existing = <String>[];
      for (var page = 1; page <= PlaylistLoadSession.maximumPages; page++) {
        final remote = await client.getServerPlaylist(destination,
            page: page, serverOverride: server);
        await _assertCurrent();
        if (remote.playlistId != destination ||
            existing.length + remote.videos.length > ids.length) {
          throw StateError('The server copy has been changed');
        }
        existing.addAll(remote.videos.map((video) => video.videoId));
        if (existing.length >= remote.videoCount) break;
        if (remote.videos.isEmpty || page == PlaylistLoadSession.maximumPages) {
          throw StateError('Could not read the complete server copy');
        }
      }
      if (!listEquals(existing, ids.take(existing.length).toList())) {
        throw StateError('The server copy has been changed');
      }
      onProgress?.call(existing.length, ids.length);
      for (var index = existing.length; index < ids.length; index++) {
        await _assertCurrent();
        await client.addVideoToServerPlaylist(destination, ids[index], server);
        onProgress?.call(index + 1, ids.length);
      }
      return destination;
    } finally {
      complete.complete();
      if (identical(writes[_checkpointKey], complete.future)) {
        writes.remove(_checkpointKey);
      }
    }
  }
}
