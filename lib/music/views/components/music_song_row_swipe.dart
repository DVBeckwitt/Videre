import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../main.dart' show isTv;
import '../../../settings/states/settings.dart';
import '../../models/music_song_row_swipe_action.dart';

class MusicSongRowSwipe extends StatelessWidget {
  final Widget child;
  final Future<void> Function(MusicSongRowSwipeAction)? onAction;
  final double trailingInset;

  const MusicSongRowSwipe({
    super.key,
    required this.child,
    required this.onAction,
    this.trailingInset = 64,
  });

  @override
  Widget build(BuildContext context) {
    final action = onAction;
    if (isTv || action == null) return child;
    final (towardStart, towardEnd) =
        context.select((SettingsCubit? settings) => (
              settings?.state.musicSongSwipeTowardStart ??
                  MusicSongRowSwipeAction.off,
              settings?.state.musicSongSwipeTowardEnd ??
                  MusicSongRowSwipeAction.off,
            ));
    if (towardStart == MusicSongRowSwipeAction.off &&
        towardEnd == MusicSongRowSwipeAction.off) {
      return child;
    }
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final left = rtl ? towardEnd : towardStart;
    final right = rtl ? towardStart : towardEnd;
    return _SwipeGesture(
      key: ValueKey((left, right, rtl)),
      left: left,
      right: right,
      rtl: rtl,
      onAction: action,
      trailingInset: trailingInset,
      child: child,
    );
  }
}

class _SwipeGesture extends StatefulWidget {
  final Widget child;
  final MusicSongRowSwipeAction left;
  final MusicSongRowSwipeAction right;
  final bool rtl;
  final Future<void> Function(MusicSongRowSwipeAction) onAction;
  final double trailingInset;

  const _SwipeGesture({
    super.key,
    required this.child,
    required this.left,
    required this.right,
    required this.rtl,
    required this.onAction,
    required this.trailingInset,
  });

  @override
  State<_SwipeGesture> createState() => _SwipeGestureState();
}

class _SwipeGestureState extends State<_SwipeGesture> {
  static const _threshold = 64.0;
  static const _maxReveal = 88.0;
  static const _navigationInset = 24.0;
  double _distance = 0;
  AppState? _session;

  MusicSongRowSwipeAction _actionFor(double dx) =>
      dx < 0 ? widget.left : widget.right;

  bool _acceptStart(Offset position) {
    final width = context.size!.width;
    final left = widget.rtl ? widget.trailingInset : _navigationInset;
    final right = widget.rtl ? _navigationInset : widget.trailingInset;
    return position.dx >= left && position.dx < width - right;
  }

  void _update(DragUpdateDetails details) {
    setState(() => _distance += details.primaryDelta!);
  }

  void _clear() {
    _session = null;
    if (_distance != 0 && mounted) setState(() => _distance = 0);
  }

  void _end() {
    final distance = _distance;
    final session = _session;
    _clear();
    final action = _actionFor(distance);
    if (distance.abs() < _threshold ||
        action == MusicSongRowSwipeAction.off ||
        !TickerMode.getNotifier(context).value ||
        ModalRoute.isCurrentOf(context) == false) {
      return;
    }
    final current = context.read<AppCubit?>()?.state;
    if (current != null &&
        (current.profileId != session?.profileId ||
            current.sessionRevision != session?.sessionRevision ||
            current.server != session?.server ||
            current.globalLoading ||
            current.sessionRecoveryRequired)) {
      return;
    }
    final settings = context.read<SettingsCubit>().state;
    final towardEnd = (distance > 0) != widget.rtl;
    if (action !=
        (towardEnd
            ? settings.musicSongSwipeTowardEnd
            : settings.musicSongSwipeTowardStart)) {
      return;
    }
    unawaited(widget.onAction(action));
  }

  @override
  Widget build(BuildContext context) {
    final action = _actionFor(_distance);
    final offset = action == MusicSongRowSwipeAction.off
        ? 0.0
        : _distance.clamp(-_maxReveal, _maxReveal);
    final colors = Theme.of(context).colorScheme;
    final ready = _distance.abs() >= _threshold;
    return RawGestureDetector(
      excludeFromSemantics: true,
      gestures: {
        _RowDragRecognizer:
            GestureRecognizerFactoryWithHandlers<_RowDragRecognizer>(
          _RowDragRecognizer.new,
          (recognizer) {
            recognizer.acceptStart = _acceptStart;
            recognizer.acceptDirection =
                (dx) => _actionFor(dx) != MusicSongRowSwipeAction.off;
            recognizer.dragStartBehavior = DragStartBehavior.down;
            recognizer.onlyAcceptDragOnThreshold = true;
            recognizer.onDown =
                (_) => _session = context.read<AppCubit?>()?.state;
            recognizer.onUpdate = _update;
            recognizer.onEnd = (_) {
              if (recognizer.released) {
                _end();
              } else {
                _clear();
              }
            };
            recognizer.onCancel = _clear;
          },
        ),
      },
      child: ClipRect(
        child: Stack(
          alignment: offset < 0 ? Alignment.centerRight : Alignment.centerLeft,
          children: [
            if (offset.abs() >= 24)
              Positioned.fill(
                child: ExcludeSemantics(
                  child: Align(
                    alignment: offset < 0
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: SizedBox(
                      width: offset.abs(),
                      height: double.infinity,
                      child: ColoredBox(
                        color: ready
                            ? colors.primaryContainer
                            : colors.surfaceContainerHighest,
                        child: Icon(
                          action == MusicSongRowSwipeAction.playNext
                              ? Icons.playlist_play
                              : Icons.playlist_add,
                          color: ready
                              ? colors.onPrimaryContainer
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Transform.translate(
              key: const ValueKey('song-row'),
              offset: Offset(offset, 0),
              transformHitTests: false,
              child: widget.child,
            ),
          ],
        ),
      ),
    );
  }
}

/// Let the containing page claim edge swipes and unassigned directions.
class _RowDragRecognizer extends HorizontalDragGestureRecognizer {
  late bool Function(Offset) acceptStart;
  late bool Function(double) acceptDirection;
  int? _pointer;
  bool released = false;

  _RowDragRecognizer() : super(supportedDevices: {PointerDeviceKind.touch});

  @override
  bool isPointerAllowed(PointerEvent event) =>
      _pointer == null &&
      acceptStart(event.localPosition) &&
      super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _pointer = event.pointer;
    super.addAllowedPointer(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
          PointerDeviceKind pointerDeviceKind, double? deviceTouchSlop) =>
      acceptDirection(globalDistanceMoved) &&
      super.hasSufficientGlobalDistanceToAccept(
          pointerDeviceKind, deviceTouchSlop);

  @override
  void handleEvent(PointerEvent event) {
    // The base recognizer also ends accepted drags when a pointer is cancelled.
    released = event is PointerUpEvent;
    super.handleEvent(event);
    released = false;
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _pointer = null;
    super.didStopTrackingLastPointer(pointer);
  }
}
