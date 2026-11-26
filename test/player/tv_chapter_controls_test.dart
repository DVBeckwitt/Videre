import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_main;
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/states/tv_player_controls.dart';
import 'package:clipious/player/views/tv/components/player_controls.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/video_chapter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _TvTestPlayer extends TestPlayerCubit {
  _TvTestPlayer(super.initialState, super.settings);

  void setVideo(Video video) => emit(state.copyWith(currentlyPlaying: video));
}

void main() {
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _TvTestPlayer player;
  late bool priorIsTv;
  const otherVideo = Video(videoId: 'no-chapters', lengthSeconds: 60);

  setUp(() async {
    priorIsTv = app_main.isTv;
    app_main.isTv = true;
    db = await createPlayerTestDatabase();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);

    const video = Video(
      videoId: 'with-chapters',
      lengthSeconds: 60,
      chapters: [
        VideoChapter(title: 'Intro', start: Duration.zero),
        VideoChapter(title: 'First section', start: Duration(seconds: 15)),
        VideoChapter(title: 'Second section', start: Duration(seconds: 35)),
      ],
    );
    player = _TvTestPlayer(
      PlayerState.init(null).copyWith(
        currentlyPlaying: video,
        isMini: false,
        isHidden: false,
        position: const Duration(seconds: 2),
        forwardStep: 5,
        mediaEvent: const MediaEvent(state: MediaState.ready),
      ),
      settings,
    );
  });

  tearDown(() async {
    await settings.close();
    await app.close();
    await db.close();
    app_main.isTv = priorIsTv;
  });

  testWidgets('TV D-pad seeks by chapter with the video paused',
      (tester) async {
    tester.view.physicalSize = const Size(720, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      BlocProvider<PlayerCubit>.value(
        value: player,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(),
          home: const Scaffold(body: TvPlayerControls()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> press(LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    final previous = find.text('Previous chapter');
    final next = find.text('Next chapter');
    bool focused(Finder button) =>
        Focus.of(tester.element(button)).hasPrimaryFocus;

    expect(previous, findsNothing);
    expect(next, findsNothing);
    await press(LogicalKeyboardKey.arrowRight);
    expect(player.state.position, const Duration(seconds: 7));
    await press(LogicalKeyboardKey.select);
    await press(LogicalKeyboardKey.arrowUp);
    expect(focused(previous), isTrue);
    await press(LogicalKeyboardKey.arrowRight);
    expect(focused(next), isTrue);
    await press(LogicalKeyboardKey.select);
    expect(player.state.position, const Duration(seconds: 15));
    await press(LogicalKeyboardKey.select);
    expect(player.state.position, const Duration(seconds: 35));
    await press(LogicalKeyboardKey.select);
    expect(player.state.position, const Duration(seconds: 35));
    expect(focused(next), isTrue);
    await press(LogicalKeyboardKey.arrowLeft);
    expect(focused(previous), isTrue);
    await press(LogicalKeyboardKey.select);
    expect(player.state.position, const Duration(seconds: 15));
    expect(player.state.isPlaying, isFalse);

    player.setVideo(otherVideo);
    await tester.pumpAndSettle();
    expect(previous, findsNothing);
    expect(next, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(controlFadeOut);
    await player.close();
  });
}
