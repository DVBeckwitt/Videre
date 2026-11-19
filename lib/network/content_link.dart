import '../globals.dart' show youtubeHosts, youtubeMusicHost;
import '../settings/models/db/server.dart';
import '../utils/models/sharelink.dart';

enum ContentLinkKind { video, channel, playlist, search, home, unresolved }

enum PastedLinkAction { handled, searchAsText, unrecognized }

/// Interprets incoming links as content identifiers.
class ContentLink {
  final ContentLinkKind kind;
  final String id;
  final bool music;
  final String? timestamp;

  const ContentLink._(this.kind, this.id, this.music, [this.timestamp]);

  /// Explicit link positions override saved progress only when supplied.
  Duration? get startAt {
    final value = timestamp;
    if (value == null) return null;
    final seconds = int.tryParse(value);
    if (seconds != null) return Duration(seconds: seconds);
    final parts = RegExp(r'(\d+)([hms])').allMatches(value);
    return Duration(
        seconds: parts.fold(0, (sum, part) {
      final multiplier = switch (part[2]) {
        'h' => 3600,
        'm' => 60,
        _ => 1,
      };
      return sum + int.parse(part[1]!) * multiplier;
    }));
  }

  static final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');
  static final _channelId = RegExp(r'^UC[A-Za-z0-9_-]{22}$');
  static final _playlistId =
      RegExp(r'^(?:PL|OLAK5uy_|RD|UU|LL|FL)[A-Za-z0-9_-]+$');
  static final _musicPlaylistId =
      RegExp(r'^(?:VL)?(?:PL|OLAK5uy_|RD)[A-Za-z0-9_-]+$');
  static final _timestamp = RegExp(r'^(?:\d{1,9}|(?:\d{1,6}[hms]){1,3})$');
  static final _address = RegExp(
      r'(?<![\w@.:/-])(?:https?:\/\/|\/\/)?(?:[\w-]+\.)+[\w-]+\.?[^\s<>"\x27]*',
      caseSensitive: false);
  static final _httpScheme = RegExp(r'^https?://', caseSensitive: false);
  static final _invalidAddressCharacter =
      RegExp(r'''[\s\x00-\x1f\x7f<>"'\\]''');
  static final _trailingPunctuation = RegExp(r'[.,!?;:)\]]+$');

  // Paste handling matches one complete address. In a share, the sender may
  // include titles or other text around the address, so scan whole tokens.
  static ContentLink? parseAddress(String address,
      {Server? server, bool allowLandingFallback = false}) {
    final uri = completeWebAddress(address);
    return uri == null
        ? null
        : parse(uri,
            server: server, allowLandingFallback: allowLandingFallback);
  }

  /// Recognizes a complete address locally, including an explicit URL for a
  /// self-hosted instance. Search can skip remote suggestions before submit.
  static Uri? completeWebAddress(String address) {
    final text = address.trim();
    if (_invalidAddressCharacter.hasMatch(text)) return null;
    if (!_httpScheme.hasMatch(text)) {
      final match = _address.matchAsPrefix(text);
      if (match == null || match.end != text.length) return null;
    }
    try {
      final uri = _addressUri(text);
      if (uri == null || uri.host.isEmpty || uri.port > 65535) return null;
      return uri;
    } on FormatException {
      return null;
    }
  }

  static ContentLink? firstInText(String text,
      {Server? server, bool allowLandingFallback = false}) {
    ContentLink? landing;
    for (final address in webAddressesIn(text)) {
      final link = parse(address.uri,
          server: server, allowLandingFallback: allowLandingFallback);
      if (link?.kind == ContentLinkKind.home) {
        landing ??= link;
      } else if (link != null) {
        return link;
      }
    }
    return landing;
  }

  /// Candidate spans for shares and readable descriptions. The entire token
  /// is kept together so a lookalike host or redirect URL cannot be mistaken
  /// for a nested YouTube address.
  static Iterable<({Uri uri, int start, int end})> webAddressesIn(
      String text) sync* {
    for (final match in _address.allMatches(text)) {
      final address = match.group(0)!.replaceFirst(_trailingPunctuation, '');
      final uri = _addressUri(address);
      if (uri != null) {
        yield (uri: uri, start: match.start, end: match.start + address.length);
      }
    }
  }

  static Uri? _addressUri(String address) => Uri.tryParse(
        _httpScheme.hasMatch(address)
            ? address
            : address.startsWith('//')
                ? 'https:$address'
                : 'https://$address',
      );

