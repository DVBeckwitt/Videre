import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/views/screens/community_filter_settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = 'UCabcdefghijklmnopqrstuv';

class _Lists implements CommunityListStore {
  final refreshes = <CommunityList>[];
  bool failRefresh = false;

  @override
  Future<CommunitySnapshot?> load(CommunityList list) async => null;

  @override
  Future<CommunitySnapshot> refresh(CommunityList list,
      {required bool Function() isCurrent}) async {
    refreshes.add(list);
    if (failRefresh) throw StateError('List unavailable');
    return CommunitySnapshot(
      version: 1,
      generatedAt: DateTime.utc(2026, 11, 15),
      blockIds: {_channel},
      blockHandles: {},
      warnIds: {},
      warnHandles: {},
    );
  }
}

void main() {
  late _Lists lists;
  late SembastSqfDb database;
  late CommunityFilters original;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    lists = _Lists();
    original = communityFilters;
    communityFilters =
        CommunityFilters(database: () => database, repository: lists);
    await communityFilters.reloadForProfile();
  });

  tearDown(() async {
    communityFilters = original;
    await database.close();
  });

  Future<void> showSettings(WidgetTester tester, {bool tv = false}) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: CommunityFilterSettingsScreen(tv: tv),
    ));
    await tester.pumpAndSettle();
  }

  Finder tileFor(CommunityRule rule) => find.byKey(ValueKey(rule));

  Future<void> settle(WidgetTester tester) async {
    // Sembast's pending transactions also need time outside the fake clock.
    for (var attempt = 0; attempt < 8; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> tapRow(WidgetTester tester, Finder row,
      {double scroll = 160}) async {
    await tester.scrollUntilVisible(row, scroll);
    await tester.tap(row);
    await settle(tester);
  }

  Future<void> choose(WidgetTester tester, CommunityRule rule, String action,
      {double scroll = 160}) async {
    await tapRow(tester, tileFor(rule), scroll: scroll);
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text(action),
    ));
    await settle(tester);
  }

  testWidgets('each rule starts off and can be changed independently',
      (tester) async {
    await showSettings(tester);
    expect(lists.refreshes, isEmpty);
    expect(find.text('Refresh list'), findsNothing);
    for (final rule in CommunityRule.values) {
      expect(communityFilters.action(rule), CommunityAction.off);
    }

    await choose(tester, CommunityRule.youtubeBlock, 'Hide matches');
    await choose(tester, CommunityRule.youtubeWarn, 'Label matches');
    expect(lists.refreshes, [CommunityList.aislist]);
    expect(communityFilters.action(CommunityRule.music), CommunityAction.off);

    await choose(tester, CommunityRule.youtubeBlock, 'Off', scroll: -160);
    await choose(tester, CommunityRule.music, 'Hide matches');
    expect(lists.refreshes, [CommunityList.aislist, CommunityList.aimusic]);
    expect(communityFilters.action(CommunityRule.youtubeBlock),
        CommunityAction.off);
    expect(communityFilters.action(CommunityRule.youtubeWarn),
        CommunityAction.label);
    expect(communityFilters.action(CommunityRule.music), CommunityAction.hide);
  });

  testWidgets('TV Select opens the chooser and D-pad picks a different action',
      (tester) async {
    await showSettings(tester, tv: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await settle(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(communityFilters.action(CommunityRule.youtubeBlock),
        CommunityAction.label);
    expect(communityFilters.action(CommunityRule.youtubeWarn),
        CommunityAction.off);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh failure retains the verified list and shows its status',
      (tester) async {
    await showSettings(tester);
    await choose(tester, CommunityRule.youtubeBlock, 'Label matches');
    expect(find.textContaining('Last verified update'), findsOneWidget);
    lists.failRefresh = true;
    await tapRow(tester, find.text('Refresh list'));
    expect(find.textContaining('Using the last verified list'), findsOneWidget);
    expect(communityFilters.match(authorId: _channel), hasLength(1));
  });

  testWidgets('removing an allowed channel changes only the selected source',
      (tester) async {
    await tester.runAsync(() async {
      for (final source in CommunityList.values) {
        await communityFilters.allow(CommunityMatch(
          source: source,
          action: CommunityAction.hide,
          warning: false,
          identity: _channel,
        ));
      }
    });
    await showSettings(tester);
    await tapRow(tester,
        find.byKey(const ValueKey((CommunityList.aislist, 'exceptions'))));
    await tapRow(tester, find.text('Remove exception'));
    expect(find.text(_channel), findsNothing);
    expect(communityFilters.exceptions(CommunityList.aislist), isEmpty);
    expect(communityFilters.exceptions(CommunityList.aimusic), {_channel});
  });
}
