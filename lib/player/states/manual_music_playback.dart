part of 'audio_player.dart';

/// A manual selection owns this silent decoder until its queue command arrives.
/// It is independent of the old song's automatic next/previous window.
class _ManualMusicDecoder {
  final AudioPlayerCubit owner;
  final _StandbyAudio slot;
  final Duration startAt;
  final bool Function() isCurrent;
  final LocalMusicTrack? Function(String) openedAudioTrack;
  final bool borrowedAdjacent;
  final bool skipDownload;
  final _database = db;
  final _profile = db.profileId;
  final _proxy = NetworkProxy.instance.config;
  final cancelled = Completer<bool>();
  AudioPlaybackSources? admittedPlan;
  bool? providerCanSeek;
  ManualMusicSourceFailure? exhaustedSourceFailure;
  int sourceIndex = 0;
  bool changedDecoder = false;

  _ManualMusicDecoder(this.owner, this.slot, this.startAt, this.isCurrent,
      this.openedAudioTrack,
      {required this.borrowedAdjacent, required this.skipDownload});

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
            openedAudioTrack: openedAudioTrack,
            sessionId: session,
            isCurrent: active,
            skipDownload: skipDownload,
            verifyPinnedCompletion: verifyCompletion);
    try {
      final adjacent = await slot.ready;
      if (!active()) return false;
      final plan = await resolve();
      if (plan == null || !active()) return false;
      final route = plan.playbackRoute;
      bool admitted() =>
          active() &&
          (route == null ||
              !route.isInstanceFallback ||
              audioPlaybackRouteIsCurrent(route));
      final provider = providerMusicTrackForPlayback(entry.videoId);
      if (provider != null) {
        providerCanSeek =
            await LocalMusicLibrary.instance.canSeekProviderTrack(provider);
        if (!active()) return false;
      }
      final position = providerCanSeek == false ? null : startAt;
      BackendPlayback? blockedRoute;
      for (var index = 0; index < plan.sources.length; index++) {
        if (blockedRoute != null &&
            !audioPlaybackRouteIsCurrent(blockedRoute)) {
          return false;
        }
        var openingSource = false;
        try {
          await owner._setMusicGain(decoder, plan.sources[index]);
          if (!admitted()) return false;
          if (index != 0 ||
              !decoderReady ||
              !samePreparedAudioSource(adjacent, plan)) {
            // Android completes this call after ExoPlayer reports STATE_READY.
            changedDecoder = true;
            openingSource = true;
            await decoder.setAudioSource(plan.sources[index],
                initialPosition: position);
            openingSource = false;
          }
          if (!admitted()) return false;
          if (position != null && decoder.position != position) {
            changedDecoder = true;
            await decoder.seek(position);
          }
        } on PlayerException catch (error) {
          if (!admitted() ||
              (!error.backendRetryable && !error.mediaOriginBlocked)) {
            return false;
          }
          // Only a transient failure can rotate the selected song's backend.
          if (index == plan.sources.length - 1 && error.backendRetryable) {
            final canTryInstanceFallback = openingSource &&
                _remoteAudioSource(plan.sources[index]) &&
                _transientAudioOpenFailure(error);
            exhaustedSourceFailure = ManualMusicSourceFailure(error,
                canTryInstanceFallback: canTryInstanceFallback);
            if (canTryInstanceFallback) {
              plan.playbackRoute
                  ?.recordDecoderOutcome(_database, success: false);
            }
          }
          if (error.mediaOriginBlocked) blockedRoute = plan.playbackRoute;
          continue;
        }
        if (!admitted() || !decoderReady) return false;
        // A grant, saved download, or selected instance may have changed
        // while the native decoder was fetching the first playable samples.
        final confirmed = await resolve(verifyCompletion: false);
        if (confirmed == null ||
            !admitted() ||
            !decoderReady ||
            !samePreparedAudioSource(plan, confirmed, index: index)) {
          return false;
        }
        sourceIndex = index;
        admittedPlan = confirmed;
        if (_remoteAudioSource(confirmed.sources[index])) {
          confirmed.playbackRoute
              ?.recordDecoderOutcome(_database, success: true);
        }
        return true;
      }
    } catch (_) {
      // The parent owns feedback for this selection. The playing song keeps
      // its original recovery, progress and playback state.
    }
    return false;
  }
}