  static ContentLink? parse(Uri uri,
      {Server? server,
      bool allowLandingFallback = false,
      bool instanceMusic = false}) {
    final host = uri.host.replaceFirst(RegExp(r'\.+$'), '');
    if (!const {'http', 'https'}.contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.authority.contains('@')) {
      return null;
    }
    try {
      if (youtubeHosts.contains(host)) {
        if (uri.port != (uri.scheme == 'https' ? 443 : 80)) return null;
        return _parseContent(uri, host) ??
            (allowLandingFallback
                ? ContentLink._(
                    ContentLinkKind.home, '', host == youtubeMusicHost)
                : null);
      }
      if (server == null) return null;
      final base = Uri.parse(server.url);
      if (!const {'http', 'https'}.contains(base.scheme) ||
          base.scheme != uri.scheme ||
          base.host != uri.host ||
          base.port != uri.port ||
          youtubeHosts.contains(base.host)) {
        return null;
      }
      final prefix =
          base.pathSegments.where((part) => part.isNotEmpty).toList();
      final parts = uri.pathSegments;
      if (parts.length <= prefix.length) return null;
      for (var index = 0; index < prefix.length; index++) {
        if (parts[index] != prefix[index]) return null;
      }
      // A selected instance is an identifier source, never a new server choice.
      return _parseContent(
              uri.replace(pathSegments: parts.sublist(prefix.length)),
              'youtube.com')
          ?._forInstanceSearch(instanceMusic);
    } on FormatException {
      return null;
    }
  }

  /// An unfamiliar site can supply an explicit content ID for confirmation.
  /// Only canonical content paths qualify, never redirects or resolver input.
  static ContentLink? unfamiliarInstanceContent(Uri uri,
      {required bool music}) {
    if (!const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.authority.contains('@') ||
        youtubeHosts.contains(uri.host.replaceFirst(RegExp(r'\.+$'), ''))) {
      return null;
    }
    try {
      final parts = uri.pathSegments;
      if (parts.isEmpty ||
          !const {'watch', 'channel', 'playlist'}.contains(parts.first)) {
        return null;
      }
      return _parseContent(uri, 'youtube.com')?._forInstanceSearch(music);
    } on FormatException {
      return null;
    }
  }

  ContentLink _forInstanceSearch(bool preferMusic) {
    // Automatic upload/liked-video playlists have a Videos destination only.
    if (!preferMusic ||
        (kind == ContentLinkKind.playlist && !_musicPlaylistId.hasMatch(id))) {
      return this;
    }
    return ContentLink._(kind, id, true, timestamp);
  }

