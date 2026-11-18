import 'dart:math' as math;
import 'dart:ui';

// Dart translation of Flow 565d1f7a (GPL-3.0), videoplayer/motion:
// DraggablePlayerGeometry.kt, DraggablePlayerDragMath.kt,
// DraggablePlayerGestureHandler.kt, MiniPlayerPinchGestureHandler.kt.
// See docs/flow-video-ui-sources.md for the source ledger.

enum FlowMiniCorner {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight;

  bool get isLeft => this == topLeft || this == bottomLeft;
  bool get isTop => this == topLeft || this == topRight;

  static FlowMiniCorner fromSides({required bool left, required bool top}) =>
      left ? (top ? topLeft : bottomLeft) : (top ? topRight : bottomRight);
}

enum FlowMiniTuckSide { left, right }

typedef FlowMiniDrop = ({
  FlowMiniCorner corner,
  Rect rect,
  FlowMiniTuckSide? tuckSide,
  bool dismiss,
});

/// Floating video layout in Flutter logical pixels. [usable] accounts for
/// Videre's safe insets, keyboard and navigation before Flow's 8dp margin.
class FlowMiniGeometry {
  static const margin = 8.0;
  static const _baseFraction = .45;
  static const _tabletWidthCap = 260.0;
  static const _wideThreshold = 1.5;
  static const _sixteenNine = 16 / 9;
  static const _aspectTolerance = 1.03;
  static const _cornerFlingVelocity = 400.0;
  static const _cornerAxisDominance = .8;
  static const _cornerTravelFraction = .15;
  static const _velocityProjectionSeconds = .3;
  static const _rubberBandFollow = .35;
  static const _closeBelowHeights = .4;
  static const _closeFlingVelocity = 1200.0;
  static const _closeAxisDominance = 2.0;
  static const _tuckTravelFraction = .5;
  static const _tuckFlingVelocity = 2500.0;
  static const _tuckAxisDominance = 3.0;

  final Size viewport;
  final Rect usable;
  final double aspectRatio;
  final bool largeWindow;
  final double devicePixelRatio;

  const FlowMiniGeometry({
    required this.viewport,
    required this.usable,
    required this.aspectRatio,
    required this.largeWindow,
    this.devicePixelRatio = 1,
  });

  double get boxAspectRatio {
    final aspect =
        aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : _sixteenNine;
    return aspect * _aspectTolerance >= _sixteenNine ? _sixteenNine : aspect;
  }

  double get _sizingSide =>
      largeWindow ? viewport.width : viewport.shortestSide;

  double get _baseWidth => largeWindow
      ? math.min(_sizingSide * _baseFraction, _tabletWidthCap)
      : _sizingSide * _baseFraction;

  double get _wideWidth =>
      math.max(_baseWidth, _sizingSide * (largeWindow ? .60 : 1) - 2 * margin);

  double get maxScale => math.max(1, _wideWidth / math.max(1, _baseWidth));

  bool isWide(double scale) => scale > _wideThreshold;

  double settledScale(double scale) => isWide(scale) ? maxScale : 1;

  Rect get _inside {
    final left = (usable.left + margin).clamp(0, viewport.width).toDouble();
    final top = (usable.top + margin).clamp(0, viewport.height).toDouble();
    final right =
        (usable.right - margin).clamp(left, viewport.width).toDouble();
    final bottom =
        (usable.bottom - margin).clamp(top, viewport.height).toDouble();
    return Rect.fromLTRB(left, top, right, bottom);
  }

  Size sizeAt(double scale) {
    final aspect = boxAspectRatio;
    final inside = _inside;
    final envelope = _baseWidth * scale.clamp(1, maxScale);
    final width = math.min(envelope * math.min(1, aspect),
        math.min(inside.width, inside.height * aspect));
    return Size(width, width / aspect);
  }

  /// Bounds of the player's origin, after reserving room for its current box.
  Rect _bounds(Size size) {
    final inside = _inside;
    return Rect.fromLTRB(
        inside.left,
        inside.top,
        math.max(inside.left, inside.right - size.width),
        math.max(inside.top, inside.bottom - size.height));
  }

  Offset _cornerOrigin(FlowMiniCorner corner, Rect bounds) => Offset(
        corner.isLeft ? bounds.left : bounds.right,
        corner.isTop ? bounds.top : bounds.bottom,
      );

  double get _phoneCenteredX => _inside.center.dx - sizeAt(maxScale).width / 2;

  Rect rest(FlowMiniCorner corner, {double scale = 1, Offset? wideOrigin}) {
    final size = sizeAt(scale);
    final bounds = _bounds(size);
    final anchor = _cornerOrigin(corner, bounds);
    var x = anchor.dx;
    if (isWide(scale)) {
      x = largeWindow ? wideOrigin?.dx ?? x : _phoneCenteredX;
    }
    return Offset(x.clamp(bounds.left, bounds.right).toDouble(), anchor.dy) &
        size;
  }

  double _rubberBand(double raw, double min, double max) {
    if (raw < min) return min - (min - raw) * _rubberBandFollow;
    if (raw > max) return max + (raw - max) * _rubberBandFollow;
    return raw;
  }

