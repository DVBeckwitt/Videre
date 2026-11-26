import 'package:clipious/player/views/components/flow_video_gestures.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _left = Offset(156, 200);
const _right = Offset(644, 200);

Future<void> _mount(
  WidgetTester tester, {
  required ValueChanged<bool> skipChapter,
  VoidCallback? toggleControls,
  VoidCallback? fastForward,
  VoidCallback? pause,
  GestureScaleStartCallback? onScaleStart,
  ValueChanged<Duration>? seek,
}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onScaleStart: onScaleStart,
            child: FlowVideoGestures(
              video: null,
              duration: const Duration(minutes: 5),
              readPosition: () => const Duration(minutes: 1),
              canSeek: true,
              toggleControls: toggleControls ?? () {},
              togglePlayback: () {},
              rewind: () {},
              fastForward: fastForward ?? () {},
              seek: seek ?? (_) {},
              skipChapter: skipChapter,
              child: SizedBox.expand(
                child: Center(
                  child: TextButton(
                    onPressed: pause ?? () {},
                    child: const Text('Pause'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

Duration _at(int milliseconds) => Duration(milliseconds: milliseconds);

Future<(TestGesture, TestGesture)> _downPair(
  WidgetTester tester,
  Offset center,
  int start,
) async {
  const spread = Offset(20, 0);
  final first = await tester.createGesture();
  final second = await tester.createGesture();
  await first.down(center - spread, timeStamp: _at(start));
  await second.down(center + spread, timeStamp: _at(start + 8));
  return (first, second);
}

Future<void> _tapPair(
  WidgetTester tester,
  Offset center,
  int start, {
  int duration = 40,
}) async {
  final (first, second) = await _downPair(tester, center, start);
  await first.up(timeStamp: _at(start + duration - 5));
  await second.up(timeStamp: _at(start + duration));
}

void main() {
  testWidgets(
    'still tap pairs skip left and right without one-finger actions',
    (tester) async {
      final skips = <bool>[];
      var timeSeeks = 0;
      var toggles = 0;
      var pauses = 0;
      await _mount(
        tester,
        skipChapter: skips.add,
        toggleControls: () => toggles++,
        fastForward: () => timeSeeks++,
        pause: () => pauses++,
      );

      await tester.tap(find.text('Pause'));
      expect(pauses, 1);
      await tester.tapAt(_right);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(_right);
      expect(timeSeeks, 1);

      await _tapPair(tester, _right, 200);
      expect(skips, isEmpty);
      await _tapPair(tester, _right, 310);
      await _tapPair(tester, _left, 480);
      await _tapPair(tester, _left, 620);
      await tester.pump(kDoubleTapTimeout);

      expect(skips, [true, false]);
      expect(timeSeeks, 1);
      expect(toggles, 0);
      expect(pauses, 1);
    },
  );

  testWidgets('moving pinch wins the arena and cancels a pending tap pair', (
    tester,
  ) async {
    final skips = <bool>[];
    final timeSeeks = <Duration>[];
    var pinchStarts = 0;
    await _mount(
      tester,
      skipChapter: skips.add,
      onScaleStart: (_) => pinchStarts++,
      seek: timeSeeks.add,
    );
    await _tapPair(tester, _right, 0);

    final (first, second) = await _downPair(tester, _right, 120);
    await first.moveBy(const Offset(-24, 0), timeStamp: _at(145));
    await second.moveBy(const Offset(24, 0), timeStamp: _at(160));
    await first.up(timeStamp: _at(180));
    await second.up(timeStamp: _at(190));

    expect(pinchStarts, 1);
    expect(timeSeeks, isEmpty);
    await _tapPair(tester, _right, 240);
    expect(skips, isEmpty);
    await _tapPair(tester, _right, 370);
    expect(skips, [true]);
  });

  testWidgets('expired, held and cancelled taps cannot make a chapter skip', (
    tester,
  ) async {
    final skips = <bool>[];
    await _mount(tester, skipChapter: skips.add);
    await _tapPair(tester, _right, 0);
    await _tapPair(tester, _right, 400);
    await _tapPair(tester, _right, 540, duration: 550);

    await _tapPair(tester, _right, 1200);
    final (first, second) = await _downPair(tester, _right, 1340);
    await first.cancel(timeStamp: _at(1370));
    await second.up(timeStamp: _at(1380));

    await _tapPair(tester, _right, 1440);
    expect(skips, isEmpty);
    await _tapPair(tester, _right, 1560);
    expect(skips, [true]);
  });

  testWidgets('single touches and extra fingers interrupt the tap sequence', (
    tester,
  ) async {
    final skips = <bool>[];
    await _mount(tester, skipChapter: skips.add);
    await _tapPair(tester, _left, 0);
    final single = await tester.createGesture();
    await single.down(_left, timeStamp: _at(65));
    await single.up(timeStamp: _at(95));

    await _tapPair(tester, _left, 120);
    final (first, second) = await _downPair(tester, _left, 220);
    final third = await tester.createGesture();
    await third.down(_left, timeStamp: _at(234));
    await first.up(timeStamp: _at(245));
    await second.up(timeStamp: _at(250));
    await third.up(timeStamp: _at(255));

    await _tapPair(tester, _left, 300);
    expect(skips, isEmpty);
    await _tapPair(tester, _left, 430);
    expect(skips, [false]);
  });
}
