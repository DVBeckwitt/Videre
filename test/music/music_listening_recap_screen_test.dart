import 'dart:convert';
import 'dart:io';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/views/screens/music_listening_recap.dart';
import 'package:clipious/music/views/screens/music_listening_statistics.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _App extends AppCubit {
  _App() : super(AppState(0, null, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  void initState() {}

  @override
  void onReady() {}
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player() : super(PlayerState.init(null));

  final queues = <({String title, List<String> ids})>[];

  @override
  Future<void> playMusicCollectionQueue(
    List<Video> tracks, {
    required String queueTitle,
    bool shuffle = false,
    bool songTap = false,
    bool collectionDetail = false,
    int? startIndex,
    List<PlaylistReference?>? recommendationSources,
    bool Function()? isCurrent,
  }) async {
    expect(isCurrent?.call(), isTrue);
    queues.add((
      title: queueTitle,
      ids: tracks.map((track) => track.videoId).toList(),
    ));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  testWidgets('song ranking selects rows and clears on a ranking change',
      (tester) async {
    await tester.runAsync(() async {
      db = await SembastSqfDb.createInMemory();
      addTearDown(db.close);
      for (final id in ['alpha', 'bravo', 'charlie']) {
        await db
            .beginMusicListening(id)!
            .record(HistoryVideoCache(id, id, 'Artist', ''));
      }
    });
    final app = _App();
    addTearDown(app.close);
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
      value: app,
      child: const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MusicListeningStatisticsPage(),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('charlie'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('alpha'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'bravo'))
            .selected,
        isFalse);
    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsNothing);
    expect(find.text('Artist'), findsOneWidget);
    await tester.tap(find.text('Songs'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsNothing);
    expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'alpha'))
            .selected,
        isFalse);
  });

  testWidgets(
    'February recap uses local midnight for daily activity, replay and sharing',
    (tester) async {
      const files = MethodChannel('videre/files');
      const share = MethodChannel('dev.fluttercommunity.plus/share');
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      final temporary = Directory.systemTemp.createTempSync(
        'monthly-recap-test-',
      );
      addTearDown(() => temporary.deleteSync(recursive: true));

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final fileCalls = <MethodCall>[];
      final shareCalls = <MethodCall>[];
      messenger.setMockMethodCallHandler(files, (call) async {
        fileCalls.add(call);
        return true;
      });
      messenger.setMockMethodCallHandler(paths, (_) async => temporary.path);
      messenger.setMockMethodCallHandler(share, (call) async {
        shareCalls.add(call);
        return '';
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(files, null);
        messenger.setMockMethodCallHandler(paths, null);
        messenger.setMockMethodCallHandler(share, null);
      });

      final previousTv = app_globals.isTv;
      app_globals.isTv = false;
      addTearDown(() => app_globals.isTv = previousTv);
      await tester.runAsync(() async {
        db = await SembastSqfDb.createInMemory();
        addTearDown(() => db.close());
        await db.saveSetting(
          SettingsValue('music-listening-recap-enabled', 'true'),
        );
        Future<void> listen(String id, String title, DateTime date) => db
            .beginMusicListening(id)!
            .record(HistoryVideoCache(id, title, 'Artist', '')..created = date);

        await listen(
          'jan',
          'January boundary',
          DateTime(2024, 1, 31, 23, 59, 59, 999, 999),
        );
        await listen('opening', 'First of February', DateTime(2024, 2));
        await listen(
          'midnight',
          'Just before leap day',
          DateTime(2024, 2, 28, 23, 59, 59, 999, 999),
        );
        await listen('leap', 'Leap day song', DateTime(2024, 2, 29));
        await listen(
          'leap',
          'Leap day song',
          DateTime(2024, 2, 29, 23, 59, 59, 999, 999),
        );
        await listen('mar', 'March boundary', DateTime(2024, 3));
      });

      final app = _App();
      final player = _Player();
      addTearDown(app.close);
      addTearDown(player.close);
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<AppCubit>.value(value: app),
            BlocProvider<PlayerCubit>.value(value: player),
          ],
          child: const MaterialApp(
            locale: Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MusicListeningStatisticsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Listening recap'));
      await tester.pumpAndSettle();
      expect(find.text('6 plays · 5 songs'), findsOneWidget);

      final monthPicker = find.byKey(
        const ValueKey('music-listening-recap-month'),
      );
      await tester.tap(monthPicker);
      await tester.pumpAndSettle();
      await tester.tap(find.text('February 2024').last);
      await tester.pumpAndSettle();
      expect(find.text('4 plays · 3 songs'), findsOneWidget);

      final recapScroll = find.descendant(
        of: find.byType(MusicListeningRecapPage),
        matching: find.byType(Scrollable),
      );
      Future<void> reveal(Finder finder) async {
        final position = tester.state<ScrollableState>(recapScroll).position;
        position.jumpTo(position.minScrollExtent);
        await tester.pump();
        await tester.scrollUntilVisible(finder, 250, scrollable: recapScroll);
        await tester.pumpAndSettle();
      }

      final dates = MaterialLocalizations.of(tester.element(monthPicker));
      Future<void> expectDay(int day, String count) async {
        final row = find.byKey(ValueKey('music-listening-recap-day-$day'));
        await reveal(row);
        expect(
          find.descendant(
            of: row,
            matching: find.text(dates.formatMediumDate(DateTime(2024, 2, day))),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: row, matching: find.text(count)),
          findsOneWidget,
        );
      }

      await expectDay(1, '1 play');
      await expectDay(2, '0 plays');
      await expectDay(28, '1 play');
      await expectDay(29, '2 plays');
      expect(
        find.byKey(const ValueKey('music-listening-recap-day-30')),
        findsNothing,
      );

      final replay = find.byKey(const ValueKey('music-listening-recap-replay'));
      await reveal(replay);
      await tester.tap(replay);
      await tester.pumpAndSettle();
      expect(player.queues.single.title, 'February 2024 listening recap');
      expect(player.queues.single.ids, ['leap', 'midnight', 'opening']);

      final preview = find.byKey(
        const ValueKey('music-listening-recap-preview'),
      );
      await reveal(preview);
      await tester.tap(preview);
      await tester.pumpAndSettle();
      Finder previewText(String text) => find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(text),
          );

      expect(previewText('February 2024'), findsOneWidget);
      expect(previewText('4 plays · 3 songs'), findsOneWidget);
      expect(previewText('Leap day song'), findsOneWidget);
      expect(previewText('January boundary'), findsNothing);
      expect(previewText('March boundary'), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(previewText('Share image'));
        await Future.doWhile(() async {
          if (shareCalls.isNotEmpty) return false;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          return true;
        }).timeout(const Duration(seconds: 5));
      });
      await tester.pumpAndSettle();
      final shareCall = shareCalls.single;
      expect(shareCall.method, 'share');
      final shareArgs = shareCall.arguments as Map;
      final image = File((shareArgs['paths'] as List).single as String);
      expect(image.uri.pathSegments.last, 'videre-music-recap-2024-02.png');
      expect(shareArgs['mimeTypes'], ['image/png']);
      await tester.tap(previewText('Cancel'));
      await tester.pumpAndSettle();

      final save = find.byKey(const ValueKey('music-listening-recap-save'));
      await reveal(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final fileCall = fileCalls.single;
      expect(fileCall.method, 'save');
      final args = fileCall.arguments as Map;
      expect(args['name'], 'videre-music-recap-2024-02.json');
      final json = jsonDecode(args['text'] as String) as Map;
      expect(json['year'], 2024);
      expect(json['month'], 2);
      expect(json['recordedPlays'], 4);
      expect(json['distinctSongs'], 3);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
