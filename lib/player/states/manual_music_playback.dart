part of 'audio_player.dart';

/// A manual selection owns this silent decoder until its queue command arrives.
/// It is independent of the old song's automatic next/previous window.
class _ManualMusicDecoder {
  final AudioPlayerCubit owner;
  final _StandbyAudio slot;
  final Duration startAt;
  final bool Function() isCurrent;
  final bool borrowedAdjacent;
  final _database = db;
  final _profile = db.profileId;
  final _proxy = NetworkProxy.instance.config;
  final cancelled = Completer<bool>();
  AudioPlaybackSources? admittedPlan;
  PlayerException? exhaustedSourceError;
  int sourceIndex = 0;
  bool changedDecoder = false;

  _ManualMusicDecoder(this.owner, this.slot, this.startAt, this.isCurrent,
      {required this.borrowedAdjacent});

  bool get decoderReady =>
      !slot.decoder.playing &&
      slot.decoder.processingState == ProcessingState.ready &&
      slot.decoder.playbackEvent.errorCode == null;

  bool get samePlaybackContext =>
      identical(db, _database) &&
      db.profileId == _profile &&
      !NetworkProxy.instance.isChanging &&
      identical(_proxy, NetworkProxy.instance.config) &&
      slot.matches(slot.entry);

  bool get inScope => isCurrent() && samePlaybackContext;

  Future<bool> prepare() async {
    final entry = slot.entry;
    final offline = entry is DownloadedVideo ? entry : null;
    if (offline != null && offline.profileId != _profile) return false;
    final decoder = slot.decoder;
    bool active() => !cancelled.isCompleted && inScope;
    final session = 'selection:${identityHashCode(this)}:'
        '${DateTime.now().microsecondsSinceEpoch}';
    Future<AudioPlaybackSources?> resolve({bool verifyCompletion = true}) =>
        resolveAudioPlaybackSources(
            video: entry is Video ? entry : null,
            offlineVideo: offline,
            sessionId: session,
            isCurrent: active,
            verifyPinnedCompletion: verifyCompletion);
    try {
      final adjacent = await slot.ready;
      if (!active()) return false;
      final plan = await resolve();
      if (plan == null || !active()) return false;
      BackendPlayback? blockedRoute;
      for (var index = 0; index < plan.sources.length; index++) {
        if (blockedRoute != null &&
            !audioPlaybackRouteIsCurrent(blockedRoute)) {
          return false;
        }
        try {
          await owner._setMusicGain(decoder, plan.sources[index]);
          if (!active()) return false;
          if (index != 0 ||
              !decoderReady ||
              !samePreparedAudioSource(adjacent, plan)) {
            // Android completes this call after ExoPlayer reports STATE_READY.
            changedDecoder = true;
            await decoder.setAudioSource(plan.sources[index],
                initialPosition: startAt);
          }
          if (!active()) return false;
          if (decoder.position != startAt) {
            changedDecoder = true;
            await decoder.seek(startAt);
          }
        } on PlayerException catch (error) {
          if (!active() ||
              (!error.backendRetryable && !error.mediaOriginBlocked)) {
            return false;
          }
          // Only a transient failure can rotate the selected song's backend.
          if (index == plan.sources.length - 1 && error.backendRetryable) {
            exhaustedSourceError = error;
          }
          if (error.mediaOriginBlocked) blockedRoute = plan.playbackRoute;
          continue;
        }
        if (!active() || !decoderReady) return false;
        // A grant, saved download, or selected instance may have changed
        // while the native decoder was fetching the first playable samples.
        final confirmed = await resolve(verifyCompletion: false);
        if (confirmed == null ||
            !active() ||
            !decoderReady ||
            !samePreparedAudioSource(plan, confirmed, index: index)) {
          return false;
        }
        sourceIndex = index;
        admittedPlan = confirmed;
        return true;
      }
    } catch (_) {
      // The parent owns feedback for this selection. The playing song keeps
      // its original recovery, progress and playback state.
    }
    return false;
  }
}
