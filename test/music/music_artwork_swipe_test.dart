import 'dart:collection';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/services/music_lyrics_service.dart';
import 'package:clipious/music/views/components/music_playback_artwork.dart';
import 'package:clipious/music/views/components/music_player_artwork.dart';
import 'package:clipious/music/views/components/music_track_swipe.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/gestures.dart'
    show kDoubleTapMinTime, kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _Player extends TestPlayerCubit {
  _Player(super.initialState, super.settings);

  int skips = 0;
  int toggles = 0;

  Future<void> seed(PlayerState value) async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async => emit(value));
  }

  @override
  void playNext({bool userInitiated = true}) => skips++;

  @override
  void togglePlaying() => toggles++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const song = Video(
      videoId: 'song',
      title: 'Song',
      lengthSeconds: 180,
      musicMetadata: MusicMetadata(title: 'Song', artist: 'Artist'));
  const next = Video(
      videoId: 'next',
      title: 'Next',
      musicMetadata: MusicMetadata(title: 'Next', artist: 'Artist'));
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _Player player;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = _Player(
        PlayerState.init([song, next]).copyWith(
          currentlyPlaying: song,
          playQueue: ListQueue.of([next.videoId]),
          isAudio: true,
          isMini: false,
          isHidden: false,
        ),
        settings);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> pump(WidgetTester tester,
      {bool compact = false,
      bool interactive = true,
      ValueChanged<bool>? onSeekStep,
      TextDirection direction = TextDirection.ltr}) async {
    if (compact) player.showMiniPlayer();
    final cover = compact
        ? const MusicTrackSwipe(
            compact: true, child: ColoredBox(color: Colors.black))
        : BlocBuilder<PlayerCubit, PlayerState>(builder: (context, state) {
            final current = state.currentlyPlaying!;
            return MusicPlayerArtwork(
                music: current.musicMetadata!,
                video: current,
                offline: null,
                size: 240,
                active: false,
                onSeekStep: onSeekStep,
                interactive: interactive,
                lyricsLoader: loadMusicLyrics);
          });
    await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<AppCubit>.value(value: app),
          BlocProvider<SettingsCubit>.value(value: settings),
          BlocProvider<PlayerCubit>.value(value: player),
        ],
        child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
                body: Directionality(
                    textDirection: direction,
                    child: Center(
                        child:
                            SizedBox.square(dimension: 240, child: cover)))))));
    await tester.pump();
  }

  Future<void> doubleTap(WidgetTester tester, Offset point) async {
    await tester.tapAt(point);
    await tester.pump(kDoubleTapMinTime + const Duration(milliseconds: 10));
    await tester.tapAt(point);
    await tester.pump(kDoubleTapTimeout);
  }

  testWidgets('with cover seeking off a single tap toggles immediately',
      (tester) async {
    final steps = <bool>[];
    await pump(tester, onSeekStep: steps.add);
    final center = tester.getCenter(find.byType(MusicTrackSwipe));
    await tester.tapAt(center + const Offset(75, 0));
    expect(player.toggles, 1);
    expect(steps, isEmpty);
  });

  testWidgets(
      'cover double taps use physical sides in RTL and leave single tap and drag available',
      (tester) async {
    await tester.runAsync(() => settings.setMusicArtworkDoubleTapSeek(true));
    final steps = <bool>[];
    await pump(tester, direction: TextDirection.rtl, onSeekStep: steps.add);
    final cover = find.byType(MusicTrackSwipe);
    final center = tester.getCenter(cover);
    await doubleTap(tester, center - const Offset(75, 0));
    await doubleTap(tester, center + const Offset(75, 0));
    await doubleTap(tester, center);
    expect(steps, [true, false]);
    expect(player.toggles, 0);
    await tester.tapAt(center);
    await tester.pump(kDoubleTapTimeout);
    expect(player.toggles, 1);
    await tester.drag(cover, const Offset(130, 0));
    await tester.pumpAndSettle();
    expect(player.skips, 1);
    expect(player.toggles, 1);
    expect(steps, [true, false]);
  });

  testWidgets(
      'a pending cover tap cannot toggle a repeat occurrence or a covered player',
      (tester) async {
    await tester.runAsync(() => settings.setMusicArtworkDoubleTapSeek(true));
    final steps = <bool>[];
    await pump(tester, onSeekStep: steps.add);
    final edge =
        tester.getCenter(find.byType(MusicTrackSwipe)) + const Offset(75, 0);
    await tester.tapAt(edge);
    await tester.pump(kDoubleTapMinTime);
    final duplicate = song.copyWith(queueEntryId: 'second occurrence');
    await player.seed(player.state
        .copyWith(videos: [song, duplicate], currentlyPlaying: duplicate));
    await tester.pump();
    await tester.pump(kDoubleTapTimeout);
    expect(player.toggles, 0);

    await tester.tapAt(edge);
    await tester.pump(kDoubleTapMinTime + const Duration(milliseconds: 10));
    final held = await tester.startGesture(edge);
    await pump(tester, onSeekStep: steps.add, interactive: false);
    await held.up();
    await tester.pump(kDoubleTapTimeout);
    expect(player.toggles, 0);
    expect(steps, isEmpty);
  });

  for (final compact in [false, true]) {
    testWidgets(
        'cancel an accepted ${compact ? 'compact' : 'cover'} drag past its skip threshold',
        (tester) async {
      await pump(tester, compact: compact);
      final cover = find.byType(MusicTrackSwipe);
      Finder drawing(Video video) => find.byWidgetPredicate(
          (widget) => widget is MusicPlaybackArtwork && widget.video == video);
      final bounds = tester.getRect(cover);
      final start =
          compact ? bounds.center : Offset(bounds.right - 2, bounds.center.dy);
      final paused = compact ? null : tester.getRect(drawing(song));
      if (paused != null) expect(paused.contains(start), isFalse);
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(-120, 0));
      await tester.pump();
      final preview = drawing(next);
      if (paused != null) {
        expect(preview, findsOneWidget);
        expect(tester.getRect(preview).width, closeTo(paused.width, 0.01));
      }
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(player.skips, 0);
      expect(player.toggles, 0);
      if (!compact) expect(preview, findsNothing);
      expect(tester.getRect(cover), bounds);
      await tester.drag(cover, const Offset(-120, 0));
      expect(player.skips, 1);
    });
  }

  testWidgets(
      'disabling cover swipes preserves the playback tap and Lyrics action',
      (tester) async {
    await tester.runAsync(() => settings.setMusicArtworkSwipe(false));
    await pump(tester);
    final cover = find.byType(MusicTrackSwipe);
    await tester.drag(cover, const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(player.skips, 0);
    expect(player.toggles, 0);
    await tester.tap(cover);
    expect(player.toggles, 1);
    await tester.tap(find.byKey(const ValueKey('music-player-lyrics')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(player.toggles, 1);
  });

  testWidgets('changing the cover swipe preference retires a held RTL gesture',
      (tester) async {
    await pump(tester, direction: TextDirection.rtl);
    final cover = find.byType(MusicTrackSwipe);
    final current = find.byWidgetPredicate(
        (widget) => widget is MusicPlaybackArtwork && widget.video == song);
    final preview = find.byWidgetPredicate(
        (widget) => widget is MusicPlaybackArtwork && widget.video == next);
    final artwork = tester.element(current);
    final held = await tester.startGesture(tester.getCenter(cover));
    await held.moveBy(const Offset(130, 0));
    await tester.pump();
    expect(preview, findsOneWidget);
    await tester.runAsync(() => settings.setMusicArtworkSwipe(false));
    await tester.pump();
    expect(preview, findsNothing);
    expect(tester.element(current), same(artwork));
    // Re-enabling affects new touches. It must not revive an accepted drag.
    await tester.runAsync(() => settings.setMusicArtworkSwipe(true));
    await tester.pump();
    await held.up();
    expect(player.skips, 0);
    expect(player.state.currentQueueId, song.videoId);
    await tester.drag(cover, const Offset(130, 0));
    await tester.pumpAndSettle();
    expect(player.skips, 1);
    expect(player.toggles, 0);
  });

  testWidgets('mini-player track swipes still work when cover swipes are off',
      (tester) async {
    await tester.runAsync(() => settings.setMusicArtworkSwipe(false));
    await pump(tester, compact: true);
    await tester.drag(find.byType(MusicTrackSwipe), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(player.skips, 1);
    expect(player.toggles, 0);
  });

  testWidgets('minimizing while holding the cover retires its drag',
      (tester) async {
    await pump(tester);
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(MusicTrackSwipe)));
    await gesture.moveBy(const Offset(-120, 0));
    await tester.pump();
    player.showMiniPlayer();
    expect(player.state.isMini, isTrue);
    await gesture.up();
    expect(player.skips, 0);
  });
}
