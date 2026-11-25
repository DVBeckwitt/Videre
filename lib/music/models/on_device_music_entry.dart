import '../../downloads/models/downloaded_video.dart';
import '../../downloads/services/explicit_music_download.dart';
import 'local_music_track.dart';

/// A playable library row backed by one authorized device file.
class OnDeviceMusicEntry {
  OnDeviceMusicEntry.device(LocalMusicTrack track)
      : deviceTrack = track,
        download = null,
        downloadFileProof = null;

  OnDeviceMusicEntry.download(DownloadedVideo file, String fileProof)
      : deviceTrack = null,
        download = file,
        downloadFileProof = fileProof;

  final LocalMusicTrack? deviceTrack;
  final DownloadedVideo? download;
  final String? downloadFileProof;

  late final String id = deviceTrack?.playbackId ??
      'download:${musicDownloadFingerprint(download!)}:$downloadFileProof';
  String get title => deviceTrack?.title ?? download!.musicMetadata!.title;
  String? get artist => deviceTrack == null
      ? download!.musicMetadata!.artist
      : deviceTrack!.artist;
  String? get album =>
      deviceTrack == null ? download!.musicMetadata!.album : deviceTrack!.album;
  String? get fileName => deviceTrack?.fileName;
  DateTime? get dateAdded => deviceTrack?.dateAdded;
  DateTime? get dateModified => deviceTrack?.dateModified;
  bool get firstSeen => deviceTrack?.firstSeen ?? false;
}
