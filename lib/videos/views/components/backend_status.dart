import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../player/views/components/backend_request_indicator.dart';
import '../../../player/views/components/backend_retry_notice.dart';
import '../../states/video.dart';

bool showVideoMetadataRetry(VideoState state) =>
    state.retryingVideo && (state.requestedBackend?.retryIndex ?? 0) == 0;

class VideoBackendStatus extends StatelessWidget {
  final VideoState state;

  const VideoBackendStatus({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    if (!state.loadingVideo && state.error.isEmpty) {
      return const SizedBox.shrink();
    }
    final request = state.requestedBackend;
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
