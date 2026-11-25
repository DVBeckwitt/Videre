import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/views/components/music_playback_toggles.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

class _App extends Cubit<AppState> implements AppCubit {
  _App() : super(AppState(0, null, HomeLayout()));

  void switchSession() =>
      emit(state.copyWith(sessionRevision: state.sessionRevision + 1));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player()
      : super(PlayerState.init(
            const [Video(videoId: 'first'), Video(videoId: 'second')]));

  @override
  int playlistGeneration = 1;
  int regenerations = 0;

  @override
  void generatePlayQueue() => regenerations++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends Cubit<SettingsState> implements SettingsCubit {
  _Settings()
      : super(SettingsState(
            settings: const {},
            packageInfo: PackageInfo(
                appName: '', packageName: '', version: '', buildNumber: '')));

  late final Completer<void> saving;
  final writes = <bool>[];

  @override
  Future<void> setShuffle(bool value) async {
    writes.add(value);
    await saving.future;
    emit(state.copyWith(settings: {
      playerShuffle: SettingsValue(playerShuffle, value.toString())
    }));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const compact = ValueKey('compact');
  const full = ValueKey('full');
  const fill = Color(0xff444444);
  late _App app;
  late _Player player;
  late _Settings settings;
  setUp(() {
    app = _App();
    player = _Player();
    settings = _Settings();
  });
  tearDown(() async {
    await settings.close();
    await player.close();
    await app.close();
  });

  Future<void> show(WidgetTester tester) async {
    settings.saving = Completer<void>();
    await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<AppCubit>.value(value: app),
          BlocProvider<PlayerCubit>.value(value: player),
          BlocProvider<SettingsCubit>.value(value: settings),
        ],
        child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
                body: Row(children: [
              MusicShuffleButton(
                  controlKey: compact,
                  selectedBackgroundColor: fill,
                  style: IconButton.styleFrom(foregroundColor: Colors.white)),
              const MusicShuffleButton(controlKey: full),
            ])))));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'a pending shuffle tap is shared across surfaces and refreshes the same queue once',
      (tester) async {
    await show(tester);
    await tester.tap(find.byKey(compact));
    await tester.tap(find.byKey(full));
    expect(settings.writes, [true]);
    expect(player.regenerations, 0);
    settings.saving.complete();
    await tester.pumpAndSettle();
    expect(player.regenerations, 1);
    final button = tester.widget<IconButton>(find.byKey(compact));
    expect(button.isSelected, isTrue);
    expect(
        button.style!.backgroundColor!.resolve({WidgetState.selected}), fill);
    expect(button.style!.foregroundColor!.resolve({WidgetState.selected}),
        Colors.white);
    await tester.tap(find.byKey(full));
    await tester.pumpAndSettle();
    expect(settings.writes, [true, false]);
    expect(player.regenerations, 2);
  });

  for (final changed in ['profile', 'queue']) {
    testWidgets('pending shuffle leaves a replaced $changed alone',
        (tester) async {
      await show(tester);
      await tester.tap(find.byKey(compact));
      if (changed == 'profile') {
        app.switchSession();
      } else {
        player.playlistGeneration++;
      }
      settings.saving.complete();
      await tester.pumpAndSettle();
      expect(settings.writes, [true]);
      expect(player.regenerations, 0);
    });
  }
}
