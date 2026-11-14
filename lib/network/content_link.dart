import '../globals.dart' show youtubeHosts, youtubeMusicHost;
import '../settings/models/db/server.dart';
import '../utils/models/sharelink.dart';

enum ContentLinkKind { video, channel, playlist }

/// Interprets incoming links as content identifiers.
class ContentLink {
  final ContentLinkKind kind;
  final String id;
  final bool music;
  final String? timestamp;

  const ContentLink._(this.kind, this.id, this.music, [this.timestamp]);

  static final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');
  static final _channelId = RegExp(r'^UC[A-Za-z0-9_-]{22}$');
  static final _playlistId =
      RegExp(r'^(?:PL|OLAK5uy_|RD|UU|LL|FL)[A-Za-z0-9_-]+$');
  static final _musicPlaylistId =
      RegExp(r'^(?:VL)?(?:PL|OLAK5uy_|RD)[A-Za-z0-9_-]+$');
  static final _timestamp = RegExp(r'^(?:\d{1,9}|(?:\d{1,6}[hms]){1,3})$');

  static ContentLink? parse(Uri uri) {
    final host = uri.host.replaceFirst(RegExp(r'\.+$'), '');
    if (!const {'http', 'https'}.contains(uri.scheme) ||
        !youtubeHosts.contains(host) ||
        uri.userInfo.isNotEmpty ||
        uri.authority.contains('@')) {
      return null;
    }
    try {
      return _parseContent(uri, host);
    } on FormatException {
      return null;
    }
  }

  static ContentLink? _parseContent(Uri uri, String host) {
    final music = host == youtubeMusicHost;
    final parts = uri.pathSegments;
    final query = uri.queryParameters;
    if (parts.length == 2 &&
        host != 'youtu.be' &&
        (parts.first == 'channel' || (music && parts.first == 'browse')) &&
        _channelId.hasMatch(parts.last)) {
      return ContentLink._(ContentLinkKind.channel, parts.last, music);
    }
    if (parts.length != 1) return null;
    final path = parts.single;
    if (host != 'youtu.be' && path == 'playlist') {
      final id = query['list'];
      final format = music ? _musicPlaylistId : _playlistId;
      return id != null && id.length <= 200 && format.hasMatch(id)
          ? ContentLink._(ContentLinkKind.playlist, id, music)
          : null;
    }
    final id = host == 'youtu.be'
        ? path
        : path == 'watch'
            ? query['v']
            : null;
    if (id == null || !_videoId.hasMatch(id)) return null;
    final time = query['t'];
    return ContentLink._(ContentLinkKind.video, id, music,
        time != null && _timestamp.hasMatch(time) ? time : null);
  }

  Uri invidiousUrl(Server server) => switch (kind) {
        ContentLinkKind.video => invidiousShareLink(server, pathSegments: [
            'watch'
          ], queryParameters: {
            'v': id,
            if (timestamp != null) 't': timestamp!,
          }),
        ContentLinkKind.channel =>
          invidiousShareLink(server, pathSegments: ['channel', id]),
        ContentLinkKind.playlist => invidiousShareLink(server, pathSegments: [
            'playlist'
          ], queryParameters: {
            'list': music && id.startsWith('VL') ? id.substring(2) : id
          }),
      };
}
