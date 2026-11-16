import 'dart:async';

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/mini_player_aware.dart';
import 'package:clipious/podcasts/views/podcast_player_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_podcast_player.dart';

class _SlowStopPodcastPlayer extends FakePodcastPlayer {
  final stopped = Completer<void>();

  @override
  Future<void> stop() async {
    await super.stop();
    await stopped.future;
  }
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  @override
  final FakePodcastPlayer podcasts;

  _Player(this.podcasts) : super(PlayerState.init(null));

  void videoMiniPlayer() =>
      emit(state.copyWith(isHidden: false, isMini: true, isClosing: false));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

void main() {
  late FakePodcastPlayer podcasts;

  setUp(() => podcasts = FakePodcastPlayer());
  tearDown(() => podcasts.dispose());

  Future<void> show(WidgetTester tester,
      {double width = 390,
      double height = 844,
      double scale = 1,
      Widget? child}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: Scaffold(
        body: child,
        bottomNavigationBar:
            child == null ? PodcastPlaybackBar(controller: podcasts) : null,
      ),
    ));
    await tester.pumpAndSettle();
  }

  for (final (width, scale) in [
    (240.0, 3.0),
    (320.0, 1.0),
    (390.0, 2.0),
    (1024.0, 2.0),
  ]) {
    testWidgets('compact podcast controls fit width $width scale $scale',
        (tester) async {
      podcasts.start();
      await show(tester, width: width, scale: scale);
      expect(tester.getSize(find.byKey(const ValueKey('podcast-playback-bar'))),
          Size(width, podcastBarHeight));
      expect(find.byTooltip('Play'), findsOneWidget);
      expect(find.byTooltip('Stop podcast'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('bar follows playback and stops without leaving empty space',
      (tester) async {
    await show(tester);
    expect(find.byKey(const ValueKey('podcast-playback-bar')), findsNothing);
    podcasts.start();
    await tester.pump();
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(podcasts.playCalls, 1);
    expect(find.byTooltip('Pause'), findsOneWidget);
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(podcasts.pauseCalls, 1);
    await tester.tap(find.byTooltip('Stop podcast'));
    await tester.pump();
    expect(podcasts.stopCalls, 1);
    expect(find.byKey(const ValueKey('podcast-playback-bar')), findsNothing);
  });

  testWidgets('expanded controls seek, change speed, and discard old drags',
      (tester) async {
    podcasts.start();
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('podcast-player-expand')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back 15 seconds'));
    await tester.pump();
    expect(podcasts.position, const Duration(seconds: 5));
    await tester.tap(find.byTooltip('Forward 30 seconds'));
    await tester.pump();
    expect(podcasts.position, const Duration(seconds: 35));
    final oldSlider = tester
        .widget<Slider>(find.byKey(const ValueKey('podcast-player-position')));
    oldSlider.onChanged!(50000);
    podcasts.start();
    await tester.pump();
    oldSlider.onChangeEnd!(60000);
    expect(podcasts.seeks, hasLength(2));
    await tester.tap(find.byTooltip('Playback speed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.5×'));
    await tester.pumpAndSettle();
    expect(podcasts.speed, 1.5);
    expect(tester.takeException(), isNull);
  });

  for (final useBack in [true, false]) {
    testWidgets(
        'finishing Stop after ${useBack ? 'Back' : 'Close'} preserves the library route',
        (tester) async {
      final slow = _SlowStopPodcastPlayer();
      podcasts = slow;
      podcasts.start();
      await show(tester,
          child: Builder(
              builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                          builder: (_) => Scaffold(
                              body: const Text('Library page'),
                              bottomNavigationBar:
                                  PodcastPlaybackBar(controller: podcasts)))),
                  child: const Text('Open library'))));
      await tester.tap(find.text('Open library'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('podcast-player-expand')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Stop podcast').last);
      await tester.pump();
      if (useBack) {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(find.byType(CloseButton));
      }
      // The sheet remains mounted during its exit animation. Delayed native
      // disposal must not dismiss the page beneath it when Stop completes.
      slow.stopped.complete();
      await tester.pumpAndSettle();
      expect(find.text('Library page'), findsOneWidget);
      expect(find.text('Open library'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('TV-sized sheet is scrollable and keyboard controls work',
      (tester) async {
    podcasts.start();
    podcasts.offline = true;
    await show(tester, width: 720, height: 360, scale: 1.5);
    await tester.tap(find.byKey(const ValueKey('podcast-player-expand')));
    await tester.pumpAndSettle();
    expect(find.text('On this device'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(podcasts.playCalls, 1);
    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded controls fit a narrow display with large text',
      (tester) async {
    podcasts.start();
    await show(tester, width: 240, height: 640, scale: 3);
    await tester.tap(find.byKey(const ValueKey('podcast-player-expand')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('podcast-player-play')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed playback offers retry and unknown duration cannot seek',
      (tester) async {
    podcasts.start();
    podcasts.error = 'Playback failed';
    podcasts.duration = Duration.zero;
    await show(tester);
    expect(find.byTooltip('Retry'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('podcast-player-expand')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<Slider>(
                find.byKey(const ValueKey('podcast-player-position')))
            .onChanged,
        isNull);
    await tester.tap(find.byKey(const ValueKey('podcast-player-play')));
    await tester.pump();
    expect(podcasts.playCalls, 1);
    expect(podcasts.error, isNull);
  });

  testWidgets('content padding switches between podcast and video controls',
      (tester) async {
    final player = _Player(podcasts);
    addTearDown(player.close);
    await show(tester,
        child: BlocProvider<PlayerCubit>.value(
          value: player,
          child: const MiniPlayerAware(child: SizedBox.expand()),
        ));
    EdgeInsetsGeometry padding() => tester
        .widget<AnimatedContainer>(find.byType(AnimatedContainer))
        .padding!;
    expect(padding(), EdgeInsets.zero);
    player.videoMiniPlayer();
    await tester.pumpAndSettle();
    expect(padding(), const EdgeInsets.only(bottom: targetHeight));
    podcasts.start();
    await tester.pumpAndSettle();
    expect(padding(), const EdgeInsets.only(bottom: podcastBarHeight));
    await podcasts.stop();
    await tester.pumpAndSettle();
    expect(padding(), const EdgeInsets.only(bottom: targetHeight));
  });
}
