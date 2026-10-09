import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/states/player_controls.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

void main() {
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = TestPlayerCubit(
        PlayerState.init(null).copyWith(isMini: false), settings);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await db.close();
  });

  testWidgets('closing controls cancels pending feedback and hide timers',
      (tester) async {
    final controls = PlayerControlsCubit(const PlayerControlsState(), player);
    controls.doubleTapFastForward();
    controls.doubleTapRewind();
    controls.onStreamEvent(const MediaEvent(
        state: MediaState.playing, type: MediaEventType.sponsorSkipped));
    await controls.close();
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('separate controls keep their own hide deadlines',
      (tester) async {
    final first = PlayerControlsCubit(const PlayerControlsState(), player);
    await tester.pump(const Duration(seconds: 1));
    final second = PlayerControlsCubit(const PlayerControlsState(), player);
    await tester.pump(const Duration(seconds: 2));
    expect(first.state.displayControls, isFalse);
    expect(second.state.displayControls, isTrue);
    await first.close();
    await tester.pump(const Duration(seconds: 1));
    expect(second.state.displayControls, isFalse);
    await second.close();
  });
}
