import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:videre_proxy/videre_proxy.dart';

import '../../network/gateway_context.dart';
import '../../network/youtube_privacy.dart';
import '../../settings/models/db/server.dart';
import '../../videos/models/music_metadata.dart';
import '../../videos/models/video.dart';
import '../../player/media_source.dart';

final _digest = RegExp(r'^[0-9a-f]{64}$');
final _contentId = RegExp(r'^[a-zA-Z0-9_-]{1,128}$');

Map<String, Object?>? _owner(Server server) {
  final url = parseMediaUrl(server.url);
  if (url == null ||
      server.profileId.isEmpty ||
      server.accountId.isEmpty ||
      server.profileId.length > 4096 ||
      server.accountId.length > 4096) {
    return null;
  }
  final uri = Uri.parse(url);
  if (isOfficialYoutubeUrl(uri)) return null;
  final gateway = GatewayRequestContext.forAccount(
      server.profileId, server.accountId, server.url);
  return {
    'profileId': server.profileId,
    'accountId': server.accountId,
    'origin': uri.origin,
    if (gateway != null) 'gatewayContext': gateway.encoded,
  };
}

String? cachedMusicOwner(Server server) {
  final owner = _owner(server);
  if (owner == null) return null;
  return sha256
      .convert(utf8.encode(jsonEncode([
        owner['profileId'],
        owner['accountId'],
        owner['origin'],
      ])))
      .toString();
}

class CachedMusicSong {
  final String videoId;
  final String title;
  final String artist;
  final int lengthSeconds;
  final String rendition;

  const CachedMusicSong({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.lengthSeconds,
    required this.rendition,
  });

  static CachedMusicSong? _parse(Object? value) {
    if (value
        case {
          'videoId': final String id,
          'title': final String title,
          'artist': final String artist,
          'lengthSeconds': final int seconds,
          'rendition': final String rendition,
        }
        when _contentId.stringMatch(id) == id &&
            title.trim().isNotEmpty &&
            seconds > 0 &&
            _digest.stringMatch(rendition) == rendition) {
      return CachedMusicSong(
          videoId: id,
          title: title,
          artist: artist,
          lengthSeconds: seconds,
          rendition: rendition);
    }
    return null;
  }

  Video playbackEntry(String owner) => Video(
        videoId: videoId,
        title: title,
        author: artist,
        lengthSeconds: lengthSeconds,
        musicMetadata: MusicMetadata(title: title, artist: artist),
        playbackSourceId: CachedMusicPlayback(owner, rendition),
      );
}

Future<List<CachedMusicSong>> listCachedMusicSongs(Server server) async {
  final owner = _owner(server);
  if (owner == null) return const [];
  final values = await PlaybackCache.cachedMusicSongs(owner);
  final songs = <String, CachedMusicSong>{};
  for (final value in values) {
    final song = CachedMusicSong._parse(value);
    if (song != null) songs.putIfAbsent(song.videoId, () => song);
  }
  return songs.values.toList();
}

/// A cache-only occurrence retains its owner and rendition when copied or
/// restored. The native cache separately checks the current disk bytes.
class CachedMusicPlayback {
  final String owner;
  final String rendition;

  const CachedMusicPlayback(this.owner, this.rendition);

  static CachedMusicPlayback? of(Video? video) =>
      switch (video?.playbackSourceId) {
        final CachedMusicPlayback cached => cached,
        _ => null,
      };

  static CachedMusicPlayback? tryParse(Object? value) {
    if (value
        case {
          'owner': final String owner,
          'rendition': final String rendition,
        }
        when _digest.stringMatch(owner) == owner &&
            _digest.stringMatch(rendition) == rendition) {
      return CachedMusicPlayback(owner, rendition);
    }
    return null;
  }

  Map<String, String> toJson() => {'owner': owner, 'rendition': rendition};

  Uri get uri =>
      Uri(scheme: 'videre-cache', host: 'music', path: '/$rendition');

  Map<String, Object?>? source(Server server, String videoId) {
    if (!PlaybackCache.supported ||
        cachedMusicOwner(server) != owner ||
        _contentId.stringMatch(videoId) != videoId ||
        _digest.stringMatch(rendition) != rendition) {
      return null;
    }
    return {
      'cachedMusic': {
        ..._owner(server)!,
        'contentId': videoId,
        'rendition': rendition,
      },
    };
  }
}
