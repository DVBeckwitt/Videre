import '../../downloads/models/downloaded_video.dart';
import '../../downloads/services/download_storage.dart';
import '../../downloads/services/explicit_music_download.dart';
import '../../utils/interfaces/db.dart';
import '../../videos/models/video.dart';
import '../models/on_device_music_entry.dart';
import 'local_music_library.dart';
import 'music_listening_history.dart';

/// A replay uses each recording once, in newest-listened order.
class MusicRecapPlayback {
  MusicRecapPlayback._(
      this.videos, this.files, this.deviceSelection, this.unavailable);

  final List<Video> videos;
  final List<OnDeviceMusicEntry> files;
  final String? deviceSelection;
  final int unavailable;

  static Future<MusicRecapPlayback?> resolve(
      Iterable<MusicListeningEvent> events, IDbClient owner,
      {required bool Function() isCurrent}) async {
    final ordered = events.toList()
      ..sort((a, b) {
        final byDate = b.playedAt.compareTo(a.playedAt);
        if (byDate != 0) return byDate;
        final byTrack = a.trackId.compareTo(b.trackId);
        return byTrack != 0 ? byTrack : b.id.compareTo(a.id);
      });
    final recordings = <String, List<MusicListeningEvent>>{};
    final downloads = <String, DownloadedVideo>{};
    final deviceIds = <String>{};
    for (final event in ordered) {
      (recordings[event.trackId] ??= []).add(event);
      switch (event.source) {
        case MusicListeningSource.catalog:
          break;
        case MusicListeningSource.download:
          final file = readyMusicDownload(owner, event.trackId);
          if (file != null && file.accountId == event.entry.downloadAccountId) {
            downloads[event.trackId] = file;
          }
        case MusicListeningSource.device:
          deviceIds.add(event.trackId);
      }
    }

    final library = LocalMusicLibrary.instance;
    if (deviceIds.isNotEmpty) await library.loadForPlayback(deviceIds);
    if (!isCurrent()) return null;
    final selection = library.selectionId;
    final probes = downloads.isEmpty
        ? <MusicFileProbe>[]
        : await DownloadStorage()
            .probeMusicFiles(owner.profileId, downloads.values);
    if (!isCurrent()) return null;
    final readable = {
      for (final probe in probes) probe.download.videoId: probe,
    };
    final deviceAvailable = library.acceptsSessionSelection(selection);
    final videos = <Video>[];
    final files = <OnDeviceMusicEntry>[];
    var hasStreaming = false;
    var unavailable = 0;
    for (final listens in recordings.values) {
      // If the newest source is gone, try an older source actually used for
      // this recording in the period. Never substitute a title match.
      var resolved = false;
      for (final event in listens) {
        switch (event.source) {
          case MusicListeningSource.catalog:
            if (!DownloadedVideo.isSafeFileId(event.trackId)) continue;
            videos.add(event.entry.toVideo());
            hasStreaming = true;
          case MusicListeningSource.download:
            final probe = readable[event.trackId];
            if (probe == null ||
                probe.download.accountId != event.entry.downloadAccountId) {
              continue;
            }
            final fingerprint =
                musicDownloadFileFingerprint(probe.download, probe.identity)!;
            files.add(
                OnDeviceMusicEntry.download(probe.download, probe.identity));
            videos.add(event.entry.toVideo().copyWith(
                  explicitMusicDownload: fingerprint,
                ));
          case MusicListeningSource.device:
            final track = deviceAvailable
                ? library.visibleTrackById(event.trackId)
                : null;
            if (track == null) continue;
            files.add(OnDeviceMusicEntry.device(track));
        }
        resolved = true;
        break;
      }
      if (!resolved) unavailable++;
    }
    // Device files and verified downloads can share an offline queue. With
    // streams present, downloads stay with the catalog queue as in History.
    if (hasStreaming) {
      files.removeWhere((entry) => entry.deviceTrack == null);
    } else {
      videos.clear();
    }
    return MusicRecapPlayback._(videos, files, selection, unavailable);
  }
}
