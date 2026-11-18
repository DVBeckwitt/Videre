import 'package:clipious/globals.dart' as globals;
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/recommendations/recommendation_snapshot.dart';
import 'package:clipious/recommendations/views/recommendation_settings.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SembastSqfDb database;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    globals.db = database;
  });

  tearDown(() async {
    RecommendationService.forgetProfile(database, database.profileId);
    await RecommendationService.flushPending();
    await database.close();
  });

  Future<void> show(WidgetTester tester, {double textScale = 1}) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!),
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () => showRecommendationSettings(context),
                  child: const Text('Open taste')))),
    ));
    await tester.tap(find.text('Open taste'));
    await tester.pumpAndSettle();
  }

  testWidgets('learning switches are separate and durable', (tester) async {
    await show(tester);
    await tester
        .tap(find.byKey(const ValueKey('recommendation-learning-music')));
    await tester.pumpAndSettle();
    final service =
        RecommendationService.forProfile(database, database.profileId);
    expect(service.learningEnabled(RecommendationDomain.video), isTrue);
    expect(service.learningEnabled(RecommendationDomain.music), isFalse);
    expect(find.text('Learning paused'), findsOneWidget);
  });

  testWidgets('reset is explicit and preserves the other mode', (tester) async {
    // Sembast may yield through a timer during writes. Seed outside the
    // widget's fake clock, which is not pumped until the UI is mounted below.
    await tester.runAsync(() async {
      for (final domain in RecommendationDomain.values) {
        await database.saveSetting(SettingsValue(
            recommendationSettingName(domain),
            RecommendationSnapshot(state: {
              'schemaVersion': 1,
              'domain': domain.name,
              if (domain == RecommendationDomain.video)
                'totalInteractions': 3
              else
                'totalPlays': 4,
            }).encode()));
      }
    });
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('recommendation-reset-video')));
    await tester.pumpAndSettle();
    expect(find.text('Reset preferences?'), findsOneWidget);
    await tester
        .tap(find.widgetWithText(FilledButton, 'Reset learned preferences'));
    await tester.pumpAndSettle();
    final video = RecommendationSnapshot.tryParse(database
        .getSettings(recommendationSettingName(RecommendationDomain.video))!
        .value)!;
    final music = RecommendationSnapshot.tryParse(database
        .getSettings(recommendationSettingName(RecommendationDomain.music))!
        .value)!;
    expect(video.state, isEmpty);
    expect(music.state['totalPlays'], 4);
  });

  testWidgets('settings stay scrollable on a narrow large-text phone',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(tester, textScale: 2);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(
        find.byKey(const ValueKey('recommendation-reset-music')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('unblocking a creator leaves the other blocks and mode intact',
      (tester) async {
    const first = 'UCabcdefghijklmnopqrstuv';
    const second = 'UCabcdefghijklmnopqrstuw';
    const artist = 'uploader:UCzyxwvutsrqponmlkjihgfe';
    await tester.runAsync(() async {
      await database.saveSetting(SettingsValue(
        recommendationSettingName(RecommendationDomain.video),
        const RecommendationSnapshot(blockedCreators: {first, second}).encode(),
      ));
      await database.saveSetting(SettingsValue(
        recommendationSettingName(RecommendationDomain.music),
        const RecommendationSnapshot(blockedCreators: {artist}).encode(),
      ));
    });
    const channel = MethodChannel('videre/recommendations');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel, (call) async => {'state': (call.arguments as Map)['state']});
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    await show(tester);
    final videoBlocks =
        find.byKey(const ValueKey('recommendation-blocked-video'));
    await tester.ensureVisible(videoBlocks);
    await tester.tap(videoBlocks);
    await tester.pumpAndSettle();

    final firstAction =
        find.byKey(const ValueKey('recommendation-unblock-video-$first'));
    final secondAction =
        find.byKey(const ValueKey('recommendation-unblock-video-$second'));
    expect(firstAction, findsOneWidget);
    expect(secondAction, findsOneWidget);
    expect(find.byKey(const ValueKey('recommendation-unblock-music-$artist')),
        findsNothing);

    await tester.tap(firstAction);
    await tester.pumpAndSettle();
    expect(firstAction, findsNothing);
    expect(secondAction, findsOneWidget);
    final service =
        RecommendationService.forProfile(database, database.profileId);
    expect(
        service.blockedCreators(RecommendationDomain.video).single.key, second);
    expect(
        service.blockedCreators(RecommendationDomain.music).single.key, artist);
  });
}
