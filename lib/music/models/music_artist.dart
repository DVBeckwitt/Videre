import 'package:clipious/content_filter/community_models.dart';
import 'package:clipious/utils/models/image_object.dart';

class MusicArtist {
  final String id;
  final String name;
  final List<ImageObject> thumbnails;

  const MusicArtist({
    required this.id,
    required this.name,
    this.thumbnails = const [],
  });
}

/// A displayed artist may have a public catalog channel, or only a name.
class MusicArtistCredit {
  final String name;
  final String? id;

  const MusicArtistCredit({required this.name, this.id});

  /// Catalog responses may supply fewer channel links than artist names.
  /// A link belongs to a single occurrence, even when names are repeated.
  static List<MusicArtistCredit> fromCatalog(
      List<String> names, List<MusicArtist> links) {
    if (links.isEmpty) return const [];
    if (names.isEmpty) {
      return [
        for (final artist in links)
          MusicArtistCredit(name: artist.name, id: artist.id)
      ];
    }
    final channelIds = <String, List<String>>{};
    for (final artist in links.reversed) {
      (channelIds[artist.name] ??= []).add(artist.id);
    }
    // A partial set of links for identically named artists is ambiguous.
    channelIds.removeWhere((name, ids) =>
        names.where((label) => label == name).length != ids.length);
    return [
      for (final name in names)
        MusicArtistCredit(name: name, id: channelIds[name]?.removeLast()),
    ];
  }

  static MusicArtistCredit? forAuthor(
      String? author, String? authorId, String? authorUrl) {
    final id = normalizeChannelId(authorId) ??
        normalizeChannelId(authorUrl) ??
        channelIdFromAuthorUrl(authorUrl);
    if (author == null || author.trim().isEmpty || id == null) return null;
    return MusicArtistCredit(name: author, id: id);
  }

  Map<String, dynamic> toJson() => {'name': name, if (id != null) 'id': id};

  static List<MusicArtistCredit> parseList(Object? json) {
    if (json is! List) return const [];
    final credits = <MusicArtistCredit>[];
    for (final row in json.take(64)) {
      if (row is! Map || row['name'] is! String) continue;
      final name = row['name'] as String;
      if (name.trim().isEmpty ||
          name.length > 1024 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
        continue;
      }
      final id = row['id'];
      credits.add(MusicArtistCredit(
          name: name, id: id is String ? normalizeChannelId(id) : null));
    }
    return credits;
  }
}

extension MusicCreditList on List<MusicArtistCredit> {
  List<String> get artistNames => [for (final credit in this) credit.name];

  List<MusicArtist> get artistLinks => [
        for (final credit in this)
          if (credit.id case final id?) MusicArtist(id: id, name: credit.name),
      ];
}
