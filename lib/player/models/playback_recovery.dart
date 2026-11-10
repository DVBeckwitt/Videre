import '../../settings/models/errors/invidious_service_error.dart';
import 'backend_playback.dart';

/// Shared by every decoder for one queue occurrence, including mode changes.
class PlaybackRecoveryBudget {
  int _attempts = 0;

  bool get hasRemaining => _attempts < 2;

  Duration? reserve() {
    if (!hasRemaining) return null;
    return Duration(seconds: _attempts++ == 0 ? 1 : 3);
  }
}

bool isPlaybackRefreshRetryable(Object error) =>
    isBackendRetryable(error) ||
    (error is InvidiousServiceError &&
        !error.isGatewayAccessFailure &&
        !error.responseWasHtml &&
        !error.retryAfterIsInvalid &&
        (error.retryAfter ?? Duration.zero) <= Duration.zero &&
        const {408, 500}.contains(error.statusCode));
