import '../../utils/interfaces/db.dart';
import '../../videos/models/db/history_video_cache.dart';
import '../../videos/models/music_metadata.dart';
import '../models/music_library_entry.dart';
import '../models/music_listening_event.dart';
import 'local_music_library.dart';
import 'music_library_service.dart';
import 'spotify_music_history_import.dart';

final _catalogId = RegExp(r'^[A-Za-z0-9_-]{11}$');
final _controlCharacter = RegExp(r'[\x00-\x1f\x7f-\x9f]');

String? _label(String? value) {
  final trimmed = value?.replaceAll(_controlCharacter, ' ').trim();
  return trimmed == null || trimmed.isEmpty || trimmed.length > 1000
      ? null
      : trimmed;
}

/// The active profile's known songs and its visible, authorized device files.
/// Candidate collection never looks up the imported titles on a server.
Future<List<SpotifyMusicHistoryCandidate>> spotifyMusicHistoryCandidates(
  IDbClient owner,
  MusicLibraryService library, {
  required List<MusicListeningEvent> events,
  required bool Function() isCurrent,
}) async {
  if (!isCurrent() || library.profileId != owner.profileId) return const [];

  final device = LocalMusicLibrary.instance;
  await device.initialize();
  if (!isCurrent()) return const [];
  final selection = device.selectionId;
  await device.revalidate();
  if (!isCurrent()) return const [];
  if (device.acceptsSessionSelection(selection) &&
      (!device.loaded || device.scanning)) {
    await device.refresh();
    if (!isCurrent()) return const [];
  }

  final candidates =
      <(String, String, String, String?), SpotifyMusicHistoryCandidate>{};
  void add({
    required String id,
    required String? title,
    required String? artist,
    required String? album,
    required MusicListeningSource source,
    int? durationSeconds,
    bool isArtTrack = false,
  }) {
    final track = _label(title);
    final performer = _label(artist);
    if (track == null || performer == null) return;
    final release = _label(album);
    // The same ID can legitimately have more than one catalog label or album.
    // Retain those aliases for matching without indexing every play separately.
    candidates.putIfAbsent(
      (id, track, performer, release),
      () => SpotifyMusicHistoryCandidate(
        HistoryVideoCache(
          id,
          track,
          performer,
          '',
          lengthSeconds: durationSeconds,
          musicMetadata: MusicMetadata(
            title: track,
            artist: performer,
            album: release,
            isArtTrack: isArtTrack,
          ),
        ),
        source,
      ),
    );
  }

  for (final saved in library.entries) {
    if (saved.kind != MusicLibraryKind.song ||
        _catalogId.stringMatch(saved.id) != saved.id) {
      continue;
    }
    add(
      id: saved.id,
      title: saved.title,
      artist: saved.subtitle,
      album: saved.album,
      source: MusicListeningSource.catalog,
      durationSeconds: saved.durationSeconds,
      isArtTrack: saved.isArtTrack,
    );
  }
  for (final event in events) {
    if (event.source == MusicListeningSource.device ||
        isSpotifyMusicHistoryEventId(event.id) ||
        _catalogId.stringMatch(event.trackId) != event.trackId) {
      continue;
    }
    final entry = event.entry;
    final metadata = entry.musicMetadata;
    add(
      id: event.trackId,
      title: _label(metadata?.title) ?? entry.title,
      artist: _label(metadata?.artist) ?? entry.author,
      album: metadata?.album,
      source: MusicListeningSource.catalog,
      durationSeconds: entry.lengthSeconds,
      isArtTrack: metadata?.isArtTrack ?? false,
    );
  }
  if (device.acceptsSessionSelection(selection)) {
    for (final track in device.visibleTracks) {
      add(
        id: track.playbackId,
        title: track.title,
        artist: track.artist,
        album: track.album,
        source: MusicListeningSource.device,
        durationSeconds: track.durationMs > 0
            ? track.durationMs ~/ Duration.millisecondsPerSecond
            : null,
      );
    }
  }
  return candidates.values.toList();
}
