import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/expanded_player.dart';
import 'package:clipious/player/views/tablet/expanded_player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/dislike.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/states/video.dart';
import 'package:clipious/videos/views/components/video_dislike_metrics.dart';
import 'package:clipious/videos/views/screens/info_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_app_cubit.dart';
import '../../test_player_cubit.dart';
import '../../test_settings_cubit.dart';

const _video = Video(videoId: 'first', title: 'First video');

class _DislikeService extends Service {
  final requests = <String>[];
  final responses = <Completer<Dislike>>[];

  @override
  Future<Dislike> getDislikes(String videoId) {
    requests.add(videoId);
    final response = Completer<Dislike>();
    responses.add(response);
    return response.future;
  }

  @override
  Future<bool> isLoggedIn() async => false;

  @override
  Future<Video> getVideo(String videoId,
          {Server? serverOverride,
          VideoLoadObserver? loadObserver,
          void Function(BackendPlayback request)? onBackendRequest}) async =>
      _video;
}

class _Downloads extends DownloadManagerCubit {
  _Downloads(super.initialState, super.player);

  @override
  Future<void> onReady() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Service previousService;
  late _DislikeService dislikes;
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;
  late _Downloads downloads;
  VideoCubit? details;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    previousService = service;
    service = dislikes = _DislikeService();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    await app.initState();
    settings = TestSettingsCubit(SettingsState.init(), app);
    await settings.setDistractionFreeMode(true);
    player = TestPlayerCubit(
        PlayerState.init(null)
            .copyWith(currentlyPlaying: _video, isMini: false),
        settings);
    downloads = _Downloads(const DownloadManagerState(), player);
  });

  tearDown(() async {
    await details?.close();
    details = null;
    await downloads.close();
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    service = previousService;
  });

  Future<void> show(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<PlayerCubit>.value(value: player),
        BlocProvider<SettingsCubit>.value(value: settings),
        if (details != null) BlocProvider<VideoCubit>.value(value: details!),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    ));
    await tester.pumpAndSettle();
  }

  for (final (label, widget) in [
    ('phone', const ExpandedPlayer()),
    ('tablet', const TabletExpandedPlayer()),
  ]) {
    testWidgets('$label expanded player displays delayed dislikes once',
        (tester) async {
      await show(tester, widget);
      expect(dislikes.requests, ['first']);
      expect(find.byIcon(Icons.thumb_down), findsNothing);

      dislikes.responses.single.complete(Dislike(71));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.thumb_down), findsOneWidget);
      expect(find.text('71'), findsOneWidget);

      await show(tester, widget);
      expect(dislikes.requests, ['first']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'Info tab observes delayed state without changing route arguments',
      (tester) async {
    details = VideoCubit(
        VideoState.init(videoId: _video.videoId), downloads, player, settings);
    await show(tester, const VideoInfoTab(video: _video));
    expect(find.byIcon(Icons.thumb_down), findsNothing);
    expect(dislikes.requests, ['first']);

    dislikes.responses.single.complete(Dislike(0));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.thumb_down), findsOneWidget);
    expect(find.text('0'), findsOneWidget);

    await tester.runAsync(() => settings.setUseReturnYoutubeDislike(false));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.thumb_down), findsNothing);
    await tester.runAsync(() => settings.setUseReturnYoutubeDislike(true));
    await tester.pumpAndSettle();
    expect(dislikes.requests, ['first', 'first']);
    dislikes.responses.last.complete(Dislike(82));
    await tester.pumpAndSettle();
    expect(find.text('82'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('player metrics hide disabled results and ignore late responses',
      (tester) async {
    await show(tester, const VideoDislikeMetrics(video: _video));
    await tester.runAsync(() => settings.setUseReturnYoutubeDislike(false));
    await tester.pumpAndSettle();
    dislikes.responses.first.complete(Dislike(71));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.thumb_down), findsNothing);

    await tester.runAsync(() => settings.setUseReturnYoutubeDislike(true));
    await tester.pumpAndSettle();
    expect(dislikes.requests, ['first', 'first']);
    dislikes.responses.last.complete(Dislike(0));
    await tester.pumpAndSettle();
    expect(find.text('0'), findsOneWidget);
    expect(find.byIcon(Icons.thumb_down), findsOneWidget);
  });

  testWidgets('details discard pending results after changing the RYD endpoint',
      (tester) async {
    details = VideoCubit(
        VideoState.init(videoId: _video.videoId), downloads, player, settings);
    await show(tester, const VideoInfoTab(video: _video));
    await tester.runAsync(
        () => settings.setReturnYoutubeDislikeUrl('https://ryd.example/'));
    await tester.pumpAndSettle();
    expect(dislikes.requests, ['first', 'first']);

    dislikes.responses.first.complete(Dislike(71));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.thumb_down), findsNothing);
    dislikes.responses.last.complete(Dislike(82));
    await tester.pumpAndSettle();
    expect(find.text('82'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('video switches and endpoint changes discard previous counts',
      (tester) async {
    await show(tester, const VideoDislikeMetrics(video: _video));
    const second = Video(videoId: 'second');
    await show(tester, const VideoDislikeMetrics(video: second));
    dislikes.responses.first.complete(Dislike(71));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.thumb_down), findsNothing);
    dislikes.responses.last.complete(Dislike(82));
    await tester.pumpAndSettle();
    expect(find.text('82'), findsOneWidget);

    await tester.runAsync(
        () => settings.setReturnYoutubeDislikeUrl('https://ryd.example/'));
    await tester.pumpAndSettle();
    expect(dislikes.requests, ['first', 'second', 'second']);
    expect(find.text('82'), findsNothing);
    dislikes.responses.last.complete(Dislike(93));
    await tester.pumpAndSettle();
    expect(find.text('93'), findsOneWidget);
  });

  testWidgets('failed and disposed requests do not show a false zero',
      (tester) async {
    await show(tester, const VideoDislikeMetrics(video: _video));
    dislikes.responses.first.completeError(StateError('RYD unavailable'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.thumb_down), findsNothing);
    expect(tester.takeException(), isNull);

    await show(
        tester, const VideoDislikeMetrics(video: Video(videoId: 'second')));
    await show(tester, const SizedBox.shrink());
    dislikes.responses.last.complete(Dislike(71));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
