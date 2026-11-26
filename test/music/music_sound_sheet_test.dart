import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/replay_gain.dart';
import 'package:clipious/music/services/music_replay_gain_preferences.dart';
import 'package:clipious/music/services/music_output_presets.dart';
import 'package:clipious/music/services/music_sound_controller.dart';
import 'package:clipious/music/views/components/music_sound_sheet.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _Equalizer implements MusicEqualizerBackend {
  final changes = StreamController<int?>.broadcast(sync: true);
  final writes = <({int session, int band, double gain})>[];
  final levels = <int, double>{0: 0, 1: 0, 2: 0};
  double minimum = -12;
  double maximum = 12;
  int currentSession = 7;
  bool enabled = false;
  bool failRead = false;
  bool failDisable = false;
  int? failBand;

  @override
  int get sessionId => currentSession;
  @override
  Stream<int?> get sessions => changes.stream;

  void _check(int session) {
    if (session != currentSession) throw StateError('Stale session');
  }

  @override
  Future<MusicEqualizerParameters> read(int session) async {
    _check(session);
    if (failRead) throw UnsupportedError('Device has no equalizer');
    return MusicEqualizerParameters(minimum, maximum, [
      MusicEqualizerBand(0, 60, levels[0]!),
      MusicEqualizerBand(1, 1000, levels[1]!),
      MusicEqualizerBand(2, 8000, levels[2]!),
    ]);
  }

  @override
  Future<void> setEnabled(bool value, int session) async {
    _check(session);
    if (!value && failDisable) throw StateError('Could not disable');
    enabled = value;
  }

  @override
  Future<void> setGain(int band, double gain, int session) async {
    _check(session);
    if (band == failBand) throw StateError('Band change rejected');
    if (gain < minimum || gain > maximum) throw RangeError.value(gain);
    writes.add((session: session, band: band, gain: gain));
    levels[band] = gain;
  }

  void replaceSession() {
    currentSession++;
    levels.updateAll((_, __) => 0);
    changes.add(currentSession);
  }
}

class _Player extends TestPlayerCubit {
  double? requestedSpeed;
  int? requestedPitch;

  _Player(super.initialState, super.settings);

  @override
  void setSpeed(double value) => requestedSpeed = value;
  @override
  void setPitchSemitones(int value) => requestedPitch = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _Player player;
  late _Equalizer backend;
  late StreamController<MusicOutput?> outputs;
  late MusicSoundController controller;
  const song = Video(
      videoId: 'sound-song',
      title: 'Song',
      lengthSeconds: 180,
      musicMetadata: MusicMetadata(title: 'Song', artist: 'Artist'));

  setUp(() async {
    db = await createPlayerTestDatabase();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = _Player(
        PlayerState.init([song]).copyWith(
            currentlyPlaying: song,
            isAudio: true,
            isHidden: false,
            isMini: false),
        settings);
    backend = _Equalizer();
    outputs = StreamController<MusicOutput?>.broadcast(sync: true);
    controller = player.musicSound;
    controller.attachBackend(backend,
        owner: backend, profileId: db.profileId, outputs: outputs.stream);
  });

