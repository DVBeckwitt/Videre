import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/services/watch_history.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The retry remains owned by this account if the active profile changes.
class WatchSyncStatus extends StatefulWidget {
  final Server account;
  const WatchSyncStatus({super.key, required this.account});

  @override
  State<WatchSyncStatus> createState() => _WatchSyncStatusState();
}

class _WatchSyncStatusState extends State<WatchSyncStatus> {
  bool _retrying = false;
  bool _failed = false;

  Future<void> _retry() async {
    if (_retrying) return;
    final owner = db.forProfile(widget.account.profileId);
    final account = owner.getAccount(widget.account.accountId);
    if (account == null) return;
    setState(() {
      _retrying = true;
      _failed = false;
    });
    try {
      await service.syncAccountHistory(account, database: owner, force: true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
      valueListenable: playbackHistoryRevision,
      builder: (context, _, __) {
        final owner = db.forProfile(widget.account.profileId);
        final repository = WatchRepository.forDatabase(owner);
        final status =
            repository?.syncStatus(widget.account.accountId)?['state'];
        final pending =
            repository?.pending(widget.account.accountId).isNotEmpty ?? false;
        if (!_retrying &&
            !_failed &&
            !pending &&
            (status == null || status == 'synced')) {
          return const SizedBox.shrink();
        }
        final account = owner.getAccount(widget.account.accountId);
        final signedIn = account != null && hasHistoryAccount(account);
        final locals = AppLocalizations.of(context)!;
        return Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_failed
                ? locals.accountActionFailed
                : status == 'signInRequired' || !signedIn
                    ? locals.watchedSyncSignIn
                    : locals.watchedSyncPending),
            Shortcuts(
              shortcuts: {
                LogicalKeySet(LogicalKeyboardKey.select):
                    const ActivateIntent(),
              },
              child: TextButton.icon(
                onPressed: _retrying || !signedIn ? null : _retry,
                icon: _retrying
                    ? const SizedBox.square(
                        dimension: 18,
                        child: MotionLoadingIndicator(
                            child: CircularProgressIndicator(strokeWidth: 2)))
                    : const Icon(Icons.sync),
                label: Text(locals.watchedSyncRetry),
              ),
            ),
          ]),
        );
      });
}
