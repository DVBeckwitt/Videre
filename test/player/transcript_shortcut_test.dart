import 'dart:async';

import 'package:back_button_interceptor/back_button_interceptor.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/media_command.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/expanded_player.dart';
import 'package:clipious/player/views/components/mini_player_controls.dart';
import 'package:clipious/player/views/tablet/expanded_player.dart';
import 'package:clipious/player/views/tablet/expanded_side_bar.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/subscription_management/view/components/subscribe_button.dart';
import 'package:clipious/videos/models/caption.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/video_transcript.dart';
import 'package:clipious/videos/views/components/flow_watch_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _TranscriptService extends Service {
  final transcriptServers = <Server?>[];
  final transcriptsByLanguage = <String, FutureOr<VideoTranscript>>{};
  Completer<VideoTranscript>? pendingTranscript;

  @override
  Future<List<Playlist>> getUserPlaylists({bool postProcessing = true}) async =>
      [];

  @override
  Future<VideoTranscript> getTranscript(String videoId, Caption caption,
      {Server? serverOverride}) async {
    transcriptServers.add(serverOverride);
    if (pendingTranscript case final pending?) return pending.future;
    if (transcriptsByLanguage[caption.label] case final transcript?) {
      return transcript;
    }
    return const VideoTranscript(label: 'English', languageCode: 'en', lines: [
      VideoTranscriptLine(
        type: VideoTranscriptLineType.regular,
        startMs: 0,
        endMs: 1000,
        text: 'Test transcript',
      ),
    ]);
  }
}

class _TranscriptPlayer extends TestPlayerCubit {
  _TranscriptPlayer(super.initialState, super.settings);

  void replaceVideo(Video video, Duration position) {
    emit(state.copyWith(currentlyPlaying: video, position: position));
  }
}

VideoTranscript _timedTranscript(String language) => VideoTranscript(
      label: language,
      languageCode: null,
      lines: [
        for (var index = 0; index < 120; index++)
          VideoTranscriptLine(
            type: VideoTranscriptLineType.regular,
            startMs: index * 1000,
            endMs: index * 1000 + 600,
            text: '$language cue $index'
                '${index.isEven ? '\nSecond caption line.\nThird line.' : ''}',
          ),
      ],
    );

