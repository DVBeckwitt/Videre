import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/views/components/music_chart_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _showPicker(WidgetTester tester, String country,
    ValueChanged<String?> onSelected) async {
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async => onSelected(
              await showMusicChartPicker(context, browsingCountry: country)),
          child: const Text('Browse'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Browse'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the preferred country and opens its selected chart',
      (tester) async {
    String? playlist;
    await _showPicker(tester, 'JP', (selected) => playlist = selected);
    final japan = find.widgetWithText(ListTile, 'Japan');
    expect(japan, findsNWidgets(2));
    expect(tester.widget<ListTile>(japan.first).autofocus, isTrue);
    await tester.tap(find.descendant(
      of: japan,
      matching: find.text('Top 100 music videos'),
    ));
    await tester.pumpAndSettle();
    expect(playlist, 'PL4fGSI1pDJn5FhDrWnRp2NLzJCoPliNgT');
  });

  testWidgets('the TV Select key can open the Worldwide chart', (tester) async {
    String? playlist;
    await _showPicker(tester, 'NZ', (selected) => playlist = selected);
    final worldwide = find.widgetWithText(ListTile, 'Worldwide');
    expect(tester.widget<ListTile>(worldwide.first).autofocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(playlist, 'PL4fGSI1pDJn6puJdseH2Rt9sMvt9E2M4i');
  });
}
