import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/views/components/playback_speed_quick_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final slider = find.byKey(const ValueKey('playback-speed-quick-slider'));
  final advanced = find.byKey(const ValueKey('playback-speed-quick-advanced'));
  final advancedButton =
      find.byKey(const ValueKey('playback-speed-advanced-button'));
  final value = find.byKey(const ValueKey('playback-speed-quick-value'));

  Future<void> pumpControls(
    WidgetTester tester, {
    double speed = 1,
    double textScale = 1,
    required ValueChanged<double> onChanged,
    required VoidCallback onAdvanced,
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
          child: PlaybackSpeedQuickControls(
            initialSpeed: speed,
            onChanged: onChanged,
            onAdvanced: onAdvanced,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('drag selects the five detents without opening advanced controls',
      (tester) async {
    final speeds = <double>[];
    var advancedCount = 0;
    await pumpControls(tester,
        onChanged: speeds.add, onAdvanced: () => advancedCount++);

    final rect = tester.getRect(slider);
    final gesture =
        await tester.startGesture(Offset(rect.left + 2, rect.center.dy));
    for (var i = 1; i <= 40; i++) {
      await gesture.moveTo(
          Offset(rect.left + 2 + (rect.width - 4) * i / 40, rect.center.dy));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(speeds, [0.5, 1, 2, 3, 4]);
    expect(tester.widget<Text>(value).data, '4×');
    expect(advancedCount, 0);
  });

  testWidgets('header opens advanced while custom speed remains unchanged',
      (tester) async {
    final speeds = <double>[];
    var advancedCount = 0;
    await pumpControls(tester,
        speed: 1.37, onChanged: speeds.add, onAdvanced: () => advancedCount++);

    expect(tester.widget<Text>(value).data, '1.37×');
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    expect(advancedCount, 1);
    expect(speeds, isEmpty);
    expect(tester.widget<Text>(value).data, '1.37×');

    for (final custom in [0.1, 3.25, 6.0]) {
      await pumpControls(tester,
          speed: custom,
          onChanged: speeds.add,
          onAdvanced: () => advancedCount++);
      expect(tester.widget<Text>(value).data, custom == 6 ? '6×' : '$custom×');
      expect(tester.takeException(), isNull);
    }
    expect(speeds, isEmpty);
  });

  testWidgets(
      'visible Advanced button opens fine controls without changing speed',
      (tester) async {
    final speeds = <double>[];
    var advancedCount = 0;
    await pumpControls(tester,
        speed: 1.37, onChanged: speeds.add, onAdvanced: () => advancedCount++);

    expect(advancedButton, findsOneWidget);
    expect(find.descendant(of: advancedButton, matching: find.text('Advanced')),
        findsOneWidget);
    await tester.tap(advancedButton);
    await tester.pumpAndSettle();

    expect(advancedCount, 1);
    expect(speeds, isEmpty);
    expect(tester.widget<Text>(value).data, '1.37×');
  });

  testWidgets('quick entry fits a narrow screen with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var advancedCount = 0;
    final speeds = <double>[];
    await pumpControls(tester,
        speed: 1.51,
        textScale: 2,
        onChanged: speeds.add,
        onAdvanced: () => advancedCount++);

    expect(tester.takeException(), isNull);
    await tester.tap(value);
    await tester.pumpAndSettle();
    expect(advancedCount, 1);
    expect(speeds, isEmpty);
    await tester.ensureVisible(advancedButton);
    await tester.tap(advancedButton);
    await tester.pumpAndSettle();
    expect(advancedCount, 2);
    expect(speeds, isEmpty);
    await tester.ensureVisible(slider);
    await tester.drag(slider, const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(speeds.last, 4);
    expect(tester.takeException(), isNull);
  });
}
