import 'dart:async';
import 'dart:collection';

import 'package:back_button_interceptor/back_button_interceptor.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_artist_identity.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/models/music_mini_player_preferences.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/views/components/music_mini_player.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/backend_recovery.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _App extends TestAppCubit {
  _App(super.initialState);

  void changeSession() =>
      emit(state.copyWith(sessionRevision: state.sessionRevision + 1));
}

class _Player extends TestPlayerCubit {
  _Player(super.initialState, super.settings);

  int nextCalls = 0;
  int previousCalls = 0;
  int expandCalls = 0;
  int closeCalls = 0;
  Duration? sought;
  bool loadingMoreSongs = false;

  @override
  bool get playlistComplete => !loadingMoreSongs && super.playlistComplete;

  Future<void> seed(PlayerState next) async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async => emit(next));
  }

  @override
  void playNext({bool userInitiated = true}) => nextCalls++;

  @override
  void playPrevious() => previousCalls++;

  @override
  void showBigPlayer() => expandCalls++;

  @override
  void hide() => closeCalls++;

  @override
  void seek(Duration position) {
    sought = position;
    super.seek(position);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _App app;
  late TestSettingsCubit settings;
  late _Player player;
  const song = Video(
      videoId: 'song0000001',
      title: 'Video title',
      lengthSeconds: 180,
      musicMetadata: MusicMetadata(title: 'Song', artist: 'Singer'));
  const next = Video(
      videoId: 'next0000001',
      title: 'Next',
      lengthSeconds: 180,
      musicMetadata: MusicMetadata(title: 'Next', artist: 'Singer'));

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = _App(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = _Player(
        PlayerState.init([song, next]).copyWith(
            currentlyPlaying: song,
            playQueue: ListQueue.of([next.videoId]),
            isAudio: true,
            isMini: true,
            isHidden: false,
            position: const Duration(seconds: 30),
            mediaEvent: const MediaEvent(state: MediaState.ready)),
        settings);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> pump(WidgetTester tester,
      {double width = 390,
      double scale = 1,
      MotionPreference motion = MotionPreference.system}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
        BlocProvider<PlayerCubit>.value(value: player),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: MotionScope(preference: motion, child: child!)),
        home: const Scaffold(
            body: Align(
                alignment: Alignment.bottomCenter, child: MusicMiniPlayer())),
      ),
    ));
    await tester.pump();
  }

  Finder key(String value) => find.byKey(ValueKey(value));

  Future<void> tapBookmark(WidgetTester tester, Finder control, String id,
      {required bool saved}) async {
    final library = MusicLibraryService.forProfile(db, db.profileId);
    await tester.runAsync(() async {
      await tester.tap(control);
      await Future.doWhile(() async {
        await tester.pump();
        if (library.contains(MusicLibraryKind.song, id) == saved) return false;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return true;
      }).timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
  }

  Future<void> miniPreferences(WidgetTester tester,
      MusicMiniPlayerLayout layout, MusicMiniPlayerShortcut shortcut) async {
    await tester.runAsync(() async {
      await settings.setMusicMiniPlayerLayout(layout);
      await settings.setMusicMiniPlayerShortcut(shortcut);
    });
  }

  testWidgets('Mini player refreshes the artist alias for the current song',
      (tester) async {
    const channelId = 'UCabcdefghijklmnopqrstuv';
    const identity = MusicArtistIdentity.catalog(channelId);
    const credit = MusicArtistCredit(name: 'Singer', id: channelId);
    final linked = song.copyWith(
        musicMetadata: const MusicMetadata(
            title: 'Song', artist: 'Singer', artistCredits: [credit]));
    await player.seed(player.state.copyWith(currentlyPlaying: linked));
    await pump(tester);
    expect(find.text('Singer'), findsOneWidget);

    final library = MusicLibraryService.forProfile(db, db.profileId);
    await tester.runAsync(
        () => library.setArtistAlias(identity, 'Alias', isCurrent: () => true));
    await tester.pump();
    expect(find.text('Alias'), findsOneWidget);
    expect(find.text('Singer'), findsNothing);

    await tester.runAsync(
        () => library.setArtistAlias(identity, null, isCurrent: () => true));
    await tester.pump();
    expect(find.text('Alias'), findsNothing);
    expect(find.text('Singer'), findsOneWidget);
    expect(player.state.currentlyPlaying?.musicMetadata?.artistCredits.single,
        same(credit));
  });

  testWidgets(
      'Transport mini layout offers direct Previous and paged Next with Save in More',
      (tester) async {
    await miniPreferences(tester, MusicMiniPlayerLayout.transport,
        MusicMiniPlayerShortcut.automatic);
    await player.seed(player.state.copyWith(
        currentlyPlaying: next,
        playedVideos: [song.videoId],
        playQueue: ListQueue<String>()));
    player.loadingMoreSongs = true;
    await pump(tester);
    expect(key('music-mini-previous').hitTestable(), findsOneWidget);
    final advance = key('music-mini-next');
    expect(advance.hitTestable(), findsOneWidget);
    await tester.tap(advance);
    await tester.pump();
    expect(player.nextCalls, 1);
    expect(find.byTooltip('Save song'), findsNothing);
    await tester.tap(key('music-mini-more'));
    await tester.pumpAndSettle();
    final bookmark = key('music-mini-bookmark-menu');
    expect(bookmark.hitTestable(), findsOneWidget);
    expect(key('music-mini-close').hitTestable(), findsOneWidget);
    await tapBookmark(tester, bookmark, next.videoId, saved: true);
    await tester.tap(key('music-mini-more'));
    await tester.pumpAndSettle();
    expect(find.text('Remove saved song'), findsOneWidget);
    expect(player.expandCalls, 0);
  });

  testWidgets(
      'Compact mini Repeat remains available for one song as Save moves into More',
      (tester) async {
    await miniPreferences(
        tester, MusicMiniPlayerLayout.compact, MusicMiniPlayerShortcut.repeat);
    await player.seed(
        player.state.copyWith(videos: [song], playQueue: ListQueue<String>()));
    await pump(tester, width: 360, scale: 2.5);
    expect(find.byTooltip('Save song').hitTestable(), findsOneWidget);
    final repeat = key('music-mini-repeat');
    expect(repeat.hitTestable(), findsOneWidget);
    expect(find.byTooltip('Repeat off'), findsOneWidget);
    for (final (mode, label) in [
      (PlayerRepeat.repeatAll, 'Repeat all'),
      (PlayerRepeat.repeatOne, 'Repeat song'),
      (PlayerRepeat.noRepeat, 'Repeat off'),
    ]) {
      await tester.runAsync(() async {
        final changed = settings.stream
            .firstWhere((state) => state.playerRepeatMode == mode);
        await tester.tap(repeat);
        await changed.timeout(const Duration(seconds: 5));
      });
      await tester.pumpAndSettle();
      expect(find.byTooltip(label), findsOneWidget);
    }

    tester.view.physicalSize = const Size(240, 844);
    await tester.pumpAndSettle();
    expect(repeat.hitTestable(), findsOneWidget);
    expect(key('music-mini-play').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Save song'), findsNothing);
    await tester.tap(key('music-mini-more'));
    await tester.pumpAndSettle();
    final savedAction = key('music-mini-bookmark-menu');
    expect(savedAction.hitTestable(), findsOneWidget);
    await tester.tap(savedAction);
    await player
        .seed(player.state.copyWith(videos: [next], currentlyPlaying: next));
    await tester.pumpAndSettle();
    final library = MusicLibraryService.forProfile(db, db.profileId);
    expect(library.contains(MusicLibraryKind.song, song.videoId), isFalse);
    expect(library.contains(MusicLibraryKind.song, next.videoId), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'mini Shuffle preserves the playing occurrence, position, and transport command',
      (tester) async {
    await miniPreferences(tester, MusicMiniPlayerLayout.transport,
        MusicMiniPlayerShortcut.shuffle);
    await pump(tester, width: 320, scale: 2.5);
    final shuffle = key('music-mini-shuffle');
    expect(shuffle.hitTestable(), findsOneWidget);
    await tester.tap(key('music-mini-play'));
    await tester.pump();
    final before = player.state;
    expect(before.mediaCommand?.type, MediaCommandType.play);
    await tester.runAsync(() async {
      final changed =
          settings.stream.firstWhere((state) => state.playerShuffleMode);
      await tester.tap(shuffle);
      await changed.timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
    expect(player.state.currentQueueId, before.currentQueueId);
    expect(player.state.position, before.position);
    expect(player.state.mediaCommand, same(before.mediaCommand));
    expect(player.nextCalls, 0);
    expect(player.sought, isNull);
    expect(tester.takeException(), isNull);
  });

  for (final (width, scale) in [
    (240.0, 2.5),
    (320.0, 1.0),
    (320.0, 2.5),
    (320.0, 3.0),
    (1024.0, 2.0)
  ]) {
    testWidgets('compact Music fits width $width and text scale $scale',
        (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await pump(tester, width: width, scale: scale);
        expect(tester.getSize(key('music-mini-player')),
            Size(width, targetHeight));
        if (width >= 320) {
          expect(tester.getSize(key('music-mini-artwork')), const Size(48, 48));
        }
        expect(find.text('Song'), findsOneWidget);
        expect(
            find.bySemanticsLabel('Now playing, Song, Singer'), findsOneWidget);
        if (width >= 600) {
          expect(find.byTooltip('Close'), findsOneWidget);
          expect(key('music-mini-next'), findsOneWidget);
          expect(find.byTooltip('Save song'), findsNothing);
        } else {
          expect(key('music-mini-more'), findsOneWidget);
          expect(find.byTooltip('Save song'), findsOneWidget);
        }
        expect(tester.getRect(key('music-mini-expand')).right,
            lessThanOrEqualTo(tester.getRect(key('music-mini-play')).left));
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets('compact controls use the shared player without expanding',
      (tester) async {
    await pump(tester);
    expect(find.text('Singer'), findsOneWidget);
    await tester.tap(key('music-mini-play'));
    await tester.pump();
    expect(player.state.mediaCommand!.type, MediaCommandType.play);
    await player.seed(player.state.copyWith(isPlaying: true));
    await tester.pump();
    expect(find.byTooltip('Pause'), findsOneWidget);
    await tester.tap(key('music-mini-play'));
    await tester.pump();
    expect(player.state.mediaCommand!.type, MediaCommandType.pause);
    await tester.tap(key('music-mini-more'));
    await tester.pumpAndSettle();
    // The shared Previous command restarts the first song.
    expect(tester.widget<MenuItemButton>(key('music-mini-previous')).onPressed,
        isNotNull);
    await tester.tap(key('music-mini-next'));
    await tester.pumpAndSettle();
    expect(player.nextCalls, 1);
    await tester.tap(key('music-mini-more'));
    await tester.pumpAndSettle();
    await tester.tap(key('music-mini-close'));
    await tester.pumpAndSettle();
    expect(player.closeCalls, 1);
    expect(player.expandCalls, 0);
    await tester.tap(key('music-mini-expand'));
    expect(player.expandCalls, 1);
  });

  testWidgets('Song details distinguish recordings with matching prefixes',
      (tester) async {
    await pump(tester);
    final reveal = key('music-mini-song-details');
    expect(reveal, findsNothing);
    const titlePrefix = 'Somewhere far beyond the edge of this town';
    const artistPrefix = 'The Somewhere Far Beyond This Town Orchestra';
    final dialog = find.byType(AlertDialog);
    for (final (video, suffix) in [(song, 'studio'), (next, 'live')]) {
      final title = '$titlePrefix ($suffix recording)';
      final artist = '$artistPrefix ($suffix lineup)';
      await player.seed(player.state.copyWith(
        currentlyPlaying: video.copyWith(
            musicMetadata: MusicMetadata(title: title, artist: artist)),
      ));
      await tester.pump();
      expect(
          tester
              .renderObject<RenderParagraph>(find.text(title))
              .didExceedMaxLines,
          isTrue);
      expect(
          tester
              .renderObject<RenderParagraph>(find.text(artist))
              .didExceedMaxLines,
          isTrue);
      expect(find.bySemanticsLabel('Now playing, $title, $artist'),
          findsOneWidget);
      expect(reveal.hitTestable(), findsOneWidget);
      tester.semantics.tap(find.semantics.byPredicate((node) =>
          node.label == 'Song details' ||
          node.getSemanticsData().tooltip == 'Song details'));
      await tester.pumpAndSettle();
      expect(find.descendant(of: dialog, matching: find.text(title)),
          findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.text(artist)),
          findsOneWidget);
      final closeLabel =
          MaterialLocalizations.of(tester.element(dialog)).closeButtonLabel;
      await tester.tap(find.widgetWithText(TextButton, closeLabel));
      await tester.pumpAndSettle();
    }
    expect(player.expandCalls, 0);
    await tester.tap(key('music-mini-expand'));
    expect(player.expandCalls, 1);
  });

  testWidgets('large text reveals an overflowing artist with reduced motion',
      (tester) async {
    const artist = 'The Artist With a Long Name and a Distinct Ending';
    await player.seed(player.state.copyWith(
      currentlyPlaying: song.copyWith(
        musicMetadata: const MusicMetadata(title: 'A', artist: artist),
      ),
    ));
    await pump(tester,
        width: 320, scale: 2.5, motion: MotionPreference.reduced);
    expect(find.text(artist), findsNothing);
    expect(
        tester.renderObject<RenderParagraph>(find.text('A')).didExceedMaxLines,
        isFalse);
    await tester.tap(key('music-mini-song-details'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(tester.widget<AlertDialog>(dialog).scrollable, isTrue);
    expect(ModalRoute.of(tester.element(dialog))!.transitionDuration,
        const Duration(milliseconds: 100));
    final fullArtist = find.descendant(of: dialog, matching: find.text(artist));
    expect(tester.renderObject<RenderParagraph>(fullArtist).didExceedMaxLines,
        isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow transport preserves expand and details during a failure',
      (tester) async {
    await miniPreferences(tester, MusicMiniPlayerLayout.transport,
        MusicMiniPlayerShortcut.shuffle);
    const title = 'A very long title for the recording that failed';
    await player.seed(player.state.copyWith(
      currentlyPlaying: song.copyWith(
        musicMetadata: const MusicMetadata(title: title, artist: 'Singer'),
      ),
    ));
    player.setEvent(const MediaEvent(state: MediaState.error));
    await pump(tester, width: 240, motion: MotionPreference.off);

    for (final control in [
      'music-mini-expand',
      'music-mini-song-details',
      'music-mini-shuffle',
      'music-mini-play',
      'music-mini-more',
    ]) {
      expect(key(control).hitTestable(), findsOneWidget);
    }
    expect(key('music-mini-error'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(key('music-mini-expand'));
    await tester.pump();
    expect(player.expandCalls, 1);
    await tester.tap(key('music-mini-song-details'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(ModalRoute.of(tester.element(dialog))!.transitionDuration,
        Duration.zero);
    expect(find.descendant(of: dialog, matching: find.text(title)),
        findsOneWidget);
    expect(player.expandCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an overflowing lyric keeps its place without Song details',
      (tester) async {
    const lyric = 'This lyric is longer than the space in the compact subtitle';
    await tester.runAsync(() => settings.setMusicMiniPlayerLyrics(true));
    player.publishResolvedMusicLyrics(
      const MusicLyrics.synced([(start: Duration(seconds: 1), text: lyric)]),
      Duration.zero,
      mayRead: () => true,
      sourceChanges: Listenable.merge(const []),
    );
    await pump(tester);
    expect(
        tester
            .renderObject<RenderParagraph>(find.text(lyric))
            .didExceedMaxLines,
        isTrue);
    expect(find.text('Singer'), findsNothing);
    expect(key('music-mini-song-details'), findsNothing);
  });

  testWidgets('compact music can save and unsave the current online song',
      (tester) async {
    await pump(tester);
    await tapBookmark(tester, find.byTooltip('Save song'), song.videoId,
        saved: true);
    expect(find.byTooltip('Remove saved song'), findsOneWidget);
    await tapBookmark(tester, find.byTooltip('Remove saved song'), song.videoId,
        saved: false);
    expect(find.byTooltip('Save song'), findsOneWidget);
    expect(player.expandCalls, 0);
    expect(player.nextCalls, 0);
  });

  testWidgets('last song menu still returns to the previous track',
      (tester) async {
    await player.seed(player.state.copyWith(
        currentlyPlaying: next,
        playedVideos: [song.videoId],
        playQueue: ListQueue<String>()));
    await pump(tester);
    await tester.tap(key('music-mini-more'));
    await tester.pumpAndSettle();
    expect(tester.widget<MenuItemButton>(key('music-mini-next')).onPressed,
        isNull);
    await tester.tap(key('music-mini-previous'));
    await tester.pumpAndSettle();
    expect(player.previousCalls, 1);
    expect(player.nextCalls, 0);
  });

  testWidgets('Android Back closes the compact overflow before the page',
      (tester) async {
    await pump(tester);
    var pageBacks = 0;
    bool pageBack(bool stopped, RouteInfo info) {
      pageBacks++;
      return true;
    }

    BackButtonInterceptor.add(pageBack, zIndex: 1, ifNotYetIntercepted: true);
    addTearDown(() => BackButtonInterceptor.remove(pageBack));
    Future<void> back() async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.navigation.name,
        SystemChannels.navigation.codec
            .encodeMethodCall(const MethodCall('popRoute')),
        null,
      );
      await tester.pumpAndSettle();
    }

    await tester.tap(key('music-mini-more'));
    await tester.pumpAndSettle();
    expect(key('music-mini-next'), findsOneWidget);
    await back();
    expect(key('music-mini-next'), findsNothing);
    expect(pageBacks, 0);
    expect(
        tester.widget<IconButton>(key('music-mini-more')).focusNode!.hasFocus,
        isTrue);
    await back();
    expect(pageBacks, 1);
    expect(player.closeCalls, 0);
  });

  testWidgets('dismissing the compact overflow cannot toggle playback',
      (tester) async {
    await pump(tester);
    final command = player.state.mediaCommand;
    await tester.tap(key('music-mini-more'));
    await tester.pumpAndSettle();
    await tester.tap(key('music-mini-play'));
    await tester.pumpAndSettle();
    expect(key('music-mini-next'), findsNothing);
    expect(player.state.mediaCommand, command);
  });

  for (final replaceSession in [false, true]) {
    testWidgets(
        'deferred compact action preserves replacement '
        '${replaceSession ? 'session' : 'song'}', (tester) async {
      await pump(tester);
      await tester.tap(key('music-mini-more'));
      await tester.pumpAndSettle();
      await tester.tap(key('music-mini-close'));
      if (replaceSession) {
        app.changeSession();
      } else {
        await player.seed(player.state.copyWith(currentlyPlaying: next));
      }
      await tester.pumpAndSettle();
      expect(player.closeCalls, 0);
    });
  }

  testWidgets('deferred Next does not skip after the queue changes',
      (tester) async {
    await pump(tester);
    await tester.tap(key('music-mini-more'));
    await tester.pumpAndSettle();
    await tester.tap(key('music-mini-next'));
    await player.seed(player.state.copyWith(playQueue: ListQueue<String>()));
    await tester.pumpAndSettle();
    expect(player.nextCalls, 0);
  });

  testWidgets('Next stays available at the end of a partially loaded playlist',
      (tester) async {
    player.loadingMoreSongs = true;
    await player.seed(
        player.state.copyWith(videos: [song], playQueue: ListQueue<String>()));
    await pump(tester);
    await tester.tap(key('music-mini-more'));
    await tester.pumpAndSettle();
    await tester.tap(key('music-mini-next'));
    await tester.pumpAndSettle();
    expect(player.nextCalls, 1);
    player.loadingMoreSongs = false;
    player.playlistLoadingRevision.value++;
    await tester.pumpAndSettle();
    expect(key('music-mini-more'), findsNothing);
    expect(key('music-mini-close'), findsOneWidget);
  });

  testWidgets('mini player swipes change tracks without expanding or seeking',
      (tester) async {
    await pump(tester);
    await tester.drag(key('music-mini-expand'), const Offset(-140, 0));
    await tester.pump();
    expect(player.nextCalls, 1);
    await player.seed(player.state.copyWith(
        currentlyPlaying: next,
        playedVideos: [song.videoId],
        playQueue: ListQueue<String>()));
    await tester.pump();
    await tester.drag(key('music-mini-expand'), const Offset(140, 0));
    await tester.pump();
    expect(player.previousCalls, 1);
    expect(player.expandCalls, 0);
    expect(player.sought, isNull);
  });

  testWidgets('a mini swipe cannot carry into a replacement track',
      (tester) async {
    await pump(tester);
    final gesture =
        await tester.startGesture(tester.getCenter(key('music-mini-expand')));
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    await player.seed(player.state.copyWith(currentlyPlaying: next));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(player.nextCalls, 0);
    expect(player.previousCalls, 0);
    expect(player.expandCalls, 0);
  });

  testWidgets('single-song mini swipes do not send queue commands',
      (tester) async {
    await player.seed(player.state.copyWith(videos: [song]));
    await pump(tester);
    await tester.drag(key('music-mini-expand'), const Offset(-140, 0));
    await tester.pump();
    expect(player.nextCalls, 0);
    expect(player.previousCalls, 0);
  });

  testWidgets('finished songs forward Play to the shared decoder',
      (tester) async {
    await player.seed(player.state.copyWith(
        position: const Duration(seconds: 180),
        isPlaying: false,
        mediaEvent: const MediaEvent(state: MediaState.completed)));
    await pump(tester);
    expect(find.byIcon(Icons.replay_rounded), findsOneWidget);
    await tester.tap(key('music-mini-play'));
    await tester.pump();
    expect(player.sought, isNull);
    expect(player.state.mediaCommand!.type, MediaCommandType.play);
  });

  testWidgets('a playing final second still pauses instead of restarting',
      (tester) async {
    await player.seed(player.state
        .copyWith(position: const Duration(seconds: 180), isPlaying: true));
    await pump(tester);
    await tester.tap(key('music-mini-play'));
    await tester.pump();
    expect(player.sought, isNull);
    expect(player.state.mediaCommand!.type, MediaCommandType.pause);
  });

  testWidgets('paused near the end resumes without restarting', (tester) async {
    await player.seed(player.state
        .copyWith(position: const Duration(seconds: 179), isPlaying: false));
    await pump(tester);
    expect(find.byIcon(Icons.replay_rounded), findsNothing);
    await tester.tap(key('music-mini-play'));
    await tester.pump();
    expect(player.sought, isNull);
    expect(player.state.mediaCommand!.type, MediaCommandType.play);
  });

  for (final (length, position, expected) in [
    (null, 45, 0.0),
    (0, 45, 0.0),
    (-1, 45, 0.0),
    (180, -1, 0.0),
    (180, 90, 0.5),
    (180, 200, 1.0),
  ]) {
    testWidgets('progress is finite with length $length and position $position',
        (tester) async {
      await player.seed(player.state.copyWith(
          currentlyPlaying: song.copyWith(lengthSeconds: length),
          position: Duration(seconds: position)));
      await pump(tester);
      expect(
          tester
              .widget<LinearProgressIndicator>(key('music-mini-progress'))
              .value,
          expected);
      if (length == null || length <= 0) {
        expect(find.byIcon(Icons.replay_rounded), findsNothing);
        await tester.tap(key('music-mini-play'));
        await tester.pump();
        expect(player.sought, isNull);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('single-song playback leaves room instead of a dead next button',
      (tester) async {
    await player.seed(player.state.copyWith(videos: [song]));
    await pump(tester);
    expect(key('music-mini-next'), findsNothing);
    expect(key('music-mini-play'), findsOneWidget);
    expect(key('music-mini-close'), findsOneWidget);
  });

  testWidgets('loading survives presentation events and clears when ready',
      (tester) async {
    player.setEvent(const MediaEvent(state: MediaState.loading));
    await pump(tester);
    LinearProgressIndicator indicator() =>
        tester.widget<LinearProgressIndicator>(key('music-mini-progress'));
    expect(indicator().value, isNull);
    player.showMiniPlayer();
    await tester.pump();
    expect(indicator().value, isNull);
    player.setEvent(const MediaEvent(state: MediaState.ready));
    await tester.pump();
    expect(indicator().value, isNotNull);
  });

  testWidgets('decoder failure remains visible across minimizing and mute',
      (tester) async {
    player.setEvent(const MediaEvent(state: MediaState.error));
    player.showMiniPlayer();
    player.setEvent(const MediaEvent(
        state: MediaState.playing,
        type: MediaEventType.volumeChanged,
        value: false));
    await pump(tester, width: 240, scale: 2.5);
    expect(key('music-mini-error'), findsOneWidget);
    expect(tester.takeException(), isNull);
    player.setEvent(const MediaEvent(state: MediaState.loading));
    expect(player.playbackStatus, MediaState.loading);
    await tester.pump();
    await tester.pump();
    expect(key('music-mini-error'), findsNothing);
  });

  for (final phase in BackendRecoveryPhase.values) {
    testWidgets('compact player exposes backend recovery ${phase.name}',
        (tester) async {
      await player.seed(player.state.copyWith(
          backendRecovery: BackendRecovery(
              phase: phase,
              request: BackendPlayback(Server(
                  url: 'https://instance.example',
                  backendSelector: BackendSelector('COMPANION_ID',
                      const [BackendOption('a', 'Backend A')]))),
              videoId: song.videoId,
              manual: false)));
      await pump(tester);
      final value = tester
          .widget<LinearProgressIndicator>(key('music-mini-progress'))
          .value;
      expect(value, phase == BackendRecoveryPhase.trying ? isNull : isNotNull);
      expect(key('music-mini-error'),
          phase == BackendRecoveryPhase.failed ? findsOneWidget : findsNothing);
      expect(find.text('Singer'), findsNothing);
      expect(key('music-mini-song-details'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('live Music does not become a completed recording',
      (tester) async {
    await player.seed(player.state.copyWith(
        currentlyPlaying: song.copyWith(liveNow: true),
        position: const Duration(seconds: 200)));
    await pump(tester);
    expect(find.byIcon(Icons.replay_rounded), findsNothing);
    expect(
        tester
            .widget<LinearProgressIndicator>(key('music-mini-progress'))
            .value,
        0);
    await tester.tap(key('music-mini-play'));
    await tester.pump();
    expect(player.sought, isNull);
    expect(player.state.mediaCommand!.type, MediaCommandType.play);
  });
}
