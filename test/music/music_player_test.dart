import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/music/views/components/music_player.dart';
import 'package:clipious/music/views/components/music_sponsor_notice.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/expanded_player.dart';
import 'package:clipious/player/views/components/player.dart';
import 'package:clipious/player/models/sleep_timer.dart';
import 'package:clipious/player/views/tablet/expanded_player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/views/components/info.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _Player extends TestPlayerCubit {
  int nextCalls = 0;
  int previousCalls = 0;
  Duration? sought;

  _Player(super.initialState, super.settings);

  Future<void> seed(PlayerState next) async {
    // Start session persistence outside the widget test's fake frame clock.
    await TestWidgetsFlutterBinding.instance.runAsync(() async => emit(next));
  }

  @override
  void playNext() => nextCalls++;

  @override
  void playPrevious() => previousCalls++;

  @override
  void seek(Duration position) {
    sought = position;
    super.seek(position);
  }
}

class _Settings extends TestSettingsCubit {
  _Settings(super.initialState, super.appCubit);

  @override
  Future<void> saveSetting(SettingsValue value) async {
    emit(state.copyWith(settings: {...state.settings, value.name: value}));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _Player player;
  const song = Video(
      videoId: 'song',
      title: 'Song',
      author: 'Singer',
      lengthSeconds: 180,
      musicMetadata:
          MusicMetadata(title: 'Song', artist: 'Singer', album: 'Album'));
  const next = Video(
      videoId: 'next',
      title: 'Next',
      lengthSeconds: 180,
      musicMetadata: MusicMetadata(title: 'Next', artist: 'Singer'));

  setUp(() async {
    app_main.darkColorScheme = ColorScheme.fromSeed(
        seedColor: Colors.blue, brightness: Brightness.dark);
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = _Settings(SettingsState.init(), app);
    player = _Player(
        PlayerState.init([song, next]).copyWith(
            currentlyPlaying: song,
            isAudio: true,
            isMini: false,
            isHidden: false,
            top: 0,
            position: const Duration(seconds: 30),
            mediaEvent: const MediaEvent(state: MediaState.ready)),
        settings);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> pump(WidgetTester tester,
      {Size size = const Size(390, 844),
      double scale = 1,
      Widget child = const MusicPlayer()}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: Scaffold(body: child),
        )));
    await tester.pump();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.tap(target);
    await tester.pump();
  }

  Future<void> skipSponsor(WidgetTester tester) async {
    player.setEvent(const MediaEvent(
        type: MediaEventType.sponsorSkipped, state: MediaState.playing));
    await tester.pump();
    await tester.pump();
  }

