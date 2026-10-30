import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/views/components/playback_speed_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Finder control(String name) => find.byKey(ValueKey('playback-speed-$name'));

  Future<void> pumpControls(
    WidgetTester tester, {
    double speed = 1,
    required ValueChanged<double> onChanged,
    int pitch = 0,
    ValueChanged<int>? onPitchChanged,
    bool compact = false,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: PlaybackSpeedControls(
            initialSpeed: speed,
            onChanged: onChanged,
            initialPitchSemitones: pitch,
            onPitchChanged: onPitchChanged,
            compact: compact,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> tapControl(WidgetTester tester, String name) async {
    final target = control(name);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Slider slider(WidgetTester tester) =>
      tester.widget<Slider>(control('slider'));

  Finder pitchControl(String name) =>
      find.byKey(ValueKey('playback-pitch-$name'));

  Future<void> tapPitch(WidgetTester tester, String name) async {
    final target = pitchControl(name);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets('pitch steps and resets independently of speed', (tester) async {
    final speeds = <double>[];
    final pitches = <int>[];
    await pumpControls(tester,
        speed: 1.5, onChanged: speeds.add, onPitchChanged: pitches.add);

    await tapPitch(tester, 'increase');
    await tapPitch(tester, 'increase');
    expect(pitches, [1, 2]);
    expect(speeds, isEmpty);
    expect(slider(tester).value, 1.5);
    await tapControl(tester, 'reset');
    expect(speeds, [1]);
    expect(pitches, [1, 2]);
    expect(tester.widget<Slider>(pitchControl('slider')).value, 2);
    await tapPitch(tester, 'reset');
    expect(pitches, [1, 2, 0]);
    expect(speeds, [1]);
    expect(tester.widget<Slider>(pitchControl('slider')).value, 0);
  });

  testWidgets('pitch clamps to an octave and ignores repeated bound presses',
      (tester) async {
    final pitches = <int>[];
    await pumpControls(tester,
        pitch: 11, onChanged: (_) {}, onPitchChanged: pitches.add);
    await tapPitch(tester, 'increase');
    await tapPitch(tester, 'increase');
    expect(pitches, [12]);
    expect(
        tester.widget<IconButton>(pitchControl('increase')).onPressed, isNull);

    await pumpControls(tester,
        pitch: -11, onChanged: (_) {}, onPitchChanged: pitches.add);
    await tapPitch(tester, 'decrease');
    await tapPitch(tester, 'decrease');
    expect(pitches, [12, -12]);
    expect(
        tester.widget<IconButton>(pitchControl('decrease')).onPressed, isNull);
  });

  testWidgets('external pitch updates and reopening reflect current pitch',
      (tester) async {
    final pitches = <int>[];
    await pumpControls(tester,
        pitch: 4, onChanged: (_) {}, onPitchChanged: pitches.add);
    await tapPitch(tester, 'decrease');
    expect(pitches, [3]);
    await pumpControls(tester,
        pitch: -2, onChanged: (_) {}, onPitchChanged: pitches.add);
    expect(tester.widget<Slider>(pitchControl('slider')).value, -2);
    expect(pitches, [3]);
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpControls(tester,
        pitch: -2, onChanged: (_) {}, onPitchChanged: pitches.add);
    expect(tester.widget<Slider>(pitchControl('slider')).value, -2);
    expect(pitches, [3]);
  });

  testWidgets('TV select and horizontal navigation adjust pitch in semitones',
      (tester) async {
    final pitches = <int>[];
    await pumpControls(tester,
        compact: true, onChanged: (_) {}, onPitchChanged: pitches.add);
    await tester.ensureVisible(pitchControl('increase'));
    await tester.pumpAndSettle();
    final increaseIcon = find.descendant(
        of: pitchControl('increase'), matching: find.byType(Icon));
    Focus.of(tester.element(increaseIcon)).requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(pitches, [1]);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(pitches, [1, 0]);
  });

  testWidgets('pitch remains usable on a narrow screen with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pitches = <int>[];
    await pumpControls(tester,
        textScale: 2, onChanged: (_) {}, onPitchChanged: pitches.add);
    expect(tester.takeException(), isNull);
    await tapPitch(tester, 'increase');
    await tapPitch(tester, 'reset');
    expect(pitches, [1, 0]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'fine steps update immediately without accumulated rounding error',
      (tester) async {
    final speeds = <double>[];
    await pumpControls(tester, onChanged: speeds.add);

    await tapControl(tester, 'step-0.01');
    expect(speeds, isEmpty);
    for (var i = 0; i < 25; i++) {
      await tapControl(tester, 'increase');
    }
    expect(speeds.last, 1.25);
    expect(slider(tester).value, 1.25);

    for (var i = 0; i < 25; i++) {
      await tapControl(tester, 'decrease');
    }
    expect(speeds.last, 1);
    expect(slider(tester).value, 1);
  });

  testWidgets('step choice changes only the size of the next adjustment',
      (tester) async {
    final speeds = <double>[];
    await pumpControls(tester, onChanged: speeds.add);

    await tapControl(tester, 'increase');
    expect(speeds, [1.05]);
    await tapControl(tester, 'step-0.25');
    expect(speeds, [1.05]);
    await tapControl(tester, 'increase');
    expect(speeds.last, 1.30);
    await tapControl(tester, 'step-0.1');
    await tapControl(tester, 'decrease');
    expect(speeds.last, 1.20);
  });

  testWidgets('presets and reset apply immediately and retain fine adjustment',
      (tester) async {
    final speeds = <double>[];
    await pumpControls(tester, speed: 1.13, onChanged: speeds.add);

    await tapControl(tester, 'preset-1.5');
    expect(speeds.single, 1.5);
    expect(slider(tester).value, 1.5);
    await tapControl(tester, 'increase');
    expect(speeds.last, 1.55);
    await tapControl(tester, 'reset');
    expect(speeds.last, 1);
    expect(slider(tester).value, 1);
  });

  testWidgets('adjustments clamp to bounds and stop sending duplicate commands',
      (tester) async {
    final speeds = <double>[];
    await pumpControls(tester, speed: 5.99, onChanged: speeds.add);

    await tapControl(tester, 'increase');
    expect(speeds, [6]);
    await tapControl(tester, 'increase');
    expect(speeds, [6]);
    await tapControl(tester, 'decrease');
    expect(speeds.last, 5.95);

    await tester.pumpWidget(const SizedBox.shrink());
    speeds.clear();
    await pumpControls(tester, speed: 0.11, onChanged: speeds.add);
    await tapControl(tester, 'decrease');
    expect(speeds, [0.1]);
    await tapControl(tester, 'decrease');
    expect(speeds, [0.1]);
    await tapControl(tester, 'increase');
    expect(speeds.last, 0.15);
  });

  testWidgets('unexpected starting speeds are safe without changing playback',
      (tester) async {
    final speeds = <double>[];
    for (final (input, expected) in [
      (-1.0, 0.1),
      (10.0, 6.0),
      (double.nan, 1.0),
      (double.infinity, 1.0),
    ]) {
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpControls(tester, speed: input, onChanged: speeds.add);
      expect(slider(tester).value, expected);
      expect(tester.takeException(), isNull);
    }
    expect(speeds, isEmpty);
  });

  testWidgets('slider applies a speed without waiting for the sheet to close',
      (tester) async {
    final speeds = <double>[];
    await pumpControls(tester, onChanged: speeds.add);
    await tester.drag(control('slider'), const Offset(120, 0));
    await tester.pumpAndSettle();

    expect(speeds, isNotEmpty);
    expect(speeds.last, greaterThan(1));
    expect(slider(tester).value, speeds.last);
  });

  testWidgets('external speed changes and reopening show the active speed',
      (tester) async {
    final speeds = <double>[];
    await pumpControls(tester, onChanged: speeds.add);
    await tapControl(tester, 'increase');
    expect(speeds, [1.05]);

    await pumpControls(tester, speed: 2.35, onChanged: speeds.add);
    expect(slider(tester).value, 2.35);
    expect(speeds, [1.05]);
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpControls(tester, speed: 2.35, onChanged: speeds.add);
    expect(slider(tester).value, 2.35);
    expect(speeds, [1.05]);
  });

  testWidgets('TV select activates buttons and D-pad moves between them',
      (tester) async {
    final speeds = <double>[];
    await pumpControls(tester, compact: true, onChanged: speeds.add);
    final increaseIcon =
        find.descendant(of: control('increase'), matching: find.byType(Icon));
    Focus.of(tester.element(increaseIcon)).requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(speeds, [1.05]);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(speeds, [1.05, 1]);
  });

  testWidgets('TV slider adjusts horizontally and lets D-pad leave vertically',
      (tester) async {
    final speeds = <double>[];
    await pumpControls(tester, compact: true, onChanged: speeds.add);
    final sliderFocus = tester
        .widget<FocusableActionDetector>(find.descendant(
            of: control('slider'),
            matching: find.byType(FocusableActionDetector)))
        .focusNode!;
    sliderFocus.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(speeds.single, greaterThan(1));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(sliderFocus.hasFocus, isFalse);
    expect(speeds, hasLength(1));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(sliderFocus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(sliderFocus.hasFocus, isFalse);
    expect(speeds, hasLength(1));
  });

  testWidgets('controls remain usable on a narrow screen with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final speeds = <double>[];
    await pumpControls(tester, textScale: 2, onChanged: speeds.add);

    expect(tester.takeException(), isNull);
    await tapControl(tester, 'preset-3.0');
    expect(speeds.last, 3);
    await tapControl(tester, 'reset');
    expect(speeds.last, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact controls scroll in short landscape layouts',
      (tester) async {
    tester.view.physicalSize = const Size(640, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final speeds = <double>[];
    await pumpControls(tester, compact: true, onChanged: speeds.add);

    await tapControl(tester, 'step-0.01');
    await tapControl(tester, 'increase');
    expect(speeds.last, 1.01);
    await tapControl(tester, 'reset');
    expect(speeds.last, 1);
    expect(tester.takeException(), isNull);
  });
}
