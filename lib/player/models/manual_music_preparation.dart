import '../../videos/models/ided_video.dart';

/// All admitted renditions failed with retryable native transport errors.
class ManualMusicSourceFailure implements Exception {
  final Object cause;
  const ManualMusicSourceFailure(this.cause);
}

/// Prepares a selected Music occurrence while the current decoder keeps playing.
abstract interface class ManualMusicPreparer {
  Future<bool> prepareMusicSelection(
      IdedVideo entry, Duration startAt, bool Function() isCurrent,
      {bool skipDownload = false});

  void cancelMusicSelection();
}