  for (final (size, scale) in [
    (const Size(320, 568), 2.5),
    (const Size(390, 844), 1.0),
    (const Size(1024, 720), 2.0),
  ]) {
    testWidgets('music artwork and controls fit $size at text scale $scale',
        (tester) async {
      await pump(tester, size: size, scale: scale);
      final artwork =
          tester.getSize(find.byKey(const ValueKey('music-player-artwork')));
      expect(artwork.width, artwork.height);
      expect(find.text('Singer'), findsWidgets);
      expect(find.text('Album'), findsOneWidget);
      await tester
          .ensureVisible(find.byKey(const ValueKey('music-player-repeat')));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'music controls use shared transport seek shuffle repeat and queue',
      (tester) async {
    await pump(tester);
    await tap(tester, 'music-player-play');
    expect(player.state.mediaCommand!.type, MediaCommandType.play);
    await tap(tester, 'music-player-next');
    await tap(tester, 'music-player-previous');
    expect(player.nextCalls, 1);
    expect(player.previousCalls, 1);

    final slider = tester
        .widget<Slider>(find.byKey(const ValueKey('music-player-progress')));
    slider.onChanged!(45000);
    slider.onChangeEnd!(45000);
    await tester.pump();
    expect(player.sought, const Duration(seconds: 45));
    await tap(tester, 'music-player-shuffle');
    expect(settings.state.playerShuffleMode, isTrue);
    await tap(tester, 'music-player-repeat');
    expect(settings.state.playerRepeatMode, PlayerRepeat.repeatAll);
    await tap(tester, 'music-player-queue');
    expect(find.byType(MusicQueue), findsOneWidget);
    await tap(tester, 'music-player-close-queue');
    expect(find.byKey(const ValueKey('music-player-title')), findsOneWidget);
  });

  testWidgets('expanded phone and tablet music avoid video information tabs',
      (tester) async {
    for (final widget in [
      const ExpandedPlayer(),
      const TabletExpandedPlayer()
    ]) {
      await pump(tester, child: widget);
      expect(find.byType(MusicPlayer), findsOneWidget);
      expect(find.byType(VideoInfo), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('a stale seek gesture cannot move a replacement song',
      (tester) async {
    await pump(tester);
    final oldSlider = tester
        .widget<Slider>(find.byKey(const ValueKey('music-player-progress')));
    oldSlider.onChanged!(120000);
    await player.seed(
        player.state.copyWith(currentlyPlaying: next, position: Duration.zero));
    await tester.pump();
    oldSlider.onChangeEnd!(120000);
    await tester.pump();
    expect(player.sought, isNull);
    expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('music-player-progress')))
            .value,
        0);
  });

  for (final size in [const Size(390, 844), const Size(1024, 720)]) {
    testWidgets('Music skip feedback stays visible with its queue at $size',
        (tester) async {
      await pump(tester, size: size);
      await skipSponsor(tester);
      expect(find.text('Sponsor skipped'), findsOneWidget);
      expect(
          find.byWidgetPredicate((widget) =>
              widget is Semantics && widget.properties.liveRegion == true),
          findsOneWidget);
      await tap(tester, 'music-player-queue');
      expect(find.byType(MusicQueue), findsOneWidget);
      final notice = tester.getRect(find.text('Sponsor skipped'));
      expect(notice.top, greaterThanOrEqualTo(0));
      expect(notice.bottom, lessThan(size.height));
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Sponsor skipped'), findsNothing);
    });
  }

  testWidgets('skip feedback persists through events and restarts its timeout',
      (tester) async {
    await pump(tester);
    await skipSponsor(tester);
    await tester.pump(const Duration(seconds: 2));
    player.setEvent(const MediaEvent(state: MediaState.playing));
    await tester.pump();
    expect(find.text('Sponsor skipped'), findsOneWidget);
    await skipSponsor(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Sponsor skipped'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Sponsor skipped'), findsNothing);
  });

  testWidgets('skip feedback clears for duplicate queue entries and disposal',
      (tester) async {
    final songs = assignPlaybackQueueIds([song, song]);
    await player.seed(
        player.state.copyWith(videos: songs, currentlyPlaying: songs.first));
    await pump(tester);
    await skipSponsor(tester);
    expect(find.text('Sponsor skipped'), findsOneWidget);
    await player.seed(player.state.copyWith(currentlyPlaying: songs.last));
    await tester.pump();
    expect(find.text('Sponsor skipped'), findsNothing);
    player.setEvent(const MediaEvent(state: MediaState.playing));
    await skipSponsor(tester);
    expect(find.text('Sponsor skipped'), findsOneWidget);
    expect(find.byType(MusicSponsorNotice), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'duplicate song occurrences have separate selection and seek ownership',
      (tester) async {
    final songs = assignPlaybackQueueIds([song, next, song]);
    await player.seed(
        player.state.copyWith(videos: songs, currentlyPlaying: songs.first));
    await pump(tester, size: const Size(1024, 720));
    final oldSlider = tester
        .widget<Slider>(find.byKey(const ValueKey('music-player-progress')));
    oldSlider.onChanged!(120000);
    await player.seed(player.state
        .copyWith(currentlyPlaying: songs.last, position: Duration.zero));
    await tester.pump();
    oldSlider.onChangeEnd!(120000);
    expect(player.sought, isNull);
    final rows = tester
        .widgetList<ListTile>(find.descendant(
            of: find.byType(MusicQueue), matching: find.byType(ListTile)))
        .toList();
    expect(rows.where((row) => row.selected), hasLength(1));
    expect(rows.singleWhere((row) => row.selected).key,
        ValueKey('music-queue-${playbackQueueId(songs.last)}'));
    await tester.runAsync(
        () async => player.removeVideoFromQueue(playbackQueueId(songs.first)));
    await tester.pump();
    expect(player.state.videos.map(playbackQueueId),
        [playbackQueueId(songs[1]), playbackQueueId(songs.last)]);
    expect(player.state.currentlyPlaying, songs.last);
  });

  testWidgets('music can cancel its existing sleep timer', (tester) async {
    player.sleep(const SleepTimer(duration: Duration(minutes: 5)));
    await pump(tester);
    expect(player.state.hasTimer, isTrue);
    await tap(tester, 'music-player-sleep');
    expect(player.state.hasTimer, isFalse);
    expect(find.text('Cancel sleep timer'), findsNothing);
  });

  testWidgets('minimizing and expanding music keeps the mounted audio decoder',
      (tester) async {
    await tester.runAsync(
        () => pump(tester, child: const Stack(children: [Player(844)])));
    final audioBuilder = find.byType(
        BlocBuilder<AudioPlayerCubit, AudioPlayerState>,
        skipOffstage: false);
    final decoder = tester.element(audioBuilder).read<AudioPlayerCubit>();
    final native = decoder.audioPlayer;
    for (final mini in [true, false, true, false]) {
      await player.seed(player.state.copyWith(isMini: mini));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
          tester.element(audioBuilder).read<AudioPlayerCubit>(), same(decoder));
      expect(decoder.audioPlayer, same(native));
      expect(decoder.isClosed, isFalse);
    }
    await tester.runAsync(() async {
      final closed = decoder.stream.drain<void>();
      await tester.pumpWidget(const SizedBox.shrink());
      await closed.timeout(const Duration(seconds: 2));
    });
    expect(decoder.isClosed, isTrue);
  });
}