void main() {
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late _TranscriptPlayer player;
  late Service originalService;
  final shortcut = find.byKey(const ValueKey('video-transcript-open'));
  final transcript = find.byKey(const ValueKey('video-transcript-list'));
  final activeLine = find.descendant(
    of: transcript,
    matching: find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.selected == true,
    ),
  );
  final returnToCurrent = find.text('Return to current');
  final search = find.byKey(const ValueKey('video-transcript-search'));
  final languageMenu = find.byKey(const ValueKey('video-transcript-language'));

  Finder timestamp(int seconds) =>
      find.byKey(ValueKey('video-transcript-seek-${seconds * 1000}'));

  void expectActiveCue(String language, int seconds) {
    expect(
      find.descendant(
        of: activeLine,
        matching: find.textContaining('$language cue $seconds'),
      ),
      findsOneWidget,
    );
    expect(timestamp(seconds).hitTestable(), findsOneWidget);
  }

  Future<void> reportProgress(WidgetTester tester, int milliseconds) async {
    await tester.runAsync(
        () => player.onProgress(Duration(milliseconds: milliseconds)));
  }

  Future<void> chooseLanguage(WidgetTester tester, String language) async {
    await tester.tap(languageMenu);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text(language).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  final export = find.byKey(const ValueKey('video-transcript-export'));
  final timedCopy = find.byKey(const ValueKey('video-transcript-copy-timed'));
  final save = find.byKey(const ValueKey('video-transcript-save'));
  const files = MethodChannel('videre/files');

  Future<void> exportWith(WidgetTester tester, Finder action) async {
    await tester.tap(export);
    await tester.pumpAndSettle();
    await tester.tap(action);
    await tester.pumpAndSettle();
  }

  setUp(() async {
    db = await createPlayerTestDatabase();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    await settings.setDistractionFreeMode(true);
    await settings.setUseReturnYoutubeDislike(false);
    originalService = service;
    service = _TranscriptService();
  });

  tearDown(() async {
    service = originalService;
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> pumpPlayer(WidgetTester tester,
      {bool isAudio = false, bool withQueueAndBackend = false}) async {
    final video = Video(
      videoId: 'test-video',
      captions: [Caption('English', 'en', '/api/v1/captions/test-video')],
      backendPlayback: withQueueAndBackend
          ? BackendPlayback(Server(
              url: 'https://example.test',
              backendSelector: BackendSelector('COMPANION_ID',
                  const [BackendOption('1', 'One'), BackendOption('2', 'Two')]),
            ))
          : null,
    );
    player = _TranscriptPlayer(
        PlayerState.init(null).copyWith(
          isMini: false,
          isAudio: isAudio,
          currentlyPlaying: video,
          videos: withQueueAndBackend
              ? [video, const Video(videoId: 'second-video')]
              : [],
        ),
        settings);
    BackButtonInterceptor.add(player.handleBackButton,
        name: 'miniPlayer', zIndex: 2, ifNotYetIntercepted: true);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<PlayerCubit>.value(value: player),
        BlocProvider<SettingsCubit>.value(value: settings),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: Column(children: [
            Text('Player screen'),
            MiniPlayerControls(),
          ]),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> pressAndroidBack(WidgetTester tester) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      SystemChannels.navigation.codec
          .encodeMethodCall(const MethodCall('popRoute')),
      null,
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpWatch(WidgetTester tester,
      {double width = 390,
      double height = 900,
      double textScale = 1,
      bool inPlayer = true,
      bool captions = true,
      bool live = false,
      bool closing = false,
      bool matchingVideo = true,
      bool withQueueAndBackend = false,
      bool expandedAudio = false,
      bool tablet = false,
      List<Caption> additionalCaptions = const [],
      Duration position = const Duration(seconds: 42),
      String? authorId,
      Server? playbackServer,
      Server? backendServer}) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final video = Video(
      videoId: 'watch-video',
      title: 'A video with direct playback actions',
      author: 'Test creator',
      authorId: authorId,
      lengthSeconds: 180,
      liveNow: live,
      playbackConnection:
          playbackServer == null ? null : BackendPlayback(playbackServer),
      backendPlayback: backendServer != null
          ? BackendPlayback(backendServer)
          : withQueueAndBackend
              ? BackendPlayback(Server(
                  url: 'https://example.test',
                  backendSelector: BackendSelector('COMPANION_ID', const [
                    BackendOption('1', 'One'),
                    BackendOption('2', 'Two')
                  ]),
                ))
              : null,
      captions: captions
          ? [
              Caption('English', 'en', '/api/v1/captions/watch-video'),
              ...additionalCaptions,
            ]
          : [],
    );
    player = _TranscriptPlayer(
        PlayerState.init([
          video,
          if (withQueueAndBackend) const Video(videoId: 'second-video')
        ]).copyWith(
          isHidden: false,
          isMini: false,
          isAudio: expandedAudio,
          isClosing: closing,
          position: position,
          currentlyPlaying:
              matchingVideo ? video : const Video(videoId: 'another-video'),
        ),
        settings);
    BackButtonInterceptor.add(player.handleBackButton,
        name: 'miniPlayer', zIndex: 2, ifNotYetIntercepted: true);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<PlayerCubit>.value(value: player),
        BlocProvider<SettingsCubit>.value(value: settings),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: expandedAudio
              ? BlocBuilder<PlayerCubit, PlayerState>(
                  builder: (context, state) => tablet
                      ? const TabletExpandedPlayer()
                      : const ExpandedPlayer())
              : SingleChildScrollView(
                  child: FlowWatchBody(
                      video: video, inPlayer: inPlayer, showRelated: false),
                ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Finder watchAction(String name) => find.byKey(ValueKey('watch-$name'));

  Future<void> pumpLegacyNavigation(WidgetTester tester,
      {required bool tablet, bool offline = false}) async {
    const video = Video(videoId: 'watch-video', title: 'Playing video');
    const saved = DownloadedVideo(
        videoId: 'saved-video',
        title: 'Saved video',
        lengthSeconds: 120,
        quality: '720p');
    player = _TranscriptPlayer(
        PlayerState.init(null).copyWith(
            currentlyPlaying: offline ? null : video,
            offlineCurrentlyPlaying: offline ? saved : null,
            isAudio: !offline,
            isHidden: false,
            isMini: false,
            selectedFullScreenIndex: 3),
        settings);
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
          body: BlocBuilder<PlayerCubit, PlayerState>(
              builder: (context, state) =>
                  tablet ? const ExpandedSideBar() : const ExpandedPlayer()),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('offline queue keeps logical selection across filtered tabs',
      (tester) async {
    await pumpLegacyNavigation(tester, tablet: false, offline: true);
    expect(tester.takeException(), isNull);
    final navigation = find.byType(NavigationBar);
    expect(tester.widget<NavigationBar>(navigation).selectedIndex, 1);

    await tester.tap(
        find.descendant(of: navigation, matching: find.byIcon(Icons.info)));
    await tester.pumpAndSettle();
    expect(player.state.selectedFullScreenIndex, 0);
    await tester.tap(find.descendant(
        of: navigation, matching: find.byIcon(Icons.playlist_play)));
    await tester.pumpAndSettle();
    expect(player.state.selectedFullScreenIndex, 3);

    await tester.runAsync(() => settings.setDistractionFreeMode(false));
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationBar>(navigation).selectedIndex, 3);
    await tester.runAsync(() => settings.setDistractionFreeMode(true));
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationBar>(navigation).selectedIndex, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'tablet audio queue maps tabs and retains tap and swipe selection',
      (tester) async {
    await pumpLegacyNavigation(tester, tablet: true);
    expect(tester.takeException(), isNull);
    final tabBar = find.byType(TabBar);
    TabController tabs() =>
        tester.widget<TabBar>(tabBar).controller ??
        DefaultTabController.of(tester.element(tabBar));
    expect(tabs().index, 1);

    await tester
        .tap(find.descendant(of: tabBar, matching: find.byIcon(Icons.info)));
    await tester.pumpAndSettle();
    expect(player.state.selectedFullScreenIndex, 0);
    await tester.drag(find.byType(TabBarView), const Offset(-700, 0));
    await tester.pumpAndSettle();
    expect(player.state.selectedFullScreenIndex, 3);
    expect(tabs().index, 1);

    await tester.runAsync(() => settings.setDistractionFreeMode(false));
    await tester.pumpAndSettle();
    expect(tabs().index, 3);
    await tester.runAsync(() => settings.setDistractionFreeMode(true));
    await tester.pumpAndSettle();
    expect(tabs().index, 1);
    expect(player.state.selectedFullScreenIndex, 3);

    // A removed Comments tab falls back to Info. Explicitly selecting that
    // fallback must remain Info when the full tab set becomes available.
    player.selectTab(1);
    await tester.pumpAndSettle();
    expect(tabs().index, 0);
    await tester
        .tap(find.descendant(of: tabBar, matching: find.byIcon(Icons.info)));
    await tester.pumpAndSettle();
    expect(player.state.selectedFullScreenIndex, 0);
    await tester.runAsync(() => settings.setDistractionFreeMode(false));
    await tester.pumpAndSettle();
    expect(tabs().index, 0);
    expect(tester.takeException(), isNull);
  });

  for (final layout in [(320.0, 1.0), (320.0, 2.0), (1024.0, 1.5)]) {
    testWidgets('watch toolbar stays in one accessible row at $layout',
        (tester) async {
      await pumpWatch(tester, width: layout.$1, textScale: layout.$2);
      expect(find.byType(FlowWatchBody), findsOneWidget);
      expect(watchAction('pitch-open'), findsNothing);
      expect(watchAction('more-open'), findsNothing);
      final bar = tester.getRect(watchAction('playback-actions'));
      expect(bar.height, closeTo(48, 0.01));
      for (final action in [
        shortcut,
        watchAction('mode-toggle'),
        watchAction('speed-open'),
        watchAction('repeat')
      ]) {
        expect(action.hitTestable(), findsOneWidget);
        final rect = tester.getRect(action);
        expect(rect.left, greaterThanOrEqualTo(bar.left));
        expect(rect.right, lessThanOrEqualTo(bar.right));
        expect(rect.center.dy, closeTo(bar.center.dy, 0.01));
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a stale Watch repeat button cannot change the new playback mode',
      (tester) async {
    await pumpWatch(tester);
    final oldButton = tester.widget<IconButton>(watchAction('repeat'));
    player.switchAudio(true);
    await tester.pumpAndSettle();
    oldButton.onPressed!();
    await tester.pumpAndSettle();
    expect(settings.state.playerRepeatMode, PlayerRepeat.noRepeat);
    expect(player.state.isAudio, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('watch transcript opens in one tap and preserves playback',
      (tester) async {
    await pumpWatch(tester);
    final current = player.state.currentlyPlaying;
    final interceptorsBefore = BackButtonInterceptor.describe();
    await tester.tap(shortcut);
    await tester.pumpAndSettle();
    expect(transcript, findsOneWidget);
    expect(find.text('Test transcript'), findsOneWidget);
    await pressAndroidBack(tester);
    expect(transcript, findsNothing);
    expect(player.state.currentlyPlaying, same(current));
    expect(player.state.position, const Duration(seconds: 42));
    expect(player.state.isMini, isFalse);
    expect(BackButtonInterceptor.describe(), interceptorsBefore);
    expect(tester.takeException(), isNull);
  });

  testWidgets('watch follows the player and yields to reading and search',
      (tester) async {
    await pumpWatch(tester, position: const Duration(seconds: 1));
    final transcripts = (service as _TranscriptService).transcriptsByLanguage;
    transcripts['English'] = _timedTranscript('English');
    await tester.tap(shortcut);
    await tester.pumpAndSettle();
    expectActiveCue('English', 1);

    for (final seconds in [2, 3]) {
      await reportProgress(tester, seconds * 1000 + 800);
      await tester.pumpAndSettle();
      expectActiveCue('English', seconds);
      expect(returnToCurrent, findsNothing);
    }

    expect(timestamp(60), findsNothing);
    await reportProgress(tester, 60000);
    await tester.pumpAndSettle();
    expectActiveCue('English', 60);

    final viewport = tester.getRect(transcript);
    await tester.dragFrom(
      Offset(viewport.left + 8, viewport.center.dy),
      const Offset(0, 100),
    );
    await tester.pumpAndSettle();
    expect(returnToCurrent.hitTestable(), findsOneWidget);
    final readingPosition = tester.getTopLeft(timestamp(60));
    await reportProgress(tester, 61000);
    await tester.pumpAndSettle();
    expectActiveCue('English', 61);
    expect(tester.getTopLeft(timestamp(60)), readingPosition);

    await reportProgress(tester, 110000);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(timestamp(60)), readingPosition);
    expect(timestamp(110).hitTestable(), findsNothing);
    await tester.tap(returnToCurrent);
    await tester.pumpAndSettle();
    expectActiveCue('English', 110);
    expect(returnToCurrent, findsNothing);

    await tester.enterText(search, 'English cue 80');
    await tester.pumpAndSettle();
    await reportProgress(tester, 44000);
    await tester.pumpAndSettle();
    expect(timestamp(80).hitTestable(), findsOneWidget);
    expect(activeLine, findsNothing);
    expect(timestamp(44), findsNothing);

    await tester.enterText(search, '');
    await tester.pumpAndSettle();
    expect(returnToCurrent.hitTestable(), findsOneWidget);
    await tester.enterText(search, 'English cue 80');
    await tester.pumpAndSettle();
    await tester.tap(returnToCurrent);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller!.text, isEmpty);
    expectActiveCue('English', 44);

    await reportProgress(tester, 45000);
    await tester.pumpAndSettle();
    expectActiveCue('English', 45);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late language and replaced video cannot move the transcript',
      (tester) async {
    await pumpWatch(tester, additionalCaptions: [
      Caption('Spanish', 'es', '/captions/spanish'),
      Caption('French', 'fr', '/captions/french'),
    ]);
    final spanish = Completer<VideoTranscript>();
    final transcripts = (service as _TranscriptService).transcriptsByLanguage;
    transcripts
      ..['English'] = _timedTranscript('English')
      ..['Spanish'] = spanish.future
      ..['French'] = _timedTranscript('French');
    await tester.tap(shortcut);
    await tester.pumpAndSettle();
    expectActiveCue('English', 42);

    await chooseLanguage(tester, 'Spanish');
    expect(transcript, findsNothing);
    await reportProgress(tester, 90000);
    await tester.pump();
    await chooseLanguage(tester, 'French');
    await tester.pumpAndSettle();
    expectActiveCue('French', 90);
    final frenchPosition = tester.getTopLeft(timestamp(90));

    spanish.complete(_timedTranscript('Spanish'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Spanish cue'), findsNothing);
    expectActiveCue('French', 90);
    expect(tester.getTopLeft(timestamp(90)), frenchPosition);

    final seekFromOldSheet = tester.widget<TextButton>(timestamp(90)).onPressed;
    final copy = find.byKey(const ValueKey('video-transcript-copy'));
    expect(seekFromOldSheet, isNotNull);
    expect(tester.widget<IconButton>(copy).onPressed, isNotNull);
    expect(tester.widget<IconButton>(export).onPressed, isNotNull);
    await reportProgress(tester, 15000);
    player.replaceVideo(
      const Video(videoId: 'different-video', lengthSeconds: 180),
      const Duration(seconds: 20),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(timestamp(90)), frenchPosition);
    expect(timestamp(15).hitTestable(), findsNothing);
    expect(timestamp(20).hitTestable(), findsNothing);
    expect(tester.widget<IconButton>(copy).onPressed, isNull);
    expect(tester.widget<IconButton>(export).onPressed, isNull);

    seekFromOldSheet!();
    await tester.pumpAndSettle();
    expect(player.state.position, const Duration(seconds: 20));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'watch exports the selected language and can retry a canceled save',
      (tester) async {
    final transcriptService = service as _TranscriptService;
    transcriptService.transcriptsByLanguage['Espa\u00f1ol'] =
        const VideoTranscript(
      label: 'Espa\u00f1ol',
      languageCode: 'es',
      lines: [
        VideoTranscriptLine(
          type: VideoTranscriptLineType.regular,
          startMs: 1250,
          endMs: 2000,
          text: 'Buenos d\u00edas',
        ),
        VideoTranscriptLine(
          type: VideoTranscriptLineType.regular,
          startMs: 3000,
          endMs: 4000,
          text: 'Adi\u00f3s',
        ),
      ],
    );
    final clipboardWrites = <String>[];
    final saves = <MethodCall>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardWrites.add(call.arguments['text'] as String);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(files, (call) async {
      saves.add(call);
      return saves.length == 1 ? null : true;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(files, null);
    });

    await pumpWatch(tester, additionalCaptions: [
      Caption('Espa\u00f1ol', 'es', '/api/v1/captions/watch-video?lang=es'),
    ]);
    await tester.tap(shortcut);
    await tester.pumpAndSettle();
    await tester.tap(export);
    await tester.pumpAndSettle();
    expect(timedCopy, findsOneWidget);
    await pressAndroidBack(tester);
    expect(timedCopy, findsNothing);
    expect(transcript, findsOneWidget);
    expect(player.state.isMini, isFalse);

    await exportWith(tester, timedCopy);
    expect(clipboardWrites.single, '[00:00:00.000] Test transcript');

    await tester.tap(find.byKey(const ValueKey('video-transcript-language')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Espa\u00f1ol').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('video-transcript-search')),
      'Buenos',
    );
    await tester.pumpAndSettle();
    expect(find.text('Adi\u00f3s'), findsNothing);

    const expected =
        '[00:00:01.250] Buenos d\u00edas\n[00:00:03.000] Adi\u00f3s';
    await exportWith(tester, timedCopy);
    expect(clipboardWrites.last, expected);

    await exportWith(tester, save);
    expect(saves, hasLength(1));
    expect(find.text('Transcript saved'), findsNothing);
    expect(find.text('Could not save transcript.'), findsNothing);
    expect(transcript, findsOneWidget);

    await exportWith(tester, save);
    expect(saves, hasLength(2));
    for (final call in saves) {
      expect(call.method, 'save');
      expect(call.arguments, {
        'name': 'A video with direct playback actions - Espa\u00f1ol.txt',
        'text': expected,
        'mimeType': 'text/plain',
      });
    }
    expect(find.text('Transcript saved'), findsOneWidget);
    expect(transcriptService.transcriptServers, hasLength(2));
    expect(player.state.position, const Duration(seconds: 42));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'watch saves a complete transcript that exceeds the clipboard cap',
      (tester) async {
    final transcriptService = service as _TranscriptService;
    final spokenText = '\u00e9' * 260;
    final lines = List.generate(
      1000,
      (index) => VideoTranscriptLine(
        type: VideoTranscriptLineType.regular,
        startMs: index * 1000,
        endMs: (index + 1) * 1000,
        text: '$index $spokenText',
      ),
    );
    transcriptService.transcriptsByLanguage['English'] = VideoTranscript(
      label: 'English',
      languageCode: 'en',
      lines: lines,
    );
    var clipboardWrites = 0;
    final saves = <MethodCall>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboardWrites++;
      return null;
    });
    messenger.setMockMethodCallHandler(files, (call) async {
      saves.add(call);
      return true;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(files, null);
    });

    await pumpWatch(tester);
    await tester.tap(shortcut);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('video-transcript-copy')));
    await tester.pumpAndSettle();
    expect(
        find.text(
          'This transcript is too long to copy. You can save it as a text file.',
        ),
        findsOneWidget);
    await exportWith(tester, timedCopy);
    expect(clipboardWrites, 0);

    await exportWith(tester, save);
    expect(saves.single.method, 'save');
    final output = saves.single.arguments['text'] as String;
    expect(output.length, greaterThan(250000));
    expect(output.split('\n'), hasLength(lines.length));
    expect(output, startsWith('[00:00:00.000] 0 $spokenText\n'));
    expect(output, endsWith('\n[00:16:39.000] 999 $spokenText'));
    expect(transcriptService.transcriptServers, hasLength(1));
    expect(find.text('Transcript saved'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final hasConnection in [true, false]) {
    testWidgets(
        'watch transcript keeps the playback server (connection: $hasConnection)',
        (tester) async {
      const connection = Server(url: 'https://playback.example');
      const backend = Server(url: 'https://backend.example');
      const selected = Server(url: 'https://newly-selected.example');
      await pumpWatch(tester,
          playbackServer: hasConnection ? connection : null,
          backendServer: backend);
      await tester.runAsync(() async {
        await db.upsertServer(selected);
        await db.useServer(selected);
        expect((await db.getCurrentlySelectedServer()).url, selected.url);
      });
      await tester.tap(shortcut);
      await tester.pumpAndSettle();
      final request = (service as _TranscriptService).transcriptServers.single;
      expect(request, same(hasConnection ? connection : backend));
      expect(request?.url, isNot(selected.url));
      expect(find.text('Test transcript'), findsOneWidget);
      await pressAndroidBack(tester);
      expect(player.state.position, const Duration(seconds: 42));
      expect(tester.takeException(), isNull);
    });
  }

  for (final fails in [false, true]) {
    testWidgets(
        'watch ignores a late transcript after changing mode (error: $fails)',
        (tester) async {
      await pumpWatch(tester);
      final pending = Completer<VideoTranscript>();
      final transcripts = service as _TranscriptService;
      transcripts.pendingTranscript = pending;
      await tester.tap(shortcut);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(transcripts.transcriptServers, hasLength(1));
      player.switchAudio(true);
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      if (fails) {
        pending.completeError(StateError('old transcript request failed'));
      } else {
        pending.complete(
            const VideoTranscript(label: 'English', languageCode: 'en', lines: [
          VideoTranscriptLine(
              type: VideoTranscriptLineType.regular,
              startMs: 0,
              endMs: 1000,
              text: 'Stale transcript')
        ]));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(transcript, findsNothing);
      expect(find.text('Stale transcript'), findsNothing);
      expect(
          find.byKey(const ValueKey('video-transcript-retry')), findsNothing);
      expect(player.state.isAudio, isTrue);
      expect(player.state.position, const Duration(seconds: 42));
      Navigator.of(tester
              .element(find.byKey(const ValueKey('video-transcript-language'))))
          .pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'one Watch control opens speed and pitch and guards both after a mode change',
      (tester) async {
    await pumpWatch(tester);
    player.setSpeed(1.25);
    player.setPitchSemitones(2);
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(watchAction('speed-open')).tooltip,
        contains('Speed and pitch'));
    await tester.tap(watchAction('speed-open'));
    await tester.pumpAndSettle();
    expect(find.text('Speed and pitch'), findsOneWidget);
    final increase = find.byKey(const ValueKey('playback-pitch-increase'));
    final speed = find.byKey(const ValueKey('playback-speed-increase'));
    expect(find.byKey(const ValueKey('playback-speed-slider')), findsOneWidget);
    await tester.ensureVisible(increase);
    await tester.tap(increase);
    await tester.pumpAndSettle();
    expect(player.state.pitchSemitones, 3);
    expect(player.state.mediaCommand?.type, MediaCommandType.pitch);
    expect(player.state.speed, 1.25);
    expect(player.state.position, const Duration(seconds: 42));
    player.switchAudio(true);
    await tester.pumpAndSettle();
    await tester.tap(increase);
    await tester.pumpAndSettle();
    expect(player.state.pitchSemitones, 3);
    await tester.ensureVisible(speed);
    await tester.tap(speed);
    await tester.pumpAndSettle();
    expect(player.state.speed, 1.25);
    await pressAndroidBack(tester);
    expect(player.state.isMini, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Watch keeps speed and pitch beside direct Repeat even with a queue and backends',
      (tester) async {
    await pumpWatch(tester, withQueueAndBackend: true);
    await tester.tap(watchAction('speed-open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('playback-speed-slider')), findsOneWidget);
    expect(find.byKey(const ValueKey('playback-pitch-slider')), findsOneWidget);
    await pressAndroidBack(tester);
    expect(watchAction('more-open'), findsNothing);
    await tester.tap(watchAction('repeat'));
    await tester.pumpAndSettle();
    expect(settings.state.playerRepeatMode, PlayerRepeat.repeatAll);
    expect(settings.state.playerShuffleMode, isFalse);
    expect(player.state.isMini, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('watch repeat cycles the existing player repeat setting',
      (tester) async {
    await pumpWatch(tester);
    expect(settings.state.playerRepeatMode, PlayerRepeat.noRepeat);
    final button = watchAction('repeat');
    final playback = player.state.currentlyPlaying;
    final before = BackButtonInterceptor.describe();
    expect(tester.widget<IconButton>(button).tooltip, 'Repeat off');
    for (final (repeat, label) in [
      (PlayerRepeat.repeatAll, 'Repeat all'),
      (PlayerRepeat.repeatOne, 'Repeat one'),
      (PlayerRepeat.noRepeat, 'Repeat off')
    ]) {
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(settings.state.playerRepeatMode, repeat);
      final shown = tester.widget<IconButton>(button);
      expect(shown.tooltip, label);
      expect(shown.isSelected, repeat != PlayerRepeat.noRepeat);
      expect(
          find.descendant(
              of: button,
              matching: find.byIcon(repeat == PlayerRepeat.repeatOne
                  ? Icons.repeat_one
                  : Icons.repeat)),
          findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(BackButtonInterceptor.describe(), before);
      expect(player.state.currentlyPlaying, same(playback));
      expect(player.state.position, const Duration(seconds: 42));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'watch mode toggle retains the current playback in both directions',
      (tester) async {
    await pumpWatch(tester);
    final current = player.state.currentlyPlaying;
    final queue = player.state.videos;
    final generation = player.backendPlaybackGeneration;
    expect(watchAction('mode-toggle'), findsOneWidget);
    expect(
        find.descendant(
            of: watchAction('mode-toggle'), matching: find.text('Video')),
        findsOneWidget);
    expect(
        tester
            .getSemantics(watchAction('mode-toggle'))
            .flagsCollection
            .isToggled,
        isFalse);
    await tester.tap(watchAction('mode-toggle'));
    await tester.pumpAndSettle();
    expect(player.state.isAudio, isTrue);
    expect(
        find.descendant(
            of: watchAction('mode-toggle'), matching: find.text('Audio')),
        findsOneWidget);
    expect(
        tester
            .getSemantics(watchAction('mode-toggle'))
            .flagsCollection
            .isToggled,
        isTrue);
    expect(player.state.startAt, const Duration(seconds: 42));
    expect(player.state.currentlyPlaying, same(current));
    expect(player.state.videos, queue);
    expect(player.backendPlaybackGeneration, generation);
    await tester.tap(watchAction('mode-toggle'));
    await tester.pumpAndSettle();
    expect(player.state.isAudio, isFalse);
    expect(
        find.descendant(
            of: watchAction('mode-toggle'), matching: find.text('Video')),
        findsOneWidget);
    expect(
        tester
            .getSemantics(watchAction('mode-toggle'))
            .flagsCollection
            .isToggled,
        isFalse);
    expect(player.state.startAt, const Duration(seconds: 42));
    expect(player.state.currentlyPlaying, same(current));
    expect(player.state.videos, queue);
    expect(player.backendPlaybackGeneration, generation);
    expect(tester.takeException(), isNull);
  });

  testWidgets('details outside playback do not show playback actions',
      (tester) async {
    await pumpWatch(tester, inPlayer: false);
    expect(watchAction('playback-actions'), findsNothing);
    expect(shortcut, findsNothing);
    expect(watchAction('sound-toggle'), findsNothing);
    expect(watchAction('pitch-open'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final tablet in [false, true]) {
    testWidgets(
        'audio info fills the space below the actions (tablet: $tablet)',
        (tester) async {
      await pumpWatch(tester,
          height: 520,
          expandedAudio: true,
          tablet: tablet,
          authorId: 'test-channel');
      if (!tablet) {
        // Exercise the same switch from the ordinary watch page as the report.
        await tester.tap(watchAction('mode-toggle'));
        await tester.pumpAndSettle();
        await tester.tap(watchAction('mode-toggle'));
        await tester.pumpAndSettle();
      }
      expect(player.state.isAudio, isTrue);
      final panel = find.byType(tablet ? TabletExpandedPlayer : ExpandedPlayer);
      final lastControl = tablet
          ? find.ancestor(
              of: find.byType(SubscribeButton),
              matching: find.byWidgetPredicate((widget) =>
                  widget is SingleChildScrollView &&
                  widget.scrollDirection == Axis.vertical))
          : find.byType(NavigationBar);
      expect(tester.getRect(lastControl).bottom, tester.getRect(panel).bottom);
      expect(find.byType(SubscribeButton).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('expanded audio controls fit a short body (tablet: $tablet)',
        (tester) async {
      await pumpWatch(tester,
          width: 320,
          height: 260,
          textScale: 2,
          expandedAudio: true,
          tablet: tablet);
      expect(find.byType(tablet ? TabletExpandedPlayer : ExpandedPlayer),
          findsOneWidget);
      expect(watchAction('playback-actions'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final videoMode = watchAction('mode-toggle');
      await tester.ensureVisible(videoMode);
      await tester.pumpAndSettle();
      expect(videoMode.hitTestable(), findsOneWidget);
      await tester.tap(videoMode);
      await tester.pumpAndSettle();
      expect(player.state.isAudio, isFalse);
      expect(player.state.currentlyPlaying?.videoId, 'watch-video');
      expect(player.state.startAt, const Duration(seconds: 42));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('watch keeps an unavailable transcript visible and disabled',
      (tester) async {
    await pumpWatch(tester, captions: false);
    expect(tester.widget<IconButton>(shortcut).tooltip, 'Transcript');
    expect(tester.widget<IconButton>(shortcut).onPressed, isNull);
    expect(
        tester.widget<IconButton>(watchAction('repeat')).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('watch live media cannot switch decoder modes', (tester) async {
    await pumpWatch(tester, live: true);
    expect(tester.widget<FilledButton>(watchAction('mode-toggle')).onPressed,
        isNull);
    expect(player.state.isAudio, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final closing in [false, true]) {
    testWidgets(
        'watch actions cannot target an inactive player (closing: $closing)',
        (tester) async {
      await pumpWatch(tester, closing: closing, matchingVideo: closing);
      expect(tester.widget<FilledButton>(watchAction('mode-toggle')).onPressed,
          isNull);
      for (final action in [
        shortcut,
        watchAction('speed-open'),
        watchAction('repeat')
      ]) {
        expect(tester.widget<IconButton>(action).onPressed, isNull);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('watch offers speed alone when pitch is unsupported',
      (tester) async {
    await pumpWatch(tester);
    await tester.tap(watchAction('speed-open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('playback-speed-slider')), findsOneWidget);
    expect(find.byKey(const ValueKey('playback-pitch-slider')), findsNothing);
    await pressAndroidBack(tester);
    expect(watchAction('repeat').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  for (final isAudio in [false, true]) {
    for (final dismissal in ['Back', 'scrim', 'Navigator']) {
      testWidgets(
          '${isAudio ? 'audio' : 'video'} transcript $dismissal dismissal preserves player and restores Back',
          (tester) async {
        await pumpPlayer(tester, isAudio: isAudio);
        final interceptorsBefore = BackButtonInterceptor.describe();
        await tester.tap(shortcut);
        await tester.pumpAndSettle();
        expect(transcript, findsOneWidget);
        expect(find.text('Test transcript'), findsOneWidget);

        if (dismissal == 'Back') {
          await pressAndroidBack(tester);
        } else if (dismissal == 'scrim') {
          await tester.tapAt(const Offset(10, 10));
          await tester.pumpAndSettle();
        } else {
          Navigator.of(tester.element(transcript)).pop();
          await tester.pumpAndSettle();
        }

        expect(transcript, findsNothing);
        expect(player.state.isMini, isFalse);
        expect(shortcut, findsOneWidget);
        expect(BackButtonInterceptor.describe(), interceptorsBefore);
        await pressAndroidBack(tester);
        expect(player.state.isMini, isTrue);
        expect(shortcut, findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final dismissal in ['Back', 'scrim', 'Cancel']) {
    testWidgets(
        'backend $dismissal dismissal preserves player and restores Back',
        (tester) async {
      await pumpPlayer(tester, withQueueAndBackend: true);
      final interceptorsBefore = BackButtonInterceptor.describe();
      await tester.tap(find.byKey(const ValueKey('player-backend-shortcut')));
      await tester.pumpAndSettle();
      final cancel = find.byKey(const ValueKey('player-backend-cancel'));
      expect(cancel, findsOneWidget);

      if (dismissal == 'Back') {
        await pressAndroidBack(tester);
      } else if (dismissal == 'scrim') {
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
      } else {
        await tester.tap(cancel);
        await tester.pumpAndSettle();
      }

      expect(cancel, findsNothing);
      expect(player.state.isMini, isFalse);
      expect(BackButtonInterceptor.describe(), interceptorsBefore);
      await pressAndroidBack(tester);
      expect(player.state.isMini, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('all controls fit a narrow player with transcript beside speed',
      (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpPlayer(tester, withQueueAndBackend: true);

    final speed = find.byKey(const ValueKey('playback-speed-open'));
    expect(
        find.byKey(const ValueKey('player-backend-shortcut')), findsOneWidget);
    expect(find.byIcon(Icons.shuffle), findsOneWidget);
    expect(shortcut, findsOneWidget);
    expect(tester.getRect(shortcut).left,
        greaterThanOrEqualTo(tester.getRect(speed).right));
    expect(tester.getCenter(shortcut).dy, tester.getCenter(speed).dy);
    expect(tester.takeException(), isNull);
    await tester.tap(shortcut);
    await tester.pumpAndSettle();
    expect(transcript, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
