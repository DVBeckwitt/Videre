import 'backend_playback.dart';

enum BackendRecoveryPhase { trying, ready, succeeded, failed }

/// Playback feedback is independent of transient decoder loading/buffering
/// events. The request identifies the attempt; it is not a serving-backend claim.
class BackendRecovery {
  final BackendRecoveryPhase phase;
  final BackendPlayback request;
  final String videoId;
  final bool manual;

  const BackendRecovery({
    required this.phase,
    required this.request,
    required this.videoId,
    required this.manual,
  });

  int get alternativeIndex => request.retryIndex;
  String get label => request.label;

  BackendRecovery withPhase(BackendRecoveryPhase phase) => BackendRecovery(
      phase: phase, request: request, videoId: videoId, manual: manual);
}
