import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/mini_player.dart';
import 'package:clipious/player/views/components/mini_player_progress.dart';
import 'package:clipious/player/views/components/player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _Player extends TestPlayerCubit {
  _Player(super.initialState, super.settings);

  Future<void> seed(PlayerState next) async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async => emit(next));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _Player player;
  late ValueNotifier<MediaQueryData> viewport;
  const song = Video(
    videoId: 'position-test',
    title: 'Position test',
    author: 'Artist',
    musicMetadata: MusicMetadata(title: 'Position test', artist: 'Artist'),
  );
  const window = Size(390, 844);
  const safe = EdgeInsets.only(top: 24, bottom: 34);
  final audioBuilder = find.byType(
      BlocBuilder<AudioPlayerCubit, AudioPlayerState>,
      skipOffstage: false);
  final positioned = find.descendant(
      of: find.byType(Player), matching: find.byType(AnimatedPositioned));

  setUp(() async {
    app_main.darkColorScheme = const ColorScheme.dark();
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = _Player(
      PlayerState.init([song]).copyWith(
        currentlyPlaying: song,
        isAudio: true,
        isMini: true,
        isHidden: false,
        mediaEvent: const MediaEvent(state: MediaState.ready),
      ),
      settings,
    );
    viewport = ValueNotifier(const MediaQueryData(
      size: window,
      padding: safe,
      viewPadding: safe,
    ));
  });

  tearDown(() async {
    viewport.dispose();
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<AudioPlayerCubit> pumpPlayer(
    WidgetTester tester, {
    double pixelRatio = 1,
    Size physicalSize = window,
    ThemeData? theme,
  }) async {
    tester.view.devicePixelRatio = pixelRatio;
    tester.view.physicalSize = physicalSize;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<AppCubit>.value(value: app),
          BlocProvider<SettingsCubit>.value(value: settings),
          BlocProvider<PlayerCubit>.value(value: player),
        ],
        child: MaterialApp(
          theme: theme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ValueListenableBuilder<MediaQueryData>(
            valueListenable: viewport,
            builder: (context, data, _) => MediaQuery(
              data: data,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox.fromSize(
                  size: data.size,
                  child: LayoutBuilder(
                    builder: (context, constraints) => Stack(
                      children: [Player(constraints.maxHeight)],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
    });
    await tester.pump(const Duration(milliseconds: 500));
    final decoder = tester.element(audioBuilder).read<AudioPlayerCubit>();
    addTearDown(() async {
      await tester.runAsync(() async {
        final closed = decoder.stream.drain<void>();
        await tester.pumpWidget(const SizedBox.shrink());
        await closed.timeout(const Duration(seconds: 2));
      });
    });
    return decoder;
  }

  testWidgets('compact Music player fits a taller mixed-script title',
      (tester) async {
    const title = 'PSY - GANGNAM STYLE(강남스타일) M/V';
    const artist = 'officialpsy';
    final track = song.copyWith(
      title: title,
      author: artist,
      musicMetadata: const MusicMetadata(title: title, artist: artist),
    );
    await player.seed(player.state.copyWith(currentlyPlaying: track));
    viewport.value = viewport.value.copyWith(size: const Size(360, 720));
    await pumpPlayer(
      tester,
      physicalSize: const Size(540, 1080),
      pixelRatio: 1.5,
      // Match the taller fallback-font line seen on Android.
      theme: ThemeData(
        textTheme: const TextTheme(bodySmall: TextStyle(height: 17 / 12)),
      ),
    );

    final bounds = tester.getRect(find.byType(MiniPlayer));
    expect(tester.getRect(find.text('$title - $artist')).top,
        greaterThanOrEqualTo(bounds.top));
    expect(tester.getRect(find.byType(MiniPlayerProgress)).bottom,
        lessThanOrEqualTo(bounds.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('mini-player drag stays within the safe viewport at both edges',
      (tester) async {
    await pumpPlayer(tester);
    for (final top in [-150.0, 900.0]) {
      await player.seed(player.state.copyWith(isDragging: true, top: top));
      await tester.pump(const Duration(milliseconds: 500));
      final rect = tester.getRect(positioned);
      expect(rect.top, greaterThanOrEqualTo(safe.top));
      expect(rect.bottom, lessThanOrEqualTo(window.height - safe.bottom));
      expect(rect.height, closeTo(targetHeight, 0.01));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('tapping the mini-player restores it inside the viewport',
      (tester) async {
    final decoder = await pumpPlayer(tester);
    final native = decoder.audioPlayer;
    final docked = tester.getRect(positioned);
    expect(docked.top, greaterThan(window.height / 2));
    await tester.tap(find.text('Position test - Artist'));
    await tester.pump();
    expect(player.state.isMini, isFalse);
    expect(player.state.isHidden, isFalse);
    expect(player.state.isClosing, isFalse);
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
      final rect = tester.getRect(positioned);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(window.height));
      expect(rect.height, greaterThan(targetHeight));
      expect(tester.takeException(), isNull);
    }
    expect(tester.getRect(positioned).top, closeTo(0, 0.01));
    expect(
        tester.element(audioBuilder).read<AudioPlayerCubit>(), same(decoder));
    expect(decoder.audioPlayer, same(native));
  });

  testWidgets('restoring a repeatedly minimized player keeps its bounds',
      (tester) async {
    await pumpPlayer(tester);
    for (final delay in [300, 50, 300]) {
      player.showBigPlayer();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pump();
      await tester.pump(Duration(milliseconds: delay));
      expect(player.state.isMini, isTrue);
      await tester.tap(find.text('Position test - Artist'));
      await tester.pump();
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
        final rect = tester.getRect(positioned);
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(window.height));
        expect(tester.takeException(), isNull);
      }
      expect(player.state.isMini, isFalse);
      expect(tester.getRect(positioned).top, closeTo(0, 0.01));
    }
  });

  testWidgets(
      'keyboard show and hide keep mini-player visible without remounting',
      (tester) async {
    final decoder = await pumpPlayer(tester);
    final native = decoder.audioPlayer;
    expect(native, isNotNull);
    for (final keyboard in [300.0, 0.0]) {
      viewport.value = viewport.value.copyWith(
        viewInsets: EdgeInsets.only(bottom: keyboard),
        padding: EdgeInsets.only(top: safe.top, bottom: keyboard > 0 ? 0 : 34),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final rect = tester.getRect(positioned);
      expect(rect.top, greaterThanOrEqualTo(safe.top));
      expect(rect.bottom, lessThanOrEqualTo(window.height - keyboard));
      expect(
          tester.element(audioBuilder).read<AudioPlayerCubit>(), same(decoder));
      expect(decoder.audioPlayer, same(native));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('viewport shrink reclamps a dragged mini-player and it settles',
      (tester) async {
    await pumpPlayer(tester);
    await player.seed(player.state.copyWith(isDragging: true, top: 700));
    await tester.pump(const Duration(milliseconds: 500));
    viewport.value = viewport.value.copyWith(size: const Size(390, 500));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final dragged = tester.getRect(positioned);
    expect(dragged.bottom, lessThanOrEqualTo(500 - safe.bottom));
    await player.seed(player.state.copyWith(isDragging: false, top: null));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final settled = tester.getRect(positioned);
    expect(settled.bottom, closeTo(500, 0.01));
    expect(settled.height, greaterThanOrEqualTo(targetHeight));
    expect(tester.takeException(), isNull);
  });
}
