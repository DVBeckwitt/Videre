import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/home/models/home_tabs_layout.dart';
import 'package:clipious/home/views/components/flow_video_home.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/tv/screens/tv_player_view.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/subscription_management/models/subscription.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/services/watch_history.dart';
import 'package:clipious/videos/states/video_in_list.dart';
import 'package:clipious/videos/views/tv/components/video_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../test_app_cubit.dart';
import '../../test_player_cubit.dart';
import '../../test_settings_cubit.dart';

class _FeedService extends Service {
  int requests = 0;
  int historyDeletes = 0;
  final queries = <String?>[];
  FutureOr<List<Video>> Function(String?)? discoveryResults;
  List<Subscription> follows = [];

  @override
  Future<void> deleteFromUserHistory(String videoId) async {
    historyDeletes++;
  }

  @override
  Future<List<Subscription>> getRecommendationSubscriptions({
    required Server server,
    required Future<void> Function() beforeRequest,
  }) async {
    await beforeRequest();
    return follows;
  }

  @override
  Future<List<Video>> getVideoRecommendationCandidates({
    required Server server,
    required Future<void> Function() beforeRequest,
    String? query,
    String? channelId,
  }) async {
    await beforeRequest();
    requests++;
    queries.add(query);
    return discoveryResults?.call(query) ?? const <Video>[];
  }

  @override
  Future<List<Video>> getPopular() async {
    requests++;
    return [];
  }

  @override
  Future<List<Video>> getTrending({String? type}) async {
    requests++;
    return [];
  }
}

class _HomeAppCubit extends TestAppCubit {
  _HomeAppCubit(super.initialState);

  void changeProfile(String id) {
    emit(state.copyWith(
        profileId: id, sessionRevision: state.sessionRevision + 1));
  }
}

class _HomePlayerCubit extends TestPlayerCubit {
  _HomePlayerCubit(super.initialState, super.settings);

  final playedDownloads = <DownloadedVideo>[];

  @override
  Future<void> playOfflineVideos(List<DownloadedVideo> offlineVids,
      {int startIndex = 0,
      bool fromMusic = false,
      bool songTap = false}) async {
    expect(fromMusic, isFalse);
    playedDownloads.add(offlineVids[startIndex]);
  }
}

// Inspect the TV route without starting a decoder in a widget test.
class _PlaybackNavigator extends Navigator {
  const _PlaybackNavigator({super.key, required super.onGenerateRoute});

  @override
  NavigatorState createState() => _PlaybackNavigatorState();
}

class _PlaybackNavigatorState extends NavigatorState {
  final pushed = <Route<dynamic>>[];

  @override
  Future<T?> push<T extends Object?>(Route<T> route) {
    pushed.add(route);
    return Future<T?>.value();
  }
}

class _OfflinePlatform {
  static const _network = MethodChannel('videre/network');
  static const _networkEvents = MethodChannel('videre/network_changes');
  static const _storage = MethodChannel('videre/download_storage');
  static const _codec = StandardMethodCodec();

  final _messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final files = <String>{};
  final probes = <({String profile, List<String> ids})>[];
  bool? online;
  Future<void> Function(String profile)? beforeProbe;

  _OfflinePlatform({this.online = false}) {
    _messenger.setMockMethodCallHandler(_network, (call) async {
      expect(call.method, 'isNetworkConnected');
      return online;
    });
    _messenger.setMockMethodCallHandler(_networkEvents, (_) async => null);
    _messenger.setMockMethodCallHandler(_storage, (call) async {
      expect(call.method, 'probeMusicFiles');
      final args = call.arguments as Map<Object?, Object?>;
      final profile = args['profileId'] as String;
      final ids = [
        for (final entry in args['files'] as List<Object?>)
          (entry as Map<Object?, Object?>)['videoId'] as String,
      ];
      probes.add((profile: profile, ids: ids));
      await beforeProbe?.call(profile);
      return {
        for (final id in ids)
          if (files.contains(id)) id: {'identity': 'a' * 64, 'byteLength': 10},
      };
    });
    addTearDown(() {
      _messenger.setMockMethodCallHandler(_network, null);
      _messenger.setMockMethodCallHandler(_networkEvents, null);
      _messenger.setMockMethodCallHandler(_storage, null);
    });
  }

  Future<void> changeConnection(bool value) async {
    online = value;
    final delivered = Completer<void>();
    unawaited(_messenger.handlePlatformMessage(
        _networkEvents.name,
        _codec.encodeSuccessEnvelope({'wifi': false, 'connected': value}),
        (_) => delivered.complete()));
    await delivered.future;
  }
}

DownloadedVideo _download(String id, String title,
        {bool ready = true, bool audio = false}) =>
    DownloadedVideo(
        videoId: id,
        title: title,
        lengthSeconds: 42,
        quality: audio ? 'audio' : '720p',
        storageUri: 'content://downloads/tree/videos/document/$id',
        folderUri: 'content://downloads/tree/videos',
        downloadComplete: ready,
        audioOnly: audio);

Finder _downloadCard(String id) =>
    find.byKey(ValueKey('flow-offline-video-$id'));

final _reconnectRefresh =
    find.byKey(const ValueKey('video-home-refresh-online'));

bool _hasPrimaryFocus(WidgetTester tester, Finder finder) {
  final target = tester.element(finder);
  var found = false;
  FocusManager.instance.primaryFocus?.context?.visitAncestorElements((element) {
    found = identical(element, target);
    return !found;
  });
  return found;
}

