import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/video_player.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/motion.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import 'player_modal_back_handler.dart';

Future<void> showSubtitleTimingPicker(
  BuildContext context,
  VideoPlayerCubit player,
) async {
  final target = player.subtitleTimingTarget;
  final offset = player.videoController?.subtitleOffset;
  if (target == null || offset == null) return;
  return showDialog<void>(
    context: context,
    useRootNavigator: false,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (_) => PlayerModalBackHandler(
      child:
          _SubtitleTimingPicker(player: player, target: target, offset: offset),
    ),
  );
}

class _SubtitleTimingPicker extends StatefulWidget {
  final VideoPlayerCubit player;
  final WatchSubtitleTimingTarget target;
  final ValueListenable<Duration> offset;

  const _SubtitleTimingPicker({
    required this.player,
    required this.target,
    required this.offset,
  });

  @override
  State<_SubtitleTimingPicker> createState() => _SubtitleTimingPickerState();
}

class _SubtitleTimingPickerState extends State<_SubtitleTimingPicker> {
  bool _saveFailed = false;

  Future<void> _adjust([Duration? shift]) async {
    try {
      await widget.player.adjustSubtitleTiming(widget.target, shift: shift);
      if (mounted && _saveFailed) setState(() => _saveFailed = false);
    } catch (_) {
      if (mounted && widget.player.subtitleTimingTarget == widget.target) {
        setState(() => _saveFailed = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final format =
        NumberFormat.decimalPattern(Localizations.localeOf(context).toString());
    const step = VideoPlayerCubit.subtitleTimingStep;
    const limit = VideoPlayerCubit.subtitleTimingLimit;
    return Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent(),
      },
      child: AlertDialog(
        alignment: Alignment.topCenter,
        scrollable: true,
        title: Text(locals.subtitleTiming),
        content: BlocBuilder<VideoPlayerCubit, VideoPlayerState>(
          bloc: widget.player,
          builder: (context, _) => ValueListenableBuilder<Duration>(
            valueListenable: widget.offset,
            builder: (context, offset, _) {
              final current =
                  widget.player.subtitleTimingTarget == widget.target;
              final milliseconds = offset.inMilliseconds;
              final formatted = format.format(milliseconds);
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text(locals.subtitleTimingOffset(
                        milliseconds > 0 ? '+$formatted' : formatted)),
                  ),
                  Wrap(
                    alignment: WrapAlignment.center,
                    children: [
                      TextButton(
                        autofocus: offset > -limit,
                        onPressed: current && offset > -limit
                            ? () => _adjust(-step)
                            : null,
                        child: Text(locals.subtitleTimingEarlier),
                      ),
                      TextButton(
                        autofocus: offset <= -limit,
                        onPressed: current && offset < limit
                            ? () => _adjust(step)
                            : null,
                        child: Text(locals.subtitleTimingLater),
                      ),
                      TextButton(
                        onPressed: current && offset != Duration.zero
                            ? () => _adjust()
                            : null,
                        child: Text(locals.subtitleTimingReset),
                      ),
                    ],
                  ),
                  if (_saveFailed)
                    Semantics(
                      liveRegion: true,
                      child: Text(locals.subtitleTimingSaveFailed),
                    ),
                ],
              );
            },
          ),
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
