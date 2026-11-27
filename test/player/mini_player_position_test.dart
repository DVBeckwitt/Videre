import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/music/views/components/music_mini_player.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/audio_player.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/mini_player.dart';
import 'package:clipious/player/views/components/player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  AudioPlayerCubit? mountedDecoder;
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
    mountedDecoder = null;
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
    // Decoder setup can mount animated status controls in the preceding frame.
    // Flush their zero-delay startup callbacks before inspecting or disposing.
    await tester.pump(Duration.zero);
    final decoder = tester.element(audioBuilder).read<AudioPlayerCubit>();
    mountedDecoder = decoder;
    return decoder;
  }

  void testPosition(String description, WidgetTesterCallback check) {
    testWidgets(description, (tester) async {
      const output = MethodChannel('videre/music_output');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(output, (call) async {
        if (call.method != 'listen' && call.method != 'cancel') {
          throw MissingPluginException();
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(output, null));
      try {
        await check(tester);
      } finally {
        final decoder = mountedDecoder;
        if (decoder != null) {
          // Unmount before Flutter's automatic cleanup so decoder shutdown
          // starts on the same real clock on which we await its completion.
          await tester.runAsync(() async {
            final closed = decoder.stream.drain<void>();
            await tester.pumpWidget(const SizedBox.shrink());
            await closed.timeout(const Duration(seconds: 2));
          });
          expect(decoder.isClosed, isTrue);
        }
      }
    });
  }

  testPosition('compact Music player fits a taller mixed-script title',
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

    final bounds = tester.getRect(find.byType(MusicMiniPlayer));
    expect(
        tester.getRect(find.text(title)).top, greaterThanOrEqualTo(bounds.top));
    expect(
        tester
            .getRect(find.byKey(const ValueKey('music-mini-progress')))
            .bottom,
        lessThanOrEqualTo(bounds.bottom));
    expect(tester.takeException(), isNull);
  });

  testPosition('mini-player drag stays within the safe viewport at both edges',
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

  testPosition('tapping the mini-player restores it inside the viewport',
      (tester) async {
    final decoder = await pumpPlayer(tester);
    final native = decoder.audioPlayer;
    final docked = tester.getRect(positioned);
    expect(docked.top, greaterThan(window.height / 2));
    await tester.tap(find.byKey(const ValueKey('music-mini-expand')));
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

  testPosition('restoring a repeatedly minimized player keeps its bounds',
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
      await tester.tap(find.byKey(const ValueKey('music-mini-expand')));
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

  testPosition(
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

  testPosition('viewport shrink reclamps a dragged mini-player and it settles',
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

  testPosition('ordinary audio retains the existing video mini-player',
      (tester) async {
    await player.seed(player.state
        .copyWith(currentlyPlaying: song.copyWith(musicMetadata: null)));
    await pumpPlayer(tester);
    expect(find.byType(MiniPlayer), findsOneWidget);
    expect(find.byType(MusicMiniPlayer), findsNothing);
    expect(find.text('Position test - Artist'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testPosition(
      'expanded audio keeps Info and Queue reachable in short landscape',
      (tester) async {
    const size = Size(760, 360);
    viewport.value = const MediaQueryData(
      size: size,
      textScaler: TextScaler.linear(1.7),
    );
    await player.seed(player.state.copyWith(
      isMini: false,
      orientation: Orientation.landscape,
      top: 0,
      currentlyPlaying: song.copyWith(musicMetadata: null, lengthSeconds: 180),
    ));
    await pumpPlayer(tester, physicalSize: size);

    final info = tester.getRect(find.byType(PageView));
    final tabs = tester.getRect(find.byType(NavigationBar));
    expect(info.height, greaterThanOrEqualTo(kMinInteractiveDimension));
    expect(tabs.bottom, closeTo(size.height, 0.01));
    expect(tester.getSize(audioBuilder).width, size.width);
    final queueTab = find.byType(NavigationDestination).last;
    await tester.tap(queueTab);
    await tester.pump();
    expect(player.state.selectedFullScreenIndex, 3);
    expect(tester.takeException(), isNull);
  });

  for (final music in [true, false]) {
    testPosition(
        music
            ? 'hidden Music decoder controls cannot receive keyboard focus'
            : 'visible ordinary audio decoder controls retain keyboard focus',
        (tester) async {
      await player.seed(player.state.copyWith(
          isMini: false,
          top: 0,
          currentlyPlaying: song.copyWith(
              lengthSeconds: 180,
              musicMetadata: music ? song.musicMetadata : null)));
      await pumpPlayer(tester);
      final controls = find.descendant(
          of: audioBuilder,
          matching: find.byWidgetPredicate((widget) => widget is Focus,
              skipOffstage: false),
          skipOffstage: false);
      expect(controls, findsWidgets);
      late FocusNode node;
      tester.element(controls.first).visitChildElements((child) {
        node = Focus.of(child, createDependency: false);
      });
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, !music);
      expect(node.canRequestFocus, !music);
      node.unfocus();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testPosition('Music artwork drag expands and settles with the same decoder',
      (tester) async {
    final decoder = await pumpPlayer(tester);
    final native = decoder.audioPlayer;
    final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('music-mini-artwork'))));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -240));
    await tester.pump();
    expect(player.state.isDragging, isTrue);
    expect(player.state.isMini, isFalse);
    expect(
        tester.element(audioBuilder).read<AudioPlayerCubit>(), same(decoder));
    expect(decoder.audioPlayer, same(native));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(player.state.isDragging, isFalse);
    expect(player.state.isMini, isFalse);
    expect(player.state.top, 0);
    expect(tester.getRect(positioned).top, closeTo(0, 0.01));
    expect(
        tester.element(audioBuilder).read<AudioPlayerCubit>(), same(decoder));
    expect(decoder.audioPlayer, same(native));
    expect(tester.takeException(), isNull);
  });

  testPosition(
      'expanded Music keeps artwork and controls visible after reopening',
      (tester) async {
    await player.seed(player.state.copyWith(isMini: false, top: 0));
    await pumpPlayer(tester);

    void expectVisibleBody() {
      final frame = tester.getRect(positioned);
      final header = tester.getRect(find.byType(AppBar));
      for (final key in [
        'music-now-playing-scroll',
        'music-player-artwork',
        'music-player-title',
        'music-player-play',
      ]) {
        final bounds = tester.getRect(find.byKey(ValueKey(key)));
        expect(bounds.height, greaterThan(0), reason: key);
        expect(bounds.width, greaterThan(0), reason: key);
        expect(bounds.top, greaterThanOrEqualTo(header.bottom), reason: key);
        expect(bounds.bottom, lessThanOrEqualTo(frame.bottom), reason: key);
      }
      expect(find.byKey(const ValueKey('music-player-play')).hitTestable(),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    }

    expectVisibleBody();
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('music-mini-expand')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(player.state.isMini, isFalse);
    expectVisibleBody();
  });

  testPosition('expanded Music follows a short pull and returns on release',
      (tester) async {
    await player.seed(player.state.copyWith(isMini: false, top: 0));
    final decoder = await pumpPlayer(tester);
    final native = decoder.audioPlayer;
    final expanded = tester.getRect(positioned);
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(AppBar)));

    await gesture.moveBy(const Offset(0, 45));
    await tester.pump();
    final first = tester.getRect(positioned);
    await gesture.moveBy(const Offset(0, 75));
    await tester.pump();
    final pulled = tester.getRect(positioned);

    expect(first.top, greaterThan(expanded.top));
    expect(pulled.top, greaterThan(first.top));
    expect(player.state.isMini, isFalse);
    expect(
        tester.element(audioBuilder).read<AudioPlayerCubit>(), same(decoder));
    expect(decoder.audioPlayer, same(native));

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(player.state.isMini, isFalse);
    expect(tester.getRect(positioned).top, closeTo(expanded.top, 0.01));
    expect(
        tester.element(audioBuilder).read<AudioPlayerCubit>(), same(decoder));
    expect(decoder.audioPlayer, same(native));
    expect(tester.takeException(), isNull);
  });

  testPosition('Music minimize settles from the held position with one decoder',
      (tester) async {
    await player.seed(player.state.copyWith(isMini: false, top: 0));
    final decoder = await pumpPlayer(tester);
    final native = decoder.audioPlayer;
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(AppBar)));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 220));
    await tester.pump();
    final held = tester.getRect(positioned);
    expect(held.top, greaterThan(0));
    expect(player.state.isMini, isFalse);

    await gesture.up();
    await tester.pump();
    expect(player.state.isMini, isTrue);
    expect(tester.getRect(positioned).top, closeTo(held.top, 1));
    await tester.pump(const Duration(milliseconds: 80));
    final settling = tester.getRect(positioned);
    expect(settling.top, greaterThan(held.top));
    await tester.pump(const Duration(milliseconds: 500));
    final compact = tester.getRect(positioned);
    expect(compact.top, greaterThan(settling.top));
    expect(compact.bottom, lessThanOrEqualTo(window.height));
    expect(find.byType(MusicMiniPlayer), findsOneWidget);
    expect(
        tester.element(audioBuilder).read<AudioPlayerCubit>(), same(decoder));
    expect(decoder.audioPlayer, same(native));
    expect(tester.takeException(), isNull);
  });

  testPosition('pulling down on Now Playing artwork docks the same track',
      (tester) async {
    await player.seed(player.state.copyWith(isMini: false, top: 0));
    final decoder = await pumpPlayer(tester);
    final native = decoder.audioPlayer;
    final artwork = find.byKey(const ValueKey('music-player-artwork'));

    await tester.drag(artwork, const Offset(0, 90));
    await tester.pumpAndSettle();
    expect(player.state.isMini, isFalse);
    expect(tester.getRect(positioned).top, closeTo(0, 0.01));

    final pull = await tester.startGesture(tester.getCenter(artwork));
    await pull.moveBy(const Offset(0, 40));
    await tester.pump();
    await pull.moveBy(const Offset(0, 220));
    await tester.pump();
    expect(tester.getRect(positioned).top, greaterThan(0));
    expect(player.state.isMini, isFalse);

    await pull.up();
    await tester.pumpAndSettle();
    expect(player.state.isMini, isTrue);
    expect(player.state.currentlyPlaying, same(song));
    expect(find.byType(MusicMiniPlayer), findsOneWidget);
    expect(
        tester.element(audioBuilder).read<AudioPlayerCubit>(), same(decoder));
    expect(decoder.audioPlayer, same(native));
  });

  testPosition('cancelled expanded Music pull returns without minimizing',
      (tester) async {
    await player.seed(player.state.copyWith(isMini: false, top: 0));
    final decoder = await pumpPlayer(tester);
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(AppBar)));
    await gesture.moveBy(const Offset(0, 45));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 220));
    await tester.pump();
    expect(tester.getRect(positioned).top, greaterThan(0));

    await gesture.cancel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(player.state.isMini, isFalse);
    expect(tester.getRect(positioned).top, closeTo(0, 0.01));
    expect(
        tester.element(audioBuilder).read<AudioPlayerCubit>(), same(decoder));
    expect(tester.takeException(), isNull);
  });

  testPosition('Music minimize honors disabled animations at release',
      (tester) async {
    viewport.value = viewport.value.copyWith(disableAnimations: true);
    await player.seed(player.state.copyWith(isMini: false, top: 0));
    final decoder = await pumpPlayer(tester);
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(AppBar)));
    await gesture.moveBy(const Offset(0, 45));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 220));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(player.state.isMini, isTrue);
    expect(tester.getRect(positioned).top, greaterThan(window.height / 2));
    expect(
        tester.widget<AnimatedPositioned>(positioned).duration, Duration.zero);
    expect(
        tester.element(audioBuilder).read<AudioPlayerCubit>(), same(decoder));
    expect(tester.takeException(), isNull);
  });

  testPosition('cancelled Music drag beyond the threshold returns to mini',
      (tester) async {
    await pumpPlayer(tester);
    final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('music-mini-artwork'))));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -180));
    await tester.pump();
    expect(player.state.isDragging, isTrue);
    await gesture.cancel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(player.state.isDragging, isFalse);
    expect(player.state.isMini, isTrue);
    expect(player.state.top, isNull);
    expect(find.byType(MusicMiniPlayer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testPosition('a held mini-player pull cannot reopen a minimized player',
      (tester) async {
    final decoder = await pumpPlayer(tester);
    final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('music-mini-artwork'))));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -180));
    await tester.pump();
    expect(player.state.isMini, isFalse);
    expect(player.state.isDragging, isTrue);

    player.showMiniPlayer();
    await tester.pump();
    await gesture.moveBy(const Offset(0, -140));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(player.state.isMini, isTrue);
    expect(player.state.isDragging, isFalse);
    expect(
        tester.element(audioBuilder).read<AudioPlayerCubit>(), same(decoder));
  });
}