  static ContentLink? _parseContent(Uri uri, String host, [int depth = 0]) {
    final music = host == youtubeMusicHost;
    final parts = uri.pathSegments.toList();
    if (parts.isNotEmpty && parts.last.isEmpty) parts.removeLast();
    final query = uri.queryParameters;
    if (host != 'youtu.be' &&
        parts.length == 1 &&
        parts.single == 'attribution_link') {
      if (depth >= 2) return null;
      final wrapped = query['u'];
      if (wrapped == null || wrapped.length > 4096) return null;
      final target = Uri.tryParse(wrapped);
      if (target == null ||
          target.hasScheme ||
          target.hasAuthority ||
          !target.path.startsWith('/') ||
          target.path.startsWith('//')) {
        return null;
      }
      return _parseContent(
          uri.replace(
              path: target.path,
              query: target.query,
              fragment: target.fragment),
          host,
          depth + 1);
    }
    final channelParts = parts.length == 3 &&
            const {
              'videos',
              'shorts',
              'streams',
              'playlists',
              'featured',
              'about'
            }.contains(parts.last)
        ? parts.sublist(0, 2)
        : parts;
    if (channelParts.length == 2 &&
        host != 'youtu.be' &&
        (channelParts.first == 'channel' ||
            (music && channelParts.first == 'browse')) &&
        _channelId.hasMatch(channelParts.last)) {
      return ContentLink._(ContentLinkKind.channel, channelParts.last, music);
    }
    if (host != 'youtu.be' &&
        ((parts.length == 1 && parts.single == 'playlist') ||
            (parts.length == 2 &&
                parts.first == 'embed' &&
                parts.last == 'videoseries') ||
            (music &&
                parts.length == 2 &&
                parts.first == 'browse' &&
                parts.last.startsWith('VL')))) {
      final id = music && parts.first == 'browse' ? parts.last : query['list'];
      final format = music ? _musicPlaylistId : _playlistId;
      return id != null && id.length <= 200 && format.hasMatch(id)
          ? ContentLink._(ContentLinkKind.playlist, id, music)
          : null;
    }
    if (host != 'youtu.be' &&
        parts.length == 1 &&
        const {'results', 'search'}.contains(parts.single)) {
      final text = (query['search_query'] ?? query['q'])?.trim();
      if (text != null && text.isNotEmpty && text.length <= 2000) {
        return ContentLink._(ContentLinkKind.search, text, music);
      }
    }
    final alias = parts.isNotEmpty &&
            parts.first.startsWith('@') &&
            (parts.length == 1 ||
                (parts.length == 2 &&
                    const {
                      'videos',
                      'shorts',
                      'streams',
                      'playlists',
                      'featured',
                      'about'
                    }.contains(parts.last)))
        ? [parts.first]
        : channelParts.length == 2 &&
                const {'c', 'user'}.contains(channelParts.first)
            ? channelParts
            : null;
    final opaque = parts.length == 2 &&
        (parts.first == 'clip' ||
            (music &&
                parts.first == 'browse' &&
                parts.last.startsWith('MPRE')));
    final resolverParts = alias ?? (opaque ? parts : null);
    if (host != 'youtu.be' &&
        resolverParts != null &&
        resolverParts.last.length <= 200 &&
        resolverParts.last.isNotEmpty &&
        !RegExp(r'[/\\\x00-\x20\x7f]').hasMatch(resolverParts.last) &&
        resolverParts.last != '@') {
      return ContentLink._(
          ContentLinkKind.unresolved,
          Uri(scheme: 'https', host: host, pathSegments: resolverParts)
              .toString(),
          music,
          _parseTimestamp(uri));
    }
    final id = switch (parts) {
      [final id] when host == 'youtu.be' => id,
      ['shorts' || 'live' || 'embed' || 'v', final id]
          when host != 'youtu.be' =>
        id,
      ['watch'] => query['v'],
      _ => null,
    };
    if (id == null || !_videoId.hasMatch(id)) return null;
    return ContentLink._(
        ContentLinkKind.video, id, music, _parseTimestamp(uri));
  }

  static String? _parseTimestamp(Uri uri) {
    final fragment = uri.fragment;
    for (final value in [
      uri.queryParameters['t'],
      uri.queryParameters['start'],
      uri.queryParameters['time_continue'],
      fragment.startsWith('t=') ? fragment.substring(2) : null
    ]) {
      if (value != null && _timestamp.hasMatch(value)) return value;
    }
    return null;
  }

  ContentLink get landing => ContentLink._(ContentLinkKind.home, '', music);

  /// Resolver output is untrusted metadata, never a new transport URL.
  static ContentLink? fromResolution(ContentLink original, dynamic payload) {
    if (original.kind != ContentLinkKind.unresolved || payload is! Map) {
      return null;
    }
    final video = payload['videoId'];
    if (video is String && _videoId.hasMatch(video)) {
      final start = payload['startTimeSeconds'];
      final timestamp = start is int && start >= 0 && start <= 999999999
          ? '$start'
          : start is String && RegExp(r'^\d{1,9}$').hasMatch(start)
              ? start
              : null;
      return ContentLink._(ContentLinkKind.video, video, original.music,
          original.timestamp ?? timestamp);
    }
    for (final channel in [payload['ucid'], payload['browseId']]) {
      if (channel is String && _channelId.hasMatch(channel)) {
        return ContentLink._(ContentLinkKind.channel, channel, original.music);
      }
    }
    final playlist = payload['playlistId'];
    final format = original.music ? _musicPlaylistId : _playlistId;
    if (playlist is String &&
        playlist.length <= 200 &&
        format.hasMatch(playlist)) {
      return ContentLink._(ContentLinkKind.playlist, playlist, original.music);
    }
    return null;
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
        ContentLinkKind.search => invidiousShareLink(server,
            pathSegments: ['search'], queryParameters: {'q': id}),
        ContentLinkKind.home => invidiousShareLink(server, pathSegments: []),
        ContentLinkKind.unresolved =>
          throw const FormatException('This link requires instance resolution'),
      };
}
