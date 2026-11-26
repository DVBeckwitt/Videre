import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/states/player_controls.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/flow_watch_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_app_cubit.dart';
import '../../test_player_cubit.dart';
import '../../test_settings_cubit.dart';

class _WatchService extends Service {
  @override
  Future<List<Playlist>> getUserPlaylists({bool postProcessing = true}) async =>
      [];
}

class _WatchPlayer extends TestPlayerCubit {
  _WatchPlayer(super.initialState, super.settings);

  void loadForWatch(Video video) => emit(
        state.copyWith(
          currentlyPlaying: video,
          isHidden: false,
          isMini: false,
          position: const Duration(seconds: 15),
          mediaEvent: const MediaEvent(state: MediaState.pause),
        ),
      );

  void advanceToRepeat() {
    emit(
      state.copyWith(
        currentlyPlaying: state.currentlyPlaying!.copyWith(
          queueEntryId: 'repeated-video',
        ),
        position: Duration.zero,
        mediaCommand: null,
      ),
    );
  }
}

void main() {
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _WatchPlayer player;
  late Service originalService;

  const video = Video(
    videoId: 'watch-video',
    title: 'Video with chapters',
    lengthSeconds: 120,
    description: '0:00 Introduction\n0:30 Demonstration\n1:00 Conclusion',
  );
  final launcher = find.byKey(const ValueKey('watch-open-chapters'));
  final chapterList = find.byKey(const ValueKey('watch-chapter-list'));

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription = const Stream<void>.empty().listen(
      (_) {},
    );
    settings = TestSettingsCubit(SettingsState.init(), app);
    await settings.setDistractionFreeMode(true);
    await settings.setUseReturnYoutubeDislike(false);
    originalService = service;
    service = _WatchService();
    player = _WatchPlayer(PlayerState.init(null), settings);
  });

  tearDown(() async {
    service = originalService;
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> pumpWatch(WidgetTester tester, Video video) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Initialize session writes in the same clock as player teardown.
    await tester.runAsync(() async => player.loadForWatch(video));
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<PlayerCubit>.value(value: player),
          BlocProvider<SettingsCubit>.value(value: settings),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: FlowWatchBody(
                video: video,
                inPlayer: true,
                showRelated: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder chapter(String title) => find.descendant(
        of: chapterList,
        matching: find.widgetWithText(ListTile, title),
      );

  bool selected(WidgetTester tester, String title) =>
      tester.widget<ListTile>(chapter(title)).selected;

  Future<void> openChapters(WidgetTester tester) async {
    await tester.ensureVisible(launcher);
    await tester.tap(launcher);
    await tester.pumpAndSettle();
    expect(chapterList, findsOneWidget);
  }

  testWidgets(
    'choosing a chapter seeks while paused and scrub updates the row',
    (tester) async {
      await pumpWatch(tester, video);
      await openChapters(tester);
      expect(selected(tester, 'Introduction'), isTrue);
      expect(selected(tester, 'Demonstration'), isFalse);

      await tester.tap(chapter('Demonstration'));
      await tester.pumpAndSettle();
      expect(player.state.mediaCommand?.type, MediaCommandType.seek);
      expect(player.state.mediaCommand?.value, const Duration(seconds: 30));
      expect(player.state.position, const Duration(seconds: 30));
      expect(player.state.isPlaying, isFalse);
      expect(player.state.mediaEvent.state, MediaState.pause);
      expect(selected(tester, 'Introduction'), isFalse);
      expect(selected(tester, 'Demonstration'), isTrue);

      final controls = PlayerControlsCubit(const PlayerControlsState(), player);
      try {
        controls.onScrubbed(59999);
        await tester.pump();
        expect(selected(tester, 'Demonstration'), isTrue);
        expect(selected(tester, 'Conclusion'), isFalse);

        controls.onScrubbed(60000);
        await tester.pump();
        expect(selected(tester, 'Demonstration'), isFalse);
        expect(selected(tester, 'Conclusion'), isTrue);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('watch-current-chapter')))
              .data,
          'Conclusion',
        );
        expect(player.state.isPlaying, isFalse);
      } finally {
        await controls.close();
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('malformed and out-of-range times do not open a chapter sheet', (
    tester,
  ) async {
    await pumpWatch(
      tester,
      video.copyWith(description: '0:70 Invalid\n2:00 At end\n3:00 Past end'),
    );
    expect(launcher, findsNothing);
    expect(chapterList, findsNothing);
  });

  testWidgets('an already-open list cannot seek the next queue occurrence', (
    tester,
  ) async {
    await pumpWatch(tester, video);
    await openChapters(tester);
    final seekFromOldRow =
        tester.widget<ListTile>(chapter('Demonstration')).onTap!;

    player.advanceToRepeat();
    seekFromOldRow();
    expect(player.state.mediaCommand, isNull);
    expect(player.state.position, Duration.zero);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
