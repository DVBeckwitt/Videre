import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class FullscreenVideoZoom extends ChangeNotifier {
  static const maxScale = 6.0;

  Size _viewport = Size.zero;
  Size _fittedVideo = Size.zero;
  double _scale = 1;
  Offset _offset = Offset.zero;
  int _resetCount = 0;

  double get scale => _scale;
  Offset get offset => _offset;

  void reset() {
    _resetCount++;
    if (_scale == 1) return;
    _scale = 1;
    _offset = Offset.zero;
    notifyListeners();
  }

  Offset _boundedOffset(Offset offset, double scale) {
    if (scale == 1) return Offset.zero;
    final x = math.max(0.0, (_fittedVideo.width * scale - _viewport.width) / 2);
    final y = math.max(
      0.0,
      (_fittedVideo.height * scale - _viewport.height) / 2,
    );
    return Offset(offset.dx.clamp(-x, x), offset.dy.clamp(-y, y));
  }

  void _update(
    double targetScale,
    Offset previousFocalPoint,
    Offset focalPoint,
  ) {
    final scale = targetScale.clamp(1.0, maxScale);
    final center = _viewport.center(Offset.zero);
    final offset = _boundedOffset(
      focalPoint -
          center -
          (previousFocalPoint - center - _offset) * (scale / _scale),
      scale,
    );
    if (scale == _scale && offset == _offset) return;
    _scale = scale;
    _offset = offset;
    notifyListeners();
  }

  Widget buildSurface(Widget child, Size sourceSize, BoxFit fit) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        final fitted = applyBoxFit(fit, sourceSize, _viewport);
        // With Cover, the fitted destination shows only part of the texture.
        // Recover the full painted size so pan can reveal the cropped pixels.
        _fittedVideo = fitted.source.isEmpty
            ? Size.zero
            : Size(
                fitted.destination.width *
                    sourceSize.width /
                    fitted.source.width,
                fitted.destination.height *
                    sourceSize.height /
                    fitted.source.height,
              );
        _offset = _boundedOffset(_offset, _scale);
        return ListenableBuilder(
          listenable: this,
          child: child,
          builder: (context, child) => Transform(
            transform: Matrix4.diagonal3Values(_scale, _scale, 1)
              ..setTranslationRaw(_offset.dx, _offset.dy, 0),
            alignment: Alignment.center,
            transformHitTests: false,
            child: child,
          ),
        );
      },
    );
  }
}

class FullscreenVideoZoomScope extends InheritedWidget {
  const FullscreenVideoZoomScope({
    super.key,
    required this.zoom,
    required super.child,
  });

  final FullscreenVideoZoom? zoom;

  static FullscreenVideoZoom? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<FullscreenVideoZoomScope>()
      ?.zoom;

  @override
  bool updateShouldNotify(FullscreenVideoZoomScope oldWidget) =>
      zoom != oldWidget.zoom;
}

class FullscreenVideoZoomGestures extends StatelessWidget {
  const FullscreenVideoZoomGestures({
    super.key,
    required this.zoom,
    required this.child,
  });

  final FullscreenVideoZoom? zoom;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final zoom = this.zoom;
    _TwoFingerZoomRecognizer? pinch;
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        if (zoom != null)
          _TwoFingerZoomRecognizer:
              GestureRecognizerFactoryWithHandlers<_TwoFingerZoomRecognizer>(
            _TwoFingerZoomRecognizer.new,
            (recognizer) {
              pinch = recognizer;
              recognizer
                ..gestureSettings = MediaQuery.maybeGestureSettingsOf(
                  context,
                )
                ..zoom = zoom;
            },
          ),
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        // Hit-test callbacks run before the binding routes this move to the
        // seek and screen-control drag recognizers. A drag that already won
        // has rejected its pointer's entry below.
        onPointerMove: (event) => pinch?.update(event),
        child: child,
      ),
    );
  }
}

class _TwoFingerZoomRecognizer extends OneSequenceGestureRecognizer {
  _TwoFingerZoomRecognizer()
      : super(supportedDevices: {PointerDeviceKind.touch});

  late FullscreenVideoZoom zoom;
  final _positions = <int, Offset>{};
  final _accepted = <int>{};
  var _focalPoint = Offset.zero;
  var _startSpan = 1.0;
  var _startScale = 1.0;
  var _resetCountAtStart = 0;
  var _started = false;
  var _ended = false;

  @override
  String get debugDescription => 'fullscreen video zoom';

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    if (_ended || _positions.length == 2 || zoom._viewport.isEmpty) {
      resolvePointer(event.pointer, GestureDisposition.rejected);
      return;
    }
    _positions[event.pointer] = event.localPosition;
    if (_positions.length == 2) {
      final first = _positions.values.first;
      final second = _positions.values.last;
      _focalPoint = (first + second) / 2;
      _startSpan = math.max(1.0, (first - second).distance);
      _startScale = zoom.scale;
      _resetCountAtStart = zoom._resetCount;
    }
  }

  @override
  void acceptGesture(int pointer) {
    if (_positions.containsKey(pointer)) _accepted.add(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    if (_positions.containsKey(pointer)) _ended = true;
  }

  void update(PointerMoveEvent event) {
    if (_ended || !_positions.containsKey(event.pointer)) return;
    _positions[event.pointer] = event.localPosition;
    if (_positions.length != 2) return;
    if (_resetCountAtStart != zoom._resetCount) {
      _ended = true;
      return;
    }

    final first = _positions.values.first;
    final second = _positions.values.last;
    final focalPoint = (first + second) / 2;
    final span = math.max(1.0, (first - second).distance);
    if (!_started) {
      final slop = computeHitSlop(event.kind, gestureSettings);
      // A single pointer event can contribute to both measures.
      final motion = math.max(
        (span - _startSpan).abs(),
        (focalPoint - _focalPoint).distance * 2,
      );
      if (motion <= slop) return;
      resolve(GestureDisposition.accepted);
      if (_ended || _accepted.length != 2) return;
      _started = true;
    }

    zoom._update(_startScale * span / _startSpan, _focalPoint, focalPoint);
    _focalPoint = focalPoint;
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (_positions.remove(event.pointer) != null) _ended = true;
      resolvePointer(event.pointer, GestureDisposition.rejected);
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _accepted.clear();
    _started = false;
    _ended = false;
  }
}
