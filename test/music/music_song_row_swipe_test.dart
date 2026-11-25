import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app;
import 'package:clipious/music/models/music_song_row_swipe_action.dart';
import 'package:clipious/music/views/components/music_song_row_swipe.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_settings_cubit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppCubit appCubit;
  late SettingsCubit settings;
  late List<MusicSongRowSwipeAction> actions;
  late bool previousTv;
  final row = find.byKey(const ValueKey('test-song'));
  const playNext = MusicSongRowSwipeAction.playNext;
  const addToQueue = MusicSongRowSwipeAction.addToQueue;

  setUp(() async {
    previousTv = app.isTv;
    app.isTv = false;
    db = await SembastSqfDb.createInMemory();
    appCubit = TestAppCubit(AppState(0, null, HomeLayout()));
    appCubit.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    await appCubit.initState();
    settings = TestSettingsCubit(SettingsState.init(), appCubit);
    actions = [];
  });

  tearDown(() async {
    app.isTv = previousTv;
    await settings.close();
    await appCubit.close();
    await db.close();
  });

  Future<void> pumpRow(
    WidgetTester tester, {
    TextDirection direction = TextDirection.ltr,
    Widget Function(Widget)? surround,
    bool canQueue = true,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
    VoidCallback? onMenu,
  }) async {
    final song = MusicSongRowSwipe(
      onAction: canQueue ? (action) async => actions.add(action) : null,
      child: ListTile(
        key: const ValueKey('test-song'),
        title: const Text('Song'),
        onTap: onTap,
        onLongPress: onLongPress,
        trailing: IconButton(
          tooltip: 'Song actions',
          onPressed: onMenu,
          icon: const Icon(Icons.more_vert),
        ),
      ),
    );
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: appCubit),
        BlocProvider<SettingsCubit>.value(value: settings),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 440,
              height: 280,
              child: Directionality(
                textDirection: direction,
                child: surround?.call(song) ?? Center(child: song),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('off directions and row edges leave swipes to the page',
      (tester) async {
    final pages = PageController(initialPage: 1);
    addTearDown(pages.dispose);
    await pumpRow(tester,
        surround: (song) => PageView(controller: pages, children: [
              const Center(child: Text('Previous page')),
              Center(child: song),
              const Center(child: Text('Next page')),
            ]));

    Future<void> swipe(Offset from, double dx, double expectedPage) async {
      await tester.dragFrom(from, Offset(dx, 0));
      await tester.pumpAndSettle();
      expect(pages.page, expectedPage);
      pages.jumpToPage(1);
      await tester.pumpAndSettle();
    }

    expect(settings.state.musicSongSwipeTowardEnd, MusicSongRowSwipeAction.off);
    expect(
        settings.state.musicSongSwipeTowardStart, MusicSongRowSwipeAction.off);
    await swipe(tester.getCenter(row), 300, 0);
    await swipe(tester.getCenter(row), -300, 2);

    await tester.runAsync(() => settings.setMusicSongSwipeTowardEnd(playNext));
    await tester.pumpAndSettle();
    await swipe(tester.getCenter(row), -300, 2);
    final bounds = tester.getRect(row);
    await swipe(Offset(bounds.left + 10, bounds.center.dy), 300, 0);

    await tester
        .runAsync(() => settings.setMusicSongSwipeTowardStart(addToQueue));
    await tester.pumpAndSettle();
    await swipe(Offset(bounds.right - 10, bounds.center.dy), -300, 2);
    expect(actions, isEmpty);

    await swipe(tester.getCenter(row), 150, 1);
    expect(actions, [playNext]);
  });

  for (final direction in TextDirection.values) {
    testWidgets('swipes commit once on release in $direction', (tester) async {
      await tester.runAsync(() async {
        await settings.setMusicSongSwipeTowardEnd(playNext);
        await settings.setMusicSongSwipeTowardStart(addToQueue);
      });
      await pumpRow(tester, direction: direction);
      final towardEnd = direction == TextDirection.ltr ? 1.0 : -1.0;
      final center = tester.getCenter(row);
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(Offset(95 * towardEnd, 0));
      await gesture.moveBy(Offset(45 * towardEnd, 0));
      await tester.pump(const Duration(milliseconds: 100));
      expect(actions, isEmpty);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(actions, [playNext]);

      await tester.drag(row, Offset(-140 * towardEnd, 0));
      await tester.pumpAndSettle();
      expect(actions, [playNext, addToQueue]);
    });
  }

  testWidgets('cancelled and short swipes preserve tapping and scrolling',
      (tester) async {
    await tester.runAsync(() => settings.setMusicSongSwipeTowardEnd(playNext));
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    var taps = 0;
    var holds = 0;
    var menus = 0;
    await pumpRow(tester,
        onTap: () => taps++,
        onLongPress: () => holds++,
        onMenu: () => menus++,
        surround: (song) => ListView(controller: scroll, children: [
              song,
              const SizedBox(height: 420),
            ]));

    final gesture = await tester.startGesture(tester.getCenter(row));
    await gesture.moveBy(const Offset(140, 0));
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();
    await tester.drag(row, const Offset(40, 0));
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.longPress(row);
    await tester.tap(find.byTooltip('Song actions'));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(holds, 1);
    expect(menus, 1);

    await tester.drag(row, const Offset(8, -100));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    expect(actions, isEmpty);
  });

  testWidgets('unavailable rows, mouse drags and TV leave queue unchanged',
      (tester) async {
    await tester.runAsync(() => settings.setMusicSongSwipeTowardEnd(playNext));
    await pumpRow(tester, canQueue: false);
    await tester.drag(row, const Offset(150, 0));
    expect(actions, isEmpty);

    await pumpRow(tester);
    final mouse = await tester.startGesture(tester.getCenter(row),
        kind: PointerDeviceKind.mouse);
    await mouse.moveBy(const Offset(150, 0));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(actions, isEmpty);

    app.isTv = true;
    await pumpRow(tester);
    await tester.drag(row, const Offset(150, 0));
    await tester.pumpAndSettle();
    expect(actions, isEmpty);
  });
}
