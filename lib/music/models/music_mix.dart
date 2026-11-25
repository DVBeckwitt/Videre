import 'package:clipious/content_filter/community_models.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_search_text.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/videos/models/video.dart';

enum MusicMixSteering { balanced, moreFromSeedArtist, moreVariety }

/// Candidate metadata belongs to the active queue. Steering never changes
/// the listener's recommendation preferences.
class MusicMix {
  static const upcomingLimit = 4;

  MusicMix(Video seed, Iterable<MusicTrack> candidates)
      : _seedArtist = _artists(seed),
        candidates = List.unmodifiable(candidates);

  final List<MusicArtistCredit> _seedArtist;
  final List<MusicTrack> candidates;

  bool get hasSeedArtist => _seedArtist.isNotEmpty;

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
      Iterable<MusicTrack> eligible, MusicMixSteering steering) {
    if (steering == MusicMixSteering.balanced) return eligible.toList();
    final preferred = <MusicTrack>[];
    final remaining = <MusicTrack>[];
    final heard = [..._seedArtist];
    for (final track in eligible) {
      final artists = _artists(track.toVideo());
      final matches = switch (steering) {
        MusicMixSteering.moreFromSeedArtist => _overlap(_seedArtist, artists),
        MusicMixSteering.moreVariety =>
          artists.isNotEmpty && !_overlap(heard, artists),
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
