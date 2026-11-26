import 'package:clipious/music/models/music_player_appearance.dart';
import 'package:clipious/music/views/components/music_player_scrubber.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final progress = find.byKey(const ValueKey('music-player-progress'));

  for (final style in MusicScrubberStyle.values) {
    testWidgets('${style.name} supports accessible and release-only seeking', (
      tester,
    ) async {
      final commits = <double>[];
      var position = 20000.0;
      final rtl = style == MusicScrubberStyle.wave;
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 260,
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      return MusicPlayerScrubber(
                        style: style,
                        semanticLabel: 'Playback position',
                        maxPosition: 100000,
                        position: position,
                        onChanged: (value) => setState(() => position = value),
                        onChangeEnd: commits.add,
                        waveformPeaks: style == MusicScrubberStyle.wave
                            ? const [0.1, 0.9]
                            : null,
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final node = tester.getSemantics(progress);
      final data = node.getSemanticsData();
      expect(data.label, 'Playback position');
      expect(data.value, '00:20');
      expect(data.hasAction(SemanticsAction.increase), isTrue);
      expect(data.hasAction(SemanticsAction.decrease), isTrue);
      node.owner!.performAction(node.id, SemanticsAction.increase);
      await tester.pumpAndSettle();
      expect(commits.single, greaterThan(20000));

      final afterAccessibilitySeek = commits.removeLast();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(
        rtl ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight,
      );
      await tester.pumpAndSettle();
      expect(commits.single, greaterThan(afterAccessibilitySeek));

      final afterKeyboardSeek = commits.removeLast();
      final center = tester.getCenter(progress);
      final forward = rtl ? -1.0 : 1.0;
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(Offset(30 * forward, 0));
      await gesture.moveBy(Offset(40 * forward, 0));
      await tester.pump();
      expect(position, greaterThan(afterKeyboardSeek));
      expect(commits, isEmpty);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(commits.single, position);

      commits.clear();
      await tester.tapAt(center - Offset(60 * forward, 0));
      await tester.pumpAndSettle();
      expect(commits.single, lessThan(afterKeyboardSeek));
    });
  }

  for (final direction in TextDirection.values) {
    testWidgets(
      'Wave follows the amplitudes and resized track in ${direction.name}',
      (tester) async {
        final commits = <double>[];
        final peaks = List<double>.generate(128, (i) => i < 64 ? 0.05 : 0.85);
        Future<void> mount(double width, List<double>? peaks) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Directionality(
                textDirection: direction,
                child: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: width,
                      height: 48,
                      child: MusicPlayerScrubber(
                        style: MusicScrubberStyle.wave,
                        semanticLabel: 'Playback position',
                        maxPosition: 100000,
                        position: 50000,
                        onChanged: (_) {},
                        onChangeEnd: commits.add,
                        waveformPeaks: peaks,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        List<(double x, double height)> bars() {
          final bars = <(double, double)>[];
          expect(
            progress,
            paints
              ..everything((method, arguments) {
                if (method == #drawLine) {
                  final top = arguments[0] as Offset;
                  final bottom = arguments[1] as Offset;
                  bars.add((top.dx, bottom.dy - top.dy));
                }
                return true;
              }),
          );
          return bars;
        }

        Future<void> seekAtLoudBar(List<(double, double)> bars) async {
          final bar = (bars.length * 0.75).floor();
          final slider = tester.getRect(progress);
          await tester.tapAt(
            Offset(slider.left + bars[bar].$1, slider.center.dy),
          );
          final expected = (bar + 0.5) / bars.length * 100000;
          expect(commits.single, closeTo(expected, 1));
          commits.clear();
        }

        await mount(172, peaks);
        final narrowBars = bars();
        expect(narrowBars.first.$2, lessThan(narrowBars.last.$2 / 3));
        expect(
          narrowBars.first.$1,
          direction == TextDirection.rtl
              ? greaterThan(narrowBars.last.$1)
              : lessThan(narrowBars.last.$1),
        );
        await seekAtLoudBar(narrowBars);

        await mount(322, peaks);
        final wideBars = bars();
        expect(wideBars.length, greaterThan(narrowBars.length));
        expect(wideBars.first.$2, lessThan(wideBars.last.$2 / 3));
        await seekAtLoudBar(wideBars);

        await mount(322, null);
        expect(bars(), isEmpty);
        await seekAtLoudBar(wideBars);
      },
    );
  }

  testWidgets('all appearances preserve a disabled position slider', (
    tester,
  ) async {
    for (final style in MusicScrubberStyle.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MusicPlayerScrubber(
              style: style,
              semanticLabel: 'Playback position',
              maxPosition: 1,
              position: 0,
              onChanged: null,
              onChangeEnd: null,
            ),
          ),
        ),
      );
      final data = tester.getSemantics(progress).getSemanticsData();
      expect(data.hasAction(SemanticsAction.increase), isFalse);
      expect(data.hasAction(SemanticsAction.decrease), isFalse);
    }
  });
}
