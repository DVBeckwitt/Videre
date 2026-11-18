import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/settings/views/screens/video_filter.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async => db = await SembastSqfDb.createInMemory());
  tearDown(() => db.close());

  testWidgets('filter removal requires a hold and explicit confirmation',
      (tester) async {
    final filter = VideoFilter(value: 'keep me');
    await tester.runAsync(() => db.saveFilter(filter));
    await tester.pumpWidget(const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: VideoFilterSettingsScreen(),
    ));
    await tester.pumpAndSettle();
    final row = find.byKey(ValueKey('filter-${filter.uuid}'));
    await tester.drag(row, const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tester.drag(row, const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(db.getAllFilters().map((item) => item.uuid), [filter.uuid]);
    expect(row, findsOneWidget);

    await tester.longPress(row);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(db.getAllFilters(), hasLength(1));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(db.getAllFilters(), hasLength(1));

    await tester.longPress(row);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    for (var attempt = 0; attempt < 8; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(db.getAllFilters(), isEmpty);
    expect(row, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