  Rect drag(Offset rawOrigin, {required double scale}) {
    final size = sizeAt(scale);
    final bounds = _bounds(size);
    return Offset(
          !largeWindow && isWide(scale)
              ? _phoneCenteredX
              : _rubberBand(rawOrigin.dx, bounds.left, bounds.right),
          _rubberBand(rawOrigin.dy, bounds.top, bounds.bottom),
        ) &
        size;
  }

  bool _goLeading({
    required bool wasLeading,
    required double delta,
    required double totalTravel,
    required double velocity,
    required double crossVelocity,
  }) {
    if (velocity.abs() * devicePixelRatio > _cornerFlingVelocity &&
        velocity.abs() > crossVelocity.abs() * _cornerAxisDominance) {
      return velocity < 0;
    }
    final projected = delta + velocity * _velocityProjectionSeconds;
    final threshold =
        math.max(totalTravel, 1 / devicePixelRatio) * _cornerTravelFraction;
    return wasLeading ? projected <= threshold : projected < -threshold;
  }

  FlowMiniDrop release({
    required FlowMiniCorner corner,
    required Offset rawOrigin,
    required Offset velocity,
    required double scale,
  }) {
    final size = sizeAt(scale);
    final bounds = _bounds(size);
    final current = drag(rawOrigin, scale: scale).topLeft;
    final vx = velocity.dx;
    final vy = velocity.dy;
    if (rawOrigin.dy - bounds.bottom > size.height * _closeBelowHeights ||
        (!corner.isTop &&
            vy * devicePixelRatio > _closeFlingVelocity &&
            vy > vx.abs() * _closeAxisDominance)) {
      return (
        corner: corner,
        rect: Offset(current.dx, viewport.height + margin) & size,
        tuckSide: null,
        dismiss: true,
      );
    }

    final anchor = _cornerOrigin(corner, bounds);
    final next = FlowMiniCorner.fromSides(
      left: _goLeading(
          wasLeading: corner.isLeft,
          delta: current.dx - anchor.dx,
          totalTravel: bounds.width,
          velocity: vx,
          crossVelocity: vy),
      top: _goLeading(
          wasLeading: corner.isTop,
          delta: current.dy - anchor.dy,
          totalTravel: bounds.height,
          velocity: vy,
          crossVelocity: vx),
    );
    if (!isWide(scale)) {
      final reach = size.width * _tuckTravelFraction;
      final sideways = vx.abs() > vy.abs() * _tuckAxisDominance;
      final side = switch (rawOrigin.dx) {
        final x when x - bounds.right > reach => FlowMiniTuckSide.right,
        final x when bounds.left - x > reach => FlowMiniTuckSide.left,
        _
            when sideways &&
                vx * devicePixelRatio > _tuckFlingVelocity &&
                !corner.isLeft =>
          FlowMiniTuckSide.right,
        _
            when sideways &&
                vx * devicePixelRatio < -_tuckFlingVelocity &&
                corner.isLeft =>
          FlowMiniTuckSide.left,
        _ => null,
      };
      if (side != null) {
        final rect = tucked(side, y: current.dy, scale: scale);
        return (
          corner: FlowMiniCorner.fromSides(
              left: side == FlowMiniTuckSide.left,
              top: rect.top < bounds.center.dy),
          rect: rect,
          tuckSide: side,
          dismiss: false,
        );
      }
    }
    return (
      corner: next,
      rect: rest(next, scale: scale),
      tuckSide: null,
      dismiss: false,
    );
  }

  Rect tucked(FlowMiniTuckSide side, {required double y, double scale = 1}) {
    final size = sizeAt(scale);
    final bounds = _bounds(size);
    return Offset(
          side == FlowMiniTuckSide.left ? -size.width : viewport.width,
          y.clamp(bounds.top, bounds.bottom).toDouble(),
        ) &
        size;
  }

  double pinchScale(
          {required double startScale, required double distanceRatio}) =>
      (startScale * distanceRatio).clamp(1, maxScale).toDouble();

  Offset _pinchAnchor(double scale, FlowMiniCorner corner) {
    final bounds = _bounds(sizeAt(scale));
    final anchor = _cornerOrigin(corner, bounds);
    if (largeWindow || maxScale <= 1) return anchor;
    final fraction = ((scale - 1) / (maxScale - 1)).clamp(0, 1);
    return Offset(
        anchor.dx + (_phoneCenteredX - anchor.dx) * fraction, anchor.dy);
  }

  Rect pinch({
    required double scale,
    required FlowMiniCorner corner,
    required Offset startOrigin,
    required double startScale,
  }) {
    final size = sizeAt(scale);
    final bounds = _bounds(size);
    final moved = startOrigin +
        _pinchAnchor(scale, corner) -
        _pinchAnchor(startScale, corner);
    return Offset(moved.dx.clamp(bounds.left, bounds.right).toDouble(),
            moved.dy.clamp(bounds.top, bounds.bottom).toDouble()) &
        size;
  }
}
