import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Shares the expanded surface's raw drag with its video, header and scrollable
/// details. The decoder and playback state stay mounted throughout the gesture.
class MinimizeDragScope extends InheritedWidget {
  final Object identity;
  final ValueChanged<double> onUpdate;
  final ValueChanged<bool> onEnd;

  const MinimizeDragScope(
      {super.key,
      required this.identity,
      required this.onUpdate,
      required this.onEnd,
      required super.child});

  static MinimizeDragScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MinimizeDragScope>();

  @override
  bool updateShouldNotify(MinimizeDragScope oldWidget) =>
      identity != oldWidget.identity;
}

class MinimizeOnSwipeDown extends StatefulWidget {
  final bool enabled;
  final bool scrollable;
  final EdgeInsetsGeometry? scrollPadding;
  final VoidCallback onSwipeDown;
  final Widget child;

  const MinimizeOnSwipeDown({
    super.key,
    required this.enabled,
    this.scrollable = false,
    this.scrollPadding,
    required this.onSwipeDown,
    required this.child,
  });

  @override
  State<MinimizeOnSwipeDown> createState() => _MinimizeOnSwipeDownState();
}

class _MinimizeOnSwipeDownState extends State<MinimizeOnSwipeDown> {
  static const _swipeDistance = 200.0;

  int? _pointer;
  final _activePointers = <int>{};
  Offset? _startPosition;
  bool _scrollDragStarted = false;
  MinimizeDragScope? _previewScope;
  Object? _gestureIdentity;
  final _scrollController = ScrollController();

  @override
  void dispose() {
    final preview = _previewScope;
    if (preview != null) {
      // A replacement surface can unmount this listener during the frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => preview.onEnd(false));
    }
    _pointer = null;
    _scrollController.dispose();
    super.dispose();
  }

  void _pointerDown(PointerDownEvent event) {
    _activePointers.add(event.pointer);
    if (_activePointers.length > 1) {
      _endPreview(false);
      _pointer = null;
      _startPosition = null;
      return;
    }
    // Reaching the top during a scroll needs a fresh pull to minimize.
    if (widget.enabled &&
        _pointer == null &&
        (!_scrollController.hasClients ||
            _scrollController.position.extentBefore == 0)) {
      _pointer = event.pointer;
      _startPosition = event.position;
      _scrollDragStarted = false;
      _gestureIdentity = MinimizeDragScope.maybeOf(context)?.identity;
    }
  }

  bool get _current =>
      widget.enabled &&
      _gestureIdentity == MinimizeDragScope.maybeOf(context)?.identity;

  void _endPreview(bool minimize) {
    final preview = _previewScope;
    _previewScope = null;
    preview?.onEnd(minimize);
  }

  void _pointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _startPosition == null) return;
    if (!_current) {
      _endPreview(false);
      _pointer = null;
      _startPosition = null;
      return;
    }
    final distance = event.position - _startPosition!;
    // A horizontal seek/track swipe retains ownership for its whole gesture.
    if (_previewScope == null &&
        distance.dx.abs() > kTouchSlop &&
        distance.dx.abs() > distance.dy.abs()) {
      _pointer = null;
      _startPosition = null;
      return;
    }
    if ((!widget.scrollable || _scrollDragStarted) &&
        (_previewScope != null ||
            (distance.dy > kTouchSlop && distance.dy > distance.dx.abs()))) {
      final motion = MinimizeDragScope.maybeOf(context);
      if (motion != null) {
        _previewScope = motion;
        // Muzza BottomSheet.kt dispatches raw deltas while held, then settles
        // at an anchor. Do not ease or repeatedly restart a tween under a finger.
        motion.onUpdate(distance.dy.clamp(0.0, double.infinity));
      }
    }
  }

  bool _scrollStart(ScrollStartNotification notification) {
    if (notification.depth == 0 && notification.dragDetails != null) {
      // Only the outer scroll view may minimize; text selection owns its drag.
      _scrollDragStarted = true;
    }
    return false;
  }

  void _pointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    if (event.pointer != _pointer || _startPosition == null) {
      return;
    }

    final distance = event.position - _startPosition!;
    _pointer = null;
    _startPosition = null;

    final minimize = _current &&
        (!widget.scrollable || _scrollDragStarted) &&
        distance.dy > _swipeDistance &&
        distance.dy > distance.dx.abs();
    if (_previewScope != null) {
      _endPreview(minimize);
    } else if (minimize) {
      widget.onSwipeDown();
    }
  }

  void _pointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    if (event.pointer == _pointer) {
      _endPreview(false);
      _pointer = null;
      _startPosition = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _pointerDown,
      onPointerMove: _pointerMove,
      onPointerUp: _pointerUp,
      onPointerCancel: _pointerCancel,
      child: widget.scrollable
          ? NotificationListener<ScrollStartNotification>(
              onNotification: _scrollStart,
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: widget.scrollPadding,
                physics: widget.enabled
                    ? const AlwaysScrollableScrollPhysics()
                    : null,
                child: widget.child,
              ),
            )
          : widget.child,
    );
  }
}
