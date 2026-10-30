import 'package:flutter/material.dart';
import '../../../l10n/generated/app_localizations.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../player/states/player.dart';
import '../../../player/views/components/backend_request_indicator.dart';
import '../../../player/views/components/backend_retry_notice.dart';
import '../../states/video.dart';

/// Retains the metadata request, then follows active playback of this video.
class VideoBackendStatus extends StatelessWidget {
  final VideoState state;

  const VideoBackendStatus({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final request = context.select((PlayerCubit player) {
      final active = player.state;
      if (!state.loadingVideo &&
          state.error.isEmpty &&
          !active.isClosing &&
          active.currentlyPlaying?.videoId == state.videoId) {
        return active.requestedBackend;
      }
      return state.requestedBackend;
    });
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BackendRequestIndicator(playback: request),
        if (state.loadingVideo && (request?.retryIndex ?? 0) > 0)
          BackendRetryNotice(
            backendName: request!.label,
            alternativeIndex: request.retryIndex,
          ),
        if (!state.loadingVideo &&
            state.error.isNotEmpty &&
            (request?.retryIndex ?? 0) > 0)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(AppLocalizations.of(context)!
                  .backendRecoveryFailedAfter(request!.retryIndex)),
            ),
          ),
      ],
    );
  }
}
