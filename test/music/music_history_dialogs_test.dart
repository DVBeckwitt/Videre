import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/services/music_listening_history.dart';
import 'package:clipious/music/views/components/music_history_privacy.dart';
import 'package:clipious/music/views/components/music_listening_timeline.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _App extends AppCubit {
  _App() : super(AppState(0, null, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  onReady() {}

  @override
  initState() {}

  void changeProfile(String id) => emit(state.copyWith(profileId: id));
}

void main() {
  late SembastSqfDb database;
  late _App app;
  late bool previousTv;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    db = database;
    app = _App();
    previousTv = app_globals.isTv;
    app_globals.isTv = false;
  });

  tearDown(() async {
    RecommendationService.forgetProfile(database, 'default');
    await RecommendationService.flushPending();
    await app.close();
    await database.close();
    app_globals.isTv = previousTv;
  });

  Future<void> show(WidgetTester tester, Widget child,
      {double textScale = 1}) async {
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
      value: app,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(body: child),
      ),
    ));
  }

  Widget timelineButton() => Builder(
        builder: (context) => TextButton(
          onPressed: () => showMusicListeningTimeline(context,
              trackId: 'first', title: 'First song'),
          child: const Text('Open timeline'),
        ),
      );

  HistoryVideoCache entry(String id, DateTime date) =>
      HistoryVideoCache(id, 'Track $id', 'Artist', '')..created = date;

  testWidgets('timeline shows every play for the selected song and old history',
      (tester) async {
    final oldest = DateTime(2024, 2, 1, 12);
    final middle = DateTime(2024, 2, 2, 12);
    final latest = DateTime(2024, 2, 3, 12);
    final other = DateTime(2024, 2, 4, 12);
    await tester.runAsync(() async {
      await database.recordPlaybackHistory(
          PlaybackHistoryOrigin.music, entry('first', oldest));
      await database
          .beginMusicListening('first')!
          .record(entry('first', middle));
      await database
          .beginMusicListening('first')!
          .record(entry('first', latest));
      await database
          .beginMusicListening('second')!
          .record(entry('second', other));
    });
    await show(tester, timelineButton());
    await tester.tap(find.text('Open timeline'));
    await tester.pumpAndSettle();

    final material =
        MaterialLocalizations.of(tester.element(find.byType(AlertDialog)));
    final recentDate = find.text(material.formatFullDate(latest));
    final middleDate = find.text(material.formatFullDate(middle));
    expect(find.text('First song'), findsOneWidget);
    expect(tester.getTopLeft(recentDate).dy,
        lessThan(tester.getTopLeft(middleDate).dy));
    expect(find.text(material.formatFullDate(oldest)), findsOneWidget);
    expect(
        find.text('Last play recorded by an earlier version'), findsOneWidget);
    expect(find.text(material.formatFullDate(other)), findsNothing);

    await tester.runAsync(() async {
      final next = await database.createProfile('Another person');
      await database.useProfile(next.id);
      app.changeProfile(next.id);
    });
    await tester.pumpAndSettle();
    expect(find.text('First song'), findsNothing);
    expect(recentDate, findsNothing);
  });

  testWidgets('TV focus advances through the timeline and can close it',
      (tester) async {
    app_globals.isTv = true;
    final secondDay = DateTime(2024, 2, 2, 10);
    final firstDay = DateTime(2024, 2, 1, 10);
    await tester.runAsync(() async {
      await database
          .beginMusicListening('first')!
          .record(entry('first', firstDay));
      await database
          .beginMusicListening('first')!
          .record(entry('first', secondDay));
    });
    await show(tester, timelineButton());
    await tester.tap(find.text('Open timeline'));
    await tester.pumpAndSettle();

    final tiles = find.byType(ListTile);
    expect(tester.widget<ListTile>(tiles.at(0)).tileColor, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(tiles.at(1)).tileColor, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('Music privacy controls are independent and fit large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(tester, const MusicHistoryPrivacy(), textScale: 2);
    await tester
        .tap(find.byKey(const ValueKey('music-history-privacy-setting')));
    await tester.pumpAndSettle();

    final history =
        MusicListeningHistory.forProfile(database, database.profileId);
    final recommendations =
        RecommendationService.forProfile(database, database.profileId);
    final record = find.byKey(const ValueKey('music-history-pause-recording'));
    final learn =
        find.byKey(const ValueKey('music-history-recommendation-learning'));
    await tester.ensureVisible(record);
    await tester.tap(record);
    await tester.pumpAndSettle();
    expect(history.recordingPaused, isTrue);
    expect(recommendations.learningEnabled(RecommendationDomain.music), isTrue);

    await tester.ensureVisible(learn);
    await tester.tap(learn);
    await tester.pumpAndSettle();
    expect(history.recordingPaused, isTrue);
    expect(
        recommendations.learningEnabled(RecommendationDomain.music), isFalse);
    expect(recommendations.learningEnabled(RecommendationDomain.video), isTrue);
    expect(tester.takeException(), isNull);
  });
}
