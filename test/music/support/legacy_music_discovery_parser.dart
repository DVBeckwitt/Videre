part of 'legacy_music_catalog.dart';

// Shapes checked against ytmusicapi 1.12.3 explore/charts and anonymous public
// responses. See test/music/fixtures/discovery/README.md for captured evidence.
Never _invalidDiscovery() => throw const MusicCatalogException(
    'The music catalog returned an invalid response.');

List<dynamic> _discoverySections(Map<String, dynamic> data) {
  final sections =
      _maps(data['contents'], 'sectionListRenderer').firstOrNull?['contents'];
  if (sections is! List) _invalidDiscovery();
  return sections;
}

List<Map<String, dynamic>> _discoveryContainers(Map<String, dynamic> data,
    {required bool onlyGrids}) {
  final grid =
      _maps(data['continuationContents'], 'gridContinuation').firstOrNull;
  if (grid != null) return [grid];
  final appended =
      _maps(data['onResponseReceivedActions'], 'appendContinuationItemsAction')
          .firstOrNull?['continuationItems'];
  if (appended != null) {
    return [
      {'items': appended}
    ];
  }
  final sectionContinuation =
      _maps(data['continuationContents'], 'sectionListContinuation')
          .firstOrNull;
  final sections = sectionContinuation == null
      ? _discoverySections(data)
      : sectionContinuation['contents'];
  if (sections is! List) _invalidDiscovery();
  final containers = <Map<String, dynamic>>[];
  for (final section in sections) {
    final value = _map(section);
    final container = value['gridRenderer'] ??
        (onlyGrids
            ? null
            : value['musicCarouselShelfRenderer'] ??
                value['musicImmersiveCarouselShelfRenderer']);
    if (container is Map<String, dynamic>) containers.add(container);
  }
  if (sections.isNotEmpty && containers.isEmpty) _invalidDiscovery();
  if (sectionContinuation?['continuations'] != null) {
    containers.add({
      'items': <dynamic>[],
      'continuations': sectionContinuation!['continuations'],
    });
  }
  return containers;
}

MusicAlbum? _discoveryAlbum(Map<String, dynamic> item) {
  final id = _browseId(item['navigationEndpoint']);
  final title = _text(item['title']);
  if (!LegacyMusicCatalogFixture._albumId.hasMatch(id) || title.isEmpty) {
    return null;
  }
  return MusicAlbum(
    id: id,
    title: title,
    artists: _artists(item['subtitle']),
    artistLinks: _artistLinks(item['subtitle']),
    thumbnails: _thumbnails(item['thumbnailRenderer']),
  );
}

MusicPlaylist? _discoveryPlaylist(Map<String, dynamic> item) {
  final browseId = _browseId(item['navigationEndpoint']);
  final titleId = _browseId(item['title']);
  final target = browseId.isNotEmpty ? browseId : titleId;
  final id = target.startsWith('VL') ? target.substring(2) : target;
  final title = _text(item['title']);
  if (!LegacyMusicCatalogFixture._playlistId.hasMatch(id) || title.isEmpty) {
    return null;
  }
  return MusicPlaylist(
    id: id,
    title: title,
    author: _artists(item['subtitle']).firstOrNull,
    thumbnails: _thumbnails(item['thumbnailRenderer']),
  );
}

MusicCharts _discoveryCharts(Map<String, dynamic> data, String requested) {
  final sections = _discoverySections(data);
  final choices = <String, Map<String, dynamic>>{};
  for (final choice
      in _maps(data['frameworkUpdates'], 'musicFormBooleanChoice')) {
    final code = _string(choice['opaqueToken']);
    final id = _string(choice['id']);
    if (LegacyMusicCatalogFixture._countryCode.hasMatch(code) &&
        id.isNotEmpty) {
      choices[id] = choice;
    }
  }
  final countries = <String, MusicCountry>{};
  String? selected;
  for (final option in _maps(sections, 'musicMultiSelectMenuItemRenderer')) {
    final choice = choices[_string(option['formItemEntityKey'])];
    if (choice == null) continue;
    final code = _string(choice['opaqueToken']);
    final name = _text(option['title']);
    if (name.isEmpty) continue;
    countries[code] = MusicCountry(code: code, name: name);
    if (choice['selected'] == true) selected = code;
  }
  // A server fallback must not silently label US charts as another country.
  if (selected != requested || !countries.containsKey(requested)) {
    throw const MusicCatalogException(
        'Charts for this country are unavailable.');
  }
  final playlists = <String, MusicPlaylist>{};
  final artists = <String, MusicArtist>{};
  for (final section in sections) {
    final carousel = _map(section)['musicCarouselShelfRenderer'];
    if (carousel is! Map<String, dynamic>) continue;
    final contents = carousel['contents'];
    if (contents is! List) _invalidDiscovery();
    for (final row in contents) {
      final card = _map(row)['musicTwoRowItemRenderer'];
      final playlist =
          card is Map<String, dynamic> ? _discoveryPlaylist(card) : null;
      if (playlist != null) {
        playlists.putIfAbsent(playlist.id, () => playlist);
      }
      final artistRow = _map(row)['musicResponsiveListItemRenderer'];
      final artist =
          artistRow is Map<String, dynamic> ? _artist(artistRow) : null;
      if (artist != null) artists.putIfAbsent(artist.id, () => artist);
    }
  }
  return MusicCharts(
    country: selected!,
    countries: countries.values.toList(),
    playlists: playlists.values.toList(),
    artists: artists.values.toList(),
  );
}

List<MusicMoodCategory> _discoveryMoods(Map<String, dynamic> data) {
  final categories = <String, MusicMoodCategory>{};
  for (final section in _discoverySections(data)) {
    final grid = _map(section)['gridRenderer'];
    if (grid is! Map<String, dynamic>) continue;
    final group = _text(
        _maps(grid['header'], 'gridHeaderRenderer').firstOrNull?['title']);
    // Requests use English. An allowlist excludes personal "For you" groups.
    if (!const {'Genres', 'Moods & moments'}.contains(group)) continue;
    final items = grid['items'];
    if (items is! List) _invalidDiscovery();
    for (final row in items) {
      final button = _map(_map(row)['musicNavigationButtonRenderer']);
      final endpoint =
          _maps(button['clickCommand'], 'browseEndpoint').firstOrNull;
      final title = _text(button['buttonText']);
      final params = _string(endpoint?['params']);
      if (endpoint?['browseId'] != 'FEmusic_moods_and_genres_category' ||
          title.isEmpty ||
          !LegacyMusicCatalogFixture._browseParams.hasMatch(params)) {
        continue;
      }
      categories.putIfAbsent(params,
          () => MusicMoodCategory(title: title, params: params, group: group));
    }
  }
  return categories.values.toList();
}
