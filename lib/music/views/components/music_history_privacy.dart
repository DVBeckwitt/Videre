import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/services/music_listening_history.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/utils.dart' show selectKeys;
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class MusicHistoryPrivacy extends StatelessWidget {
  const MusicHistoryPrivacy({super.key});

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final active = context.select((AppCubit app) =>
        db.profileId == app.state.profileId &&
        !app.state.globalLoading &&
        !app.state.sessionRecoveryRequired);
    return Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent(),
      },
      child: ListTile(
        key: const ValueKey('music-history-privacy-setting'),
        leading: const Icon(Icons.privacy_tip_outlined),
        title: Text(locals.musicHistoryPrivacy),
        enabled: active,
        onTap: active ? () => showMusicHistoryPrivacy(context) : null,
      ),
    );
  }
}

Future<void> showMusicHistoryPrivacy(BuildContext context) async {
  final app = context.read<AppCubit>();
  final owner = app.state;
  final database = db;
  bool isCurrent() {
    final state = app.state;
    return !app.isClosed &&
        identical(db, database) &&
        db.profileId == owner.profileId &&
        state.profileId == owner.profileId &&
        state.sessionRevision == owner.sessionRevision &&
        state.server == owner.server &&
        !state.globalLoading &&
        !state.sessionRecoveryRequired;
  }

  if (!isCurrent()) return;
  final history = MusicListeningHistory.forProfile(database, owner.profileId);
  final recommendations =
      RecommendationService.forProfile(database, owner.profileId);
  await showDialog<void>(
    context: context,
    useRootNavigator: false,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (_) => BlocBuilder<AppCubit, AppState>(
      bloc: app,
      builder: (context, _) => _MusicHistoryPrivacyDialog(
        history: history,
        recommendations: recommendations,
        isCurrent: isCurrent,
      ),
    ),
  );
}

class _MusicHistoryPrivacyDialog extends StatefulWidget {
  const _MusicHistoryPrivacyDialog({
    required this.history,
    required this.recommendations,
    required this.isCurrent,
  });

  final MusicListeningHistory history;
  final RecommendationService recommendations;
  final bool Function() isCurrent;

  @override
  State<_MusicHistoryPrivacyDialog> createState() =>
      _MusicHistoryPrivacyDialogState();
}

class _MusicHistoryPrivacyDialogState
    extends State<_MusicHistoryPrivacyDialog> {
  late final _changes = Listenable.merge(
      [widget.history.changes, widget.recommendations.changes]);
  bool _saving = false;
  bool _failed = false;

  Future<void> _save(Future<void> Function() update) async {
    if (_saving || !widget.isCurrent()) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await update();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent(),
      },
      child: ListenableBuilder(
        listenable: _changes,
        builder: (context, _) => AlertDialog(
          title: Text(locals.musicHistoryPrivacy),
          scrollable: true,
          content: !widget.isCurrent()
              ? Text(locals.musicSourceUnavailable)
              : SizedBox(
                  width: 420,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SwitchListTile(
                        key: const ValueKey('music-history-pause-recording'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(locals.musicHistoryPauseRecording),
                        value: widget.history.recordingPaused,
                        onChanged: _saving
                            ? null
                            : (paused) => _save(() =>
                                widget.history.setRecordingPaused(paused)),
                      ),
                      Text(locals.musicHistoryPauseRecordingHelp),
                      const SizedBox(height: 12),
                      SwitchListTile(
                        key: const ValueKey(
                            'music-history-recommendation-learning'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(locals.musicHistoryRecommendationLearning),
                        value: widget.recommendations
                            .learningEnabled(RecommendationDomain.music),
                        onChanged: _saving || !widget.recommendations.isCurrent
                            ? null
                            : (enabled) => _save(() => widget.recommendations
                                .setLearningEnabled(
                                    RecommendationDomain.music, enabled)),
                      ),
                      Text(locals.musicHistoryRecommendationLearningHelp),
                      if (_failed)
                        Semantics(liveRegion: true, child: Text(locals.error)),
                    ],
                  ),
                ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(MaterialLocalizations.of(context).closeButtonLabel),
            ),
          ],
        ),
      ),
    );
  }
}