void main() {
  late _HomeAppCubit app;
  late TestSettingsCubit settings;
  late _HomePlayerCubit player;
  late _FeedService api;
  final calls = <MethodCall>[];
  List<String> discoveryQueries = [];
  List<Map<String, Object>> interestChips = [];
  const channel = MethodChannel('videre/recommendations');

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    service = api = _FeedService();
    app = _HomeAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    await app.initState();
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = _HomePlayerCubit(PlayerState.init(null), settings);
    calls.clear();
    discoveryQueries = [];
    interestChips = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final arguments = call.arguments as Map;
      final candidates = arguments['candidates'] as List;
      final events = arguments['events'] as List? ?? const [];
      return {
        'state': <String, Object?>{},
        'summary': {
          'discoveryQueries': discoveryQueries,
          'interestChips': interestChips,
          // The viewport tests exercise admission to the bridge. The native
          // engine can reject duplicate sightings without writing a snapshot.
          if (events
              .whereType<Map>()
              .any((event) => event['type'] == 'impression'))
            'appliedEvents': 0,
        },
        'ranked': [
          for (final candidate in candidates.reversed)
            {
              'id': (candidate as Map)['id'],
              'score': 1.0,
              'reason': 'Matches your local video interests.'
            },
        ],
      };
    });
  });

  tearDown(() async {
    RecommendationService.forProfile(db, db.profileId).dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> connect() async {
    const server = Server(url: 'https://invidious.example');
    await db.upsertServer(server);
    await db.useServer(server);
    app.setServer(server);
  }

  Future<void> remember(String id, String title, double progress,
      {bool music = false, String? authorId}) async {
    await db.recordPlaybackHistory(
        music ? PlaybackHistoryOrigin.music : PlaybackHistoryOrigin.video,
        HistoryVideoCache(id, title, 'Creator', '',
            authorId: authorId,
            lengthSeconds: 300,
            musicMetadata: music
                ? MusicMetadata(title: title, artist: 'Artist', thumbnails: [])
                : null));
    await db.saveProgress(Progress(progress, id));
  }

  Future<void> show(WidgetTester tester,
      {double scale = 1,
      bool active = true,
      bool settle = true,
      bool television = false,
      bool disableAnimations = false,
      Widget? configuredFeed,
      Key? homeKey,
      GlobalKey<_PlaybackNavigatorState>? playbackNavigator,
      ValueChanged<List<RecommendationInterest>>? onEdit}) async {
    tester.view.physicalSize =
        television ? const Size(1280, 800) : const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final home = Scaffold(
        body: FlowVideoHome(
            key: homeKey,
            active: active,
            television: television,
            configuredFeed: configuredFeed == null
                ? null
                : (shelf) => Column(children: [
                      if (shelf != null) shelf,
                      configuredFeed,
                    ]),
            onEdit: onEdit));
    final surface = television
        ? Shortcuts(
            shortcuts: <LogicalKeySet, Intent>{
              LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
            },
            child: home,
          )
        : home;

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
          data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: disableAnimations),
          child: child!,
        ),
        home: playbackNavigator == null
            ? surface
            : _PlaybackNavigator(
                key: playbackNavigator,
                onGenerateRoute: (_) =>
                    MaterialPageRoute<void>(builder: (_) => surface),
              ),
      ),
    ));
    if (settle) await tester.pumpAndSettle();
  }

  testWidgets('offline Home offers only readable completed video downloads',
      (tester) async {
    final platform = _OfflinePlatform();
    final readable = _download('saved000001', 'Readable download');
    final deleted = _download('saved000002', 'Deleted after opening Home');
    final missing = _download('missing0001', 'Missing download');
    final pending = _download('pending0001', 'Pending download', ready: false);
    final audio = _download('audio000001', 'Audio download', audio: true);
    platform.files.addAll(
        [readable.videoId, deleted.videoId, pending.videoId, audio.videoId]);
    await tester.runAsync(() async {
      for (final download in [readable, deleted, missing, pending, audio]) {
        await db.upsertDownload(download);
      }
    });

    await show(tester);

    expect(find.text('You’re offline'), findsOneWidget);
    expect(_downloadCard(readable.videoId), findsOneWidget);
    expect(_downloadCard(deleted.videoId), findsOneWidget);
    expect(_downloadCard(missing.videoId), findsNothing);
    expect(_downloadCard(pending.videoId), findsNothing);
    expect(_downloadCard(audio.videoId), findsNothing);
    expect(platform.probes.expand((batch) => batch.ids),
        unorderedEquals([readable.videoId, deleted.videoId, missing.videoId]));
    expect(_reconnectRefresh, findsNothing);

    await tester.tap(_downloadCard(readable.videoId));
    await tester.pumpAndSettle();
    expect(player.playedDownloads, [readable]);

    platform.files.remove(deleted.videoId);
    await tester.tap(_downloadCard(deleted.videoId));
    await tester.pumpAndSettle();
    expect(player.playedDownloads, [readable]);
    expect(_downloadCard(deleted.videoId), findsNothing);
    expect(_downloadCard(readable.videoId), findsOneWidget);

    final delayedProbe = Completer<void>();
    addTearDown(() {
      if (!delayedProbe.isCompleted) delayedProbe.complete();
    });
    platform.beforeProbe = (_) => delayedProbe.future;
    await tester.tap(_downloadCard(readable.videoId));
    await tester.pump();
    final homeContext = tester.element(find.byType(FlowVideoHome));
    unawaited(showDialog<void>(
      context: homeContext,
      builder: (_) => const AlertDialog(content: Text('Other action')),
    ));
    await tester.pumpAndSettle();
    delayedProbe.complete();
    await tester.pumpAndSettle();
    expect(find.text('Other action'), findsOneWidget);
    expect(player.playedDownloads, [readable]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('offline Home holds its download cards until a manual refresh',
      (tester) async {
    final platform = _OfflinePlatform();
    final download = _download('saved000001', 'Download in view');
    platform.files.add(download.videoId);
    await tester.runAsync(() => db.upsertDownload(download));
    await show(tester);

    final card = _downloadCard(download.videoId);
    expect(card, findsOneWidget);
    final originalElement = tester.element(card);
    final originalBounds = tester.getRect(card);

    await platform.changeConnection(true);
    await tester.pumpAndSettle();
    expect(find.text('Back online'), findsOneWidget);
    expect(_reconnectRefresh, findsOneWidget);
    expect(tester.element(card), same(originalElement));
    expect(tester.getRect(card), originalBounds);

    await tester
        .runAsync(() => remember('cached00001', 'Available feed video', 0));
    playbackHistoryRevision.value++;
    await tester.pumpAndSettle();
    expect(find.text('Available feed video'), findsNothing);
    expect(tester.element(card), same(originalElement));
    expect(tester.getRect(card), originalBounds);

    await tester.tap(_reconnectRefresh);
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    expect(find.text('Available feed video'), findsOneWidget);
    expect(_reconnectRefresh, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('offline Home keeps cached feed cards in place across reconnect',
      (tester) async {
    final platform = _OfflinePlatform(online: true);
    final download = _download('saved000001', 'Unneeded fallback');
    platform.files.add(download.videoId);
    await tester.runAsync(() async {
      await db.upsertDownload(download);
      await remember('cached00001', 'Cached feed video', 0);
    });
    await show(tester);

    final card = find.byKey(const ValueKey('flow-video-cached00001'));
    expect(card, findsOneWidget);
    expect(_downloadCard(download.videoId), findsNothing);
    expect(platform.probes, isEmpty);
    final originalElement = tester.element(card);
    final originalBounds = tester.getRect(card);

    await platform.changeConnection(false);
    await tester.pumpAndSettle();
    expect(_reconnectRefresh, findsNothing);
    expect(tester.element(card), same(originalElement));
    expect(tester.getRect(card), originalBounds);

    await platform.changeConnection(true);
    await tester.pumpAndSettle();
    expect(_reconnectRefresh, findsOneWidget);
    expect(tester.element(card), same(originalElement));
    expect(tester.getRect(card), originalBounds);
    expect(platform.probes, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a profile switch discards an in-flight download shelf',
      (tester) async {
    final platform = _OfflinePlatform();
    final originalProfile = db.profileId;
    final download = _download('saved000001', 'Previous profile download');
    final oldProbe = Completer<void>();
    platform.files.add(download.videoId);
    platform.beforeProbe = (_) => oldProbe.future;
    addTearDown(() {
      if (!oldProbe.isCompleted) oldProbe.complete();
      RecommendationService.forProfile(db, originalProfile).dispose();
    });
    final nextProfile = (await tester.runAsync(() async {
      await db.upsertDownload(download);
      return db.createProfile('Next profile');
    }))!
        .id;

    await show(tester, settle: false);
    for (var frame = 0; frame < 8 && platform.probes.isEmpty; frame++) {
      await tester.pump();
    }
    expect(platform.probes.single.profile, originalProfile);
    expect(_downloadCard(download.videoId), findsNothing);

    await tester.runAsync(() => db.useProfile(nextProfile));
    app.changeProfile(nextProfile);
    oldProbe.complete();
    await tester.pumpAndSettle();
    expect(_downloadCard(download.videoId), findsNothing);

    await show(tester, homeKey: ValueKey(nextProfile));
    expect(find.text('You’re offline'), findsOneWidget);
    expect(find.text('No downloaded videos are available to play.'),
        findsOneWidget);
    expect(_downloadCard(download.videoId), findsNothing);
    expect(platform.probes.map((batch) => batch.profile), [originalProfile]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TV D-pad opens an offline Home item in the TV player',
      (tester) async {
    final platform = _OfflinePlatform();
    final download = _download('saved000001', 'Remote-friendly download');
    final navigator = GlobalKey<_PlaybackNavigatorState>();
    platform.files.add(download.videoId);
    await tester.runAsync(() => db.upsertDownload(download));
    await show(tester, television: true, playbackNavigator: navigator);

    final card = _downloadCard(download.videoId);
    expect(card, findsOneWidget);
    for (var move = 0; move < 6 && !_hasPrimaryFocus(tester, card); move++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(_hasPrimaryFocus(tester, card), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    final route =
        navigator.currentState!.pushed.single as MaterialPageRoute<void>;
    expect(route.builder(tester.element(card)), isA<TvPlayerScreen>());
    expect(platform.probes.last.ids, [download.videoId]);
    expect(player.playedDownloads, isEmpty);
    route.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('Continue watching excludes music, completed and manually watched items',
      () async {
    await remember('resume00001', 'Resume me', 0.4);
    await remember('complete001', 'Completed', 0.95);
    await remember('manual00001', 'Marked watched', 0.3);
    await remember('song0000001', 'A song', 0.2, music: true);
    await WatchRepository.forDatabase(db)!.mark('manual00001', true);
    expect(continuingVideos(db).map((video) => video.videoId), ['resume00001']);
    expect(api.requests, 0);
  });

  test('Continue watching stays in the owning profile', () async {
    await remember('resume00001', 'First person', 0.4);
    final other = await db.createProfile('Other');
    expect(continuingVideos(db.forProfile(other.id)), isEmpty);
    expect(continuingVideos(db).single.title, 'First person');
  });

  testWidgets(
      'Continue watching removes local history for the active profile only',
      (tester) async {
    await tester.runAsync(() =>
        settings.setHomeTabsLayout(HomeTabsLayout(continueWatching: true)));
    const id = 'resume00001';
    const server =
        Server(url: 'https://invidious.example', authToken: 'test-only');
    final other = await tester.runAsync(() async {
      await db.upsertServer(server);
      await db.useServer(server);
      await remember(id, 'One recording', 0.4);
      final profile = await db.createProfile('Other');
      final owner = db.forProfile(profile.id);
      await owner.recordPlaybackHistory(PlaybackHistoryOrigin.video,
          HistoryVideoCache(id, 'Same recording', 'Creator', ''));
      await owner.saveProgress(Progress(0.6, id));
      return owner;
    });
    app.setServer(server);
    await show(tester);
    final remove = find.byTooltip('Remove from local history');
    await tester.ensureVisible(remove);
    expect(tester.getSize(remove).shortestSide, greaterThanOrEqualTo(48));

    final revision = playbackHistoryRevision.value;
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(playbackHistoryRevision.value, greaterThan(revision));
    expect(remove, findsNothing);
    expect(db.getLocalHistory(), isEmpty);
    expect(db.getVideoProgress(id), 0.4);
    expect(other!.getVideoProgress(id), 0.6);
    expect(other.getLocalHistory().single.videoId, id);
    expect(api.historyDeletes, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Continue watching is opt-in and can be added back live',
      (tester) async {
    await tester.runAsync(() => remember('resume00001', 'Resume me', 0.4));
    await show(tester);
    expect(find.text('Continue watching'), findsNothing);
    expect(find.byTooltip('Remove from local history'), findsNothing);
    await tester.runAsync(() =>
        settings.setHomeTabsLayout(HomeTabsLayout(continueWatching: true)));
    await tester.pumpAndSettle();
    expect(find.text('Continue watching'), findsOneWidget);
    await tester.runAsync(
        () => settings.setHomeTabsLayout(const HomeTabsLayout.defaults()));
    await tester.pumpAndSettle();
    expect(find.text('Continue watching'), findsNothing);
    expect(db.getHistoryVideoByVideoId('resume00001'), isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('all Home tabs disabled is blank and does not rank or warm',
      (tester) async {
    await tester.runAsync(
        () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [])));
    await tester.runAsync(() => remember('video000001', 'Local video', 0));
    var edited = false;
    await show(tester,
        configuredFeed: const Text('Configured feed'),
        onEdit: (_) => edited = true);
    expect(find.text('Local video'), findsNothing);
    expect(find.text('Configured feed'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byKey(const ValueKey('video-home-discover')), findsNothing);
    expect(calls, isEmpty);
    expect(api.requests, 0);
    await tester.tap(find.byKey(const ValueKey('home-tabs-edit')));
    await tester.pumpAndSettle();
    expect(edited, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final configured in [false, true]) {
    testWidgets('Continue watching can stand alone: configured=$configured',
        (tester) async {
      await tester.runAsync(() => settings.setHomeTabsLayout(HomeTabsLayout(
          enabledOrder: configured ? [HomeTabsLayout.yourFeeds] : [],
          continueWatching: true)));
      await tester.runAsync(() => remember('resume00001', 'Resume me', 0.4));
      await show(tester, configuredFeed: const Text('Configured feed'));
      expect(find.text('Continue watching'), findsOneWidget);
      if (configured) expect(find.text('Configured feed'), findsOneWidget);
      expect(calls, isEmpty);
      expect(api.requests, 0);
      await tester.tap(find.byTooltip('Remove from local history'));
      await tester.pumpAndSettle();
      expect(find.text('Continue watching'), findsNothing);
      expect(db.getHistoryVideoByVideoId('resume00001'), isNull);
      expect(calls, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('Home chips follow saved order and disabled feeds stop learning',
      (tester) async {
    await tester.runAsync(
        () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [
              HomeTabsLayout.yourFeeds,
              HomeTabsLayout.discover,
              HomeTabsLayout.forYou,
            ])));
    await tester.runAsync(() => remember('video000001', 'Local video', 0));
    await show(tester, configuredFeed: const Text('Configured feed'));
    final yourFeeds = find.byKey(const ValueKey('video-home-your-feeds'));
    final discover = find.byKey(const ValueKey('video-home-discover'));
    final forYou = find.byKey(const ValueKey('video-home-for-you'));
    expect(find.text('Configured feed'), findsOneWidget);
    expect((calls.single.arguments as Map)['candidates'],
        contains(predicate((dynamic value) => value['id'] == 'video000001')));
    expect(api.requests, 0);
    expect(tester.getTopLeft(yourFeeds).dx,
        lessThan(tester.getTopLeft(discover).dx));
    expect(
        tester.getTopLeft(discover).dx, lessThan(tester.getTopLeft(forYou).dx));
    await tester.ensureVisible(forYou);
    await tester.tap(forYou);
    await tester.pumpAndSettle();
    expect(find.text('Local video'), findsOneWidget);
    expect(calls, isNotEmpty);
    await tester.runAsync(
        () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [])));
    await tester.pumpAndSettle();
    final ranked = calls.length;
    playbackHistoryRevision.value++;
    await tester.pumpAndSettle();
    expect(calls, hasLength(ranked));
    expect(find.text('Local video'), findsNothing);
    expect(find.text('Configured feed'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'For you publishes ready discoveries and learned topics before taps',
      (tester) async {
    await tester.runAsync(connect);
    discoveryQueries = ['discover query'];
    interestChips = [
      for (final id in ['science', 'nature', 'books', 'space', 'art'])
        {
          'id': id,
          'label': id,
          'queries': ['$id query']
        },
    ];
    final gate = Completer<void>();
    api.discoveryResults = (query) async {
      await gate.future;
      return switch (query) {
        'discover query' => const [
            Video(videoId: 'discover001', title: 'Ready discovery')
          ],
        'science query' => const [
            Video(videoId: 'science0001', title: 'Ready science')
          ],
        'space query' => const [
            Video(videoId: 'spaces00001', title: 'Ready space')
          ],
        _ => const <Video>[],
      };
    };
    await show(tester, settle: false);
    await tester.pump();
    await tester.pump();
    expect(api.queries, isNotEmpty);
    final discover = find.byKey(const ValueKey('video-home-discover'));
    final science = find.byKey(const ValueKey('flow-interest-science'));
    expect(discover, findsNothing);
    expect(science, findsNothing);
    gate.complete();
    await tester.pumpAndSettle();
    expect(
        api.queries,
        unorderedEquals([
          'discover query',
          'science query',
          'nature query',
          'books query',
          'space query'
        ]));
    expect(find.byKey(const ValueKey('flow-interest-nature')), findsNothing);
    expect(find.byKey(const ValueKey('flow-interest-books')), findsNothing);
    expect(find.byKey(const ValueKey('flow-interest-space')), findsOneWidget);
    expect(find.byKey(const ValueKey('flow-interest-art')), findsNothing);
    expect(discover, findsOneWidget);
    expect(science, findsOneWidget);
    expect(find.text('Ready discovery'), findsNothing);
    expect(find.text('Ready science'), findsNothing);

    final preparedRanks = calls.length;
    await tester.ensureVisible(science);
    await tester.tap(science);
    await tester.pump();
    expect(find.text('Ready science'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.ensureVisible(discover);
    await tester.tap(discover);
    await tester.pump();
    expect(find.text('Ready discovery'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(calls, hasLength(preparedRanks));
    expect(find.byKey(const ValueKey('video-discovery-query')), findsNothing);
    expect(api.requests, 5,
        reason: 'Opening ready suggestions only changes the view');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('returning to For You shows its cards while ranking catches up',
      (tester) async {
    await tester.runAsync(() async {
      await remember('video000001', 'Local video', 0);
      await settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [
        HomeTabsLayout.forYou,
        HomeTabsLayout.yourFeeds,
        HomeTabsLayout.discover,
      ]));
    });
    await show(tester, configuredFeed: const Text('Configured feed'));
    expect(find.text('Local video'), findsOneWidget);
    final before = calls.length;
    await tester.tap(find.byKey(const ValueKey('video-home-your-feeds')));
    await tester.pumpAndSettle();
    expect(find.text('Configured feed'), findsOneWidget);
    expect(calls, hasLength(before),
        reason: 'The completed rank already resolved the empty topic catalog');

    final pending = Completer<Map<String, Object?>>();
    var ranking = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      ranking = true;
      return pending.future;
    });
    await tester.tap(find.byKey(const ValueKey('video-home-for-you')));
    await tester.pump();
    await tester.pump();
    expect(ranking, isTrue);
    expect(find.text('Local video'), findsOneWidget);
    pending.complete({'state': <String, Object?>{}, 'ranked': <Object?>[]});
    await tester.pumpAndSettle();
    expect(find.text('Local video'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'returning to For You drops cards removed while viewing Your feeds',
      (tester) async {
    await tester.runAsync(() async {
      await remember('video000001', 'Removed video', 0);
      await settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [
        HomeTabsLayout.forYou,
        HomeTabsLayout.yourFeeds,
      ]));
    });
    await show(tester, configuredFeed: const Text('Configured feed'));
    expect(find.text('Removed video'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('video-home-your-feeds')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => db.deleteLocalHistory('video000001'));
    playbackHistoryRevision.value++;
    final pending = Completer<Map<String, Object?>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) => pending.future);
    await tester.tap(find.byKey(const ValueKey('video-home-for-you')));
    await tester.pump();
    expect(find.text('Removed video'), findsNothing);
    pending.complete({'state': <String, Object?>{}, 'ranked': <Object?>[]});
    await tester.pumpAndSettle();
    expect(find.text('Removed video'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('For you prepares only enabled suggestions while Home is visible',
      (tester) async {
    discoveryQueries = ['disabled discover'];
    interestChips = [
      for (final id in ['enabled', 'disabled'])
        {
          'id': id,
          'label': id,
          'queries': ['$id topic']
        },
    ];
    await tester.runAsync(() async {
      await connect();
      await settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [
        HomeTabsLayout.forYou,
        HomeTabsLayout.topicId('enabled')
      ]));
    });
    api.discoveryResults =
        (_) => const [Video(videoId: 'enabled0001', title: 'Enabled video')];
    await show(tester, active: false);
    expect(api.queries, isEmpty);
    await show(tester);
    expect(api.queries, ['enabled topic']);
    expect(find.byKey(const ValueKey('flow-interest-enabled')), findsOneWidget);
    expect(find.byKey(const ValueKey('flow-interest-disabled')), findsNothing);
    expect(find.byKey(const ValueKey('video-home-discover')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an instance cooldown stops preparation across all suggestions',
      (tester) async {
    await tester.runAsync(connect);
    discoveryQueries = ['new videos'];
    interestChips = [
      for (final id in ['science', 'nature'])
        {
          'id': id,
          'label': id,
          'queries': ['$id videos']
        },
    ];
    api.discoveryResults = (_) => throw InvidiousServiceError('Rate limited',
        statusCode: 429, retryAfter: const Duration(minutes: 2));
    await show(tester);
    expect(api.requests, 1);
    expect(find.byKey(const ValueKey('video-home-discover')), findsNothing);
    expect(find.byKey(const ValueKey('flow-interest-science')), findsNothing);
    expect(find.byKey(const ValueKey('flow-interest-nature')), findsNothing);
    playbackHistoryRevision.value++;
    await tester.pumpAndSettle();
    await show(tester, active: false);
    await show(tester);
    expect(api.requests, 1, reason: 'Re-entry must respect Retry-After.');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('enabling only a topic loads its videos once', (tester) async {
    await tester.runAsync(connect);
    interestChips = [
      {
        'id': 'science',
        'label': 'Science',
        'queries': ['science videos']
      },
    ];
    await tester.runAsync(
        () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [])));
    await show(tester);
    expect(calls, isEmpty);
    await tester.runAsync(
        () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [
              HomeTabsLayout.topicId('science'),
            ])));
    await tester.pumpAndSettle();
    final chip = find.byKey(const ValueKey('flow-interest-science'));
    expect(chip, findsOneWidget);
    expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
    expect(find.byKey(const ValueKey('video-home-for-you')), findsNothing);
    expect(find.text('No videos'), findsOneWidget);
    expect(find.text('Discover videos'), findsNothing);
    expect(api.requests, 1);
    playbackHistoryRevision.value++;
    await tester.pumpAndSettle();
    expect(api.requests, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'pinned topics keep their chip while Your feeds prepares their results',
      (tester) async {
    await tester.runAsync(() async {
      await connect();
      await remember('video000001', 'Local science', 0);
    });
    final gate = Completer<List<Video>>();
    api.discoveryResults = (_) => gate.future;
    interestChips = [
      {
        'id': 'science',
        'label': 'Science',
        'queries': ['science videos']
      },
    ];
    await tester.runAsync(
        () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [
              HomeTabsLayout.yourFeeds,
              HomeTabsLayout.topicId('science'),
            ])));
    await show(tester, configuredFeed: const Text('Configured feed'));
    expect(find.text('Configured feed'), findsOneWidget);
    final topic = find.byKey(const ValueKey('flow-interest-science'));
    expect(tester.widget<ChoiceChip>(topic).onSelected, isNull);
    expect(find.byKey(const ValueKey('video-home-for-you')), findsNothing);
    expect((calls.single.arguments as Map)['candidates'],
        contains(predicate((dynamic value) => value['id'] == 'video000001')));
    expect(api.queries, ['science videos']);
    gate.complete(const [Video(videoId: 'science0001', title: 'Ready topic')]);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(topic).onSelected, isNotNull);
    await tester.ensureVisible(topic);
    await tester.tap(topic);
    await tester.pump();
    expect(find.text('Ready topic'), findsOneWidget);
    expect(api.requests, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'cold saved topic displays matching videos on its first active visit',
      (tester) async {
    api.discoveryResults = (query) => query == 'science videos'
        ? const [
            Video(videoId: 'science0001', title: 'Restored science result')
          ]
        : [];
    interestChips = [
      {
        'id': 'science',
        'label': 'Science',
        'queries': ['science videos']
      },
    ];
    await tester.runAsync(() async {
      await connect();
      await remember('video000001', 'Unfiltered local item', 0);
      await settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [
        HomeTabsLayout.topicId('science'),
      ]));
    });
    await show(tester, active: false);
    expect(calls, isEmpty);
    expect(api.requests, 0);
    await show(tester);
    final chip = find.byKey(const ValueKey('flow-interest-science'));
    expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
    expect(find.text('Unfiltered local item'), findsNothing);
    expect(find.text('Restored science result'), findsOneWidget);
    expect(find.text('Discover videos'), findsNothing);
    expect(api.requests, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'restored Discover loads once with a seed and retries a failed request',
      (tester) async {
    discoveryQueries = ['interesting stories'];
    await tester.runAsync(() async {
      await connect();
      await settings.setHomeTabsLayout(
          HomeTabsLayout(enabledOrder: [HomeTabsLayout.discover]));
    });
    api.discoveryResults = (_) => throw StateError('temporarily unavailable');
    await show(tester, active: false);
    expect(api.requests, 0);
    await show(tester);
    expect(api.requests, 1);
    final retry = find.text('Could not fetch videos. Tap to try again.');
    expect(retry, findsOneWidget);
    expect(find.byKey(const ValueKey('video-discovery-query')), findsNothing);
    playbackHistoryRevision.value++;
    await tester.pumpAndSettle();
    expect(api.requests, 1);
    api.discoveryResults = (query) => query == 'interesting stories'
        ? const [Video(videoId: 'stories0001', title: 'A discovered story')]
        : [];
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(api.requests, 2);
    expect(find.text('A discovered story'), findsOneWidget);
    await show(tester, active: false);
    await show(tester);
    expect(api.requests, 2);
    expect(find.text('A discovered story'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'covered or background Home waits to prepare Discover until visible',
      (tester) async {
    discoveryQueries = ['interesting stories'];
    await tester.runAsync(() async {
      await connect();
      await settings.setHomeTabsLayout(
          HomeTabsLayout(enabledOrder: [HomeTabsLayout.discover]));
    });
    await tester.runAsync(player.close);
    player = _HomePlayerCubit(
        PlayerState.init(null).copyWith(
            currentlyPlaying: const Video(videoId: 'playing0001'),
            isHidden: false,
            isMini: false),
        settings);
    final lifecycle = tester.binding.lifecycleState;
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(
        lifecycle ?? AppLifecycleState.detached));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await show(tester);
    expect(api.requests, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    player.showMiniPlayer();
    await tester.pumpAndSettle();
    expect(api.requests, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(api.requests, 1);
    player.showBigPlayer();
    await tester.pumpAndSettle();
    player.showMiniPlayer();
    await tester.pumpAndSettle();
    expect(api.requests, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'pausing during seed ranking defers the network lookup until resume',
      (tester) async {
    await tester.runAsync(() async {
      await connect();
      await settings.setHomeTabsLayout(
          HomeTabsLayout(enabledOrder: [HomeTabsLayout.discover]));
    });
    final pending = Completer<Map<String, Object?>>();
    final ranked = {
      'state': <String, Object?>{},
      'summary': {
        'discoveryQueries': ['saved interest']
      },
      'ranked': <Object?>[],
    };
    var rankings = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      rankings++;
      return rankings == 1 ? await pending.future : ranked;
    });
    final lifecycle = tester.binding.lifecycleState;
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(
        lifecycle ?? AppLifecycleState.detached));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await show(tester, settle: false);
    await tester.pump();
    expect(rankings, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    pending.complete(ranked);
    await tester.idle();
    expect(api.requests, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(api.requests, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('adding a topic keeps the selected Your feeds page',
      (tester) async {
    interestChips = [
      {
        'id': 'science',
        'label': 'Science',
        'queries': ['science videos']
      },
    ];
    await tester.runAsync(() => settings.setHomeTabsLayout(
        HomeTabsLayout(enabledOrder: [HomeTabsLayout.yourFeeds])));
    await show(tester, configuredFeed: const Text('Configured feed'));
    expect(calls, isEmpty);
    await tester.runAsync(
        () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [
              HomeTabsLayout.yourFeeds,
              HomeTabsLayout.topicId('science'),
            ])));
    await tester.pumpAndSettle();
    expect(find.text('Configured feed'), findsOneWidget);
    expect(find.byKey(const ValueKey('flow-interest-science')), findsOneWidget);
    expect(api.requests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final fallback in [HomeTabsLayout.forYou, HomeTabsLayout.yourFeeds]) {
    testWidgets('missing saved topic restores $fallback content',
        (tester) async {
      await tester.runAsync(() => remember('video000001', 'Local video', 0));
      await tester.runAsync(
          () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [
                HomeTabsLayout.topicId('missing'),
                fallback,
              ])));
      await show(tester, configuredFeed: const Text('Configured feed'));
      expect(
          find.text(fallback == HomeTabsLayout.forYou
              ? 'Local video'
              : 'Configured feed'),
          findsOneWidget);
      expect(api.requests, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('TV skips unsupported Your feeds and preserves empty recovery',
      (tester) async {
    await tester.runAsync(
        () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [
              HomeTabsLayout.yourFeeds,
              HomeTabsLayout.forYou,
            ])));
    await tester.runAsync(() => remember('video000001', 'Local video', 0));
    await show(tester, television: true);
    expect(find.text('Local video'), findsOneWidget);
    await tester.runAsync(
        () => settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [])));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-tabs-edit')), findsOneWidget);
    expect(find.text('Local video'), findsNothing);
    expect(Focus.of(tester.element(find.byIcon(Icons.edit))).hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('For you alone ranks local metadata without loading remote feeds',
      (tester) async {
    await tester.runAsync(() async {
      await remember('video000001', 'Local video', 0);
      await settings.setHomeTabsLayout(
          HomeTabsLayout(enabledOrder: [HomeTabsLayout.forYou]));
    });
    await show(tester);
    expect(api.requests, 0);
    expect(calls, isNotEmpty);
    expect(find.text('Local video'), findsOneWidget);
    expect(find.text('Discover videos'), findsNothing);
    final card = find.byKey(const ValueKey('flow-video-video000001'));
    final overflow = find.descendant(
      of: card,
      matching: find.byIcon(Icons.more_vert),
    );
    await tester.tap(overflow);
    await tester.pumpAndSettle();
    expect(find.text('Why this?'), findsOneWidget);
    await tester.tap(find.text('Why this?'));
    await tester.pumpAndSettle();
    expect(find.text('Matches your local video interests.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('only cards with active viewport dwell count as impressions',
      (tester) async {
    await tester.runAsync(() async {
      for (var index = 1; index <= 8; index++) {
        await remember('candidate0$index', 'Candidate $index', 0);
      }
    });
    final lifecycle = tester.binding.lifecycleState;
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(
        lifecycle ?? AppLifecycleState.detached));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await show(tester);
    VisibilityDetectorController.instance.notifyNow();
    final viewport = tester.getRect(find.byType(CustomScrollView).first);
    final halfVisibleIds = <String>{};
    for (var index = 1; index <= 8; index++) {
      final id = 'candidate0$index';
      final card = find.byKey(ValueKey('flow-video-$id'));
      if (card.evaluate().isEmpty) continue;
      final bounds = tester.getRect(card);
      final visible = bounds.intersect(viewport);
      if (visible.width > 0 && visible.height * 2 >= bounds.height) {
        halfVisibleIds.add(id);
      }
    }
    expect(halfVisibleIds, isNotEmpty);
    expect(halfVisibleIds.length, lessThan(8));

    Iterable<String> impressions() sync* {
      for (final call in calls) {
        final events = (call.arguments as Map)['events'] as List? ?? const [];
        for (final event in events.whereType<Map>()) {
          if (event['type'] == 'impression') {
            yield (event['candidate'] as Map)['id'] as String;
          }
        }
      }
    }

    await tester.pump(const Duration(milliseconds: 750));
    expect(impressions(), isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 500));
    expect(impressions(), isEmpty);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    VisibilityDetectorController.instance.notifyNow();
    await tester.pump(const Duration(milliseconds: 700));
    final feed = find.byKey(const PageStorageKey('flow-video-home'));
    final controller = tester.widget<CustomScrollView>(feed).controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump(const Duration(milliseconds: 16));
    controller.jumpTo(0);
    await tester.pump(const Duration(milliseconds: 16));
    // Leaving and re-entering within a detector batching interval starts a
    // fresh dwell, even though these cards are back in their original places.
    await tester.pump(const Duration(milliseconds: 600));
    expect(impressions(), isEmpty);
    controller.jumpTo(2);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 80));
    expect(impressions().toSet(), halfVisibleIds);
    expect(impressions().length, halfVisibleIds.length);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('For You records impressions after a reset on Your Feeds',
      (tester) async {
    await tester.runAsync(() async {
      await remember('video000001', 'Local video', 0);
      await settings.setHomeTabsLayout(HomeTabsLayout(enabledOrder: [
        HomeTabsLayout.forYou,
        HomeTabsLayout.yourFeeds,
      ]));
    });
    final lifecycle = tester.binding.lifecycleState;
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(
        lifecycle ?? AppLifecycleState.detached));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    await show(tester, configuredFeed: const Text('Configured feed'));
    await tester.tap(find.byKey(const ValueKey('video-home-your-feeds')));
    await tester.pumpAndSettle();
    expect(find.text('Configured feed'), findsOneWidget);
    await tester.runAsync(() async {
      await RecommendationService.forProfile(db, db.profileId)
          .reset(RecommendationDomain.video);
    });
    await tester.pumpAndSettle();
    calls.clear();

    await tester.tap(find.byKey(const ValueKey('video-home-for-you')));
    await tester.pumpAndSettle();
    expect(find.text('Local video'), findsOneWidget);
    VisibilityDetectorController.instance.notifyNow();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 80));

    final recordings = calls
        .expand(
            (call) => (call.arguments as Map)['events'] as List? ?? const [])
        .whereType<Map>()
        .where((event) => event['type'] == 'impression')
        .map((event) => (event['candidate'] as Map)['id']);
    expect(recordings, ['video000001']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('empty local history gives an explicit discovery action',
      (tester) async {
    await show(tester);
    expect(api.requests, 0);
    expect(
        find.text('Watch or save videos to shape your local recommendations.'),
        findsOneWidget);
    final manualSearch = find.byKey(const ValueKey('video-home-discover'));
    expect(
        find.descendant(
            of: manualSearch, matching: find.text('Search a topic')),
        findsOneWidget);
    await tester.ensureVisible(manualSearch);
    await tester.tap(manualSearch);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('video-discovery-query')), findsOneWidget);
    expect(api.requests, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'For you uses existing follows before playback and drops unfollows',
      (tester) async {
    const server = Server(url: 'https://invidious.example');
    const channelId = 'UCaaaaaaaaaaaaaaaaaaaaaa';
    await tester.runAsync(() async {
      await db.upsertServer(server);
      await db.useServer(server);
      await db.addOfflineSubscription(const OfflineSubscription(
          channelId: channelId, channelName: 'Existing follow'));
    });
    // Make the active session visible to the same guarded source on device.
    app.setServer(server);
    api.discoveryResults = (_) => const [
          Video(
              videoId: 'followed001',
              title: 'Video from an existing follow',
              authorId: channelId),
        ];
    await show(tester);
    expect(api.requests, 1);
    expect(find.text('Video from an existing follow'), findsOneWidget);
    final warmed = calls.last.arguments as Map;
    expect(warmed['subscriptionChannels'], [
      {'id': channelId, 'name': 'Existing follow'},
    ]);
    expect(warmed['events'], isEmpty);

    await tester.runAsync(() => db.deleteOfflineSubscription(channelId));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(api.requests, 1);
    expect(find.text('Video from an existing follow'), findsNothing);
    expect((calls.last.arguments as Map)['subscriptionChannels'], isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('late subscription videos stay below visible For You cards',
      (tester) async {
    const channelId = 'UCaaaaaaaaaaaaaaaaaaaaaa';
    const lateId = 'followed001';
    final localIds = List.generate(
        12, (index) => 'local${index.toString().padLeft(6, '0')}');
    await tester.runAsync(() async {
      await connect();
      await db.addOfflineSubscription(const OfflineSubscription(
          channelId: channelId, channelName: 'Existing follow'));
      await settings.setHomeTabsLayout(
          HomeTabsLayout(enabledOrder: [HomeTabsLayout.forYou]));
      for (final id in localIds) {
        await remember(id, 'Local video $id', 0);
      }
    });
    final uploads = Completer<List<Video>>();
    final ranking = Completer<void>();
    final finishRanking = Completer<void>();
    addTearDown(() {
      if (!uploads.isCompleted) uploads.complete(const []);
      if (!finishRanking.isCompleted) finishRanking.complete();
    });
    api.discoveryResults = (_) => uploads.future;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final candidates = (call.arguments as Map)['candidates'] as List;
      final ids = candidates.map((item) => (item as Map)['id']).toList();
      if (ids.remove(lateId)) {
        ids.insert(0, lateId);
        if (!ranking.isCompleted) ranking.complete();
        await finishRanking.future;
      }
      return {
        'state': <String, Object?>{},
        'ranked': [
          for (final id in ids) {'id': id, 'score': 1.0, 'reason': 'Local'}
        ]
      };
    });

    await show(tester, disableAnimations: true);
    expect(api.requests, 1, reason: 'The subscription upload is pending.');
    final feed = find.byKey(const PageStorageKey('flow-video-home'));
    final scrollable =
        find.descendant(of: feed, matching: find.byType(Scrollable));
    final controller = tester.widget<CustomScrollView>(feed).controller!;
    Finder card(String id) => find.byKey(ValueKey('flow-video-$id'));

    await tester.drag(feed, const Offset(0, -630));
    await tester.pumpAndSettle();
    final offset = controller.offset;
    expect(offset, greaterThan(0));
    final viewport = tester.getRect(feed);
    Map<String, Rect> visibleCardBounds() {
      final bounds = <String, Rect>{};
      for (final id in localIds) {
        final finder = card(id);
        if (finder.evaluate().isEmpty) continue;
        final rect = tester.getRect(finder);
        if (rect.overlaps(viewport)) bounds[id] = rect;
      }
      return bounds;
    }

    final before = visibleCardBounds();
    expect(before.length, greaterThanOrEqualTo(2));
    expect(before.length, lessThan(localIds.length));

    uploads.complete(const [
      Video(
          videoId: lateId,
          title: 'Late subscription video',
          authorId: channelId),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(ranking.isCompleted, isTrue);
    final whileRanking = visibleCardBounds();
    final pendingOffset = controller.offset;

    finishRanking.complete();
    await tester.pumpAndSettle();
    expect(visibleCardBounds(), before,
        reason: 'An arriving upload must not move any visible cards.');
    expect(controller.offset, offset);
    expect(whileRanking, before,
        reason: 'The background rank must not shift the feed while pending.');
    expect(pendingOffset, offset);

    final lateCard = card(lateId);
    if (lateCard.evaluate().isNotEmpty) {
      expect(
          tester.getRect(lateCard).top, greaterThanOrEqualTo(viewport.bottom));
    }
    await tester.scrollUntilVisible(lateCard, 180, scrollable: scrollable);
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(offset));
    expect(tester.getRect(lateCard).overlaps(viewport), isTrue);

    controller.jumpTo(0);
    await tester.pumpAndSettle();
    final refresh =
        tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
    final refreshed = refresh.onRefresh();
    await tester.pumpAndSettle();
    await refreshed;
    expect(lateCard, findsOneWidget);
    expect(tester.getTopLeft(lateCard).dy, viewport.top);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('missing native engine shows unranked local items honestly',
      (tester) async {
    await tester.runAsync(() => remember('video000001', 'Local video', 0));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel, (_) async => throw MissingPluginException());
    await show(tester);
    expect(find.text('Local video'), findsOneWidget);
    expect(find.text('Why this?'), findsNothing);
    final locals =
        AppLocalizations.of(tester.element(find.byType(FlowVideoHome)))!;
    expect(find.text(locals.flowRecommendationUnavailable), findsOneWidget);
    expect(api.requests, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('prepared discovery admits subscribed videos with a full history',
      (tester) async {
    const account =
        Server(url: 'https://invidious.example', authToken: 'test-only');
    await tester.runAsync(() async {
      await db.upsertServer(account);
      await db.useServer(account);
      for (var i = 0; i < 80; i++) {
        await remember('local${i.toString().padLeft(6, '0')}', 'Local $i', 0);
      }
    });
    app.setServer(account);
    api.follows = [
      Subscription('Followed creator', 'UCaaaaaaaaaaaaaaaaaaaaaa')
    ];
    discoveryQueries = ['first interest', 'second interest'];
    api.discoveryResults = (query) {
      if (query == null) {
        return const [
          Video(
              videoId: 'followed001',
              title: 'Followed video',
              authorId: 'UCaaaaaaaaaaaaaaaaaaaaaa'),
        ];
      }
      final prefix = query == discoveryQueries.first ? 'first' : 'other';
      return [
        for (var i = 0; i < 20; i++)
          Video(
              videoId: '$prefix${i.toString().padLeft(6, '0')}',
              title: 'Discovery result $i'),
      ];
    };
    await show(tester);
    final rankedPools =
        calls.map((call) => (call.arguments as Map)['candidates'] as List);
    expect(rankedPools.any((pool) => pool.length == 81), isTrue);
    expect(api.requests, 3);
    await tester
        .ensureVisible(find.byKey(const ValueKey('video-home-discover')));
    await tester.tap(find.byKey(const ValueKey('video-home-discover')));
    await tester.pumpAndSettle();
    expect(api.requests, 3);
    final ranked = (calls.last.arguments as Map)['candidates'] as List;
    expect(ranked, hasLength(100));
    expect(
        ranked
            .whereType<Map>()
            .singleWhere((row) => row['id'] == 'followed001')['isSubscribed'],
        isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('For You and Discover keep their card delegate during scroll',
      (tester) async {
    await tester.runAsync(() async {
      await connect();
      for (var i = 0; i < 6; i++) {
        await remember('local00000$i', 'Local $i', 0);
      }
    });
    discoveryQueries = ['discover music'];
    api.discoveryResults = (_) => [
          for (var i = 0; i < 6; i++)
            Video(videoId: 'found00000$i', title: 'Found $i'),
        ];

    await show(tester, disableAnimations: true);
    final feed = find.byKey(const PageStorageKey('flow-video-home'));
    final list = find.descendant(of: feed, matching: find.byType(SliverList));
    final controller = tester.widget<CustomScrollView>(feed).controller!;

    Future<void> verifyScroll() async {
      final delegate = tester.widget<SliverList>(list).delegate;
      final next = controller.offset + 12;
      controller.jumpTo(next);
      await tester.pump();
      expect(controller.offset, next);
      expect(tester.widget<SliverList>(list).delegate, same(delegate));
    }

    await verifyScroll();
    final discover = find.byKey(const ValueKey('video-home-discover'));
    await tester.ensureVisible(discover);
    await tester.tap(discover);
    await tester.pumpAndSettle();
    final forYou = find.byKey(const ValueKey('video-home-for-you'));
    expect(tester.widget<ChoiceChip>(forYou).selected, isFalse);
    expect(api.queries, contains('discover music'));
    await verifyScroll();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('deactivating Home discards a pending local ranking',
      (tester) async {
    await tester.runAsync(() => remember('video000001', 'Local video', 0));
    final pending = Completer<Map<String, Object?>>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) => pending.future);
    await show(tester, settle: false);
    await tester.pump();
    await show(tester, active: false);
    pending.complete({
      'state': <String, Object?>{},
      'ranked': [
        {'id': 'video000001', 'score': 1.0, 'reason': 'Old result'}
      ]
    });
    await tester.pumpAndSettle();
    expect(find.text('Local video'), findsNothing);
    expect(find.text('Why this?'), findsNothing);
    expect(api.requests, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('small phone with large text keeps resumed cards scrollable',
      (tester) async {
    await tester.runAsync(() =>
        settings.setHomeTabsLayout(HomeTabsLayout(continueWatching: true)));
    await tester.runAsync(
        () => remember('resume00001', 'Resume a long video title', 0.4));
    await show(tester, scale: 2);
    expect(find.text('Continue watching'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TV reranking keeps D-pad targets matched to displayed cards',
      (tester) async {
    await tester.runAsync(() async {
      await remember('video000001', 'First video', 0);
      await remember('video000002', 'Second video', 0);
    });
    var reverse = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final candidates = (call.arguments as Map)['candidates'] as List;
      return {
        'state': <String, Object?>{},
        'ranked': [
          for (final candidate in reverse ? candidates.reversed : candidates)
            {'id': (candidate as Map)['id'], 'score': 1.0, 'reason': 'Local'}
        ],
      };
    });
    await show(tester, television: true);
    final before = tester
        .widgetList<TvVideoItem>(find.byType(TvVideoItem))
        .map((card) => card.video.videoId)
        .toList();
    expect(before, hasLength(2));
    reverse = true;
    await tester.runAsync(() =>
        RecommendationService.forProfile(db, db.profileId)
            .setLearningEnabled(RecommendationDomain.video, true));
    await tester.pump();
    // Database notifications launch work in the real async zone. Let the
    // mocked platform reply return there before settling animation frames.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    final cards = tester.widgetList<TvVideoItem>(find.byType(TvVideoItem));
    expect(cards.map((card) => card.video.videoId), before.reversed);
    for (final card in cards) {
      final builder = find.descendant(
          of: find.byWidget(card),
          matching:
              find.byType(BlocBuilder<VideoInListCubit, VideoInListState>));
      // TvVideoItem's D-pad handler opens this cubit's retained video.
      final target =
          tester.element(builder).read<VideoInListCubit>().state.video;
      expect(target?.videoId, card.video.videoId);
      expect(target?.title, card.video.title);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final feedback in [
    RecommendationFeedback.notInterested,
    RecommendationFeedback.block,
  ]) {
    testWidgets('${feedback.name} excludes cards before reranking completes',
        (tester) async {
      const authorId = 'UCaaaaaaaaaaaaaaaaaaaaaa';
      const excluded = 'Exclude this video';
      const kept = 'Keep this video';
      const sameCreator = 'Another video from this creator';
      await tester.runAsync(() async {
        await remember('video000001', excluded, 0, authorId: authorId);
        await remember('video000002', kept, 0);
        await remember('video000003', sameCreator, 0, authorId: authorId);
      });
      await show(tester, television: true);
      expect(find.text(excluded), findsOneWidget);
      expect(find.text(kept), findsOneWidget);
      expect(find.text(sameCreator), findsOneWidget);
      final pending = Completer<Map<String, Object?>>();
      addTearDown(() {
        if (!pending.isCompleted) {
          pending
              .complete({'state': <String, Object?>{}, 'ranked': <Object?>[]});
        }
      });
      var waiting = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final events = (call.arguments as Map)['events'] as List;
        if (events.isNotEmpty) {
          return {'state': <String, Object?>{}, 'ranked': <Object?>[]};
        }
        waiting = true;
        return pending.future;
      });
      await tester.runAsync(() =>
          RecommendationService.forProfile(db, db.profileId).feedback(
              const Video(
                  videoId: 'video000001', title: excluded, authorId: authorId),
              RecommendationDomain.video,
              feedback));
      await tester.pump();
      await tester.pump();
      expect(waiting, isTrue);
      expect(find.text(excluded), findsNothing);
      expect(find.text(kept), findsOneWidget);
      expect(
          find.text(sameCreator),
          feedback == RecommendationFeedback.block
              ? findsNothing
              : findsOneWidget);
      pending.complete({
        'state': <String, Object?>{},
        'ranked': [
          {'id': 'video000002', 'score': 1.0, 'reason': 'Local'},
        ],
      });
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.text(sameCreator), findsNothing,
          reason: 'The native rank can suppress the rest of the creator.');
      expect(find.text(kept), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
