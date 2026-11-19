import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../player/states/player.dart';

/// Shows a failed song selection above both the browsing route and the player.
/// The expanded phone player sits over the Navigator's page Scaffolds, while
/// a TV artist route can sit above the Scaffold that owns its player.
class MusicSelectionFeedback extends StatefulWidget {
  final Widget child;

  const MusicSelectionFeedback(
      {super.key, this.child = const SizedBox.shrink()});

  @override
  State<MusicSelectionFeedback> createState() => _MusicSelectionFeedbackState();
}

class _MusicSelectionFeedbackState extends State<MusicSelectionFeedback> {
  ValueNotifier<int>? _failures;
  OverlayEntry? _notice;

  void _show() {
    _removeNotice();
    final message = AppLocalizations.of(context)!.musicPlaybackError;
    var shown = false;
    late final OverlayEntry entry;
    entry = OverlayEntry(
        builder: (_) => ExcludeFocus(
              child: IgnorePointer(child: ScaffoldMessenger(
                child: Builder(builder: (context) {
                  if (!shown) {
                    shown = true;
                    final messenger = ScaffoldMessenger.of(context);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!identical(entry, _notice)) return;
                      messenger
                          .showSnackBar(
                            SnackBar(
                                content: Text(message),
                                behavior: SnackBarBehavior.floating),
                          )
                          .closed
                          .then((_) {
                        if (identical(entry, _notice)) _removeNotice();
                      });
                    });
                  }
                  return const Scaffold(backgroundColor: Colors.transparent);
                }),
              )),
            ));
    _notice = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  void _removeNotice() {
    final entry = _notice;
    _notice = null;
    entry?.remove();
    entry?.dispose();
  }

  @override
  void dispose() {
    _failures?.removeListener(_show);
    _removeNotice();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final failures = context
        .select((PlayerCubit player) => player.musicSelectionFailureRevision);
    if (!identical(failures, _failures)) {
      _failures?.removeListener(_show);
      _removeNotice();
      _failures = failures..addListener(_show);
    }
    return widget.child;
  }
}
