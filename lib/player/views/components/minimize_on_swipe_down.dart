import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

class MinimizeOnSwipeDown extends StatefulWidget {
  final bool enabled;
  final bool scrollable;
  final VoidCallback onSwipeDown;
  final Widget child;

  const MinimizeOnSwipeDown({
    super.key,
    required this.enabled,
    this.scrollable = false,
    required this.onSwipeDown,
    required this.child,
  });

  @override
  State<MinimizeOnSwipeDown> createState() => _MinimizeOnSwipeDownState();
}

class _MinimizeOnSwipeDownState extends State<MinimizeOnSwipeDown> {
  static const _swipeDistance = 200.0;

  int? _pointer;
  Offset? _startPosition;
  Duration _pointerDownAt = Duration.zero;
  bool _dragStarted = false;
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _pointerDown(PointerDownEvent event) {
    // Reaching the top during a scroll needs a fresh pull to minimize.
    if (widget.enabled &&
        _pointer == null &&
        (!_scrollController.hasClients ||
            _scrollController.position.extentBefore == 0)) {
      _pointer = event.pointer;
      _startPosition = event.position;
      _pointerDownAt = event.timeStamp;
      _dragStarted = false;
    }
  }

  void _pointerMove(PointerMoveEvent event) {
    if (event.pointer == _pointer && !_dragStarted) {
      if (widget.scrollable &&
          event.timeStamp - _pointerDownAt >= kLongPressTimeout) {
        // Leave long-press selection to the description and comment text.
        _pointer = null;
        _startPosition = null;
      } else if ((event.position - _startPosition!).distance > kTouchSlop) {
        _dragStarted = true;
      }
    }
  }

  void _pointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer || _startPosition == null) {
      return;
    }

    final distance = event.position - _startPosition!;
    _pointer = null;
    _startPosition = null;

    if (widget.enabled &&
        distance.dy > _swipeDistance &&
        distance.dy > distance.dx.abs()) {
      widget.onSwipeDown();
    }
  }

  void _pointerCancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) {
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
          ? SingleChildScrollView(
              controller: _scrollController, child: widget.child)
          : widget.child,
    );
  }
}
