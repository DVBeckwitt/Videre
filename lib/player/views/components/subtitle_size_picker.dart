import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import 'player_modal_back_handler.dart';

Future<void> showSubtitleSizePicker(BuildContext context) {
  final settings = context.read<SettingsCubit>();
  final profile = db.profileId;
  final session = settings.appCubit.state.sessionRevision;
  return showDialog<void>(
    context: context,
    useRootNavigator: false,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (_) => PlayerModalBackHandler(
      child: _SubtitleSizePicker(
        settings: settings,
        isCurrentSession: () =>
            !settings.isClosed &&
            db.profileId == profile &&
            settings.appCubit.state.sessionRevision == session,
      ),
    ),
  );
}

class _SubtitleSizePicker extends StatefulWidget {
  final SettingsCubit settings;
  final bool Function() isCurrentSession;

  const _SubtitleSizePicker({
    required this.settings,
    required this.isCurrentSession,
  });

  @override
  State<_SubtitleSizePicker> createState() => _SubtitleSizePickerState();
}

class _SubtitleSizePickerState extends State<_SubtitleSizePicker> {
  bool _saveFailed = false;

  Future<void> _changeSize({required bool increase}) async {
    final settings = widget.settings;
    final isCurrentSession = widget.isCurrentSession;
    if (!isCurrentSession()) return;
    try {
      await settings.changeSubtitleSize(increase: increase);
      if (mounted && _saveFailed) setState(() => _saveFailed = false);
    } catch (_) {
      if (mounted && isCurrentSession()) {
        setState(() => _saveFailed = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final format =
        NumberFormat('0.##', Localizations.localeOf(context).toString());
    return Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent(),
      },
      child: AlertDialog(
        alignment: Alignment.topCenter,
        scrollable: true,
        title: Text(locals.subtitleFontSize),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BlocSelector<SettingsCubit, SettingsState, double>(
              bloc: widget.settings,
              selector: (state) => state.subtitleSize,
              builder: (context, size) => Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    key: const ValueKey('player-subtitle-size-decrease'),
                    tooltip: locals.subtitleFontSizeDecrease,
                    onPressed:
                        size <= 1 ? null : () => _changeSize(increase: false),
                    icon: const Icon(Icons.remove),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(format.format(size)),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('player-subtitle-size-increase'),
                    autofocus: true,
                    tooltip: locals.subtitleFontSizeIncrease,
                    onPressed: () => _changeSize(increase: true),
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            ),
            if (_saveFailed)
              Semantics(
                liveRegion: true,
                child: Text(locals.subtitleFontSizeSaveFailed),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MaterialLocalizations.of(context).closeButtonLabel),
          ),
        ],
      ),
    );
  }
}
