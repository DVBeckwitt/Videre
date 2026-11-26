import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../content_filter/community_models.dart';
import '../../settings/models/db/server.dart';
import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';
import '../../utils/invidious_image.dart';
import '../../utils/models/image_object.dart';
import '../models/music_artist.dart';
import '../models/music_search_text.dart';
import '../models/music_track.dart';

const musicStarterArtistsSettingName = 'music-starter-artists-v1';

class MusicStarterArtistPick {
  static const _maxThumbnails = 4;

  final String name;
  final String? catalogId;
  final List<ImageObject> thumbnails;

  const MusicStarterArtistPick._(this.name,
      {this.catalogId, this.thumbnails = const []});

  String get key => catalogId == null
      ? 'legacy:${MusicStarterArtists.artistKey(name)}'
      : 'catalog:$catalogId';

  static MusicStarterArtistPick? fromCatalog(
      MusicArtist artist, Server server) {
    final id = normalizeChannelId(artist.id);
    final name = MusicStarterArtists.cleanName(artist.name);
    if (id == null || name == null) return null;
    final images = <ImageObject>[];
    final urls = <String>{};
    for (final image in artist.thumbnails) {
      if (!_validArtworkUrl(image.url)) continue;
      final resolved = invidiousImageUrl(image.url, server);
      if (resolved == null ||
          Uri.parse(resolved).origin != Uri.parse(server.url).origin ||
          !urls.add(resolved)) {
        continue;
      }
      images
          .add(_thumbnail(image.url, image.quality, image.width, image.height));
      if (images.length == _maxThumbnails) break;
    }
    return MusicStarterArtistPick._(name,
        catalogId: id, thumbnails: List.unmodifiable(images));
  }

  Object _toJson() => catalogId == null
      ? name
      : {
          'id': catalogId,
          'name': name,
          if (thumbnails.isNotEmpty)
            'thumbnails': thumbnails.map((image) => image.toJson()).toList(),
        };

  static MusicStarterArtistPick? _parse(Object? value) {
    if (value is String) {
      final name = MusicStarterArtists.cleanName(value);
      return name == null ? null : MusicStarterArtistPick._(name);
    }
    if (value is! Map || value['name'] is! String || value['id'] is! String) {
      return null;
    }
    final name = MusicStarterArtists.cleanName(value['name'] as String);
    final id = normalizeChannelId(value['id'] as String);
    if (name == null || id == null) return null;
    final rawImages = value['thumbnails'];
    final images = [
      if (rawImages is List)
        for (final image in rawImages.take(_maxThumbnails))
          if (image is Map)
            if (image['url'] case final String url when _validArtworkUrl(url))
              _thumbnail(
                  url, image['quality'], image['width'], image['height']),
    ];
    return MusicStarterArtistPick._(name,
        catalogId: id, thumbnails: List.unmodifiable(images));
  }

  static bool _validArtworkUrl(String url) {
    if (url.isEmpty ||
        url.length > 2048 ||
        url.trim() != url ||
        MusicStarterArtists._control.hasMatch(url)) {
      return false;
    }
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.userInfo.isEmpty &&
        (!uri.hasScheme || const {'http', 'https'}.contains(uri.scheme));
  }

  static ImageObject _thumbnail(
      String url, Object? quality, Object? width, Object? height) {
    int size(Object? value) =>
        value is int && value >= 0 && value <= 16384 ? value : 0;
    return ImageObject(
        quality is String && quality.length <= 32 ? quality : null,
        url,
        size(width),
        size(height));
  }
}

/// Explicit discovery preferences stored in the active person's settings.
class MusicStarterArtists {
  static const maxPicks = 3;
  static const maxNameLength = 100;
  static final _owners = Expando<Map<String, ValueNotifier<int>>>();
  static final _whitespace = RegExp(r'\s+');
  static final _control = RegExp(r'[\x00-\x1f\x7f-\x9f]');

  final IDbClient _root;
  final String _profileId;
  final IDbClient _database;
  final ValueNotifier<int> _changes;

  MusicStarterArtists(IDbClient database, String profileId)
      : _root = database,
        _profileId = profileId,
        _database = database.forProfile(profileId),
        _changes = (_owners[database] ??= {})
            .putIfAbsent(profileId, () => ValueNotifier(0));

  Listenable get changes => _changes;

  /// Null means undecided. An empty list records an explicit skip or clear.
  List<MusicStarterArtistPick>? get picks {
    final raw = _database.getSettings(musicStarterArtistsSettingName)?.value;
    if (raw == null || raw.length > 64 * 1024) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.length > maxPicks) return null;
      final picks = <MusicStarterArtistPick>[];
      final keys = <String>{};
      for (final value in decoded) {
        final pick = MusicStarterArtistPick._parse(value);
        if (pick == null || !keys.add(pick.key)) return null;
        picks.add(pick);
      }
      return List.unmodifiable(picks);
    } on FormatException {
      return null;
    }
  }

  Future<void> save(Iterable<MusicStarterArtistPick> selections) async {
    if (_root.profileId != _profileId) return;
    final picks = <Object>[];
    final keys = <String>{};
    for (final pick in selections) {
      if (!keys.add(pick.key)) continue;
      picks.add(pick._toJson());
      if (picks.length == maxPicks) break;
    }
    await _database.saveSetting(
        SettingsValue(musicStarterArtistsSettingName, jsonEncode(picks)));
    if (_root.profileId == _profileId) _changes.value++;
  }

  static String? cleanName(String raw) {
    final name = raw.replaceAll(_whitespace, ' ').trim();
    if (name.isEmpty ||
        name.runes.length > maxNameLength ||
        _control.hasMatch(name) ||
        artistKey(name).isEmpty) {
      return null;
    }
    return name;
  }

  static String artistKey(String raw) =>
      normalizeMusicSearchText(raw).replaceAll(_whitespace, ' ').trim();

  static bool matches(
      MusicTrack track, Iterable<MusicStarterArtistPick> picks) {
    for (final pick in picks) {
      final id = pick.catalogId;
      if (id != null) {
        if (track.artistCredits.any((credit) => credit.id == id) ||
            track.artistLinks.any((artist) => artist.id == id)) {
          return true;
        }
      } else {
        final key = artistKey(pick.name);
        if (track.artists.any((name) => artistKey(name) == key) ||
            track.artistCredits
                .any((credit) => artistKey(credit.name) == key)) {
          return true;
        }
      }
    }
    return false;
  }
}
