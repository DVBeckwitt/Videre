import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/download_playback_provenance.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/router.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/states/video.dart';
import 'package:clipious/videos/views/screens/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

const _playing = Video(videoId: 'playing', title: 'Playlist entry one');
const _next = Video(videoId: 'next', title: 'Playlist entry two');
const _details = Video(
  videoId: 'details',
  title: 'Details without interrupting playback',
  author: 'A channel',
  authorId: 'channel',
  lengthSeconds: 90,
);

class _Service extends Service {
  final response = Completer<Video>();
  final requestedIds = <String>[];
  bool unavailable = false;

  @override
  Future<Video> getVideo(String videoId,
      {Server? serverOverride,
      VideoLoadObserver? loadObserver,
      void Function(BackendPlayback request)? onBackendRequest}) {
    requestedIds.add(videoId);
    if (unavailable) return Future.error(StateError('Metadata unavailable'));
    return response.future;
  }

  @override
  Future<bool> isLoggedIn() async => false;

  @override
  Future<List<Playlist>> getUserPlaylists({bool postProcessing = true}) async =>
      [];
}

DownloadedVideo _savedVideo(Server server) {
  final audio = AdaptiveFormat(
      null,
      '128000',
      null,
      'https://inv.example/videoplayback?itag=251',
      '251',
      'audio/webm; codecs="opus"',
      '12345',
      '1700000000000',
      'RECTANGULAR',
      'webm',
      'opus',
      null,
      null);
  final video = AdaptiveFormat(
      null,
      '1000000',
      null,
      'https://inv.example/videoplayback?itag=248',
      '248',
      'video/webm; codecs="vp9"',
      '54321',
      '1700000000000',
      'RECTANGULAR',
      'webm',
      'vp9',
      '1080p',
      '1080');
  final proof = DownloadPlaybackProvenance.create(
      video: _details.copyWith(adaptiveFormats: [audio, video]),
      server: server,
      audioOnly: false,
      container: DownloadContainer.webm,
      audio: audio,
      videoFormat: video,
      byteLength: 10000,
      sha256: 'a' * 64)!;
  return DownloadedVideo(
      videoId: _details.videoId,
      title: 'Saved video title',
      author: 'Saved channel',
      profileId: server.profileId,
      accountId: server.accountId,
      lengthSeconds: 90,
      quality: '1080p',
      container: DownloadContainer.webm,
      downloadComplete: true,
      playbackProvenance: proof,
      storageUri: 'content://downloads/tree/library/document/video',
      folderUri: 'content://downloads/tree/library');
}

