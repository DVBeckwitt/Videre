import '../../downloads/models/downloaded_video.dart';
import '../../downloads/services/download_storage.dart';
import '../../utils/interfaces/db.dart';

const _shelfLimit = 12;

/// Reads up to twelve videos from the active profile's saved library. When a
/// card is selected, revalidate that exact row and its file before playback.
Future<List<DownloadedVideo>> readableHomeDownloads({
  required IDbClient owner,
  required DownloadStorage storage,
  required bool Function() isCurrent,
  bool Function(DownloadedVideo)? include,
  int limit = _shelfLimit,
  DownloadedVideo? selection,
}) async {
  if (limit <= 0 || !isCurrent()) return [];
  final profileId = owner.profileId;
  final capacity = limit.clamp(1, _shelfLimit);
  bool stillCurrent() => isCurrent() && owner.profileId == profileId;
  bool eligible(DownloadedVideo video) =>
      DownloadStorage.isReadyVideoFile(video, profileId) &&
      (include?.call(video) ?? true);
  bool stillSaved(DownloadedVideo video) =>
      owner.getDownloadByVideoId(video.videoId) == video && eligible(video);

  final candidates = selection == null
      ? (owner.getAllDownloads().where(eligible).toList()
        ..sort((a, b) => a.videoId.compareTo(b.videoId)))
      : [if (stillSaved(selection)) selection];
  final ready = <DownloadedVideo>[];
  var start = 0;
  while (start < candidates.length && ready.length < capacity) {
    final batch = candidates.skip(start).take(capacity - ready.length).toList();
    start += batch.length;
    final probes = await storage.probeVideoFiles(profileId, batch);
    if (!stillCurrent()) return [];
    ready.addAll(probes.where(stillSaved));
  }

  return stillCurrent() ? ready.where(stillSaved).toList() : [];
}
