import 'dart:ui';

import 'package:clipious/player/models/flow_mini_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

// Cases translated from Flow 565d1f7a's DraggablePlayerGeometryTest,
// DraggablePlayerDragMathTest and MiniPlayerPinchGestureHandlerTest.
const phone = FlowMiniGeometry(
  viewport: Size(360, 800),
  usable: Rect.fromLTRB(0, 24, 360, 724),
  aspectRatio: 16 / 9,
  largeWindow: false,
);

const tablet = FlowMiniGeometry(
  viewport: Size(1024, 768),
  usable: Rect.fromLTRB(0, 24, 1024, 704),
  aspectRatio: 16 / 9,
  largeWindow: true,
);

FlowMiniDrop drop(Offset origin,
        {FlowMiniCorner from = FlowMiniCorner.bottomRight,
        Offset velocity = Offset.zero,
        double scale = 1,
        FlowMiniGeometry geometry = phone}) =>
    geometry.release(
      corner: from,
      rawOrigin: origin,
      velocity: velocity,
      scale: scale,
    );

void main() {
  test('fits the video box around the correct corner with safe margins', () {
    final right = phone.rest(FlowMiniCorner.bottomRight);
    expect(right, const Rect.fromLTWH(190, 624.875, 162, 91.125));
    expect(phone.rest(FlowMiniCorner.topLeft).topLeft, const Offset(8, 32));
    expect(tablet.rest(FlowMiniCorner.bottomLeft).width, 260);
    final landscape = FlowMiniGeometry(
      viewport: const Size(800, 360),
      usable: const Rect.fromLTRB(16, 24, 800, 320),
      aspectRatio: 16 / 9,
      largeWindow: false,
    );
    expect(landscape.sizeAt(1), phone.sizeAt(1));
  });

  test('wide content keeps the 16:9 box and portrait keeps its own ratio', () {
    FlowMiniGeometry aspect(double ratio) => FlowMiniGeometry(
          viewport: phone.viewport,
          usable: phone.usable,
          aspectRatio: ratio,
          largeWindow: false,
        );
    expect(aspect(21 / 9).sizeAt(1), phone.sizeAt(1));
    expect(aspect(1920 / 1088).sizeAt(1), phone.sizeAt(1));
    expect(aspect(double.nan).sizeAt(1), phone.sizeAt(1));
    expect(aspect(9 / 16).sizeAt(1), const Size(91.125, 162));
  });

  test('elastic drag follows the hand in bounds and 35% past a bound', () {
    final start = phone.rest(FlowMiniCorner.bottomRight);
    expect(phone.drag(start.topLeft - const Offset(30, 40), scale: 1).topLeft,
        start.topLeft - const Offset(30, 40));
    expect(phone.drag(start.topLeft + const Offset(100, 60), scale: 1).topLeft,
        start.topLeft + const Offset(35, 21));
  });

  test('corner hysteresis uses 15% travel and 300ms velocity projection', () {
    final start = phone.rest(FlowMiniCorner.bottomRight).topLeft;
    final travel = start.dx - phone.rest(FlowMiniCorner.bottomLeft).left;
    expect(drop(start - Offset(travel * .14, 0)).corner,
        FlowMiniCorner.bottomRight);
    expect(drop(start - Offset(travel * .16, 0)).corner,
        FlowMiniCorner.bottomLeft);
    expect(drop(start, velocity: const Offset(-100, 0)).corner,
        FlowMiniCorner.bottomLeft);
  });

  test('a dominant fling switches corner in its direction', () {
    final start = phone.rest(FlowMiniCorner.bottomRight).topLeft;
    expect(drop(start, velocity: const Offset(-1500, 100)).corner,
        FlowMiniCorner.bottomLeft);
    expect(drop(start, velocity: const Offset(50, -1200)).corner,
        FlowMiniCorner.topRight);
  });

  test('tucks only for half-box overshoot or a hard outward same-side fling',
      () {
    final right = phone.rest(FlowMiniCorner.bottomRight);
    final left = phone.rest(FlowMiniCorner.bottomLeft);
    expect(drop(right.topLeft + Offset(right.width * .49, 0)).tuckSide, isNull);
    final tuck = drop(right.topLeft + Offset(right.width * .51, 0));
    expect(tuck.tuckSide, FlowMiniTuckSide.right);
    expect(tuck.rect.left, phone.viewport.width);
    final leftTuck = drop(left.topLeft - Offset(left.width * .51, 0),
        from: FlowMiniCorner.bottomLeft);
    expect(leftTuck.tuckSide, FlowMiniTuckSide.left);
    expect(leftTuck.rect.right, 0);
    expect(drop(right.topLeft, velocity: const Offset(3000, 200)).tuckSide,
        FlowMiniTuckSide.right);
    expect(drop(right.topLeft, velocity: const Offset(3000, 1500)).tuckSide,
        isNull);
    expect(drop(right.topLeft, velocity: const Offset(1800, 100)).tuckSide,
        isNull);
    final crossed = drop(left.topLeft,
        from: FlowMiniCorner.bottomLeft, velocity: const Offset(3000, 200));
    expect(crossed.tuckSide, isNull);
    expect(crossed.corner, FlowMiniCorner.bottomRight);
  });

  test('downward release closes only after travel or a bottom-corner flick',
      () {
    final start = phone.rest(FlowMiniCorner.bottomRight);
    final top = phone.rest(FlowMiniCorner.topRight);
    expect(
        drop(start.topLeft + Offset(0, start.height * .39)).dismiss, isFalse);
    final dismissed = drop(start.topLeft + Offset(0, start.height * .41));
    expect(dismissed.dismiss, isTrue);
    expect(dismissed.rect.top, greaterThan(phone.viewport.height));
    expect(
        drop(start.topLeft, velocity: const Offset(100, 1500)).dismiss, isTrue);
    expect(drop(start.topLeft, velocity: const Offset(1200, 1500)).dismiss,
        isFalse);
    final topFlick = drop(top.topLeft,
        from: FlowMiniCorner.topRight, velocity: const Offset(100, 1500));
    expect(topFlick.dismiss, isFalse);
    expect(topFlick.corner, FlowMiniCorner.bottomRight);
  });

  test('Flow fling thresholds retain their meaning at high pixel density', () {
    const dense = FlowMiniGeometry(
      viewport: Size(360, 800),
      usable: Rect.fromLTRB(0, 24, 360, 724),
      aspectRatio: 16 / 9,
      largeWindow: false,
      devicePixelRatio: 3,
    );
    final origin = dense.rest(FlowMiniCorner.bottomRight).topLeft;
    expect(
        drop(origin, velocity: const Offset(0, 400), geometry: dense).dismiss,
        isFalse);
    expect(
        drop(origin, velocity: const Offset(0, 401), geometry: dense).dismiss,
        isTrue);
    expect(
        drop(origin, velocity: const Offset(900, 100), geometry: dense)
            .tuckSide,
        FlowMiniTuckSide.right);
  });

  test('tablet pinch preserves the right/bottom edges and initial offset', () {
    final start = tablet.rest(FlowMiniCorner.bottomRight);
    Rect growsFrom(Offset origin, double scale) => tablet.pinch(
        scale: scale,
        corner: FlowMiniCorner.bottomRight,
        startOrigin: origin,
        startScale: 1);
    final grown = growsFrom(start.topLeft, 1.2);
    expect(grown.bottomRight, start.bottomRight);
    expect(grown.width, closeTo(312, .001));
    const freeStart = Offset(500, 480);
    expect(growsFrom(freeStart, 1).topLeft, freeStart);
    expect(growsFrom(freeStart, 1.2).left, closeTo(448, .001));
    expect(growsFrom(freeStart, 1.2).top, closeTo(450.75, .001));
  });

  test('phone pinch drifts from its corner to the centered wide box', () {
    final start = phone.rest(FlowMiniCorner.topRight);
    Rect at(double scale) => phone.pinch(
        scale: scale,
        corner: FlowMiniCorner.topRight,
        startOrigin: start.topLeft,
        startScale: 1);
    expect(at(1), start);
    expect(at(1.3).left, lessThan(start.left));
    expect(at(phone.maxScale).center.dx, phone.viewport.width / 2);
    expect(phone.settledScale(1.49), 1);
    expect(phone.settledScale(1.51), phone.maxScale);
    expect(phone.pinchScale(startScale: 2, distanceRatio: .25), 1);
    expect(phone.pinchScale(startScale: 1, distanceRatio: 5), phone.maxScale);
    final origin =
        phone.rest(FlowMiniCorner.bottomRight, scale: phone.maxScale);
    final wide = drop(const Offset(700, 200), scale: phone.maxScale);
    expect(wide.tuckSide, isNull);
    expect(wide.rect.left, origin.left);
  });

  test('content remains inside the available viewport with the keyboard up',
      () {
    const withIme = FlowMiniGeometry(
      viewport: Size(360, 800),
      usable: Rect.fromLTRB(14, 24, 360, 290),
      aspectRatio: 9 / 16,
      largeWindow: false,
    );
    final wide =
        withIme.rest(FlowMiniCorner.bottomLeft, scale: withIme.maxScale);
    expect(wide.left, greaterThanOrEqualTo(22));
    expect(wide.right, lessThanOrEqualTo(352));
    expect(wide.top, greaterThanOrEqualTo(32));
    expect(wide.bottom, lessThanOrEqualTo(282));
    expect(wide.width / wide.height, closeTo(9 / 16, .001));
  });
}
