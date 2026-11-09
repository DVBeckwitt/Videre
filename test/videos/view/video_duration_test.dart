import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/compact_video.dart';
import 'package:clipious/videos/views/components/video_duration_badge.dart';
import 'package:clipious/videos/views/components/video_in_list.dart';
import 'package:clipious/videos/views/components/video_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_app_cubit.dart';
import '../../test_player_cubit.dart';
import '../../test_settings_cubit.dart';

void main() {
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    await app.initState();
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = TestPlayerCubit(PlayerState.init(null), settings);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> show(WidgetTester tester, Widget child,
      {double width = 320, double textScale = 1}) async {
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
        BlocProvider<PlayerCubit>.value(value: player),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  void expectThumbnailDuration(WidgetTester tester, String duration) {
    final label = find.text(duration);
    expect(label, findsOneWidget);
    final thumbnailBounds = tester.getRect(find.byType(VideoThumbnailView));
    final labelBounds = tester.getRect(label);
    expect(thumbnailBounds.contains(labelBounds.topLeft), isTrue);
    expect(thumbnailBounds.contains(labelBounds.bottomRight), isTrue);
  }

  testWidgets(
      'compact playlist and history rows show a duration in the thumbnail',
      (tester) async {
    final cached = HistoryVideoCache('history', 'Video', 'Author', '',
        lengthSeconds: 3723);
    await show(tester, CompactVideo(video: cached.toVideo()), width: 280);

    expectThumbnailDuration(tester, '1:02:03');
    expect(tester.getSize(find.byType(VideoThumbnailView)).height,
        compactVideoHeight);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('small home cards show the API duration in the thumbnail',
      (tester) async {
    final video = Video.fromJson({
      'videoId': 'popular',
      'title': 'Video',
      'author': 'Author',
      'lengthSeconds': 149,
    });
    await show(tester, VideoListItem(video: video, small: true), width: 185);

    expectThumbnailDuration(tester, '02:29');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('compact thumbnail fits a long duration with doubled text size',
      (tester) async {
    await show(
        tester,
        const VideoThumbnailView(
          videoId: 'large-text',
          thumbnails: [],
          child: Align(
            alignment: Alignment.bottomRight,
            child: VideoDurationBadge(lengthSeconds: 45296, compact: true),
          ),
        ),
        width: compactVideoHeight * 16 / 9,
        textScale: 2);

    expectThumbnailDuration(tester, '12:34:56');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'small cards keep a long duration inside the thumbnail at large text size',
      (tester) async {
    await show(
        tester,
        const VideoListItem(
            video: Video(videoId: 'large-text', lengthSeconds: 45296),
            small: true),
        width: 185,
        textScale: 3);

    expectThumbnailDuration(tester, '12:34:56');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('full popular and trending cards display the duration only once',
      (tester) async {
    await show(
        tester,
        const VideoListItem(
            video: Video(
                videoId: 'trending',
                title: 'Video',
                author: 'Author',
                lengthSeconds: 149)));

    expectThumbnailDuration(tester, '02:29');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  final layouts = <(String, Widget Function(Video))>[
    ('compact row', (video) => CompactVideo(video: video)),
    ('small card', (video) => VideoListItem(video: video, small: true)),
    ('full card', (video) => VideoListItem(video: video)),
  ];

  for (final (name, build) in layouts) {
    testWidgets('$name omits unknown, zero and upcoming durations',
        (tester) async {
      for (final video in [
        const Video(videoId: 'unknown'),
        const Video(videoId: 'zero', lengthSeconds: 0),
        const Video(videoId: 'upcoming', lengthSeconds: 90, isUpcoming: true),
        const Video(videoId: 'live', lengthSeconds: 0, liveNow: true),
      ]) {
        await show(tester, build(video));
        expect(find.text('00:00'), findsNothing);
        expect(find.text('01:30'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('$name retains a supplied duration for a live video',
        (tester) async {
      await show(
          tester,
          build(const Video(
              videoId: 'live-duration', lengthSeconds: 90, liveNow: true)));

      expectThumbnailDuration(tester, '01:30');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
