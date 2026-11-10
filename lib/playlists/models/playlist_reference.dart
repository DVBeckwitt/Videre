import 'dart:convert';

import '../../settings/models/db/server.dart';
import '../../utils/interfaces/db.dart';
import '../../videos/models/video.dart';
import 'playlist.dart';

enum PlaylistSourceKind { public, local, account }

/// A playlist's identity is distinct from the backend used to read YouTube.
/// Instance playlists retain the exact account that owns their access.
class PlaylistReference {
  final PlaylistSourceKind kind;
  final String playlistId;
  final String profileId;
  final String? accountId;
  final String? origin;

  const PlaylistReference({
    required this.kind,
    required this.playlistId,
    required this.profileId,
    this.accountId,
    this.origin,
  });

  factory PlaylistReference.forPlaylist(Playlist playlist, IDbClient database,
      {Server? server}) {
    final id = playlist.playlistId;
    final publicId = RegExp(r'^(PL|UU|LL|FL|RD|OLAK5uy_|WL)').hasMatch(id);
    final kind = playlist.isLocal
        ? PlaylistSourceKind.local
        : id.startsWith('IVP') ||
                (playlist.type == invidiousPlaylist && !publicId)
            ? PlaylistSourceKind.account
            : PlaylistSourceKind.public;
    if (kind == PlaylistSourceKind.account &&
        (server == null || server.profileId != database.profileId)) {
      throw StateError('The playlist account is unavailable');
    }
    return PlaylistReference.fromJson({
      'kind': kind.name,
      'playlistId': id,
      'profileId': database.profileId,
      if (kind == PlaylistSourceKind.account) ...{
        'accountId': server!.accountId,
        'origin': _origin(server.url),
      },
    });
  }

  factory PlaylistReference.fromJson(Map<String, dynamic> json) =>
      tryParse(json) ??
      (throw const FormatException('Invalid playlist source'));

  static PlaylistReference? tryParse(Object? value) {
    if (value is! Map) return null;
    final kind = PlaylistSourceKind.values
        .where((kind) => kind.name == value['kind'])
        .firstOrNull;
    final id = value['playlistId'];
    final profile = value['profileId'];
    if (kind == null ||
        id is! String ||
        !RegExp(r'^(local:)?[A-Za-z0-9_-]{1,256}$').hasMatch(id) ||
        !_identifier(profile)) {
      return null;
    }
    final account = value['accountId'];
    final origin = value['origin'];
    if (kind == PlaylistSourceKind.local && !id.startsWith('local:')) {
      return null;
    }
    if (kind != PlaylistSourceKind.local && id.startsWith('local:')) {
      return null;
    }
    if (kind == PlaylistSourceKind.public && id.startsWith('IVP')) return null;
    if (kind == PlaylistSourceKind.account) {
      if (!_identifier(account) || origin is! String) return null;
      final canonical = _origin(origin);
      if (canonical == null || canonical != origin) return null;
      return PlaylistReference(
          kind: kind,
          playlistId: id,
          profileId: profile as String,
          accountId: account as String,
          origin: canonical);
    }
    if (account != null || origin != null) return null;
    return PlaylistReference(
        kind: kind, playlistId: id, profileId: profile as String);
  }

  static bool _identifier(Object? value) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= 2048 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

  static String? _origin(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    return uri.origin;
  }

  String get key =>
      jsonEncode([kind.name, profileId, playlistId, accountId, origin]);

  bool matchesOwner(IDbClient database) => database.profileId == profileId;

  /// A removed account must never redirect to another account at the same URL.
  Server? resolveServer(IDbClient database) {
    if (!matchesOwner(database)) {
      throw StateError('The playlist belongs to another profile');
    }
    if (kind != PlaylistSourceKind.account) return null;
    final server = database.getAccount(accountId!);
    if (server == null || _origin(server.url) != origin) {
      throw StateError('The playlist account is unavailable');
    }
    return server;
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'playlistId': playlistId,
        'profileId': profileId,
        if (accountId != null) 'accountId': accountId,
        if (origin != null) 'origin': origin,
      };

  @override
  bool operator ==(Object other) =>
      other is PlaylistReference && key == other.key;

  @override
  int get hashCode => key.hashCode;
}

/// Only server occurrence metadata can identify overlap between fetched pages.
/// Video IDs alone cannot: the same upload may occur repeatedly in a playlist.
String? playlistSourceEntryId(Video video) {
  final id = video.indexId;
  if (id != null && id.isNotEmpty) {
    return 'playlist:${jsonEncode(['id', id, video.videoId])}';
  }
  final index = video.index;
  if (index != null && index >= 0) {
    return 'playlist:${jsonEncode(['index', index, video.videoId])}';
  }
  return null;
}

/// Run on the cumulative ordered list when source entries have no index data.
List<Video> assignPlaylistEntryIds(Iterable<Video> videos) {
  final counts = <String, int>{};
  final used = <String>{};
  return videos.map((video) {
    final occurrence =
        counts.update(video.videoId, (value) => value + 1, ifAbsent: () => 0);
    final proposed = video.queueEntryId ??
        playlistSourceEntryId(video) ??
        'playlist:${jsonEncode(['video', video.videoId, occurrence])}';
    var id = proposed;
    var collision = 0;
    while (!used.add(id)) {
      id = '$proposed#${++collision}';
    }
    return video.queueEntryId == id ? video : video.copyWith(queueEntryId: id);
  }).toList();
}