  tearDown(() async {
    await player.close();
    await outputs.close();
    await backend.changes.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> show(WidgetTester tester,
      {bool fullSheet = false, double scale = 1, double width = 390}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
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
          body: fullSheet
              ? MusicSoundSheet(player: player)
              : SingleChildScrollView(
                  child: MusicEqualizerControls(
                      controller: controller, isCurrent: () => true))),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets('Bass, Treble and Reset apply actual backend band values',
      (tester) async {
    await controller.open();
    await show(tester);
    await tap(tester, 'music-equalizer-bass');
    expect(backend.levels, {0: 4, 1: 0, 2: 0});
    expect(backend.enabled, isTrue);
    await tap(tester, 'music-equalizer-treble');
    expect(backend.levels, {0: 0, 1: 0, 2: 4});
    await tap(tester, 'music-equalizer-reset');
    expect(backend.levels, {0: 0, 1: 0, 2: 0});
    expect(backend.enabled, isFalse);
    expect(controller.failed, isFalse);
  });

  testWidgets('output presets restore EQ, ReplayGain and preamp together',
      (tester) async {
    const headphones = MusicOutput('headphones', 'Headphones');
    const saveKey = 'music-output-preset-save';
    const forgetKey = 'music-output-preset-forget';
    final defaults = MusicReplayGainPreferences(db.forProfile(db.profileId));
    await tester.runAsync(() => defaults.setMode(ReplayGainMode.track));
    await show(tester, fullSheet: true);
    expect(find.byKey(const ValueKey(saveKey)), findsNothing);

    Future<void> selectOutput(MusicOutput? output) async {
      await tester.runAsync(() async {
        outputs.add(output);
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
    }

    Future<void> tapStorage(String key) async {
      final target = find.byKey(ValueKey(key));
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(target);
        final timeout = Stopwatch()..start();
        while (controller.savingOutputPreset &&
            timeout.elapsed < const Duration(seconds: 2)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      await tester.pumpAndSettle();
    }

    await selectOutput(headphones);
    expect(find.text('Audio output: Headphones'), findsOneWidget);
    await tap(tester, 'music-replaygain-album');
    await tap(tester, 'music-tagged-preamp-increase');
    await tap(tester, 'music-untagged-preamp-decrease');
    await tap(tester, 'music-equalizer-bass');
    await tapStorage(saveKey);
    expect(find.text('A preset is saved for this output.'), findsOneWidget);
    expect(defaults.mode, ReplayGainMode.track);
    expect(defaults.taggedPreampDb, 0);
    expect(defaults.untaggedPreampDb, 0);

    await selectOutput(null);
    expect(find.byKey(const ValueKey(saveKey)), findsNothing);
    expect(controller.replayGainMode, ReplayGainMode.track);
    expect(controller.musicTaggedPreampDb, 0);
    expect(controller.musicUntaggedPreampDb, 0);
    expect(backend.enabled, isFalse);

    await selectOutput(headphones);
    expect(controller.replayGainMode, ReplayGainMode.album);
    expect(controller.musicTaggedPreampDb, 1);
    expect(controller.musicUntaggedPreampDb, -1);
    expect(backend.levels, {0: 4, 1: 0, 2: 0});
    expect(backend.enabled, isTrue);
    await tapStorage(forgetKey);
    expect(find.byKey(const ValueKey(forgetKey)), findsNothing);
    expect(controller.replayGainMode, ReplayGainMode.album);
    expect(backend.enabled, isTrue);

    await selectOutput(null);
    await selectOutput(headphones);
    expect(controller.replayGainMode, ReplayGainMode.track);
    expect(controller.musicTaggedPreampDb, 0);
    expect(controller.musicUntaggedPreampDb, 0);
    expect(backend.enabled, isFalse);
  });

  testWidgets('native EQ failure keeps shared speed and pitch controls working',
      (tester) async {
    backend.failRead = true;
    await show(tester, fullSheet: true);
    expect(
        find.byKey(const ValueKey('music-equalizer-failure')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('playback-speed-increase')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('playback-pitch-increase')), findsOneWidget);
    await tap(tester, 'playback-speed-increase');
    expect(player.requestedSpeed, 1.05);
    await tap(tester, 'playback-pitch-increase');
    expect(player.requestedPitch, 1);
    expect(
        find.byKey(const ValueKey('music-equalizer-failure')), findsOneWidget);
  });

  testWidgets('Skip silence defaults off and saves changes in Music Sound',
      (tester) async {
    await show(tester, fullSheet: true);
    final toggle = find.byKey(const ValueKey('music-skip-silence'));
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(db.getSettings(musicSkipSilenceSettingName), isNull);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();

    for (final enabled in [true, false]) {
      await tester.runAsync(() async {
        final saved = settings.stream
            .firstWhere((state) => state.musicSkipSilence == enabled);
        await tester.tap(toggle);
        await saved.timeout(const Duration(seconds: 5));
      });
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, enabled);
      expect(db.getSettings(musicSkipSilenceSettingName)?.value,
          enabled.toString());
    }
  });

  testWidgets('waiting for an audio session does not hide speed and pitch',
      (tester) async {
    backend.currentSession = 0;
    backend.changes.add(0);
    await show(tester, fullSheet: true);
    expect(controller.waiting, isTrue);
    await tap(tester, 'playback-speed-increase');
    await tap(tester, 'playback-pitch-increase');
    expect(player.requestedSpeed, 1.05);
    expect(player.requestedPitch, 1);
    final equalizer = find.byKey(const ValueKey('music-equalizer-enabled'));
    expect(tester.widget<SwitchListTile>(equalizer).onChanged, isNull);
  });

  test(
    'ReplayGain preferences are profile scoped and sanitize stored values',
    () async {
      final firstId = db.profileId;
      final first = MusicReplayGainPreferences(db.forProfile(firstId));
      final second = await db.createProfile('Other listener');
      final secondDb = db.forProfile(second.id);
      final secondPreferences = MusicReplayGainPreferences(secondDb);
      await db.useProfile(second.id);
      try {
        await first.setMode(ReplayGainMode.album);
        await first.setTaggedPreampDb(-80);
        await first.setUntaggedPreampDb(80);
        await secondDb.saveSetting(
          SettingsValue(musicReplayGainModeSettingName, 'unknown'),
        );
        await secondDb.saveSetting(
          SettingsValue(musicPreampSettingName, 'NaN'),
        );
        expect(first.mode, ReplayGainMode.album);
        expect(first.taggedPreampDb, minimumMusicPreampDb);
        expect(first.untaggedPreampDb, maximumMusicPreampDb);
        expect(secondPreferences.mode, ReplayGainMode.off);
        expect(secondPreferences.taggedPreampDb, 0);
        expect(secondPreferences.untaggedPreampDb, 0);
      } finally {
        await db.useProfile(firstId);
      }
    },
  );

  testWidgets(
    'Both preamps inherit the old level and can be edited from Sound',
    (tester) async {
      backend.failRead = true;
      final profile = db.forProfile(db.profileId);
      final preferences = MusicReplayGainPreferences(profile);
      await tester.runAsync(() => profile.saveSetting(
            SettingsValue(musicPreampSettingName, '-4'),
          ));
      await show(tester, fullSheet: true, width: 320, scale: 2.5);
      final off = find.byKey(const ValueKey('music-replaygain-off'));
      final album = find.byKey(const ValueKey('music-replaygain-album'));
      expect(tester.widget<ChoiceChip>(off).selected, isTrue);
      expect(preferences.taggedPreampDb, -4);
      expect(preferences.untaggedPreampDb, -4);
      expect(find.text('-4 dB'), findsNWidgets(2));

      Future<void> save(String key, bool Function() saved) async {
        final control = find.byKey(ValueKey(key));
        await tester.ensureVisible(control);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(control);
          final timeout = Stopwatch()..start();
          while (!saved() && timeout.elapsed < const Duration(seconds: 2)) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect(saved(), isTrue);
        });
        await tester.pumpAndSettle();
      }

      await save('music-replaygain-album',
          () => preferences.mode == ReplayGainMode.album);
      expect(tester.widget<ChoiceChip>(album).selected, isTrue);

      await save('music-replaygain-contextual',
          () => preferences.mode == ReplayGainMode.contextual);
      expect(
          tester
              .widget<ChoiceChip>(
                  find.byKey(const ValueKey('music-replaygain-contextual')))
              .selected,
          isTrue);
      await save('music-tagged-preamp-increase',
          () => preferences.taggedPreampDb == -3);
      expect(preferences.untaggedPreampDb, -4);
      expect(find.text('-3 dB'), findsOneWidget);
      expect(find.text('-4 dB'), findsOneWidget);

      await save('music-untagged-preamp-decrease',
          () => preferences.untaggedPreampDb == -5);
      final reloaded = MusicReplayGainPreferences(db.forProfile(db.profileId));
      expect(reloaded.taggedPreampDb, -3);
      expect(reloaded.untaggedPreampDb, -5);
      expect(profile.getSettings(musicPreampSettingName)?.value, '-4');
      expect(find.text('-5 dB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Music volume is adjustable and saved with the profile',
      (tester) async {
    await show(tester, fullSheet: true);
    final slider = find.byKey(const ValueKey('music-playback-volume'));
    expect(tester.widget<Slider>(slider).value, 1);
    await tester.runAsync(() async {
      final saved = settings.stream
          .firstWhere((state) => state.musicPlaybackVolume == 0.35)
          .timeout(const Duration(seconds: 5));
      tester.widget<Slider>(slider).onChanged!(0.35);
      await saved;
    });
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(slider).value, 0.35);
    expect(SettingsState.init().musicPlaybackVolume, 0.35);
  });

  testWidgets('held band drag cannot change a replacement audio session',
      (tester) async {
    await controller.open();
    await controller.setEnabled(true);
    await show(tester);
    final slider = find.byType(Slider).first;
    final drag = await tester.startGesture(tester.getCenter(slider));
    await drag.moveBy(const Offset(70, 0));
    await tester.pump();
    await tester.runAsync(() async {
      backend.replaceSession();
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    backend.writes.clear();
    await drag.up();
    await tester.pumpAndSettle();
    expect(backend.writes, isEmpty);
    expect(backend.levels, {0: 0, 1: 0, 2: 0});
  });

  testWidgets('partial preset failure keeps Disable and Reset available',
      (tester) async {
    await controller.open();
    await controller.bass();
    await show(tester);
    backend
      ..failBand = 1
      ..failDisable = true;
    await tap(tester, 'music-equalizer-treble');
    expect(controller.failed, isTrue);
    expect(backend.enabled, isTrue);
    final toggle = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('music-equalizer-enabled')));
    expect(toggle.onChanged, isNotNull);
    final reset = tester.widget<TextButton>(
        find.byKey(const ValueKey('music-equalizer-reset')));
    expect(reset.onPressed, isNotNull);
    backend
      ..failBand = null
      ..failDisable = false;
    await tap(tester, 'music-equalizer-enabled');
    expect(backend.enabled, isFalse);
    await tap(tester, 'music-equalizer-reset');
    expect(backend.levels, {0: 0, 1: 0, 2: 0});
    expect(controller.failed, isFalse);
  });

  testWidgets('fractional device gain ranges remain operable', (tester) async {
    backend
      ..minimum = -0.1
      ..maximum = 0.1;
    await controller.open();
    await show(tester);
    await tap(tester, 'music-equalizer-bass');
    expect(backend.levels[0], 0.1);
    expect(tester.takeException(), isNull);
    for (final slider in tester.widgetList<Slider>(find.byType(Slider))) {
      expect(slider.divisions, greaterThan(0));
    }
    await tap(tester, 'music-equalizer-reset');
    expect(backend.levels.values, everyElement(0));
  });

  testWidgets('narrow large-text sound controls remain reachable',
      (tester) async {
    await controller.open();
    await show(tester, width: 320, scale: 2.5);
    expect(tester.takeException(), isNull);
    await tap(tester, 'music-equalizer-treble');
    await tester.ensureVisible(find.byType(Slider).last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(backend.levels[2], 4);
    await tap(tester, 'music-equalizer-reset');
    expect(backend.enabled, isFalse);
  });
}
