import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/views/screens/release_notes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bundled tags sort stable releases and beta numbers in release order',
      () {
    expect(
        releaseVersionsFromAssets([
          'docs/releases/v1.2.10-beta.2.md',
          'docs/releases/v1.2.9.md',
          'docs/releases/v1.2.10.md',
          'docs/releases/v1.2.10-beta.10.md',
          'docs/releases/README.md',
          'docs/releases/verification.md',
          'other/v2.0.0.md',
        ]),
        ['1.2.10', '1.2.10-beta.10', '1.2.10-beta.2', '1.2.9']);
  });

  Future<void> open(WidgetTester tester, String version,
      {bool television = false}) async {
    final assets = PlatformAssetBundle();
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) =>
          DefaultAssetBundle(bundle: assets, child: child!),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (context) {
        return Scaffold(
          body: TextButton(
            onPressed: () =>
                openReleaseNotes(context, version, television: television),
            child: const Text('About'),
          ),
        );
      }),
    ));
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
  }

  testWidgets('reads the installed beta offline and opens another release',
      (tester) async {
    await open(tester, '1.22.51-beta.4+60955');
    expect(find.text('1.22.51-beta.4 (installed)'), findsOneWidget);
    expect(find.text('Videre 1.22.51 Beta 4'), findsOneWidget);
    expect(find.textContaining('• Audio-only playback.'), findsOneWidget);
    expect(find.textContaining('**'), findsNothing);
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.22.50').hitTestable().last);
    await tester.pumpAndSettle();
    expect(find.text('Videre 1.22.50'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('About'), findsOneWidget);
  });

  testWidgets('a missing installed release can still browse bundled history',
      (tester) async {
    await open(tester, '1.99.0');
    expect(find.text('1.99.0 (installed)'), findsOneWidget);
    expect(find.textContaining('aren’t included'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.22.51').hitTestable().last);
    await tester.pumpAndSettle();
    expect(find.text('Videre 1.22.51'), findsOneWidget);
    expect(find.textContaining('aren’t included'), findsNothing);
  });

  testWidgets('a TV remote can read past the first screen and choose a release',
      (tester) async {
    await open(tester, '1.22.51', television: true);
    final list = tester.widget<ListView>(find.byType(ListView));
    final scroll = list.controller!;
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    for (var i = 0; i < 2; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
    }
    expect(scroll.offset, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Videre 1.22.51 Beta 4'), findsOneWidget);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));
}