class _Downloads extends Cubit<DownloadManagerState>
    implements DownloadManagerCubit {
  _Downloads() : super(const DownloadManagerState());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends Fake implements SettingsCubit {
  _Settings(bool autoplay)
      : state = SettingsState.init().copyWith(settings: {
          playerAutoplayOnLoad:
              SettingsValue(playerAutoplayOnLoad, '$autoplay'),
          useReturnYoutubeDislikeSettingName:
              SettingsValue(useReturnYoutubeDislikeSettingName, 'false'),
          distractionFreeModeSettingName:
              SettingsValue(distractionFreeModeSettingName, 'true'),
        });

  @override
  final SettingsState state;

  @override
  Stream<SettingsState> get stream => const Stream.empty();
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  _Player()
      : super(PlayerState.init([_playing, _next]).copyWith(
          currentlyPlaying: _playing,
          isPlaying: true,
          isMini: true,
          isHidden: false,
          position: const Duration(seconds: 37),
        ));

  final playRequests = <List<Video>>[];
  final startPositions = <Duration?>[];
  final selectedWatchIds = <String>[];
  Duration? sought;

  @override
  void showBigPlayer() {}

  @override
  void seek(Duration position) => sought = position;

  @override
  void noteWatchSelection(String videoId) => selectedWatchIds.add(videoId);

  @override
  Future<List<SponsorSegment>> prepareSponsorSegments(String videoId) async =>
      [];

  @override
  Future<void> playVideo(List<Video> videos,
      {bool? audio,
      Duration? startAt,
      bool? playing,
      int? startIndex,
      bool fromMusic = false}) async {
    playRequests.add(videos);
    startPositions.add(startAt);
    emit(state.copyWith(videos: videos, currentlyPlaying: videos.first));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Service originalService;
  late _Service metadata;
  late _Downloads downloads;
  late _Player player;

  setUp(() async {
    originalService = service;
    service = metadata = _Service();
    db = await SembastSqfDb.createInMemory();
    downloads = _Downloads();
    player = _Player();
  });

  tearDown(() async {
    await downloads.close();
    await player.close();
    await db.close();
    service = originalService;
    debugDefaultTargetPlatformOverride = null;
  });

  for (final unavailable in [false, true]) {
    testWidgets(
        'ordinary video route autoplays a compatible download before ${unavailable ? 'failing' : 'held'} metadata',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const server = Server(url: 'https://inv.example', id: 'account');
      final saved = _savedVideo(server);
      await tester.runAsync(() async {
        await db.upsertServer(server);
        await db.useServer(server);
        await db.upsertDownload(saved);
      });
      metadata.unavailable = unavailable;
      final router = RootStackRouter.build(routes: [
        AutoRoute(page: VideoRoute.page, path: '/', children: [
          AutoRoute(page: VideoInfoRoute.page),
          AutoRoute(page: CommentsRoute.page),
          AutoRoute(page: RecommendedRoute.page),
        ]),
      ]);
      addTearDown(router.dispose);
      await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<SettingsCubit>.value(value: _Settings(true)),
          BlocProvider<PlayerCubit>.value(value: player),
          BlocProvider<DownloadManagerCubit>.value(value: downloads),
        ],
        child: MaterialApp.router(
          routerConfig: router.config(
            deepLinkBuilder: (_) => DeepLink([
              VideoRoute(videoId: saved.videoId),
            ]),
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
        ),
      ));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(player.playRequests, hasLength(1));
      expect(player.startPositions, [null],
          reason: 'Untimestamped video routes preserve saved progress policy');
      final selected = player.playRequests.single.single;
      expect(selected.videoId, saved.videoId);
      expect(selected.title, saved.title);
      expect(selected.downloadPlaybackOnly, isTrue);
      expect(selected.playbackConnection?.server.accountId, server.accountId);
      expect(selected.adaptiveFormats, isNull);
      expect(selected.authorId, isNull,
          reason: 'Saved metadata must not invent a channel identifier');
      expect(metadata.requestedIds, [saved.videoId]);
      expect(metadata.response.isCompleted, isFalse);
      final cubit = tester
          .element(find.byType(BlocConsumer<VideoCubit, VideoState>))
          .read<VideoCubit>();
      expect(cubit.state.loadingVideo, isFalse);
      expect(cubit.state.error, isEmpty);
      if (!unavailable) {
        metadata.response.complete(_details);
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        expect(cubit.state.video, _details);
        expect(find.text(_details.title!), findsOneWidget);
        expect(player.playRequests, hasLength(1),
            reason: 'Detail enrichment must not replace the playing source');
        expect(player.state.currentlyPlaying, same(selected));
      } else {
        expect(cubit.state.video, same(selected));
      }
      cubit.onDownload();
      await tester.pumpAndSettle();
      expect(player.playRequests, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });
  }

  for (final scenario in [
    (intent: false, autoplay: true, plays: false, name: 'details override on'),
    (
      intent: false,
      autoplay: false,
      plays: false,
      name: 'details override off'
    ),
    (intent: null, autoplay: true, plays: true, name: 'default autoplay on'),
    (intent: null, autoplay: false, plays: false, name: 'default autoplay off'),
    (intent: true, autoplay: false, plays: true, name: 'explicit play off'),
    (intent: true, autoplay: true, plays: true, name: 'explicit play on'),
  ]) {
    testWidgets('video route respects ${scenario.name}', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final before = player.state;
      final router = RootStackRouter.build(routes: [
        AutoRoute(page: VideoRoute.page, path: '/', children: [
          AutoRoute(page: VideoInfoRoute.page),
          AutoRoute(page: CommentsRoute.page),
          AutoRoute(page: RecommendedRoute.page),
        ]),
      ]);
      addTearDown(router.dispose);
      await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<SettingsCubit>.value(
              value: _Settings(scenario.autoplay)),
          BlocProvider<PlayerCubit>.value(value: player),
          BlocProvider<DownloadManagerCubit>.value(value: downloads),
        ],
        child: MaterialApp.router(
          routerConfig: router.config(
            deepLinkBuilder: (_) => DeepLink([
              VideoRoute(
                  videoId: _details.videoId,
                  playNow: scenario.intent,
                  startAt: const Duration(seconds: 23)),
            ]),
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
        ),
      ));
      await tester.pump();
      expect(find.byType(VideoScreen), findsOneWidget);
      expect(metadata.requestedIds, [_details.videoId]);
      expect(player.playRequests, isEmpty);
      metadata.response.complete(_details);
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(find.text(_details.title!), findsOneWidget);
      if (scenario.plays) {
        expect(player.playRequests, [
          [_details]
        ]);
        expect(player.startPositions, [const Duration(seconds: 23)]);
      } else {
        expect(player.playRequests, isEmpty);
        expect(player.state, same(before),
            reason:
                'Viewing details must preserve the playing queue and position');
      }
      expect(player.selectedWatchIds,
          scenario.plays && scenario.intent == true ? [_details.videoId] : []);
      final video = tester
          .element(find.byType(BlocConsumer<VideoCubit, VideoState>))
          .read<VideoCubit>();
      video.onDownload();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(player.playRequests.length, scenario.plays ? 1 : 0,
          reason: 'A download state update must not trigger playback again');
      if (!scenario.plays) {
        video.playVideo(false);
        expect(player.startPositions, [const Duration(seconds: 23)],
            reason: 'An explicit Play keeps the incoming link position');
      }
      video.restartVideo(false);
      expect(player.sought, const Duration(seconds: 23),
          reason:
              'Opening a link to the current video keeps its explicit time');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
