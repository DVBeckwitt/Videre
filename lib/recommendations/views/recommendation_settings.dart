import 'package:flutter/material.dart';

import '../../globals.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../utils/motion.dart';
import '../recommendation_service.dart';

String _blockedCreatorsTitle(
        AppLocalizations locals, RecommendationDomain domain) =>
    domain == RecommendationDomain.video
        ? locals.recommendationBlockedCreators
        : locals.recommendationBlockedArtists;

Future<void> showRecommendationSettings(BuildContext context) =>
    showDialog<void>(
      context: context,
      useRootNavigator: false,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (context) => _RecommendationSettings(
          service: RecommendationService.forProfile(db, db.profileId)),
    );

class _RecommendationSettings extends StatefulWidget {
  final RecommendationService service;

  const _RecommendationSettings({required this.service});

  @override
  State<_RecommendationSettings> createState() =>
      _RecommendationSettingsState();
}

class _RecommendationSettingsState extends State<_RecommendationSettings> {
  bool _busy = false;
  bool _failed = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await action();
    } on Object {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset(RecommendationDomain domain) async {
    final locals = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (context) => AlertDialog(
        title: Text(locals.recommendationResetConfirm),
        content: Text(locals.recommendationResetHint),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(locals.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(locals.recommendationReset)),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _run(() => widget.service.reset(domain));
  }

  Future<void> _showBlockedCreators(RecommendationDomain domain) async {
    if (_busy || !widget.service.isCurrent) return;
    await showDialog<void>(
      context: context,
      useRootNavigator: false,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (context) =>
          _BlockedCreators(service: widget.service, domain: domain),
    );
  }

  Widget? _blockedCreatorsEntry(
      AppLocalizations locals, RecommendationDomain domain) {
    final blocked = widget.service.blockedCreators(domain);
    if (blocked.isEmpty) return null;
    return ListTile(
      key: ValueKey('recommendation-blocked-${domain.name}'),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.block),
      title: Text(_blockedCreatorsTitle(locals, domain)),
      trailing:
          Text(MaterialLocalizations.of(context).formatDecimal(blocked.length)),
      enabled: !_busy && widget.service.isCurrent,
      onTap: () => _showBlockedCreators(domain),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: widget.service.changes,
      builder: (context, _) => AlertDialog(
        title: Text(locals.localRecommendations),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(locals.recommendationLearningHint),
                const SizedBox(height: 16),
                for (final domain in RecommendationDomain.values) ...[
                  Text(
                      domain == RecommendationDomain.video
                          ? locals.videos
                          : locals.music,
                      style: Theme.of(context).textTheme.titleMedium),
                  SwitchListTile.adaptive(
                    key: ValueKey('recommendation-learning-${domain.name}'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(locals.recommendationLearning),
                    subtitle: widget.service.learningEnabled(domain)
                        ? null
                        : Text(locals.recommendationLearningPaused),
                    value: widget.service.learningEnabled(domain),
                    onChanged: _busy || !widget.service.isCurrent
                        ? null
                        : (value) => _run(() =>
                            widget.service.setLearningEnabled(domain, value)),
                  ),
                  ListTile(
                    key: ValueKey('recommendation-reset-${domain.name}'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.restart_alt),
                    title: Text(locals.recommendationReset),
                    subtitle: Text(locals.recommendationResetHint),
                    enabled: !_busy && widget.service.isCurrent,
                    onTap: () => _reset(domain),
                  ),
                  if (_blockedCreatorsEntry(locals, domain)
                      case final Widget row)
                    row,
                  const SizedBox(height: 12),
                ],
                if (_busy) const LinearProgressIndicator(),
                if (_failed)
                  Text(locals.recommendationError,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(MaterialLocalizations.of(context).closeButtonLabel)),
        ],
      ),
    );
  }
}

// Flow HiddenContentScreen groups the recommendation blocks by domain and
// gives each named entry a single unblock action.
class _BlockedCreators extends StatefulWidget {
  const _BlockedCreators({required this.service, required this.domain});

  final RecommendationService service;
  final RecommendationDomain domain;

  @override
  State<_BlockedCreators> createState() => _BlockedCreatorsState();
}

class _BlockedCreatorsState extends State<_BlockedCreators> {
  bool _busy = false;
  bool _failed = false;

  Future<void> _unblock(String creatorKey) async {
    if (_busy || !widget.service.isCurrent) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await widget.service.unblockCreator(widget.domain, creatorKey);
      if (!mounted) return;
      if (widget.service.isCurrent &&
          widget.service.blockedCreators(widget.domain).isEmpty &&
          ModalRoute.of(context)?.isCurrent == true) {
        Navigator.pop(context);
      }
    } on Object {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: widget.service.changes,
      builder: (context, _) {
        final blocked = widget.service.blockedCreators(widget.domain);
        return AlertDialog(
          title: Text(_blockedCreatorsTitle(locals, widget.domain)),
          content: SizedBox(
            width: 440,
            height: MediaQuery.sizeOf(context).height * 0.4,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (_failed) Text(locals.recommendationError),
                Expanded(
                  child: ListView.builder(
                    itemCount: blocked.length,
                    itemBuilder: (context, index) {
                      final item = blocked[index];
                      return ListTile(
                        key: ValueKey(item.key),
                        contentPadding: EdgeInsets.zero,
                        title: Text(item.label),
                        trailing: Semantics(
                          label: item.label,
                          child: IconButton(
                            key: ValueKey(
                                'recommendation-unblock-${widget.domain.name}-${item.key}'),
                            tooltip: locals.recommendationUnblockCreator,
                            icon: const Icon(Icons.lock_open_rounded),
                            onPressed: _busy || !widget.service.isCurrent
                                ? null
                                : () => _unblock(item.key),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(MaterialLocalizations.of(context).closeButtonLabel),
            ),
          ],
        );
      },
    );
  }
}
