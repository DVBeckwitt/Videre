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
  final bool allowShortSwipe;
  final EdgeInsetsGeometry? scrollPadding;
  final VoidCallback onSwipeDown;
  final Widget child;

  const MinimizeOnSwipeDown({
    super.key,
    required this.enabled,
    this.scrollable = false,
    this.allowShortSwipe = false,
    this.scrollPadding,
    required this.onSwipeDown,
    required this.child,
  });

  @override
  State<MinimizeOnSwipeDown> createState() => _MinimizeOnSwipeDownState();
}

class _MinimizeOnSwipeDownState extends State<MinimizeOnSwipeDown> {
  static const _swipeDistance = 200.0;
  static const _shortSwipeDistance = 100.0;
  static const _flingDistance = 36.0;
  static const _flingVelocity = 650.0;

  int? _pointer;
  final _activePointers = <int>{};
  Offset? _startPosition;
  VelocityTracker? _velocityTracker;
  bool _verticalDragStarted = false;
  MinimizeDragScope? _previewScope;
  Object? _gestureIdentity;
  final _scrollController = ScrollController();

  @override
  void didUpdateWidget(MinimizeOnSwipeDown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) {
      _deferPreviewCancellation();
      _resetPointer();
    }
  }

  @override
  void dispose() {
    _deferPreviewCancellation();
    _resetPointer();
    _scrollController.dispose();
    super.dispose();
  }

  void _deferPreviewCancellation() {
    final preview = _previewScope;
    if (preview == null) return;
    _previewScope = null;
    // The preview lives on an ancestor that may already have built this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => preview.onEnd(false));
  }

  void _pointerDown(PointerDownEvent event) {
    _activePointers.add(event.pointer);
    if (_activePointers.length > 1) {
      _endPreview(false);
      _resetPointer();
      return;
    }
    // Reaching the top during a scroll needs a fresh pull to minimize.
    if (widget.enabled &&
        _pointer == null &&
        (!_scrollController.hasClients ||
            _scrollController.position.extentBefore == 0)) {
      _pointer = event.pointer;
      _startPosition = event.position;
      if (widget.allowShortSwipe) {
        _velocityTracker = VelocityTracker.withKind(event.kind)
          ..addPosition(event.timeStamp, event.position);
      }
      _gestureIdentity = MinimizeDragScope.maybeOf(context)?.identity;
    }
  }

  bool get _current =>
      widget.enabled &&
      _gestureIdentity == MinimizeDragScope.maybeOf(context)?.identity;

  bool get _ownsVerticalDrag =>
      _verticalDragStarted || (!widget.scrollable && !widget.allowShortSwipe);

  void _endPreview(bool minimize) {
    final preview = _previewScope;
    _previewScope = null;
    preview?.onEnd(minimize);
  }

  void _resetPointer() {
    _pointer = null;
    _startPosition = null;
    _velocityTracker = null;
    _verticalDragStarted = false;
  }

  void _pointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _startPosition == null) return;
    if (!_current) {
      _endPreview(false);
      _resetPointer();
      return;
    }
    final distance = event.position - _startPosition!;
    // A horizontal seek/track swipe or a Music pull that began by scrolling
    // upward retains ownership for the rest of the gesture.
    final horizontal =
        distance.dx.abs() > kTouchSlop && distance.dx.abs() > distance.dy.abs();
    final scrollingUp = widget.allowShortSwipe &&
        -distance.dy > kTouchSlop &&
        -distance.dy > distance.dx.abs();
    if (_previewScope == null && (horizontal || scrollingUp)) {
      _resetPointer();
      return;
    }
    _velocityTracker?.addPosition(event.timeStamp, event.position);
    if (_ownsVerticalDrag) _updatePreview(distance);
  }

  void _updatePreview(Offset distance) {
    if (_previewScope != null ||
        (distance.dy > kTouchSlop && distance.dy > distance.dx.abs())) {
      final motion = MinimizeDragScope.maybeOf(context);
      if (motion != null) {
        _previewScope = motion;
        // Muzza BottomSheet.kt dispatches raw deltas while held, then settles
        // at an anchor. Do not ease or repeatedly restart a tween under a finger.
        motion.onUpdate(distance.dy.clamp(0.0, double.infinity));
      }
    }
  }

  void _verticalDragStart(DragStartDetails details) {
    final start = _startPosition;
    if (start == null || !_current) return;
    _verticalDragStarted = true;
    _updatePreview(details.globalPosition - start);
  }

  bool _scrollStart(ScrollStartNotification notification) {
    if (_pointer != null &&
        notification.depth == 0 &&
        notification.dragDetails != null) {
      // Only the outer scroll view may minimize; text selection owns its drag.
      _verticalDragStarted = true;
    }
    return false;
  }

  bool _shouldMinimize(Offset distance) {
    if (distance.dy <= distance.dx.abs()) return false;
    if (!widget.allowShortSwipe) return distance.dy > _swipeDistance;
    if (distance.dy >= _shortSwipeDistance) return true;
    if (distance.dy < _flingDistance) return false;
    final velocity =
        _velocityTracker?.getVelocity().pixelsPerSecond ?? Offset.zero;
    return velocity.dy >= _flingVelocity && velocity.dy > velocity.dx.abs();
  }

  void _pointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    if (event.pointer != _pointer || _startPosition == null) {
      return;
    }

    final distance = event.position - _startPosition!;
    final minimize = _current && _ownsVerticalDrag && _shouldMinimize(distance);
    _resetPointer();
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
      _resetPointer();
    }
  }

  @override
  Widget build(BuildContext context) {
    var child = widget.child;
    if (widget.scrollable) {
      child = NotificationListener<ScrollStartNotification>(
        onNotification: _scrollStart,
        child: SingleChildScrollView(
          controller: _scrollController,
          padding: widget.scrollPadding,
          physics:
              widget.enabled ? const AlwaysScrollableScrollPhysics() : null,
          child: child,
        ),
      );
    } else if (widget.allowShortSwipe && widget.enabled) {
      // The artwork's horizontal recognizer can win a diagonal gesture even
      // when its vertical displacement is larger. Follow the arena result.
      child = GestureDetector(
        behavior: HitTestBehavior.translucent,
        excludeFromSemantics: true,
        onVerticalDragStart: _verticalDragStart,
        child: child,
      );
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _pointerDown,
      onPointerMove: _pointerMove,
      onPointerUp: _pointerUp,
      onPointerCancel: _pointerCancel,
      child: child,
    );
  }
}
