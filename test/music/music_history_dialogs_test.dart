import 'dart:async';
import 'dart:ui' show SemanticsAction;

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

  Widget timelineButton({
    String trackId = 'first',
    String title = 'First song',
    String label = 'Open timeline',
  }) =>
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showMusicListeningTimeline(context,
              trackId: trackId, title: title),
          child: Text(label),
        ),
      );

  HistoryVideoCache entry(String id, DateTime date, {String? title}) =>
      HistoryVideoCache(id, title ?? 'Track $id', 'Artist', '')..created = date;

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

  testWidgets('calendar follows local midnight and opens just one day',
      (tester) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final beforeMidnight = DateTime(2024, 2, 29, 23, 59);
    final midnight = DateTime(2024, 3, 1);
    final afterMidnight = DateTime(2024, 3, 1, 0, 1);
    await tester.runAsync(() async {
      for (final local in [beforeMidnight, midnight, afterMidnight]) {
        await database
            .beginMusicListening('first')!
            .record(entry('first', local.toUtc()));
      }
    });
    await show(tester, timelineButton());
    await tester.tap(find.text('Open timeline'));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(3));

    final dialog = tester.element(find.byType(AlertDialog));
    final material = MaterialLocalizations.of(dialog);
    final use24Hours = MediaQuery.alwaysUse24HourFormatOf(dialog);
    String timeLabel(DateTime date) => material.formatTimeOfDay(
          TimeOfDay.fromDateTime(date),
          alwaysUse24HourFormat: use24Hours,
        );
    final february = find.text(material.formatMonthYear(beforeMidnight));
    final march = find.text(material.formatMonthYear(midnight));
    final leapDay = find.bySemanticsLabel(
        '${material.formatFullDate(beforeMidnight)}, 1 listen');
    final repeatDay = find
        .bySemanticsLabel('${material.formatFullDate(midnight)}, 2 listens');
    final before = find.text(timeLabel(beforeMidnight));
    final at = find.text(timeLabel(midnight));
    final after = find.text(timeLabel(afterMidnight));

    await tester.tap(find.byTooltip('Show calendar'));
    await tester.pumpAndSettle();
    expect(march, findsOneWidget);
    expect(repeatDay, findsOneWidget);
    expect(
        tester
            .getSemantics(repeatDay)
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue);
    await tester.tap(find.byTooltip('Previous month'));
    await tester.pumpAndSettle();
    expect(february, findsOneWidget);
    await tester.ensureVisible(leapDay);
    await tester.pumpAndSettle();
    await tester.tap(leapDay);
    await tester.pumpAndSettle();
    expect(before, findsOneWidget);
    expect(at, findsNothing);
    expect(after, findsNothing);

    await tester.tap(find.byTooltip('Back to calendar'));
    await tester.pumpAndSettle();
    expect(february, findsOneWidget);
    await tester.tap(find.byTooltip('Next month'));
    await tester.pumpAndSettle();
    await tester.tap(repeatDay);
    await tester.pumpAndSettle();
    expect(after, findsOneWidget);
    expect(at, findsOneWidget);
    expect(before, findsNothing);

    await tester.tap(find.byTooltip('Back to calendar'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show listening list'));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(3));
  });

  testWidgets('same-title calendars follow recording IDs and live deletion',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const title = 'Same song title';
    final firstListen = DateTime(2024, 3, 1, 12);
    await tester.runAsync(() async {
      await database
          .beginMusicListening('first')!
          .record(entry('first', firstListen, title: title));
      await database.beginMusicListening('first')!.record(entry(
          'first', firstListen.add(const Duration(minutes: 1)),
          title: title));
      await database
          .beginMusicListening('second')!
          .record(entry('second', firstListen, title: title));
    });
    await show(
      tester,
      Column(children: [
        timelineButton(title: title, label: 'Open first recording'),
        timelineButton(
            trackId: 'second', title: title, label: 'Open second recording'),
      ]),
      textScale: 2,
    );

    await tester.tap(find.text('Open first recording'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show calendar'));
    await tester.pumpAndSettle();
    final dialog = tester.element(find.byType(AlertDialog));
    final material = MaterialLocalizations.of(dialog);
    final date = material.formatFullDate(firstListen);
    final repeatDay = find.bySemanticsLabel('$date, 2 listens');
    await tester.ensureVisible(repeatDay);
    await tester.pumpAndSettle();
    await tester.tap(repeatDay);
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(2));

    final history =
        MusicListeningHistory.forProfile(database, database.profileId);
    await tester.runAsync(() => history.removeTracks({'first'}));
    await tester.pumpAndSettle();
    expect(find.text('No plays are recorded for this day.'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    await tester.tap(find.byTooltip('Back to calendar'));
    await tester.pumpAndSettle();
    expect(find.text('No plays are recorded for this song.'), findsOneWidget);
    await tester.tap(find.text(material.closeButtonLabel));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open second recording'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show calendar'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('$date, 1 listen'), findsOneWidget);
    expect(find.bySemanticsLabel('$date, 2 listens'), findsNothing);
    expect(tester.takeException(), isNull);
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

  testWidgets('TV D-pad opens the calendar and a listening day',
      (tester) async {
    app_globals.isTv = true;
    await tester.runAsync(() async {
      await database
          .beginMusicListening('first')!
          .record(entry('first', DateTime(2024, 3, 2, 12)));
    });
    await show(tester, timelineButton());
    await tester.tap(find.text('Open timeline'));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Show listening list'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back to calendar'), findsOneWidget);
    expect(find.byType(ListTile), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back to calendar'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back to calendar'), findsOneWidget);
    expect(find.byType(ListTile), findsOneWidget);
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
