import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app;
import 'package:clipious/music/models/music_background_playback.dart';
import 'package:clipious/music/models/music_mini_player_preferences.dart';
import 'package:clipious/music/models/music_song_row_swipe_action.dart';
import 'package:clipious/music/models/music_song_tap_queue_scope.dart';
import 'package:clipious/music/models/music_player_appearance.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/views/components/music_provider_settings.dart';
import 'package:clipious/utils/backup.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_settings_cubit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppCubit appCubit;
  late SettingsCubit settings;
  late bool previousTv;

  setUp(() async {
    previousTv = app.isTv;
    app.isTv = false;
    db = await SembastSqfDb.createInMemory();
    appCubit = TestAppCubit(AppState(0, null, HomeLayout()));
    appCubit.intentDataStreamSubscription = const Stream.empty().listen((_) {});
    await appCubit.initState();
    settings = TestSettingsCubit(SettingsState.init(), appCubit);
  });
  tearDown(() async {
    app.isTv = previousTv;
    await settings.close();
    await appCubit.close();
    await db.close();
  });

  Future<void> showSettings(WidgetTester tester) async {
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider.value(value: appCubit),
        BlocProvider.value(value: settings),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
            body: SingleChildScrollView(child: MusicProviderSettings())),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('selects the mini-player layout and shortcut independently',
      (tester) async {
    await showSettings(tester);
    Future<void> choose(
        String setting, List<String> labels, String target) async {
      final tile = find.byKey(ValueKey('music-mini-player-$setting-setting'));
      expect(find.descendant(of: tile, matching: find.text('Automatic')),
          findsOneWidget);
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      final dialog = find.byType(SimpleDialog);
      for (final label in labels) {
        expect(find.descendant(of: dialog, matching: find.text(label)),
            findsOneWidget);
      }
      await tester
          .tap(find.descendant(of: dialog, matching: find.text(target)));
      await tester.pumpAndSettle();
      expect(find.descendant(of: tile, matching: find.text(target)),
          findsOneWidget);
    }

    await choose('layout', ['Automatic', 'Compact', 'Transport'], 'Transport');
    await choose(
        'shortcut', ['Automatic', 'Next', 'Repeat', 'Shuffle'], 'Repeat');
    expect(
        settings.state.musicMiniPlayerLayout, MusicMiniPlayerLayout.transport);
    expect(
        settings.state.musicMiniPlayerShortcut, MusicMiniPlayerShortcut.repeat);
  });

  testWidgets('artwork swiping starts enabled and can be turned off',
      (tester) async {
    await showSettings(tester);
    final tile =
        find.widgetWithText(SwitchListTile, 'Swipe artwork to change songs');
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    expect(settings.state.musicArtworkSwipe, isFalse);
  });

  testWidgets('double-tap seeking is opt-in and independent of artwork swiping',
      (tester) async {
    await showSettings(tester);
    final swipe =
        find.widgetWithText(SwitchListTile, 'Swipe artwork to change songs');
    await tester.ensureVisible(swipe);
    await tester.tap(swipe);
    await tester.pumpAndSettle();
    final tile =
        find.widgetWithText(SwitchListTile, 'Double-tap artwork to seek');
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    expect(settings.state.musicArtworkDoubleTapSeek, isTrue);
    expect(settings.state.musicArtworkSwipe, isFalse);
  });

  testWidgets('listeners can choose each song-row swipe independently',
      (tester) async {
    await showSettings(tester);
    final right = find.byKey(const ValueKey('music-song-swipe-end-setting'));
    final left = find.byKey(const ValueKey('music-song-swipe-start-setting'));
    Future<void> choose(Finder tile, String choice) async {
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byType(SimpleDialog), matching: find.text(choice)));
      await tester.pumpAndSettle();
    }

    expect(
        find.descendant(of: right, matching: find.text('Off')), findsOneWidget);
    expect(
        find.descendant(of: left, matching: find.text('Off')), findsOneWidget);
    await choose(right, 'Play next');
    expect(settings.state.musicSongSwipeTowardEnd,
        MusicSongRowSwipeAction.playNext);
    expect(
        settings.state.musicSongSwipeTowardStart, MusicSongRowSwipeAction.off);
    await choose(left, 'Add to queue');
    expect(settings.state.musicSongSwipeTowardStart,
        MusicSongRowSwipeAction.addToQueue);
    await choose(right, 'Off');
    expect(settings.state.musicSongSwipeTowardEnd, MusicSongRowSwipeAction.off);
    expect(settings.state.musicSongSwipeTowardStart,
        MusicSongRowSwipeAction.addToQueue);
  });

  testWidgets('song tap queue and retained shuffle save independently',
      (tester) async {
    await showSettings(tester);
    final scope = find.widgetWithText(ListTile, 'When tapping a song');
    final shuffle =
        find.widgetWithText(SwitchListTile, 'Keep shuffle when playing a song');
    expect(
        find.descendant(of: scope, matching: find.text('Queue the collection')),
        findsOneWidget);
    expect(tester.widget<SwitchListTile>(shuffle).value, isTrue);

    await tester.ensureVisible(scope);
    await tester.tap(scope);
    await tester.pumpAndSettle();
    final songOnly = find.widgetWithText(ListTile, 'Queue only this song');
    await tester.tap(songOnly);
    await tester.pumpAndSettle();
    expect(
        find.descendant(of: scope, matching: find.text('Queue only this song')),
        findsOneWidget);
    expect(tester.widget<SwitchListTile>(shuffle).value, isTrue);

    await tester.ensureVisible(shuffle);
    await tester.tap(shuffle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(shuffle).value, isFalse);
    final saved = SettingsState.init();
    expect(saved.musicSongTapQueueScope, MusicSongTapQueueScope.songOnly);
    expect(saved.musicRetainShuffleOnSongTap, isFalse);
  });

  testWidgets('Android Music screen privacy is opt-in and persists',
      (tester) async {
    await showSettings(tester);
    final tile = find.byKey(const ValueKey('music-screen-privacy-setting'));
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    expect(SettingsState.init().musicScreenPrivacy, isTrue);

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    expect(SettingsState.init().musicScreenPrivacy, isFalse);
  });

  testWidgets('TV omits touch gestures and mini-player choices',
      (tester) async {
    app.isTv = true;
    await showSettings(tester);
    expect(find.text('Streaming audio quality'), findsOneWidget);
    expect(find.text('When tapping a song'), findsOneWidget);
    expect(find.text('Keep shuffle when playing a song'), findsOneWidget);
    expect(find.text('Mini-player layout'), findsNothing);
    expect(find.text('Mini-player shortcut'), findsNothing);
    expect(find.text('Swipe artwork to change songs'), findsNothing);
    expect(find.text('Double-tap artwork to seek'), findsNothing);
    expect(find.text('Swipe right on song rows'), findsNothing);
    expect(find.text('Swipe left on song rows'), findsNothing);
    expect(find.text('Now Playing style'), findsOneWidget);
    expect(find.text('Now Playing background'), findsOneWidget);
    expect(find.text('Scrubber style'), findsOneWidget);
  });

  testWidgets('shows and saves the transport choices in Music settings',
      (tester) async {
    await showSettings(tester);
    final previous =
        find.byKey(const ValueKey('music-previous-track-policy-setting'));
    await tester.ensureVisible(previous);
    await tester.tap(previous);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(
        const ValueKey('music-previous-track-restartCurrentAfterThreshold')));
    await tester.pumpAndSettle();
    for (final key in ['music-pause-at-repeat', 'music-keep-paused-on-skip']) {
      final tile = find.byKey(ValueKey('$key-setting'));
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    }
    final saved = SettingsState.init();
    expect(saved.musicPreviousTrackPolicy,
        MusicPreviousTrackPolicy.restartCurrentAfterThreshold);
    expect(saved.musicPauseAtRepeat, isTrue);
    expect(saved.musicKeepPausedOnSkip, isTrue);
  });

  testWidgets('Android TV offers all four Music interruption choices',
      (tester) async {
    app.isTv = true;
    await showSettings(tester);
    for (final (key, initial, selected) in [
      ('audio-focus-return', 'Resume playback', 'Stay paused'),
      ('volume-zero', 'Keep playing', 'Pause playback'),
      ('reconnect', 'Retry automatically', 'Retry manually'),
      (
        'retry-exhaustion',
        'Stay on the failed track',
        'Skip to the next track'
      ),
    ]) {
      final tile = find.byKey(ValueKey('music-$key-setting'));
      expect(find.descendant(of: tile, matching: find.text(initial)),
          findsOneWidget);
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      final option = find.descendant(
          of: find.byType(SimpleDialog), matching: find.text(selected));
      expect(option, findsOneWidget);
      if (key == 'volume-zero') {
        expect(
          find.text('Playback pauses when you lower the media volume to zero. '
              'Press Play to resume.'),
          findsOneWidget,
        );
      }
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(find.descendant(of: tile, matching: find.text(selected)),
          findsOneWidget);
    }
    expect(settings.state.musicResumeAfterAudioFocusLoss, isFalse);
    expect(settings.state.musicPauseAtZeroVolume, isTrue);
    expect(settings.state.musicAutoReconnect, isFalse);
    expect(settings.state.musicSkipAfterRetryExhaustion, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('selects independent Android background playback choices',
      (tester) async {
    await showSettings(tester);
    final dismissal = find.byKey(const ValueKey('music-task-removal-setting'));
    final offload = find.byKey(const ValueKey('music-audio-offload-setting'));
    expect(find.descendant(of: dismissal, matching: find.text('Stop playback')),
        findsOneWidget);
    expect(
        find.descendant(of: offload, matching: find.text('Standard playback')),
        findsOneWidget);

    await tester.ensureVisible(dismissal);
    await tester.tap(dismissal);
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('music-task-removal-keepPlaying')));
    await tester.pumpAndSettle();
    expect(settings.state.musicTaskRemoval, MusicTaskRemoval.keepPlaying);
    expect(settings.state.musicAudioOffload, MusicAudioOffload.disabled);

    await tester.ensureVisible(offload);
    await tester.tap(offload);
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('music-audio-offload-whenSupported')));
    await tester.pumpAndSettle();
    expect(settings.state.musicAudioOffload, MusicAudioOffload.whenSupported);
    expect(settings.state.musicTaskRemoval, MusicTaskRemoval.keepPlaying);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('hides Android background playback choices on other platforms',
      (tester) async {
    await showSettings(tester);
    expect(
        find.byKey(const ValueKey('music-task-removal-setting')), findsNothing);
    expect(find.byKey(const ValueKey('music-audio-offload-setting')),
        findsNothing);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('selects the Now Playing style, background and scrubber', (
    tester,
  ) async {
    await showSettings(tester);
    final revision = MusicPlayerAppearance.revision.value;

    Future<void> choose(String setting, String initial, String target) async {
      final tile = find.byKey(ValueKey('music-$setting-setting'));
      expect(
        find.descendant(of: tile, matching: find.text(initial)),
        findsOneWidget,
      );
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(SimpleDialog),
          matching: find.text(target),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: tile, matching: find.text(target)),
        findsOneWidget,
      );
    }

    await choose('now-playing-style', 'Classic', 'Large artwork');
    await choose('player-background', 'Artwork', 'Solid');
    await choose('scrubber-style', 'Gapped', 'Wave');
    expect(
      MusicNowPlayingStyle.forDatabase(db),
      MusicNowPlayingStyle.largeArtwork,
    );
    expect(MusicPlayerBackground.forDatabase(db), MusicPlayerBackground.solid);
    expect(MusicScrubberStyle.forDatabase(db), MusicScrubberStyle.wave);
    expect(MusicPlayerAppearance.revision.value, revision + 3);
  });

  test(
    'Now Playing preferences follow the profile and survive backup',
    () async {
      final original = db.forProfile(db.profileId);
      final other = await db.createProfile('Other');
      await MusicNowPlayingStyle.compact.save(original);
      await MusicPlayerBackground.solid.save(original);
      await MusicScrubberStyle.continuous.save(original);
      final backup = UserBackup.parse((await db.exportBackup()).encode());

      await db.useProfile(other.id);
      expect(
        MusicNowPlayingStyle.forDatabase(db),
        MusicNowPlayingStyle.classic,
      );
      expect(
        MusicPlayerBackground.forDatabase(db),
        MusicPlayerBackground.artwork,
      );
      expect(MusicScrubberStyle.forDatabase(db), MusicScrubberStyle.gapped);
      await db.restoreBackup(backup, replace: false);
      expect(
        MusicNowPlayingStyle.forDatabase(db),
        MusicNowPlayingStyle.compact,
      );
      expect(
        MusicPlayerBackground.forDatabase(db),
        MusicPlayerBackground.solid,
      );
      expect(MusicScrubberStyle.forDatabase(db), MusicScrubberStyle.continuous);

      for (final key in [
        musicNowPlayingStyleSettingName,
        musicPlayerBackgroundSettingName,
        musicScrubberStyleSettingName,
      ]) {
        final invalid = SettingsValue(key, 'unknown');
        expect(UserBackup.validSetting(invalid), isFalse);
        await db.saveSetting(invalid);
      }
      expect(
        MusicNowPlayingStyle.forDatabase(db),
        MusicNowPlayingStyle.classic,
      );
      expect(
        MusicPlayerBackground.forDatabase(db),
        MusicPlayerBackground.artwork,
      );
      expect(MusicScrubberStyle.forDatabase(db), MusicScrubberStyle.gapped);
      expect(
        MusicScrubberStyle.forDatabase(original),
        MusicScrubberStyle.continuous,
      );
    },
  );
}
