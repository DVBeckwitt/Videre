import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/service.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/states/video_in_list.dart';
import 'package:clipious/videos/views/components/watch_status_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _ObservedService extends Service {
  Future<void>? saving;

  @override
  Future<void> markVideoWatched(Video video, bool watched) =>
      saving = super.markVideoWatched(video, watched);
}

void main() {
  late _ObservedService observed;
  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    service = observed = _ObservedService();
  });

  tearDown(() async => db.close());

  Future<void> showButton(WidgetTester tester,
      {bool television = false}) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
          body: WatchStatusButton(
              video: const Video(videoId: 'video'), television: television)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'phone action updates cards immediately and preserves partial progress',
      (tester) async {
    await tester.runAsync(() => db.saveProgress(Progress(0.35, 'video')));
    final card = VideoInListCubit(
        const VideoInListState(video: Video(videoId: 'video')));
    addTearDown(card.close);
    await showButton(tester);
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.done));
      await observed.saving;
    });
    await tester.pumpAndSettle();
    expect(find.text('Mark unwatched'), findsOneWidget);
    expect(card.state.watched, isTrue);
    expect(card.state.progress, 0.35);
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.remove_done));
      await observed.saving;
    });
    await tester.pumpAndSettle();
    expect(find.text('Mark watched'), findsOneWidget);
    expect(card.state.watched, isFalse);
    expect(card.state.progress, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('TV remote can toggle watched without starting playback',
      (tester) async {
    await showButton(tester, television: true);
    Focus.of(tester.element(find.text('Mark watched'))).requestFocus();
    await tester.pump();
    await tester.runAsync(() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await observed.saving;
    });
    await tester.pumpAndSettle();
    expect(find.text('Mark unwatched'), findsOneWidget);
    expect(service.isVideoWatched('video'), isTrue);
    expect(db.getVideoProgress('video'), 0);
    await tester.runAsync(() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await observed.saving;
    });
    await tester.pumpAndSettle();
    expect(find.text('Mark watched'), findsOneWidget);
    expect(service.isVideoWatched('video'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}
