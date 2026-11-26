import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../videos/models/video.dart';
import 'fullscreen_video_zoom.dart';
import 'seek_preview.dart';

// Dart translation of Flow 565d1f7a (GPL-3.0): PlayerTapGestures.kt,
// DoubleTapSeekZones.kt and PlayerDragGestures.kt. Flutter's gesture arena
// leaves buttons, the transport slider and the other player gestures intact.
class FlowVideoGestures extends StatefulWidget {
  final Video? video;
  final Duration duration;
  final Duration Function() readPosition;
  final bool canSeek;
  final VoidCallback toggleControls;
  final VoidCallback togglePlayback;
  final VoidCallback rewind;
  final VoidCallback fastForward;
  final ValueChanged<Duration> seek;
  final Widget child;

  const FlowVideoGestures({
    super.key,
    required this.video,
    required this.duration,
    required this.readPosition,
    required this.canSeek,
    required this.toggleControls,
    required this.togglePlayback,
    required this.rewind,
    required this.fastForward,
    required this.seek,
    required this.child,
  });

  @override
  State<FlowVideoGestures> createState() => _FlowVideoGesturesState();
}

enum _Zone { back, center, forward }

class _FlowVideoGesturesState extends State<FlowVideoGestures> {
  static const _sideGuard = 24.0;
  static const _dragEdgeGuard = 40.0;
  static const _dragSpanMs = 90000;
  static const _hapticIntervalMs = 5000;
  static const _seekWindow = Duration(milliseconds: 800);
  static const _touch = {PointerDeviceKind.touch};

  _Zone? _repeatZone;
  Timer? _pendingSurfaceTap;
  Timer? _repeatTimer;
  int _baseMs = 0;
  int _lastHapticMs = 0;
  double _travel = 0;
  Duration? _dragTarget;

  _Zone _zone(Offset point) {
    final width = context.size!.width;
    if (point.dx < width / 3) return _Zone.back;
    if (point.dx > 2 * width / 3) return _Zone.forward;
    return _Zone.center;
  }

  bool _outsideBackInset(Offset point) {
    final inset = MediaQuery.systemGestureInsetsOf(context);
    final edge = math.max(_sideGuard, math.max(inset.left, inset.right));
    return point.dx >= edge && point.dx <= context.size!.width - edge;
  }

  void _clearRepeat() {
    _repeatTimer?.cancel();
    _repeatZone = null;
  }

  void _skip(_Zone zone) {
    if (!widget.canSeek) return;
    _repeatTimer?.cancel();
    _repeatZone = zone;
    _repeatTimer = Timer(_seekWindow, _clearRepeat);
    if (zone == _Zone.back) {
      widget.rewind();
    } else {
      widget.fastForward();
    }
  }

  void _tap(TapUpDetails details) {
    final zone = _zone(details.localPosition);
    if (widget.canSeek && zone == _repeatZone) {
      _cancelPendingSurfaceTap();
      _skip(zone);
      return;
    }
    if (zone != _Zone.center && !widget.canSeek) {
      _cancelPendingSurfaceTap();
      widget.toggleControls();
      return;
    }
    if (_pendingSurfaceTap != null) {
      _cancelPendingSurfaceTap();
      if (zone == _Zone.center) {
        _clearRepeat();
        widget.togglePlayback();
      } else {
        _skip(zone);
      }
      return;
    }

    // Count only taps the surface won. An ancestor DoubleTapGestureRecognizer
    // holds the arena open, also delaying taps on the child transport buttons.
    _pendingSurfaceTap = Timer(kDoubleTapTimeout, () {
      _pendingSurfaceTap = null;
      widget.toggleControls();
    });
  }

  void _cancelPendingSurfaceTap() {
    _pendingSurfaceTap?.cancel();
    _pendingSurfaceTap = null;
  }

  void _startDrag(DragStartDetails details) {
    _cancelPendingSurfaceTap();
    _clearRepeat();
    _baseMs = widget.readPosition().inMilliseconds.clamp(
          0,
          widget.duration.inMilliseconds,
        );
    _lastHapticMs = _baseMs;
    _travel = 0;
  }

  void _updateDrag(DragUpdateDetails details) {
    final width = context.size!.width;
    final duration = widget.duration.inMilliseconds;
    if (width <= 0 || duration <= 0) return;
    final span = math.min(_dragSpanMs, duration);
    _travel += details.delta.dx;
    final rawMs = _baseMs + (_travel / width * span).toInt();
    final targetMs = rawMs.clamp(0, duration);
    if (targetMs != rawMs) {
      // Flow discards excess travel at either limit, so reversing responds
      // immediately instead of requiring the user to undo the overshoot.
      _travel = (targetMs - _baseMs) / span * width;
    }
    if ((targetMs - _lastHapticMs).abs() >= _hapticIntervalMs) {
      _lastHapticMs = targetMs;
      unawaited(HapticFeedback.selectionClick());
    }
    final target = Duration(milliseconds: targetMs);
    if (target != _dragTarget) setState(() => _dragTarget = target);
  }

  void _endDrag({required bool commit}) {
    final target = _dragTarget;
    if (target == null) return;
    setState(() => _dragTarget = null);
    if (commit && widget.canSeek && target.inMilliseconds != _baseMs) {
      widget.seek(target);
    }
  }

  @override
  void didUpdateWidget(covariant FlowVideoGestures oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.canSeek) {
      _clearRepeat();
      _dragTarget = null;
    }
  }

  @override
  void dispose() {
    _cancelPendingSurfaceTap();
    _clearRepeat();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gestureSettings = MediaQuery.maybeGestureSettingsOf(context);
    final target = _dragTarget;
    final surface = RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      excludeFromSemantics: true,
      gestures: {
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          () => TapGestureRecognizer(supportedDevices: _touch),
          (recognizer) => recognizer
            ..gestureSettings = gestureSettings
            ..onTapUp = _tap,
        ),
        if (widget.canSeek)
          _FlowSeekDragRecognizer:
              GestureRecognizerFactoryWithHandlers<_FlowSeekDragRecognizer>(
            () => _FlowSeekDragRecognizer(supportedDevices: _touch),
            (recognizer) {
              recognizer.gestureSettings = gestureSettings;
              recognizer.acceptPosition = (point) =>
                  _outsideBackInset(point) &&
                  point.dy >= _dragEdgeGuard &&
                  point.dy <= context.size!.height - _dragEdgeGuard;
              recognizer.onStart = _startDrag;
              recognizer.onUpdate = _updateDrag;
              recognizer.onEnd =
                  (_) => _endDrag(commit: !recognizer.endingWithCancel);
              recognizer.onCancel = () => _endDrag(commit: false);
            },
          ),
      },
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (target != null)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: SeekPreview(
                      video: widget.video,
                      position: target,
                      duration: widget.duration,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    return FullscreenVideoZoomGestures(
      zoom: FullscreenVideoZoomScope.maybeOf(context),
      child: surface,
    );
  }
}

class _FlowSeekDragRecognizer extends HorizontalDragGestureRecognizer {
  _FlowSeekDragRecognizer({super.supportedDevices});

  bool Function(Offset)? acceptPosition;
  bool endingWithCancel = false;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      (acceptPosition?.call(event.localPosition) ?? true) &&
      super.isPointerAllowed(event);

  @override
  void handleEvent(PointerEvent event) {
    // Once the drag has won, Flutter reports both up and cancel as onEnd.
    endingWithCancel = event is PointerCancelEvent;
    super.handleEvent(event);
  }
}
