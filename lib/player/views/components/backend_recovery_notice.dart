import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../models/backend_recovery.dart';
import 'backend_retry_notice.dart';

String backendRecoveryFailureText(
        AppLocalizations locals, BackendRecovery recovery) =>
    recovery.alternativeIndex > 0
        ? locals.backendRecoveryFailedAfter(recovery.alternativeIndex)
        : locals.backendRecoveryFailed;

class BackendRecoveryNotice extends StatelessWidget {
  final BackendRecovery recovery;
  final bool compact;

  const BackendRecoveryNotice(
      {super.key, required this.recovery, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    if (recovery.phase == BackendRecoveryPhase.trying) {
      return BackendRetryNotice(
          backendName:
              recovery.label.isEmpty ? locals.backendDefault : recovery.label,
          alternativeIndex: recovery.alternativeIndex,
          compact: compact);
    }
    final ready = recovery.phase == BackendRecoveryPhase.ready;
    final succeeded = recovery.phase == BackendRecoveryPhase.succeeded;
    return IgnorePointer(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Semantics(
            liveRegion: true,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 400),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                      ready
                          ? Icons.pause_circle_outline
                          : succeeded
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                      color: Colors.white,
                      size: 20),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      ready
                          ? locals.backendReadyPaused
                          : succeeded
                              ? locals.backendPlaybackResumed
                              : backendRecoveryFailureText(locals, recovery),
                      maxLines: compact ? 1 : null,
                      overflow:
                          compact ? TextOverflow.ellipsis : TextOverflow.clip,
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
