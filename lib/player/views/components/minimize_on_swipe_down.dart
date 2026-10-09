import 'package:flutter/material.dart';

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
  final _activePointers = <int>{};
  Offset? _startPosition;
  bool _scrollDragStarted = false;
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _pointerDown(PointerDownEvent event) {
    _activePointers.add(event.pointer);
    if (_activePointers.length > 1) {
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

    if (widget.enabled &&
        (!widget.scrollable || _scrollDragStarted) &&
        distance.dy > _swipeDistance &&
        distance.dy > distance.dx.abs()) {
      widget.onSwipeDown();
    }
  }

  void _pointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
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
      onPointerUp: _pointerUp,
      onPointerCancel: _pointerCancel,
      child: widget.scrollable
          ? NotificationListener<ScrollStartNotification>(
              onNotification: _scrollStart,
              child: SingleChildScrollView(
                controller: _scrollController,
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
