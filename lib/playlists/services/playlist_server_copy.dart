import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../globals.dart' as globals;
import '../../player/models/local_music_playback.dart';
import '../../service.dart';
import '../../settings/models/db/server.dart';
import '../../settings/models/db/settings.dart';
import '../../settings/models/errors/invidious_service_error.dart';
import '../../utils/interfaces/db.dart';
import '../../utils/sembast_sqflite_database.dart';
import '../../videos/services/watch_history.dart';
import '../models/playlist.dart';
import '../models/playlist_reference.dart';
import 'playlist_load_session.dart';

sealed class PlaylistCopyNeedsConfirmation implements Exception {
  final String id;
  const PlaylistCopyNeedsConfirmation(this.id);
}

class PlaylistCreationUnconfirmed extends PlaylistCopyNeedsConfirmation {
  const PlaylistCreationUnconfirmed(super.id);
}

class PlaylistCopyMissing extends PlaylistCopyNeedsConfirmation {
  const PlaylistCopyMissing(super.id);
}

class PlaylistTrackSaveFailure implements Exception {
  final int index;
  final int? statusCode;

  const PlaylistTrackSaveFailure(this.index, this.statusCode);
}

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

  Future<int> _readSavedCount(String destination, List<String> ids) async {
    await _assertCurrent();
    var saved = 0;
    int? declaredCount;
    for (var page = 1; page <= PlaylistLoadSession.maximumPages; page++) {
      final Playlist remote;
      try {
        remote = await client.getServerPlaylist(destination,
            page: page, serverOverride: server);
      } on InvidiousServiceError catch (error) {
        if (page != 1 ||
            error.statusCode != 404 ||
            error.isGatewayAccessFailure ||
            error.responseWasHtml) {
          rethrow;
        }
        await _assertCurrent();
        throw PlaylistCopyMissing(destination);
      }
      await _assertCurrent();
      declaredCount ??= remote.videoCount;
      if (remote.playlistId != destination ||
          remote.videoCount != declaredCount ||
          remote.videoCount > ids.length ||
          saved + remote.videos.length > remote.videoCount) {
        throw StateError('The server copy has been changed');
      }
      for (final video in remote.videos) {
        if (video.videoId != ids[saved]) {
          throw StateError('The server copy has been changed');
        }
        saved++;
      }
      if (saved == remote.videoCount) return saved;
      if (remote.videos.isEmpty) break;
    }
    throw StateError('Could not read the complete server copy');
  }

  Future<String> save(
      {void Function(int, int)? onProgress,
      PlaylistCopyNeedsConfirmation? confirmedReplacement}) async {
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
      if (ids.any(isLocalMusicPlaybackId)) {
        throw StateError('Device files can only be saved in local playlists');
      }
      if (ids.length != playlist.videoCount) {
        throw StateError('Load every playlist video before saving a copy');
      }
      final stored = database.getSettings(_checkpointKey)?.value;
      final record = stored == null ? null : jsonDecode(stored);
      String? destination;
      int? existing;
      if (record is Map &&
          record['title'] == playlist.title &&
          record['videos'] is List &&
          listEquals(record['videos'] as List, ids)) {
        destination = record['playlistId'] as String?;
        final attempt = record['pendingCreate'];
        if (attempt is String &&
            !(confirmedReplacement is PlaylistCreationUnconfirmed &&
                confirmedReplacement.id == attempt)) {
          throw PlaylistCreationUnconfirmed(attempt);
        }
      }
      if (destination != null) {
        try {
          existing = await _readSavedCount(destination, ids);
        } on PlaylistCopyMissing {
          // Recheck before replacing: the private destination might be
          // accessible again or another screen may already have replaced it.
          if (confirmedReplacement is! PlaylistCopyMissing ||
              confirmedReplacement.id != destination) {
            rethrow;
          }
          destination = null;
        }
      }
      if (destination == null) {
        Future<void> checkpoint(String field, String value) =>
            database.saveSetting(SettingsValue(
                _checkpointKey,
                jsonEncode({
                  'title': playlist.title,
                  'videos': ids,
                  field: value,
                })));
        // Creation has no idempotency key. Remember the attempt before the
        // POST so a second screen or app restart cannot silently send it again.
        final attempt = const Uuid().v4();
        await checkpoint('pendingCreate', attempt);
        await _assertCurrent();
        try {
          destination = await client.createServerPlaylist(
              playlist.title, 'private', server);
        } catch (_) {
          throw PlaylistCreationUnconfirmed(attempt);
        }
        await checkpoint('playlistId', destination);
      }
      var saved = existing ?? await _readSavedCount(destination, ids);
      var recoveredServerError = false;
      onProgress?.call(saved, ids.length);
      while (saved < ids.length) {
        await _assertCurrent();
        try {
          await client.addVideoToServerPlaylist(
              destination, ids[saved], server);
          saved++;
        } on InvidiousServiceError catch (error) {
          if (recoveredServerError ||
              error.statusCode != 500 ||
              error.isGatewayAccessFailure ||
              error.responseWasHtml) {
            throw PlaylistTrackSaveFailure(saved, error.statusCode);
          }
          recoveredServerError = true;
          // A failed response may follow a committed insert. Reconcile once
          // against this account before deciding whether to send the track.
          final verified = await _readSavedCount(destination, ids);
          if (verified != saved && verified != saved + 1) {
            throw StateError('The server copy has been changed');
          }
          saved = verified;
        } on Exception {
          throw PlaylistTrackSaveFailure(saved, null);
        }
        onProgress?.call(saved, ids.length);
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
