import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/music_ab_repeat.dart';
import 'package:clipious/utils.dart';
import 'package:flutter/material.dart';

class MusicAbRepeatControl extends StatefulWidget {
  const MusicAbRepeatControl({super.key, required this.controls});

  final MusicAbRepeatControls controls;

  @override
  State<MusicAbRepeatControl> createState() => _MusicAbRepeatControlState();
}

class _MusicAbRepeatControlState extends State<MusicAbRepeatControl> {
  final _markerFocus = FocusNode();
  final _clearFocus = FocusNode();
  bool _invalidMarker = false;

  @override
  void didUpdateWidget(MusicAbRepeatControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controls != widget.controls) _invalidMarker = false;
  }

  @override
  void dispose() {
    _markerFocus.dispose();
    _clearFocus.dispose();
    super.dispose();
  }

  void _clear() {
    if (_clearFocus.hasFocus) _markerFocus.requestFocus();
    widget.controls.clear();
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final controls = widget.controls;
    final start = controls.start;
    final end = controls.end;
    final label = switch ((start, end)) {
      (null, _) => locals.musicAbRepeat,
      (final start?, null) =>
        locals.musicAbRepeatPending(prettyDurationCustom(start)),
      (final start?, final end?) => locals.musicAbRepeatRange(
          prettyDurationCustom(start), prettyDurationCustom(end)),
    };
    final tooltip = switch ((start, end)) {
      (null, _) => locals.musicAbRepeatSetA,
      (_, null) => locals.musicAbRepeatSetB,
      _ => locals.musicAbRepeatExit,
    };
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Tooltip(
            message: tooltip,
            child: TextButton.icon(
              focusNode: _markerFocus,
              style: TextButton.styleFrom(
                iconSize: 18,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                backgroundColor: controls.isActive
                    ? theme.colorScheme.secondaryContainer
                    : null,
                foregroundColor: controls.isActive
                    ? theme.colorScheme.onSecondaryContainer
                    : null,
              ),
              onPressed: controls.isActive
                  ? _clear
                  : () {
                      final invalidMarker = !controls.mark();
                      if (_invalidMarker != invalidMarker) {
                        setState(() => _invalidMarker = invalidMarker);
                      }
                    },
              icon: Icon(controls.isActive ? Icons.close : Icons.repeat),
              label: Text(label, textAlign: TextAlign.center),
            ),
          ),
          if (start != null && end == null)
            IconButton(
              key: const ValueKey('music-ab-repeat-clear'),
              focusNode: _clearFocus,
              tooltip: locals.musicAbRepeatClear,
              onPressed: _clear,
              icon: const Icon(Icons.close, size: 18),
            ),
        ],
      ),
      if (_invalidMarker)
        Semantics(
          liveRegion: true,
          child: Text(
            start == null
                ? locals.musicAbRepeatInvalidA
                : locals.musicAbRepeatInvalidB,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
            textAlign: TextAlign.center,
          ),
        ),
    ]);
  }
}
