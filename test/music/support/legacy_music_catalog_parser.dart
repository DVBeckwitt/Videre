part of 'legacy_music_catalog.dart';

Map<String, dynamic> _map(Object? value) =>
    value is Map<String, dynamic> ? value : const {};

String _string(Object? value) => value is String ? value : '';

Iterable<Map<String, dynamic>> _maps(Object? node, String key) sync* {
  if (node is Map) {
    final match = node[key];
    if (match is Map<String, dynamic>) yield match;
    for (final value in node.values) {
      yield* _maps(value, key);
    }
  } else if (node is List) {
    for (final value in node) {
      yield* _maps(value, key);
    }
  }
}

Iterable<Map<String, dynamic>> _runs(Object? node) sync* {
  if (node is Map) {
    final runs = node['runs'];
    if (runs is List) yield* runs.whereType<Map<String, dynamic>>();
    for (final entry in node.entries) {
      if (entry.key != 'runs') yield* _runs(entry.value);
    }
  } else if (node is List) {
    for (final item in node) {
      yield* _runs(item);
    }
  }
}

String _text(Object? node) {
  final simpleText = _string(_map(node)['simpleText']);
  return simpleText.isNotEmpty
      ? simpleText
      : _runs(node).map((run) => _string(run['text'])).join().trim();
}

String _browseId(Object? run) =>
    _string(_maps(run, 'browseEndpoint').firstOrNull?['browseId']);

List<String> _artists(Object? node) => _runs(node)
    .where((run) => _browseId(run).startsWith('UC'))
    .map((run) => _string(run['text']).trim())
    .where((name) => name.isNotEmpty)
    .toSet()
    .toList();

List<MusicArtist> _artistLinks(Object? node) {
  final artists = <String, MusicArtist>{};
  for (final run in _runs(node)) {
    final id = _browseId(run);
    final name = _string(run['text']).trim();
    final pageType =
        _maps(run, 'browseEndpointContextMusicConfig').firstOrNull?['pageType'];
    if (LegacyMusicCatalogFixture._artistId.hasMatch(id) &&
        name.isNotEmpty &&
        (pageType == null || pageType == 'MUSIC_PAGE_TYPE_ARTIST')) {
      artists.putIfAbsent(id, () => MusicArtist(id: id, name: name));
    }
  }
  return artists.values.toList();
}

List<ImageObject> _thumbnails(Object? node) {
  final result = <ImageObject>[];
  void visit(Object? value) {
    if (value is Map) {
      final images = value['thumbnails'];
      if (images is List) {
        for (final item in images.whereType<Map>()) {
          final url = _string(item['url']);
          final uri = Uri.tryParse(url);
          if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
            continue;
          }
          result.add(ImageObject(
              null,
              url,
              item['width'] is int ? item['width'] : 0,
              item['height'] is int ? item['height'] : 0));
        }
      } else {
        for (final nested in value.values) {
          visit(nested);
        }
      }
    }
  }

  visit(node);
  return result;
}

int? _duration(String text) {
  if (!RegExp(r'^\d+(?::[0-5]\d){1,2}$').hasMatch(text)) return null;
  return text
      .split(':')
      .map(int.parse)
      .fold<int>(0, (sum, part) => sum * 60 + part);
}

