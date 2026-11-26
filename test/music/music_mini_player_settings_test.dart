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

  testWidgets('the mini-player lyric setting starts off and can be enabled',
      (tester) async {
    await showSettings(tester);
    final tile = find.byKey(const ValueKey('music-mini-player-lyrics-setting'));
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    await tester.ensureVisible(tile);
    await tester.runAsync(() async {
      await tester.tap(tile);
      await (db as SembastSqfDb).db.transaction((_) async {});
    });
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    expect(settings.state.musicMiniPlayerLyrics, isTrue);
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

  const deviceSongTapChoices = {
    MusicSongTapQueueScope.allSongs: 'Queue all device songs',
    MusicSongTapQueueScope.album: 'Queue this album',
    MusicSongTapQueueScope.artist: 'Queue songs by this artist',
    MusicSongTapQueueScope.genre: 'Queue songs in this genre',
  };

  testWidgets('song tap queue and retained shuffle save independently',
      (tester) async {
    await showSettings(tester);
    final scope = find.byKey(const ValueKey('music-song-tap-queue-setting'));
    final shuffle =
        find.widgetWithText(SwitchListTile, 'Keep shuffle when playing a song');
    expect(
        find.descendant(of: scope, matching: find.text('Queue the collection')),
        findsOneWidget);
    expect(tester.widget<SwitchListTile>(shuffle).value, isTrue);

    for (final option in {
      ...deviceSongTapChoices,
      MusicSongTapQueueScope.songOnly: 'Queue only this song',
    }.entries) {
      await tester.ensureVisible(scope);
      await tester.tap(scope);
      await tester.pumpAndSettle();
      final choice = find.widgetWithText(ListTile, option.value);
      await tester.ensureVisible(choice);
      await tester.tap(choice);
      await tester.pumpAndSettle();
      expect(find.descendant(of: scope, matching: find.text(option.value)),
          findsOneWidget);
      expect(SettingsState.init().musicSongTapQueueScope, option.key);
      expect(tester.widget<SwitchListTile>(shuffle).value, isTrue);
    }

    await tester.ensureVisible(shuffle);
    await tester.tap(shuffle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(shuffle).value, isFalse);
    final saved = SettingsState.init();
    expect(saved.musicSongTapQueueScope, MusicSongTapQueueScope.songOnly);
    expect(saved.musicRetainShuffleOnSongTap, isFalse);
  });

  testWidgets('album and playlist taps can override or inherit the default',
      (tester) async {
    await showSettings(tester);
    final defaultTile =
        find.byKey(const ValueKey('music-song-tap-queue-setting'));
    final detailTile =
        find.byKey(const ValueKey('music-collection-detail-song-tap-setting'));

    Future<void> choose(Finder tile, String choice) async {
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      final option = find.descendant(
          of: find.byType(SimpleDialog), matching: find.text(choice));
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(find.descendant(of: tile, matching: find.text(choice)),
          findsOneWidget);
    }

    expect(
        find.descendant(of: detailTile, matching: find.text('Use the default')),
        findsOneWidget);
    await choose(defaultTile, 'Queue only this song');
    final inherited = SettingsState.init();
    expect(inherited.musicCollectionDetailSongTapQueueScope, isNull);
    expect(inherited.resolveMusicSongTapQueueScope(collectionDetail: true),
        MusicSongTapQueueScope.songOnly);

    for (final option in deviceSongTapChoices.entries) {
      await choose(detailTile, option.value);
      expect(SettingsState.init().musicCollectionDetailSongTapQueueScope,
          option.key);
    }

    await choose(detailTile, 'Queue the collection');
    final overridden = SettingsState.init();
    expect(overridden.musicCollectionDetailSongTapQueueScope,
        MusicSongTapQueueScope.collection);
    expect(overridden.resolveMusicSongTapQueueScope(collectionDetail: false),
        MusicSongTapQueueScope.songOnly);
    expect(overridden.resolveMusicSongTapQueueScope(collectionDetail: true),
        MusicSongTapQueueScope.collection);

    await choose(detailTile, 'Use the default');
    final restored = SettingsState.init();
    expect(restored.musicCollectionDetailSongTapQueueScope, isNull);
    expect(restored.resolveMusicSongTapQueueScope(collectionDetail: true),
        MusicSongTapQueueScope.songOnly);
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

  testWidgets('Android wired headset autoplay is opt-in', (tester) async {
    await showSettings(tester);
    final tile =
        find.byKey(const ValueKey('music-wired-headset-autoplay-setting'));
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    expect(settings.state.musicWiredHeadsetAutoplay, isTrue);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('TV omits touch gestures and mini-player choices',
      (tester) async {
    app.isTv = true;
    await showSettings(tester);
    expect(find.text('Streaming audio quality'), findsOneWidget);
    expect(find.text('Default song taps (including Search)'), findsOneWidget);
    expect(find.text('Song taps in albums and playlists'), findsOneWidget);
    expect(find.text('Keep shuffle when playing a song'), findsOneWidget);
    expect(find.text('Mini-player layout'), findsNothing);
    expect(find.text('Mini-player shortcut'), findsNothing);
    expect(find.byKey(const ValueKey('music-mini-player-lyrics-setting')),
        findsNothing);
    expect(find.text('Swipe artwork to change songs'), findsNothing);
    expect(find.text('Double-tap artwork to seek'), findsNothing);
    expect(find.text('Swipe right on song rows'), findsNothing);
    expect(find.text('Swipe left on song rows'), findsNothing);
    expect(find.text('Now Playing style'), findsOneWidget);
    expect(find.text('Now Playing background'), findsOneWidget);
    expect(find.text('Scrubber style'), findsOneWidget);
    expect(find.text('Autoplay on wired headset connection'), findsNothing);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

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

  testWidgets('Android shows the opt-in resume choice with pause at zero',
      (tester) async {
    await showSettings(tester);
    final rise = find.byKey(const ValueKey('music-volume-rise-setting'));
    expect(rise, findsNothing);

    final zero = find.byKey(const ValueKey('music-volume-zero-setting'));
    await tester.ensureVisible(zero);
    await tester.tap(zero);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-volume-zero-true')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: rise, matching: find.text('Stay paused')),
        findsOneWidget);

    await tester.ensureVisible(rise);
    await tester.tap(rise);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-volume-rise-true')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: rise, matching: find.text('Resume playback')),
        findsOneWidget);
    expect(settings.state.musicResumeOnVolumeRise, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Android TV can opt in to Bluetooth reconnect resume',
      (tester) async {
    app.isTv = true;
    await showSettings(tester);
    final tile =
        find.byKey(const ValueKey('music-bluetooth-reconnect-setting'));
    expect(find.descendant(of: tile, matching: find.text('Stay paused')),
        findsOneWidget);

    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    final optIn = find.byKey(const ValueKey('music-bluetooth-reconnect-true'));
    expect(
      find.descendant(
        of: optIn,
        matching: find
            .text('On Android 13 and later, resume Music if playback paused '
                'when this Bluetooth audio device disconnected.'),
      ),
      findsOneWidget,
    );
    await tester.tap(optIn);
    await tester.pumpAndSettle();

    expect(find.descendant(of: tile, matching: find.text('Resume playback')),
        findsOneWidget);
    expect(settings.state.musicResumeOnBluetoothReconnect, isTrue);
    expect(settings.state.musicAutoReconnect, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('non-Android settings omit Bluetooth reconnect resume',
      (tester) async {
    await showSettings(tester);
    expect(find.byKey(const ValueKey('music-bluetooth-reconnect-setting')),
        findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('Android TV offers focus, volume and stream recovery choices',
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
          find.text('Playback pauses when you lower the media volume to zero.'),
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
    await choose('player-background', 'Artwork', 'Artwork gradient');
    expect(
        MusicPlayerBackground.forDatabase(db), MusicPlayerBackground.gradient);
    await choose('player-background', 'Artwork gradient', 'Moving artwork');
    expect(MusicPlayerBackground.forDatabase(db),
        MusicPlayerBackground.movingArtwork);
    await choose('player-background', 'Moving artwork', 'Solid');
    await choose('scrubber-style', 'Gapped', 'Wave');
    expect(
      MusicNowPlayingStyle.forDatabase(db),
      MusicNowPlayingStyle.largeArtwork,
    );
    expect(MusicPlayerBackground.forDatabase(db), MusicPlayerBackground.solid);
    expect(MusicScrubberStyle.forDatabase(db), MusicScrubberStyle.wave);
    expect(MusicPlayerAppearance.revision.value, revision + 5);
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

      var otherBackground = MusicPlayerBackground.solid;
      for (final background in [
        MusicPlayerBackground.gradient,
        MusicPlayerBackground.movingArtwork,
      ]) {
        await background.save(original);
        expect(MusicPlayerBackground.forDatabase(db), otherBackground);
        final artworkBackup =
            UserBackup.parse((await original.exportBackup()).encode());
        await db.restoreBackup(artworkBackup, replace: true);
        expect(MusicPlayerBackground.forDatabase(db), background);
        otherBackground = background;
      }

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
