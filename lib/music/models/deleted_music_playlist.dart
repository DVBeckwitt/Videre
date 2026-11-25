import 'dart:convert';

import 'package:clipious/playlists/models/playlist.dart';

const deletedMusicPlaylistsSetting = 'music-deleted-playlists-v1';
const musicPlaylistRecoveryRetention = Duration(days: 30);

class DeletedMusicPlaylist {
  final Playlist playlist;
  final String deletionId;
  final DateTime deletedAt;

  /// Position among both active playlists and other recoverable playlists.
  final int position;

  const DeletedMusicPlaylist(
      {required this.playlist,
      required this.deletionId,
      required this.deletedAt,
      required this.position});

  DateTime get expiresAt => deletedAt.add(musicPlaylistRecoveryRetention);

  DeletedMusicPlaylist atPosition(int position) => DeletedMusicPlaylist(
      playlist: playlist,
      deletionId: deletionId,
      deletedAt: deletedAt,
      position: position);

  static List<DeletedMusicPlaylist> decode(String? stored) {
    if (stored == null) return [];
    try {
      final rows = jsonDecode(stored);
      if (rows is List) {
        return rows.map(tryParse).nonNulls.toList()
          ..sort((a, b) => a.position.compareTo(b.position));
      }
    } on FormatException {
      // A damaged archive must not prevent using active playlists.
    }
    return [];
  }

  static DeletedMusicPlaylist? tryParse(Object? row) {
    if (row
        case {
          'playlist': final Map<String, dynamic> json,
          'deletionId': final String deletionId,
          'deletedAt': final String timestamp,
          'position': final int position,
        } when position >= 0) {
      final deletedAt = DateTime.tryParse(timestamp);
      if (deletedAt == null) return null;
      try {
        final playlist = Playlist.fromJson(json);
        if (playlist.isLocal && playlist.playlistId != localWatchLaterId) {
          return DeletedMusicPlaylist(
              playlist: playlist,
              deletionId: deletionId,
              deletedAt: deletedAt,
              position: position);
        }
      } on TypeError {
        // A damaged row must not hide other recoverable playlists.
      } on FormatException {
        // A damaged row must not hide other recoverable playlists.
      }
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        'playlist': playlist.toJson(),
        'deletionId': deletionId,
        'deletedAt': deletedAt.toUtc().toIso8601String(),
        'position': position,
      };
}
