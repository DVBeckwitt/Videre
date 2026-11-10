import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../models/video_display_mode.dart';
import 'player_modal_back_handler.dart';

Future<void> showVideoDisplayModePicker(BuildContext context) async {
  final settings = context.read<SettingsCubit>();
  final profileId = db.profileId;
  final session = settings.appCubit.state.sessionRevision;
  bool isCurrentSession() =>
      !settings.isClosed &&
      db.profileId == profileId &&
      settings.appCubit.state.sessionRevision == session;
  final selected = settings.state.videoDisplayMode;
  final mode = await showDialog<VideoDisplayMode>(
    context: context,
    useRootNavigator: false,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (_) => PlayerModalBackHandler(
      child: _VideoDisplayModePicker(selected: selected),
    ),
  );
  if (mode == null || mode == selected || !isCurrentSession()) return;
  try {
    await settings.setVideoDisplayMode(mode);
  } catch (_) {
    if (!context.mounted || !isCurrentSession()) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(AppLocalizations.of(context)!.videoDisplaySaveFailed),
    ));
  }
}

class _VideoDisplayModePicker extends StatelessWidget {
  final VideoDisplayMode selected;

  const _VideoDisplayModePicker({required this.selected});

  Widget _choice(VideoDisplayMode mode, String label, {String? description}) {
    final isSelected = mode == selected;
    return MergeSemantics(
      child: Semantics(
        checked: isSelected,
        inMutuallyExclusiveGroup: true,
        child: Builder(
          builder: (context) => ListTile(
            key: ValueKey('video-display-mode-${mode.name}'),
            selected: isSelected,
            autofocus: isSelected,
            onFocusChange: (focused) {
              if (!focused) return;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) {
                  Scrollable.ensureVisible(
                    context,
                    alignment: 0.5,
                  );
                }
              });
            },
            leading: ExcludeSemantics(
              child: Icon(isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
            ),
            title: Text(label),
            subtitle: description == null ? null : Text(description),
            onTap: () => Navigator.of(context).pop(mode),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      child: AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        scrollable: true,
        title: Text(locals.videoDisplay),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _choice(VideoDisplayMode.fit, locals.videoDisplayFit,
                  description: locals.videoDisplayFitDescription),
              _choice(VideoDisplayMode.crop, locals.videoDisplayCrop,
                  description: locals.videoDisplayCropDescription),
              _choice(VideoDisplayMode.stretch, locals.videoDisplayStretch,
                  description: locals.videoDisplayStretchDescription),
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(locals.videoDisplayFixedRatioDescription),
              ),
              _choice(VideoDisplayMode.ratio4x3, '4:3'),
              _choice(VideoDisplayMode.ratio3x2, '3:2'),
              _choice(VideoDisplayMode.ratio16x9, '16:9'),
              _choice(VideoDisplayMode.ratio21x9, '21:9'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(locals.cancel),
          ),
        ],
      ),
    );
  }
}