MusicTrack? _track(Map<String, dynamic> item,
    {String? albumId,
    String? albumTitle,
    List<String> artists = const [],
    List<MusicArtist> artistLinks = const [],
    List<ImageObject> thumbnails = const []}) {
  if (item['musicItemRendererDisplayPolicy'] ==
      'MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT') {
    return null;
  }
  final columns = item['flexColumns'];
  if (columns is! List || columns.isEmpty) return null;
  final title = _text(columns.first);
  final playlistVideoId = _string(_map(item['playlistItemData'])['videoId']);
  final id = playlistVideoId.isNotEmpty
      ? playlistVideoId
      : _string(_maps(columns.first, 'watchEndpoint').firstOrNull?['videoId']);
  if (!LegacyMusicCatalogFixture._videoId.hasMatch(id) || title.isEmpty) {
    return null;
  }
  final album = _runs(columns)
      .where(
          (run) => LegacyMusicCatalogFixture._albumId.hasMatch(_browseId(run)))
      .firstOrNull;
  final trackArtists = _artists(columns);
  final trackArtistLinks = _artistLinks(columns);
  final trackImages = _thumbnails(item['thumbnail']);
  final duration = _runs([item['fixedColumns'], ...columns.skip(1)])
      .map((run) => _duration(_string(run['text'])))
      .whereType<int>()
      .firstOrNull;
  return MusicTrack(
    videoId: id,
    title: title,
    artists: trackArtists.isEmpty ? artists : trackArtists,
    artistLinks: trackArtists.isEmpty ? artistLinks : trackArtistLinks,
    albumId: albumId ?? (album == null ? null : _browseId(album)),
    albumTitle: albumTitle ?? (album == null ? null : _string(album['text'])),
    durationSeconds: duration,
    thumbnails: trackImages.isEmpty ? thumbnails : trackImages,
  );
}

MusicAlbum? _album(Map<String, dynamic> item) {
  final id = _browseId(item['navigationEndpoint']);
  final columns = item['flexColumns'];
  if (!LegacyMusicCatalogFixture._albumId.hasMatch(id) ||
      columns is! List ||
      columns.isEmpty) {
    return null;
  }
  final title = _text(columns.first);
  if (title.isEmpty) return null;
  return MusicAlbum(
      id: id,
      title: title,
      artists: _artists(columns),
      artistLinks: _artistLinks(columns),
      thumbnails: _thumbnails(item['thumbnail']));
}

MusicAlbum? _release(Map<String, dynamic> item, MusicArtist artist) {
  final id = _browseId(item['navigationEndpoint']);
  final title = _text(item['title']);
  if (!LegacyMusicCatalogFixture._albumId.hasMatch(id) || title.isEmpty) {
    return null;
  }
  final artists = _artists(item['subtitle']);
  final artistLinks = _artistLinks(item['subtitle']);
  return MusicAlbum(
    id: id,
    title: title,
    artists: artists.isEmpty ? [artist.name] : artists,
    artistLinks: artists.isEmpty ? [artist] : artistLinks,
    thumbnails: _thumbnails(item['thumbnailRenderer']),
  );
}

MusicArtist? _artist(Map<String, dynamic> item) {
  final id = _browseId(item['navigationEndpoint']);
  final columns = item['flexColumns'];
  if (!LegacyMusicCatalogFixture._artistId.hasMatch(id) ||
      columns is! List ||
      columns.isEmpty) {
    return null;
  }
  final name = _text(columns.first);
  if (name.isEmpty) return null;
  return MusicArtist(
      id: id, name: name, thumbnails: _thumbnails(item['thumbnail']));
}

MusicPlaylist? _playlist(Map<String, dynamic> item) {
  final browseId = _browseId(item['navigationEndpoint']);
  final id = browseId.startsWith('VL') ? browseId.substring(2) : browseId;
  final columns = item['flexColumns'];
  if (!LegacyMusicCatalogFixture._playlistId.hasMatch(id) ||
      columns is! List ||
      columns.isEmpty) {
    return null;
  }
  final title = _text(columns.first);
  if (title.isEmpty) return null;
  final author = _artists(columns).firstOrNull;
  return MusicPlaylist(
      id: id,
      title: title,
      author: author,
      thumbnails: _thumbnails(item['thumbnail']));
}

void _requireSearchResponse(Map<String, dynamic> data) {
  if (_maps(data, 'tabbedSearchResultsRenderer').isEmpty &&
      _maps(data, 'sectionListRenderer').isEmpty) {
    throw const MusicCatalogException(
        'The music catalog returned an invalid response.');
  }
}
