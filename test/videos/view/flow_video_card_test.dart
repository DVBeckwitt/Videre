import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/compact_video.dart';
import 'package:clipious/videos/views/components/video_in_list.dart';
import 'package:clipious/videos/views/components/video_metrics.dart';
import 'package:clipious/videos/views/components/video_modal_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_app_cubit.dart';
import '../../test_player_cubit.dart';
import '../../test_settings_cubit.dart';

class _CardRouter extends AppRouter {
  _CardRouter() : super(hasServer: true);

  PageRouteInfo? pushed;

  @override
  Future<T?> push<T extends Object?>(PageRouteInfo route,
      {OnNavigationFailure? onFailure}) async {
    pushed = route;
    return null;
  }
}

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
      {double width = 320,
      double scale = 1,
      SettingsCubit? cardSettings}) async {
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: cardSettings ?? settings),
        BlocProvider<PlayerCubit>.value(value: player),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
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

  const video = Video(
    videoId: 'flow-card',
    title: 'A readable title for a video with a much longer description',
    author: 'A channel name',
    lengthSeconds: 480,
    viewCount: 1200,
    likeCount: 40,
    publishedText: '2 days ago',
  );

  testWidgets('card overflow is an accessible separate action', (tester) async {
    var opened = 0;
    var menu = 0;
    await show(
      tester,
      VideoListItem(
        video: video,
        openVideoOverride: (_, __) => opened++,
        showVideoModalSheet: (_, __) => menu++,
      ),
    );

    final action = find.byType(IconButton);
    expect(tester.getSize(action).width, greaterThanOrEqualTo(48));
    expect(tester.widget<IconButton>(action).tooltip, isNotEmpty);
    await tester.tap(action);
    expect(menu, 1);
    expect(opened, 0);
    await tester.tap(find.text(video.title!));
    expect(opened, 1);
    await tester.longPress(find.text(video.title!));
    expect(menu, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a card tap marks an explicit watch when autoplay is enabled',
      (tester) async {
    for (final autoplay in [false, true]) {
      final router = _CardRouter();
      final cardSettings = TestSettingsCubit(
          SettingsState.init().copyWith(settings: {
            playerAutoplayOnLoad:
                SettingsValue(playerAutoplayOnLoad, '$autoplay'),
          }),
          app);
      addTearDown(router.dispose);
      addTearDown(cardSettings.close);
      await show(
          tester,
          StackRouterScope(
            controller: router,
            stateHash: 0,
            child: const VideoListItem(video: video),
          ),
          cardSettings: cardSettings);

      await tester.tap(find.text(video.title!));
      final route = router.pushed as VideoRoute;
      expect(route.args?.videoId, video.videoId);
      expect(route.args?.playNow, autoplay ? true : null);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('filtered cards keep menu disabled until explicitly revealed',
      (tester) async {
    var menu = 0;
    await show(
      tester,
      VideoListItem(
        video: video.copyWith(filtered: true),
        showVideoModalSheet: (_, __) => menu++,
      ),
    );
    expect(find.text(video.title!), findsNothing);
    expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNull);
    await tester.tap(find.text('**********'));
    await tester.pump();
    expect(find.text(video.title!), findsOneWidget);
    await tester.tap(find.byType(IconButton));
    expect(menu, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('feed metrics are quiet while detail reactions remain available',
      (tester) async {
    await show(tester,
        const VideoMetrics(video: video, compact: true, showDuration: false));
    expect(find.byIcon(Icons.visibility), findsOneWidget);
    expect(find.text('2 days ago'), findsOneWidget);
    expect(find.byIcon(Icons.thumb_up), findsNothing);
    expect(find.byIcon(Icons.timer), findsNothing);
    await show(tester, const VideoMetrics(video: video));
    expect(find.byIcon(Icons.thumb_up), findsOneWidget);
    expect(find.byIcon(Icons.timer), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('compact rows retain transport actions at large text',
      (tester) async {
    var pressed = 0;
    await show(
      tester,
      CompactVideo(
        video: video,
        trailing: [
          IconButton(
            tooltip: 'Remove',
            onPressed: () => pressed++,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      width: 280,
      scale: 2,
    );
    expect(find.text(video.title!), findsOneWidget);
    await tester.tap(find.byTooltip('Remove'));
    expect(pressed, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the short video menu can scroll to YTDLnis and its status',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const channel = MethodChannel('videre/ytdlnis_download');
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return 'unavailable';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await show(
        tester,
        Builder(
            builder: (context) => TextButton(
                onPressed: () => VideoModalSheet.showVideoModalSheet(
                    context, const Video(videoId: 'tV5UilNUYRY')),
                child: const Text('Open video menu'))),
        scale: 2);
    await tester.tap(find.text('Open video menu'));
    await tester.pumpAndSettle();
    final action = find.text('Download with YTDLnis');
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(
        calls.single.arguments, {'videoId': 'tV5UilNUYRY', 'audioOnly': false});
    final message =
        find.text('Install or update YTDLnis to open this download.');
    await tester.ensureVisible(message);
    expect(message.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('feed details fit the existing compact phone grid at large text',
      (tester) async {
    for (final scale in [1.0, 2.0]) {
      await show(
        tester,
        SizedBox(
          height: 320 * (9 + 4 * scale) / 16,
          child: const VideoListItem(video: video),
        ),
        width: 320,
        scale: scale,
      );
      expect(find.text(video.title!), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
