import 'package:clipious/content_filter/community_models.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_search_text.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/videos/models/video.dart';

enum MusicMixSteering { balanced, moreFromSeedArtist, moreVariety }

enum MusicMixFamiliarity { balanced, moreFamiliar, moreDiscovery }

/// Candidate metadata belongs to the active queue. Steering never changes
/// the listener's recommendation preferences.
class MusicMix {
  static const upcomingLimit = 4;

  MusicMix(Video seed, Iterable<MusicTrack> candidates)
      : _seedArtist = _artists(seed),
        artistSeedIds = const {},
        candidates = List.unmodifiable(candidates);

  MusicMix.fromArtists(
      Iterable<String> verifiedChannelIds, Iterable<MusicTrack> candidates)
      : _seedArtist = const [],
        artistSeedIds = Set.unmodifiable(verifiedChannelIds),
        candidates = List.unmodifiable(candidates);

  final List<MusicArtistCredit> _seedArtist;
  final Set<String> artistSeedIds;
  final List<MusicTrack> candidates;

  bool get hasSeedArtist => _seedArtist.isNotEmpty || artistSeedIds.isNotEmpty;

  bool isSeedTrack(MusicTrack track) => _matchesSeed(_artists(track.toVideo()));

  bool _matchesSeed(List<MusicArtistCredit> credits) => artistSeedIds.isEmpty
      ? _overlap(_seedArtist, credits)
      : credits.any((credit) => artistSeedIds.contains(
            normalizeChannelId(credit.id),
          ));

  static List<MusicArtistCredit> _artists(Video video) {
    final music = video.musicMetadata;
    if (music == null) return const [];
    if (music.artistCredits.isNotEmpty) return music.artistCredits;
    if (music.artist.trim().isEmpty) return const [];
    return [MusicArtistCredit(name: music.artist)];
  }

  static bool _sameArtist(MusicArtistCredit a, MusicArtistCredit b) {
    final aId = normalizeChannelId(a.id);
    final bId = normalizeChannelId(b.id);
    if (aId != null && bId != null) return aId == bId;
    final name = normalizeMusicSearchText(a.name.trim());
    return name.isNotEmpty && name == normalizeMusicSearchText(b.name.trim());
  }

  static bool _overlap(Iterable<MusicArtistCredit> first,
          Iterable<MusicArtistCredit> second) =>
      first.any((a) => second.any((b) => _sameArtist(a, b)));

  List<MusicTrack> order(
    Iterable<MusicTrack> eligible,
    MusicMixSteering steering, {
    MusicMixFamiliarity familiarity = MusicMixFamiliarity.balanced,
    Set<String> familiarSongIds = const {},
  }) {
    var ranked = eligible.toList();
    if (familiarity != MusicMixFamiliarity.balanced &&
        familiarSongIds.isNotEmpty) {
      final preferFamiliar = familiarity == MusicMixFamiliarity.moreFamiliar;
      bool preferred(MusicTrack track) =>
          familiarSongIds.contains(track.videoId) == preferFamiliar;
      ranked = [
        ...ranked.where(preferred),
        ...ranked.where((t) => !preferred(t))
      ];
    }
    // Familiarity orders songs within each artist tier, including which song
    // represents an artist when the listener asks for more variety.
    if (steering == MusicMixSteering.balanced) return ranked;
    final preferred = <MusicTrack>[];
    final remaining = <MusicTrack>[];
    final heard = <MusicArtistCredit>[];
    for (final track in ranked) {
      final artists = _artists(track.toVideo());
      final matches = switch (steering) {
        MusicMixSteering.moreFromSeedArtist => _matchesSeed(artists),
        MusicMixSteering.moreVariety => artists.isNotEmpty &&
            !_matchesSeed(artists) &&
            !_overlap(heard, artists),
        MusicMixSteering.balanced => false,
      };
      if (matches) {
        preferred.add(track);
        if (steering == MusicMixSteering.moreVariety) heard.addAll(artists);
      } else {
        remaining.add(track);
      }
    }
    return [...preferred, ...remaining];
  }
}
