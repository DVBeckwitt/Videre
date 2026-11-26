import 'dart:async';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/network/content_link.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_load_session.dart';
import 'package:clipious/router.dart';
import 'package:clipious/search/states/search.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/models/timestamp_linkifier.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/views/components/text_linkified.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../test_settings_cubit.dart';
import '../test_player_cubit.dart';

class _LinkApp extends AppCubit {
  _LinkApp() : super(AppState(0, null, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  onReady() {}

  @override
  initState() {}

  void requireSessionRecovery() {
    emit(state.copyWith(sessionRecoveryRequired: true));
  }

  void selectForLinkDisplay(Server server) =>
      emit(state.copyWith(server: server));
}

class _LinkPlayer implements PlayerCubit {
  @override
  final PlayerState state;
  Duration? sought;

  _LinkPlayer(this.state);

  @override
  void seek(Duration duration) => sought = duration;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _RecordingRouter extends AppRouter {
  _RecordingRouter() : super(hasServer: true);

  PageRouteInfo? pushed;
  bool fail = false;
  int pushes = 0;

  @override
  Future<T?> push<T extends Object?>(PageRouteInfo route,
      {OnNavigationFailure? onFailure}) async {
    if (fail) throw StateError('navigation failed');
    pushed = route;
    pushes++;
    return null;
  }
}

class _DeferredLinkApp extends AppCubit {
  _DeferredLinkApp() : super(AppState(0, null, HomeLayout()));

  final ready = Completer<void>();

  @override
  Future<void> initState() async {
    await ready.future;
    await super.initState();
  }
}

class _AndroidLinkInbox {
  static const _channel = MethodChannel('videre/incoming_links');
  final _messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final _pending = <Map<String, Object>>[];
  int consumed = 0;

  _AndroidLinkInbox() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    _messenger.setMockMethodCallHandler(_channel, (call) async {
      expect(call.method, 'takePending');
      final batch = _pending.reversed.toList();
      _pending.clear();
      consumed += batch.length;
      return batch;
    });
    final originalService = service;
    service = _IncomingLinkService();
    addTearDown(() {
      _messenger.setMockMethodCallHandler(_channel, null);
      debugDefaultTargetPlatformOverride = null;
      service = originalService;
    });
  }

  void stage(String text, {bool share = false, bool initial = false}) {
    if (_pending.length == 16) _pending.removeAt(0);
    _pending.add({'text': text, 'share': share, 'initial': initial});
  }

  Future<void> notify() async {
    final reply = await _messenger.handlePlatformMessage(
        _channel.name,
        _channel.codec.encodeMethodCall(const MethodCall('linksAvailable')),
        null);
    expect(_channel.codec.decodeEnvelope(reply!), isNull);
    await Future<void>.delayed(Duration.zero);
  }
}

class _PlaylistService extends Service {
  final requests = <String>[];

  @override
  Future<Playlist> getPublicPlaylists(String playlistId,
      {int? page,
      bool saveLastSeen = true,
      Server? serverOverride,
      bool enrichResults = true}) async {
    requests.add(playlistId);
    return Playlist(
        title: 'Loaded playlist',
        playlistId: playlistId,
        author: 'Channel',
        videoCount: 0);
  }
}

class _IncomingLinkService extends Service {
  @override
  Future<void> syncHistory() async {}

  @override
  Future<ContentLink?> resolveContentLink(ContentLink link,
          {required Server server, bool Function()? isCurrent}) async =>
      null;
}

class _DeferredResolver extends _IncomingLinkService {
  final requests =
      <({ContentLink link, Server server, Completer<ContentLink?> reply})>[];

  @override
  Future<ContentLink?> resolveContentLink(ContentLink link,
      {required Server server, bool Function()? isCurrent}) {
    final reply = Completer<ContentLink?>();
    requests.add((link: link, server: server, reply: reply));
    return reply.future;
  }
}

Future<void> _expectPlaylistLoads(
    Playlist playlist, PlaylistReference? reference) async {
  final service = _PlaylistService();
  final loader = PlaylistLoadSession(
      playlist: playlist,
      reference: reference,
      database: db,
      playlistService: service);
  addTearDown(loader.release);
  final completed = loader.changes.firstWhere((snapshot) => !snapshot.loading);
  loader.retain();
  await completed;
  expect(service.requests, [playlist.playlistId]);
  expect(loader.playlist.title, 'Loaded playlist');
  expect(loader.error, isNull);
}

Future<void> _waitForRoute(String name, {StackRouter? router}) async {
  final active = router ?? appRouter;
  for (var attempt = 0; attempt < 100; attempt++) {
    if (active.current.name == name) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Expected $name, got ${active.current.name}');
}

void _expectMusicArgs(MusicRouteArgs args, String kind, String id,
    {Duration startAt = Duration.zero}) {
  expect(args.videoId, kind == 'song' ? id : isNull);
  expect(args.playlistId, kind == 'playlist' ? id : isNull);
  expect(args.artistId, kind == 'artist' ? id : isNull);
  expect(args.startAt, startAt);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _LinkApp app;
  late bool originalTv;
  late Service initialService;

  setUp(() async {
    initialService = service;
    service = _IncomingLinkService();
    originalTv = app_globals.isTv;
    db = await createPlayerTestDatabase();
    await db.upsertServer(
        const Server(url: 'https://instance.example', inUse: true));
    app_globals.isTv = true;
    appRouter = AppRouter(hasServer: true);
    app = _LinkApp();
  });

  tearDown(() async {
    appRouter.dispose();
    await app.close();
    await db.close();
    app_globals.isTv = originalTv;
    service = initialService;
  });

  test('link timestamps preserve zero, units and absent positions', () {
    for (final (query, expected) in [
      ('', null),
      ('?t=0', Duration.zero),
      ('?t=42', const Duration(seconds: 42)),
      ('?t=1h2m3s', const Duration(seconds: 3723)),
      ('?start=42', const Duration(seconds: 42)),
      ('?time_continue=42', const Duration(seconds: 42)),
      ('#t=1m15s', const Duration(seconds: 75)),
      ('?t=bad', null),
      ('?t=-1', null),
    ]) {
      expect(
          ContentLink.parseAddress('https://youtu.be/dQw4w9WgXcQ$query')!
              .startAt,
          expected);
    }
  });

  test('attribution wrappers unwrap only bounded relative content paths', () {
    String wrap(String target) =>
        Uri.https('youtube.com', '/attribution_link', {'u': target}).toString();
    const target = '/watch?v=dQw4w9WgXcQ&t=42';
    final wrapped = wrap(target);
    String relative(String address) {
      final uri = Uri.parse(address);
      return '${uri.path}?${uri.query}';
    }

    final twice = wrap(relative(wrapped));
    expect(ContentLink.parseAddress(wrapped)!.startAt,
        const Duration(seconds: 42));
    expect(ContentLink.parseAddress(twice)!.id, 'dQw4w9WgXcQ');
    for (final address in [
      wrap('https://outside.example/watch?v=dQw4w9WgXcQ'),
      wrap('//outside.example/watch?v=dQw4w9WgXcQ'),
      wrap(relative(twice)),
      'https://youtube.com:8443/@example',
    ]) {
      expect(ContentLink.parseAddress(address), isNull);
    }
  });

  test('only the selected instance origin and base path provide content IDs',
      () {
    const selected = Server(url: 'https://instance.example:8443/iv');
    final video = ContentLink.parseAddress(
        'https://instance.example:8443/iv/watch?v=dQw4w9WgXcQ&t=90',
        server: selected)!;
    expect(video.kind, ContentLinkKind.video);
    expect(video.id, 'dQw4w9WgXcQ');
    expect(video.startAt, const Duration(seconds: 90));
    expect(
        ContentLink.parseAddress(
                'https://instance.example:8443/iv/playlist?list=PL_123',
                server: selected)!
            .kind,
        ContentLinkKind.playlist);
    expect(
        ContentLink.parseAddress(
                'https://instance.example:8443/iv/channel/UC_kRDKYrUlrbtrSiyu5Tflg',
                server: selected)!
            .kind,
        ContentLinkKind.channel);
    for (final address in [
      'https://other.example:8443/iv/watch?v=dQw4w9WgXcQ',
      'https://instance.example:8444/iv/watch?v=dQw4w9WgXcQ',
      'http://instance.example:8443/iv/watch?v=dQw4w9WgXcQ',
      'https://instance.example:8443/iv-extra/watch?v=dQw4w9WgXcQ',
      'https://instance.example:8443/watch?v=dQw4w9WgXcQ',
      'https://user@instance.example:8443/iv/watch?v=dQw4w9WgXcQ',
      'https://instance.example:8443/iv/redirect?url=https://youtu.be/dQw4w9WgXcQ',
    ]) {
      expect(ContentLink.parseAddress(address, server: selected), isNull,
          reason: address);
    }
    expect(
        ContentLink.parseAddress(
            'https://instance.example:8443/iv/watch?v=dQw4w9WgXcQ'),
        isNull);
  });

  for (final initial in [true, false]) {
    test(
        'Android instance share waits for restored session (initial: $initial)',
        () async {
      final inbox = _AndroidLinkInbox();
      inbox.stage(
          'Saved clip: https://instance.example/watch?v=dQw4w9WgXcQ&t=12',
          share: true,
          initial: initial);
      final receiver = _DeferredLinkApp();
      addTearDown(receiver.close);
      await Future<void>.delayed(Duration.zero);
      expect(inbox.consumed, 1);
      expect(appRouter.hasEntries, isFalse);
      receiver.ready.complete();
      await _waitForRoute(TvVideoRoute.name);
      expect(
          appRouter.current.argsAs<TvVideoRouteArgs>().videoId, 'dQw4w9WgXcQ');
      expect(appRouter.current.argsAs<TvVideoRouteArgs>().startAt,
          const Duration(seconds: 12));
      expect(receiver.state.server?.url, 'https://instance.example');
    });
  }

  test('a cold instance share cannot choose a server while startup is pending',
      () async {
    final inbox = _AndroidLinkInbox();
    inbox.stage('https://other.example/watch?v=dQw4w9WgXcQ',
        share: true, initial: true);
    final receiver = _DeferredLinkApp();
    addTearDown(receiver.close);
    await Future<void>.delayed(Duration.zero);
    receiver.ready.complete();
    await receiver.stream.firstWhere((state) => state.server != null);
    await Future<void>.delayed(Duration.zero);
    expect(appRouter.hasEntries, isFalse);
    expect(receiver.state.server?.url, 'https://instance.example');
  });

  for (final validInstance in [false, true]) {
    test(
        'cold pending opens retain recognized fallback (new instance valid: $validInstance)',
        () async {
      final inbox = _AndroidLinkInbox();
      inbox.stage('https://youtu.be/dQw4w9WgXcQ?t=42', initial: true);
      final receiver = _DeferredLinkApp();
      addTearDown(receiver.close);
      await Future<void>.delayed(Duration.zero);
      expect(inbox.consumed, 1);
      inbox.stage('Unrelated text', share: true);
      await inbox.notify();
      final host = validInstance ? 'instance.example' : 'other.example';
      inbox.stage('https://$host/watch?v=nextvideo01&t=21', share: true);
      await inbox.notify();
      expect(inbox.consumed, 3);
      receiver.ready.complete();
      await _waitForRoute(TvVideoRoute.name);
      final args = appRouter.current.argsAs<TvVideoRouteArgs>();
      expect(args.videoId, validInstance ? 'nextvideo01' : 'dQw4w9WgXcQ');
      expect(args.startAt, Duration(seconds: validInstance ? 21 : 42));
    });
  }

  test('warm shares and pasted instance links preserve timestamps internally',
      () async {
    final inbox = _AndroidLinkInbox();
    appRouter.dispose();
    final router = _RecordingRouter();
    appRouter = router;
    await router.replaceAll([const TvHomeRoute()]);
    final receiver = AppCubit(AppState(0, null, HomeLayout()));
    addTearDown(receiver.close);
    await receiver.stream.firstWhere((state) => state.server != null);
    inbox.stage('Video: https://instance.example/watch?v=dQw4w9WgXcQ&t=0',
        share: true);
    await inbox.notify();
    expect((router.pushed!.args as TvVideoRouteArgs).startAt, Duration.zero);
    expect(router.pushes, 1);
    expect(
        await receiver.submitPastedAppLink(
            'https://instance.example/watch?v=dQw4w9WgXcQ&t=1m15s'),
        PastedLinkAction.handled);
    expect((router.pushed!.args as TvVideoRouteArgs).startAt,
        const Duration(seconds: 75));
    expect(router.pushes, 2);
    expect(
        await receiver
            .submitPastedAppLink('https://other.example/watch?v=dQw4w9WgXcQ'),
        PastedLinkAction.handled);
    expect(router.pushes, 2);
  });

  test('saved Invidious addresses use the search domain and selected account',
      () async {
    const selected = Server(url: 'https://instance.example', inUse: true);
    const saved = Server(url: 'https://saved.example:8443/iv');
    await db.upsertServer(saved);
    app.selectForLinkDisplay(selected);
    appRouter.dispose();
    final router = _RecordingRouter();
    appRouter = router;
    for (final base in [selected.url, saved.url]) {
      final watch = '$base/watch?v=dQw4w9WgXcQ&t=37';
      await app.submitPastedAppLink(watch);
      final video = (router.pushed! as TvVideoRoute).args!;
      expect(video.videoId, 'dQw4w9WgXcQ');
      expect(video.startAt, const Duration(seconds: 37));
      await app.submitPastedAppLink(watch, music: true);
      _expectMusicArgs(
          (router.pushed! as MusicRoute).args!, 'song', 'dQw4w9WgXcQ',
          startAt: const Duration(seconds: 37));
      await app.submitPastedAppLink('$base/playlist?list=PLmix', music: true);
      _expectMusicArgs(
          (router.pushed! as MusicRoute).args!, 'playlist', 'PLmix');
      await app.submitPastedAppLink('$base/channel/UC_kRDKYrUlrbtrSiyu5Tflg',
          music: true);
      _expectMusicArgs((router.pushed! as MusicRoute).args!, 'artist',
          'UC_kRDKYrUlrbtrSiyu5Tflg');
    }
    expect(app.state.server, selected);
    expect((await db.getCurrentlySelectedServer()).url, selected.url);
    expect(router.pushes, 8);
  });

  test('Music paste honors zero timestamps and explicit source domains',
      () async {
    app.selectForLinkDisplay(const Server(url: 'https://instance.example'));
    appRouter.dispose();
    final router = _RecordingRouter();
    appRouter = router;
    const watch = '/watch?v=dQw4w9WgXcQ&t=0';
    await app.submitPastedAppLink('https://instance.example$watch',
        music: true);
    _expectMusicArgs(
        (router.pushed! as MusicRoute).args!, 'song', 'dQw4w9WgXcQ');
    await app.submitPastedAppLink('https://www.youtube.com$watch', music: true);
    final video = (router.pushed! as TvVideoRoute).args!;
    expect(video.videoId, 'dQw4w9WgXcQ');
    expect(video.startAt, Duration.zero);
    await app.submitPastedAppLink('https://music.youtube.com$watch');
    _expectMusicArgs(
        (router.pushed! as MusicRoute).args!, 'song', 'dQw4w9WgXcQ');
    const uploads = 'UU_kRDKYrUlrbtrSiyu5Tflg';
    await app.submitPastedAppLink(
        'https://instance.example/playlist?list=$uploads',
        music: true);
    expect(
        (router.pushed! as TvPlaylistRoute).args!.playlist.playlistId, uploads);
    expect(router.pushes, 4);
  });

  test('an instance saved by another profile requires an explicit choice',
      () async {
    final other = await db.createProfile('Other listener');
    await db.forProfile(other.id).upsertServer(
        Server(url: 'https://other.example', profileId: other.id));
    app.selectForLinkDisplay(const Server(url: 'https://instance.example'));
    appRouter.dispose();
    final router = _RecordingRouter();
    appRouter = router;
    var prompts = 0;
    final outcome = await app.submitPastedAppLink(
        'https://other.example/channel/UC_kRDKYrUlrbtrSiyu5Tflg',
        chooseOpen: () async {
      prompts++;
      return false;
    });
    expect(outcome, PastedLinkAction.searchAsText);
    expect(prompts, 1);
    expect(router.pushes, 0);
  });

  test('changing the selected server dismisses a pending paste result',
      () async {
    app.selectForLinkDisplay(const Server(url: 'https://instance.example'));
    appRouter.dispose();
    final router = _RecordingRouter();
    appRouter = router;
    final asked = Completer<void>();
    final answer = Completer<bool?>();
    final submitted = app.submitPastedAppLink(
        'https://foreign.example/watch?v=dQw4w9WgXcQ', chooseOpen: () {
      asked.complete();
      return answer.future;
    });
    await asked.future;
    app.selectForLinkDisplay(const Server(url: 'https://new.example'));
    answer.complete(true);
    expect(await submitted, PastedLinkAction.handled);
    expect(router.pushes, 0);
  });

  test('unfamiliar addresses offer opening only for canonical content IDs',
      () async {
    app.selectForLinkDisplay(const Server(url: 'https://instance.example'));
    for (final address in [
      'https://foreign.example/watch?v=invalid',
      'https://foreign.example/channel/%ff',
      'https://foreign.example/watch?v=%ff',
      'https://foreign.example/@creator',
      'https://foreign.example/search?q=music',
      'https://foreign.example/redirect?u=https://youtu.be/dQw4w9WgXcQ',
      'https://someone@foreign.example/watch?v=dQw4w9WgXcQ',
      'words around https://foreign.example/watch?v=dQw4w9WgXcQ',
    ]) {
      expect(
          await app.submitPastedAppLink(address,
              chooseOpen: () => fail('Unexpected opening prompt for $address')),
          PastedLinkAction.unrecognized,
          reason: address);
    }
  });

  testWidgets('Music search asks before opening an unfamiliar watch link',
      (tester) async {
    app_globals.isTv = false;
    app.selectForLinkDisplay(const Server(url: 'https://instance.example'));
    appRouter.dispose();
    final router = _RecordingRouter();
    appRouter = router;
    final settings = TestSettingsCubit(SettingsState.init(), app);
    final player = TestPlayerCubit(PlayerState.init(null), settings);
    addTearDown(settings.close);
    addTearDown(player.close);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
        BlocProvider<PlayerCubit>.value(value: player),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const MusicScreen(),
      ),
    ));
    await tester.enterText(find.byKey(const ValueKey('music-search')),
        'https://foreign.example/watch?v=dQw4w9WgXcQ&t=42');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(router.pushes, 0);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Open on current instance'));
    await tester.pumpAndSettle();
    expect(router.pushes, 1);
    _expectMusicArgs(
        (router.pushed! as MusicRoute).args!, 'song', 'dQw4w9WgXcQ',
        startAt: const Duration(seconds: 42));
    expect(app.state.server?.url, 'https://instance.example');
    expect(db.getSearchHistory(), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
      'cold instance candidate survives unrelated shares before session restore',
      () async {
    final inbox = _AndroidLinkInbox();
    inbox.stage('https://instance.example/watch?v=dQw4w9WgXcQ&t=18',
        share: true, initial: true);
    final receiver = _DeferredLinkApp();
    addTearDown(receiver.close);
    await Future<void>.delayed(Duration.zero);
    expect(inbox.consumed, 1);
    inbox.stage('Unrelated shared text', share: true);
    await inbox.notify();
    receiver.ready.complete();
    await _waitForRoute(TvVideoRoute.name);
    final args = appRouter.current.argsAs<TvVideoRouteArgs>();
    expect(args.videoId, 'dQw4w9WgXcQ');
    expect(args.startAt, const Duration(seconds: 18));
  });

  for (final validInstance in [false, true]) {
    test(
        'Android pre-handshake batch opens newest recognized candidate (instance valid: $validInstance)',
        () async {
      final inbox = _AndroidLinkInbox();
      inbox.stage('https://youtu.be/dQw4w9WgXcQ?t=42', initial: true);
      inbox.stage('Unrelated shared text', share: true);
      final host = validInstance ? 'instance.example' : 'other.example';
      inbox.stage('https://$host/watch?v=nextvideo01&t=21', share: true);
      inbox.stage('Another unrelated share', share: true);
      final receiver = _DeferredLinkApp();
      addTearDown(receiver.close);
      await Future<void>.delayed(Duration.zero);
      expect(inbox.consumed, 4);
      expect(appRouter.hasEntries, isFalse);
      receiver.ready.complete();
      await _waitForRoute(TvVideoRoute.name);
      expect(appRouter.stack.map((page) => page.name),
          [TvHomeRoute.name, TvVideoRoute.name]);
      final args = appRouter.current.argsAs<TvVideoRouteArgs>();
      expect(args.videoId, validInstance ? 'nextvideo01' : 'dQw4w9WgXcQ');
      expect(args.startAt, Duration(seconds: validInstance ? 21 : 42));
    });
  }

  test(
      'Android warm batches route once and allow a later repeat of the same link',
      () async {
    final inbox = _AndroidLinkInbox();
    appRouter.dispose();
    final router = _RecordingRouter();
    appRouter = router;
    await router.replaceAll([const TvHomeRoute()]);
    final receiver = AppCubit(AppState(0, null, HomeLayout()));
    addTearDown(receiver.close);
    await receiver.stream.firstWhere((state) => state.server != null);
    inbox.stage('https://youtu.be/dQw4w9WgXcQ?t=42');
    inbox.stage('https://instance.example/watch?v=nextvideo01&t=21',
        share: true);
    inbox.stage('Unrelated shared text', share: true);
    await inbox.notify();
    expect(router.pushes, 1);
    expect((router.pushed!.args as TvVideoRouteArgs).videoId, 'nextvideo01');
    expect((router.pushed!.args as TvVideoRouteArgs).startAt,
        const Duration(seconds: 21));
    inbox.stage('https://instance.example/watch?v=nextvideo01&t=21',
        share: true);
    await inbox.notify();
    expect(router.pushes, 2);
    expect((router.pushed!.args as TvVideoRouteArgs).videoId, 'nextvideo01');
  });

  test('a pending instance share cannot cross profiles even on the same server',
      () async {
    final inbox = _AndroidLinkInbox();
    inbox.stage('https://instance.example/watch?v=dQw4w9WgXcQ',
        share: true, initial: true);
    final next = await db.createProfile('Another viewer');
    await db.forProfile(next.id).upsertServer(Server(
        url: 'https://instance.example', inUse: true, profileId: next.id));
    final receiver = _DeferredLinkApp();
    addTearDown(receiver.close);
    await Future<void>.delayed(Duration.zero);
    await db.useProfile(next.id);
    receiver.ready.complete();
    await receiver.stream.firstWhere((state) => state.server != null);
    await Future<void>.delayed(Duration.zero);
    expect(appRouter.hasEntries, isFalse);
  });

  testWidgets('description links for the selected instance stay in Videre',
      (tester) async {
    appRouter.dispose();
    final router = _RecordingRouter();
    appRouter = router;
    app.selectForLinkDisplay(await db.getCurrentlySelectedServer());
    const link = 'https://instance.example/watch?v=dQw4w9WgXcQ&t=42';
    const text = TextLinkified(text: link);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BlocProvider<AppCubit>.value(
          value: app, child: const Scaffold(body: text)),
    ));
    text.openLink(tester.element(find.byType(TextLinkified)), UrlElement(link));
    expect((router.pushed!.args as TvVideoRouteArgs).videoId, 'dQw4w9WgXcQ');
    expect((router.pushed!.args as TvVideoRouteArgs).startAt,
        const Duration(seconds: 42));
  });

  for (final link in [
    'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    'https://m.youtube.com/watch?v=dQw4w9WgXcQ',
    'https://youtu.be/dQw4w9WgXcQ',
    'https://youtu.be/dQw4w9WgXcQ?si=tracking&t=42',
    'https://youtu.be/dQw4w9WgXcQ?t=1h2m3s',
    'https://youtube.com/shorts/dQw4w9WgXcQ',
    'https://www.youtube.com/shorts/dQw4w9WgXcQ',
    'https://m.youtube.com/shorts/dQw4w9WgXcQ/?si=tracking',
    'https://www.youtube.com/live/dQw4w9WgXcQ?t=42',
    'https://youtube.com/embed/dQw4w9WgXcQ?start=42',
    'https://m.youtube.com/v/dQw4w9WgXcQ#t=42',
    'https://www.youtube.com/watch/?v=dQw4w9WgXcQ&time_continue=42',
  ]) {
    test('TV cold link builds a home and video stack: $link', () async {
      await app.openAppLink(link, true);

      expect(appRouter.stack.map((page) => page.name),
          [TvHomeRoute.name, TvVideoRoute.name]);
      expect(
          appRouter.current.argsAs<TvVideoRouteArgs>().videoId, 'dQw4w9WgXcQ');
      expect(appRouter.current.argsAs<TvVideoRouteArgs>().startAt,
          ContentLink.parseAddress(link)!.startAt);
    });
  }

  test('TV warm link preserves the existing home stack', () async {
    await appRouter.replaceAll([const TvHomeRoute()]);
    unawaited(app.openAppLink('https://youtu.be/dQw4w9WgXcQ', false));
    await _waitForRoute(TvVideoRoute.name);

    expect(appRouter.stack.map((page) => page.name),
        [TvHomeRoute.name, TvVideoRoute.name]);
    expect(appRouter.current.argsAs<TvVideoRouteArgs>().videoId, 'dQw4w9WgXcQ');
  });

  test('Fallback plugin opens cold and warm text shares', () async {
    final originalSharing = ReceiveSharingIntent.instance;
    final originalService = service;
    final shares = StreamController<List<SharedMediaFile>>();
    service = _IncomingLinkService();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    ReceiveSharingIntent.setMockValues(
      initialMedia: [
        SharedMediaFile(
            path: 'https://www.youtube.com/shorts/ignored0001',
            type: SharedMediaType.file),
        SharedMediaFile(
          path: 'Video (https://m.youtube.com/shorts/dQw4w9WgXcQ?si=abc).',
          type: SharedMediaType.text,
        ),
      ],
      mediaStream: shares.stream,
    );
    final receiver = AppCubit(AppState(0, null, HomeLayout()));
    addTearDown(() async {
      await receiver.close();
      await shares.close();
      ReceiveSharingIntent.instance = originalSharing;
      service = originalService;
      debugDefaultTargetPlatformOverride = null;
    });
    await _waitForRoute(TvVideoRoute.name);
    expect(appRouter.stack.map((page) => page.name),
        [TvHomeRoute.name, TvVideoRoute.name]);
    expect(appRouter.current.argsAs<TvVideoRouteArgs>().videoId, 'dQw4w9WgXcQ');

    appRouter.dispose();
    final router = _RecordingRouter();
    appRouter = router;
    await router.replaceAll([const TvHomeRoute()]);
    shares.add([
      SharedMediaFile(
        path: 'https://www.youtube.com.untrusted.test/shorts/ignored0001 '
            'https://untrusted.test/?next=https://youtu.be/ignored0001',
        type: SharedMediaType.text,
      ),
      SharedMediaFile(
        path: 'Shared video: https://youtu.be/nextvideo01?si=abc&t=42',
        type: SharedMediaType.text,
      ),
    ]);
    await Future<void>.delayed(Duration.zero);
    final route = router.pushed! as TvVideoRoute;
    expect(route.args!.videoId, 'nextvideo01');
  });

  for (final (format, text, share, initial) in [
    (
      'a tapped short link',
      'https://youtu.be/dQw4w9WgXcQ?si=abc&t=42',
      false,
      true
    ),
    (
      'a text share',
      'Video (https://m.youtube.com/shorts/dQw4w9WgXcQ?si=abc).',
      true,
      true
    ),
    (
      'a link delivered during startup',
      'https://www.youtube.com/shorts/dQw4w9WgXcQ',
      false,
      false
    ),
  ]) {
    test('Android retains $format until the phone session is available',
        () async {
      final inbox = _AndroidLinkInbox();
      inbox.stage(text, share: share, initial: initial);
      appRouter.dispose();
      app_globals.isTv = false;
      appRouter = AppRouter(hasServer: true);
      final receiver = _DeferredLinkApp();
      addTearDown(receiver.close);

      await Future<void>.delayed(Duration.zero);
      expect(inbox.consumed, 1);
      expect(appRouter.hasEntries, isFalse);

      receiver.ready.complete();
      await _waitForRoute(MainRoute.name);
      final children = appRouter.current.pendingChildren;
      expect(children.map((route) => route.name),
          [MainContentRoute.name, VideoRoute.name]);
      expect((children.last.args as VideoRouteArgs).videoId, 'dQw4w9WgXcQ');
      expect((children.last.args as VideoRouteArgs).startAt,
          format == 'a tapped short link' ? const Duration(seconds: 42) : null);
    });
  }

  test('An Android launch link leaves setup visible until a server is selected',
      () async {
    final inbox = _AndroidLinkInbox();
    inbox.stage('https://youtu.be/dQw4w9WgXcQ', initial: true);
    final server = await db.getCurrentlySelectedServer();
    await db.deleteServerById(server);
    appRouter.dispose();
    appRouter = AppRouter(hasServer: false);
    await appRouter.replaceAll([const TvWelcomeWizardRoute()]);
    expect(appRouter.stack.map((route) => route.name),
        [TvWelcomeWizardRoute.name]);
    final receiver = AppCubit(AppState(0, null, HomeLayout()));
    addTearDown(receiver.close);
    await receiver.stream.first;

    expect(inbox.consumed, 1);
    expect(appRouter.stack.map((route) => route.name),
        [TvWelcomeWizardRoute.name]);

    await db.upsertServer(server);
    receiver.setServer(server);
    await _waitForRoute(TvVideoRoute.name);
    expect(appRouter.stack.map((route) => route.name),
        [TvHomeRoute.name, TvVideoRoute.name]);
    expect(appRouter.current.argsAs<TvVideoRouteArgs>().videoId, 'dQw4w9WgXcQ');
  });

  test('An Android launch link cannot cross the startup profile boundary',
      () async {
    final inbox = _AndroidLinkInbox();
    inbox.stage('https://youtu.be/dQw4w9WgXcQ', initial: true);
    final next = await db.createProfile('Another viewer');
    await db.forProfile(next.id).upsertServer(
        Server(url: 'https://other.example', inUse: true, profileId: next.id));
    final receiver = _DeferredLinkApp();
    addTearDown(receiver.close);
    await Future<void>.delayed(Duration.zero);
    expect(inbox.consumed, 1);

    await db.useProfile(next.id);
    receiver.ready.complete();
    final state = await receiver.stream.first;
    expect(state.server?.profileId, next.id);
    expect(appRouter.hasEntries, isFalse);
  });

  test('An Android Activity attaching to the running engine keeps Back history',
      () async {
    final inbox = _AndroidLinkInbox();
    await appRouter.replaceAll([
      const TvHomeRoute(),
      TvChannelRoute(channelId: 'UCabcdefghijklmnopqrstuv'),
    ]);
    final receiver = AppCubit(AppState(0, null, HomeLayout()));
    addTearDown(receiver.close);
    await receiver.stream.firstWhere((state) => state.server != null);

    inbox.stage('https://youtu.be/dQw4w9WgXcQ', initial: true);
    await inbox.notify();
    await _waitForRoute(TvVideoRoute.name);

    expect(appRouter.stack.map((route) => route.name),
        [TvHomeRoute.name, TvChannelRoute.name, TvVideoRoute.name]);
    expect(appRouter.current.argsAs<TvVideoRouteArgs>().videoId, 'dQw4w9WgXcQ');
  });

  test('Android notifications consume one intent and allow intentional repeats',
      () async {
    final inbox = _AndroidLinkInbox();
    appRouter.dispose();
    final router = _RecordingRouter();
    appRouter = router;
    await router.replaceAll([const TvHomeRoute()]);
    final receiver = AppCubit(AppState(0, null, HomeLayout()));
    addTearDown(receiver.close);
    await receiver.stream.firstWhere((state) => state.server != null);

    const share = 'Shared from YouTube: https://youtu.be/nextvideo01?si=abc';
    inbox.stage(share, share: true);
    await inbox.notify();
    expect(inbox.consumed, 1);
    expect(router.pushes, 1);
    expect((router.pushed! as TvVideoRoute).args!.videoId, 'nextvideo01');
    await inbox.notify();
    expect(router.pushes, 1);

    inbox.stage(share, share: true);
    await inbox.notify();
    expect(router.pushes, 2);
    expect(inbox.consumed, 2);

    inbox.stage('https://youtube.com.invalid/shorts/nextvideo01');
    await inbox.notify();
    expect(router.pushes, 2);

    receiver.setGlobalLoading(true);
    inbox.stage(share, share: true);
    await inbox.notify();
    receiver.setGlobalLoading(false);
    expect(router.pushes, 2);
  });

  test('pasting a short link in search uses the normal video route', () async {
    appRouter.dispose();
    final router = _RecordingRouter();
    appRouter = router;
    final settings = TestSettingsCubit(SettingsState.init(), app);
    final search = SearchCubit(SearchState.init(), settings);
    addTearDown(settings.close);
    addTearDown(search.close);
    const address = 'youtu.be/dQw4w9WgXcQ?si=tracking&t=42';
    search.state.queryController.text = address;
    await search.search(address);
    expect((router.pushed! as TvVideoRoute).args!.videoId, 'dQw4w9WgXcQ');
    expect(search.state.showResults, isFalse);
    expect(db.getSearchHistory(), isEmpty);
  });

  for (final tv in [true, false]) {
    test('${tv ? 'TV' : 'phone'} playlist link retains the home stack',
        () async {
      appRouter.dispose();
      app_globals.isTv = tv;
      appRouter = AppRouter(hasServer: true);
      const id = 'PLy8d1u7T3WWJIuwxN8QuoUHdKYp9JDBcm';
      await app.openAppLink('https://www.youtube.com/playlist?list=$id', true);

      if (tv) {
        expect(appRouter.stack.map((page) => page.name),
            [TvHomeRoute.name, TvPlaylistRoute.name]);
        final args = appRouter.current.argsAs<TvPlaylistRouteArgs>();
        expect(args.playlist.playlistId, id);
        expect(args.canDeleteVideos, isFalse);
        await _expectPlaylistLoads(args.playlist, args.reference);
      } else {
        final children = appRouter.current.pendingChildren;
        expect(children.map((route) => route.name),
            [MainContentRoute.name, PlaylistViewRoute.name]);
        final args = children.last.args as PlaylistViewRouteArgs;
        expect(args.playlist.playlistId, id);
        expect(args.canDeleteVideos, isFalse);
        await _expectPlaylistLoads(args.playlist, args.reference);
      }
    });

    testWidgets(
        '${tv ? 'TV' : 'phone'} description playlist link opens internally',
        (tester) async {
      appRouter.dispose();
      app_globals.isTv = tv;
      final router = _RecordingRouter();
      appRouter = router;
      final linkified = TextLinkified(
          text: 'https://youtube.com/playlist?list=PLsupported_playlist',
          player: _LinkPlayer(PlayerState.init(null)));
      await tester.pumpWidget(MaterialApp(
        home: BlocProvider<AppCubit>.value(
            value: app, child: Scaffold(body: Column(children: [linkified]))),
      ));

      await tester.tapAt(
          tester.getTopLeft(find.byType(EditableText)) + const Offset(20, 10));
      await tester.pump();
      expect(router.pushed?.routeName,
          tv ? TvPlaylistRoute.name : PlaylistViewRoute.name);
    });
  }

  test('phone cold link retains the nested phone route stack', () async {
    appRouter.dispose();
    app_globals.isTv = false;
    appRouter = AppRouter(hasServer: true);
    await app.openAppLink(
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=90', true);

    expect(appRouter.stack.map((page) => page.name), [MainRoute.name]);
    final children = appRouter.current.pendingChildren;
    expect(children.map((route) => route.name),
        [MainContentRoute.name, VideoRoute.name]);
    expect((children.last.args as VideoRouteArgs).videoId, 'dQw4w9WgXcQ');
    expect((children.last.args as VideoRouteArgs).startAt,
        const Duration(seconds: 90));
  });

  test('phone warm link pushes inside the existing MainRoute', () async {
    appRouter.dispose();
    app_globals.isTv = false;
    appRouter = AppRouter(hasServer: true);
    await appRouter.replaceAll([const MainRoute()]);
    final parent = appRouter.current;
    // Attach the controller that MainScreen's AutoRouter creates when mounted.
    final nested = NestedStackRouter(
      parent: appRouter,
      key: parent.key,
      matchId: parent.matchId,
      routeData: parent,
      routeCollection: appRouter.routeCollection.subCollectionOf(parent.name),
    );
    appRouter.attachChildController(nested);
    try {
      await nested.replaceAll([const MainContentRoute()]);
      unawaited(app.openAppLink('https://youtu.be/dQw4w9WgXcQ?t=1m15s', false));
      await _waitForRoute(VideoRoute.name, router: nested);

      expect(appRouter.stack.map((page) => page.name), [MainRoute.name]);
      expect(nested.stack.map((page) => page.name),
          [MainContentRoute.name, VideoRoute.name]);
      expect(nested.current.argsAs<VideoRouteArgs>().videoId, 'dQw4w9WgXcQ');
      expect(nested.current.argsAs<VideoRouteArgs>().startAt,
          const Duration(seconds: 75));
    } finally {
      appRouter.removeChildController(nested);
      nested.dispose();
    }
  });

  for (final (kind, link, id) in [
    (
      'artist',
      'https://music.youtube.com/browse/UCuAXFkgsw1L7xaCfnd5JJOw',
      'UCuAXFkgsw1L7xaCfnd5JJOw'
    ),
    (
      'artist',
      'https://music.youtube.com/channel/UC_kRDKYrUlrbtrSiyu5Tflg',
      'UC_kRDKYrUlrbtrSiyu5Tflg'
    ),
    (
      'song',
      'https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RDAMVMdQw4w9WgXcQ&t=1m15s',
      'dQw4w9WgXcQ'
    ),
    (
      'playlist',
      'https://music.youtube.com/playlist?list=OLAK5uy_music-collection',
      'OLAK5uy_music-collection'
    ),
    ('playlist', 'https://music.youtube.com/browse/VLPLmusic', 'VLPLmusic'),
    (
      'song',
      'https://music.youtube.com/shorts/dQw4w9WgXcQ?start=75',
      'dQw4w9WgXcQ'
    ),
  ]) {
    for (final tv in [true, false]) {
      final platform = tv ? 'TV' : 'phone/tablet';
      final linkKind = kind == 'artist'
          ? '$kind (${Uri.parse(link).pathSegments.first})'
          : kind;
      test('$platform cold music $linkKind link retains the home stack',
          () async {
        appRouter.dispose();
        app_globals.isTv = tv;
        appRouter = AppRouter(hasServer: true);
        await app.openAppLink(link, true);

        if (tv) {
          expect(appRouter.stack.map((page) => page.name),
              [TvHomeRoute.name, MusicRoute.name]);
          _expectMusicArgs(appRouter.current.argsAs<MusicRouteArgs>(), kind, id,
              startAt:
                  kind == 'song' ? const Duration(seconds: 75) : Duration.zero);
        } else {
          expect(appRouter.stack.map((page) => page.name), [MainRoute.name]);
          final children = appRouter.current.pendingChildren;
          expect(children.map((route) => route.name),
              [MainContentRoute.name, MusicRoute.name]);
          _expectMusicArgs(children.last.args as MusicRouteArgs, kind, id,
              startAt:
                  kind == 'song' ? const Duration(seconds: 75) : Duration.zero);
        }
      });

      test('$platform warm music $linkKind link preserves existing navigation',
          () async {
        appRouter.dispose();
        app_globals.isTv = tv;
        appRouter = AppRouter(hasServer: true);
        NestedStackRouter? nested;
        if (tv) {
          await appRouter.replaceAll([const TvHomeRoute()]);
        } else {
          await appRouter.replaceAll([const MainRoute()]);
          final parent = appRouter.current;
          nested = NestedStackRouter(
            parent: appRouter,
            key: parent.key,
            matchId: parent.matchId,
            routeData: parent,
            routeCollection:
                appRouter.routeCollection.subCollectionOf(parent.name),
          );
          appRouter.attachChildController(nested);
          await nested.replaceAll([const MainContentRoute()]);
        }
        try {
          final active = nested ?? appRouter;
          unawaited(app.openAppLink(link, false));
          await _waitForRoute(MusicRoute.name, router: active);

          expect(active.stack.map((page) => page.name),
              [tv ? TvHomeRoute.name : MainContentRoute.name, MusicRoute.name]);
          _expectMusicArgs(active.current.argsAs<MusicRouteArgs>(), kind, id,
              startAt:
                  kind == 'song' ? const Duration(seconds: 75) : Duration.zero);
        } finally {
          if (nested != null) {
            appRouter.removeChildController(nested);
            nested.dispose();
          }
        }
      });
    }
  }

  for (final tv in [true, false]) {
    for (final link in [
      'https://youtu.be/dQw4w9WgXcQ',
      'https://music.youtube.com/watch?v=dQw4w9WgXcQ',
    ]) {
      test(
          'a ${tv ? 'TV' : 'phone'} link without a server opens onboarding: $link',
          () async {
        appRouter.dispose();
        await db.close();
        db = await SembastSqfDb.createInMemory();
        app_globals.isTv = tv;
        appRouter = AppRouter(hasServer: false);
        unawaited(app.openAppLink(link, true));
        final welcome =
            tv ? TvWelcomeWizardRoute.name : WelcomeWizardRoute.name;
        await _waitForRoute(welcome);

        expect(appRouter.stack.map((page) => page.name), [welcome]);
      });
    }
  }

  for (final tv in [true, false]) {
    for (final music in [true, false]) {
      test('shared search uses ${music ? 'music' : 'video'} search (TV=$tv)',
          () async {
        appRouter.dispose();
        app_globals.isTv = tv;
        appRouter = AppRouter(hasServer: true);
        await app.openAppLink(
            music
                ? 'https://music.youtube.com/search?q=quiet%20piano'
                : 'https://www.youtube.com/results?search_query=quiet%20piano',
            true);
        final routeName = tv
            ? appRouter.current.name
            : appRouter.current.pendingChildren.last.name;
        final arguments = tv
            ? appRouter.current.args
            : appRouter.current.pendingChildren.last.args;
        expect(
            routeName,
            music
                ? MusicRoute.name
                : tv
                    ? TvSearchRoute.name
                    : SearchRoute.name);
        if (music) {
          expect((arguments as MusicRouteArgs).initialQuery, 'quiet piano');
        } else if (tv) {
          final args = arguments as TvSearchRouteArgs;
          expect(args.query, 'quiet piano');
          expect(args.searchNow, isTrue);
        } else {
          final args = arguments as SearchRouteArgs;
          expect(args.query, 'quiet piano');
          expect(args.searchNow, isTrue);
        }
      });
    }
  }

  test('resolved aliases use the captured instance and validated channel ID',
      () async {
    final resolver = _DeferredResolver();
    service = resolver;
    app.selectForLinkDisplay(await db.getCurrentlySelectedServer());
    final opening = app.openAppLink(
        'https://www.youtube.com/@example/videos?si=private', true);
    expect(resolver.requests, hasLength(1));
    final request = resolver.requests.single;
    expect(request.server.url, 'https://instance.example');
    expect(request.link.id, 'https://www.youtube.com/@example');
    request.reply.complete(ContentLink.fromResolution(
        request.link, {'browseId': 'UC_kRDKYrUlrbtrSiyu5Tflg'}));
    await opening;
    expect(appRouter.current.argsAs<TvChannelRouteArgs>().channelId,
        'UC_kRDKYrUlrbtrSiyu5Tflg');
  });

  test('a newer direct link supersedes an unresolved alias', () async {
    appRouter.dispose();
    final recorder = _RecordingRouter();
    appRouter = recorder;
    final resolver = _DeferredResolver();
    service = resolver;
    app.selectForLinkDisplay(await db.getCurrentlySelectedServer());
    final opening = app.openAppLink('https://youtube.com/@example', false);
    await app.openAppLink('https://youtu.be/dQw4w9WgXcQ', false);
    final request = resolver.requests.single;
    request.reply.complete(ContentLink.fromResolution(
        request.link, {'ucid': 'UC_kRDKYrUlrbtrSiyu5Tflg'}));
    await opening;
    expect(recorder.pushes, 1);
    expect(recorder.pushed!.routeName, TvVideoRoute.name);
  });

  test('a saved handle cannot navigate after leaving its search context',
      () async {
    appRouter.dispose();
    final recorder = _RecordingRouter();
    appRouter = recorder;
    final resolver = _DeferredResolver();
    service = resolver;
    await db.upsertServer(const Server(url: 'https://saved.example/iv'));
    app.selectForLinkDisplay(await db.getCurrentlySelectedServer());
    var current = true;
    final opening = app.submitPastedAppLink('https://saved.example/iv/@example',
        music: true, isCurrent: () => current);
    await Future<void>.delayed(Duration.zero);
    final request = resolver.requests.single;
    expect(request.server.url, 'https://instance.example');
    current = false;
    request.reply.complete(ContentLink.fromResolution(
        request.link, {'ucid': 'UC_kRDKYrUlrbtrSiyu5Tflg'}));
    await opening;
    await Future<void>.delayed(Duration.zero);
    expect(recorder.pushes, 0);
  });

  test('a resolved alias cannot navigate after the profile changes', () async {
    appRouter.dispose();
    final recorder = _RecordingRouter();
    appRouter = recorder;
    final resolver = _DeferredResolver();
    service = resolver;
    app.selectForLinkDisplay(await db.getCurrentlySelectedServer());
    final opening = app.openAppLink('https://youtube.com/user/example', false);
    final request = resolver.requests.single;
    final next = await db.createProfile('Another viewer');
    await db.useProfile(next.id);
    request.reply.complete(ContentLink.fromResolution(
        request.link, {'ucid': 'UC_kRDKYrUlrbtrSiyu5Tflg'}));
    await opening;
    expect(recorder.pushes, 0);
  });

  for (final count in [1, 17]) {
    test('cold actionable link survives $count newer official landing shares',
        () async {
      final inbox = _AndroidLinkInbox();
      inbox.stage('https://youtu.be/dQw4w9WgXcQ', initial: true);
      final receiver = _DeferredLinkApp();
      addTearDown(receiver.close);
      await Future<void>.delayed(Duration.zero);
      for (var index = 0; index < count; index++) {
        inbox.stage('https://youtube.com/account?ignored=$index', share: true);
        await inbox.notify();
      }
      receiver.ready.complete();
      await _waitForRoute(TvVideoRoute.name);
      expect(
          appRouter.current.argsAs<TvVideoRouteArgs>().videoId, 'dQw4w9WgXcQ');
    });
  }

  test('navigation failures are caught after asynchronous dispatch', () async {
    appRouter.dispose();
    appRouter = _RecordingRouter()..fail = true;
    await expectLater(
        app.openAppLink('https://youtu.be/dQw4w9WgXcQ', false), completes);
    await expectLater(
        app.openAppLink('https://music.youtube.com/watch?v=dQw4w9WgXcQ', false),
        completes);
  });

  test('unsupported and empty links only use an internal landing', () async {
    for (final link in [
      'https://www.youtube.com/watch?v=',
      'https://www.youtube.com/playlist?list=',
      'https://www.youtube.com/playlist?list=PL..%2Fprivate',
      'https://www.youtube.com/playlist?list=${'PL' * 101}',
      'https://youtu.be/playlist?list=PLsupported_playlist',
      'https://user:private@www.youtube.com/playlist?list=PLsupported_playlist',
      'https://www.youtube.com/watch?v=..%2Flogin%3Ftoken%3Dprivate',
      'https://youtu.be/too-short',
      'https://youtu.be.example/shorts/dQw4w9WgXcQ',
      'https://youtu.be@notyoutube.example/dQw4w9WgXcQ',
      'https://www.youtube.com/shorts/dQw4w9WgXcQ/extra',
      'https://www.youtube.com/shorts/dQw4w9WgXcQ%2Fextra',
      'https://music.youtube.com/watch?v=',
      'https://music.youtube.com/watch?v=too-short',
      'https://music.youtube.com/browse/UCartist',
      'https://music.youtube.com/channel/UCartist',
      'https://music.youtube.com/channel/UC_kRDKYrUlrbtrSiyu5Tflg/extra',
      'https://music.youtube.com/channel/UC_kRDKYrUlrbtrSiyu5Tflg%2Fprivate',
      'https://music.youtube.com/channel/MPREb_K8qWMWVqXGi',
      'https://music.youtube.com/browse/MPREb_K8qWMWVqXGi',
      'https://music.youtube.com.example.com/channel/UC_kRDKYrUlrbtrSiyu5Tflg',
      'https://music.youtube.com/browse/MPREalbum%2Fprivate',
      'https://music.youtube.com/playlist?list=',
      'https://music.youtube.com/playlist?list=PL..%2Fprivate',
      'https://music.youtube.com/playlist?list=${'PL' * 101}',
      'ftp://music.youtube.com/watch?v=dQw4w9WgXcQ',
      'https://music.youtube.com.example.com/watch?v=dQw4w9WgXcQ',
      'https://example.com/watch?v=dQw4w9WgXcQ',
      'ftp://youtube.com/watch?v=dQw4w9WgXcQ',
      'videre-auth://callback?code=private',
      'not a URL',
    ]) {
      await appRouter.replaceAll([const TvHomeRoute()]);
      await app.openAppLink(link, true);
      expect(
          appRouter.stack.map((page) => page.name),
          link.startsWith('https://music.youtube.com/')
              ? [TvHomeRoute.name, MusicRoute.name]
              : [TvHomeRoute.name]);
    }
  });

  test('music links respect profile switching and session recovery gates',
      () async {
    await appRouter.replaceAll([const TvHomeRoute()]);
    app.setGlobalLoading(true);
    await app.openAppLink(
        'https://music.youtube.com/watch?v=dQw4w9WgXcQ', true);
    expect(appRouter.stack.map((page) => page.name), [TvHomeRoute.name]);

    app.setGlobalLoading(false);
    app.requireSessionRecovery();
    await app.openAppLink(
        'https://music.youtube.com/watch?v=dQw4w9WgXcQ', true);
    expect(appRouter.stack.map((page) => page.name), [TvHomeRoute.name]);
  });

  testWidgets('description music links use Music and timestamps still seek',
      (tester) async {
    appRouter.dispose();
    final router = _RecordingRouter();
    appRouter = router;
    final video = Video(videoId: 'dQw4w9WgXcQ', title: 'Song');
    final player = _LinkPlayer(PlayerState.init([video])
        .copyWith(isPlaying: true, currentlyPlaying: video));
    final linkified = TextLinkified(text: '', player: player, video: video);
    await tester.pumpWidget(MaterialApp(
      home: BlocProvider<AppCubit>.value(value: app, child: linkified),
    ));
    final context = tester.element(find.byType(TextLinkified));

    linkified.openLink(
        context,
        UrlElement(
            'https://music.youtube.com/playlist?list=PLsupported_music'));
    await tester.pump();
    expect(router.pushed?.routeName, MusicRoute.name);
    _expectMusicArgs(
        router.pushed!.args as MusicRouteArgs, 'playlist', 'PLsupported_music');

    linkified.openLink(context, TimestampElement('1:23'));
    expect(player.sought, const Duration(minutes: 1, seconds: 23));
  });

  testWidgets('unsupported description links show the existing blocked notice',
      (tester) async {
    final linkified = TextLinkified(
        text: 'https://www.youtube.com/redirect?q=https://instance.example',
        player: _LinkPlayer(PlayerState.init(null)));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BlocProvider<AppCubit>.value(
          value: app, child: Scaffold(body: Column(children: [linkified]))),
    ));

    await tester.tapAt(
        tester.getTopLeft(find.byType(EditableText)) + const Offset(20, 10));
    await tester.pumpAndSettle();
    final locals =
        AppLocalizations.of(tester.element(find.byType(AlertDialog)))!;
    expect(find.text(locals.externalLinkBlocked), findsOneWidget);
  });

  for (final action in ['Copy', 'Share']) {
    testWidgets('selected description/comment text can $action',
        (tester) async {
      final calls = <MethodCall>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call);
        if (call.method == 'Clipboard.hasStrings') return {'value': false};
        return null;
      });
      addTearDown(() =>
          messenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TextLinkified(
              text: 'Select these words only',
              player: _LinkPlayer(PlayerState.init(null))),
        ),
      ));

      await tester.longPress(find.byType(SelectableText));
      await tester.pumpAndSettle();
      final editable =
          tester.state<EditableTextState>(find.byType(EditableText));
      editable.userUpdateTextEditingValue(
          const TextEditingValue(
              text: 'Select these words only',
              selection: TextSelection(baseOffset: 7, extentOffset: 18)),
          SelectionChangedCause.longPress);
      editable.showToolbar();
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();

      if (action == 'Copy') {
        expect(
            calls
                .lastWhere((call) => call.method == 'Clipboard.setData')
                .arguments,
            {'text': 'these words'});
      } else {
        expect(
            calls.lastWhere((call) => call.method == 'Share.invoke').arguments,
            'these words');
      }
    });

    testWidgets('$action uses the selected Invidious address', (tester) async {
      final calls = <MethodCall>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        calls.add(call);
        if (call.method == 'Clipboard.hasStrings') return {'value': false};
        return null;
      });
      addTearDown(() =>
          messenger.setMockMethodCallHandler(SystemChannels.platform, null));
      app.selectForLinkDisplay(
          const Server(url: 'http://selected-instance.onion/iv'));
      await tester.pumpWidget(MaterialApp(
        home: BlocProvider<AppCubit>.value(
          value: app,
          child: const Scaffold(
            body: TextLinkified(
                text: 'https://youtu.be/dQw4w9WgXcQ?t=42&si=tracking'),
          ),
        ),
      ));
      final editable =
          tester.state<EditableTextState>(find.byType(EditableText));
      const expected =
          'http://selected-instance.onion/iv/watch?v=dQw4w9WgXcQ&t=42';
      expect(editable.widget.controller.text, expected);
      await tester.longPress(find.byType(SelectableText));
      await tester.pumpAndSettle();
      editable.userUpdateTextEditingValue(
          const TextEditingValue(
              text: expected,
              selection:
                  TextSelection(baseOffset: 0, extentOffset: expected.length)),
          SelectionChangedCause.longPress);
      editable.showToolbar();
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();

      final method = action == 'Copy' ? 'Clipboard.setData' : 'Share.invoke';
      final arguments =
          calls.lastWhere((call) => call.method == method).arguments;
      expect(arguments, action == 'Copy' ? {'text': expected} : expected);
    });
  }

  testWidgets('linkified selection survives parent rebuilds after long press',
      (tester) async {
    late StateSetter rebuild;
    const text = 'Select these words https://example.com';
    final player = _LinkPlayer(PlayerState.init(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(builder: (context, setState) {
          rebuild = setState;
          return Column(children: [TextLinkified(text: text, player: player)]);
        }),
      ),
    ));

    final gesture = await tester.startGesture(
        tester.getTopLeft(find.byType(EditableText)) + const Offset(20, 10));
    await tester.pump(const Duration(milliseconds: 600));
    final before = tester.widget<EditableText>(find.byType(EditableText));
    final selection = before.controller.selection;
    expect(selection.isCollapsed, isFalse);

    rebuild(() {});
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .controller
            .selection,
        selection);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);

    rebuild(() {});
    await tester.pumpAndSettle();
    final after = tester.widget<EditableText>(find.byType(EditableText));
    expect(after.controller.selection, selection);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
  });

  testWidgets('cached linkified text uses the current video and updated text',
      (tester) async {
    late StateSetter rebuild;
    const firstVideo = Video(videoId: 'first');
    const secondVideo = Video(videoId: 'second');
    final firstPlayer = _LinkPlayer(PlayerState.init([firstVideo])
        .copyWith(currentlyPlaying: firstVideo, isPlaying: true));
    final secondPlayer = _LinkPlayer(PlayerState.init([secondVideo])
        .copyWith(currentlyPlaying: secondVideo, isPlaying: true));
    var video = firstVideo;
    var player = firstPlayer;
    var text = '1:23 https://example.com';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: StatefulBuilder(builder: (context, setState) {
        rebuild = setState;
        return Column(children: [
          TextLinkified(text: text, player: player, video: video)
        ]);
      })),
    ));
    rebuild(() {
      video = secondVideo;
      player = secondPlayer;
    });
    await tester.pump();
    await tester.tapAt(
        tester.getTopLeft(find.byType(EditableText)) + const Offset(20, 10));
    expect(firstPlayer.sought, isNull);
    expect(secondPlayer.sought, const Duration(minutes: 1, seconds: 23));

    rebuild(() => text = 'Updated description https://example.org');
    await tester.pump();
    expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'Updated description example.org');
  });

  test('shared link query data and malformed input stay out of logs', () async {
    appRouter.dispose();
    final router = _RecordingRouter();
    appRouter = router;
    final previous = Logger.root.level;
    Logger.root.level = Level.FINE;
    addTearDown(() => Logger.root.level = previous);
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    await app.openAppLink(
        'https://youtu.be/dQw4w9WgXcQ?token=private-query-value', false);
    expect(router.pushed?.routeName, TvVideoRoute.name);
    await app.openAppLink('https://[private-invalid-value', false);
    await app.openAppLink(
        'https://music.youtube.com/watch?v=dQw4w9WgXcQ&token=private-music-value',
        false);
    expect(router.pushed?.routeName, MusicRoute.name);
    final messages = records.map((e) => '${e.message} ${e.error}').join();
    expect(messages, isNot(contains('private-query-value')));
    expect(messages, isNot(contains('private-invalid-value')));
    expect(messages, isNot(contains('private-music-value')));
  });

  test('Android registers content links and keeps auth isolated', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final mainActivity =
        RegExp(r'<activity\s+android:name="\.MainActivity"[\s\S]*?</activity>')
            .firstMatch(manifest)!
            .group(0)!;
    expect(
        RegExp(r'android:name="flutter_deeplinking_enabled"\s+android:value="false"')
            .hasMatch(mainActivity),
        isTrue);
    final filters = RegExp(r'<intent-filter[\s\S]*?</intent-filter>')
        .allMatches(mainActivity)
        .map((match) => match.group(0)!);
    final shortLinkFilter = filters
        .singleWhere((filter) => filter.contains('android:host="youtu.be"'));
    expect(shortLinkFilter, contains('android.intent.action.VIEW'));
    expect(shortLinkFilter, isNot(contains('android:pathPrefix')));
    for (final host in [
      'youtube.com',
      'www.youtube.com',
      'm.youtube.com',
      'music.youtube.com'
    ]) {
      expect(shortLinkFilter, contains('android:host="$host"'));
    }
    expect(shortLinkFilter, contains('android:scheme="http"'));
    expect(shortLinkFilter, contains('android:scheme="https"'));
    expect(shortLinkFilter, isNot(contains('android:path')));
    expect(mainActivity, isNot(contains('android:autoVerify="true"')));
    expect(mainActivity, isNot(contains('videre-auth')));
    expect(manifest,
        isNot(contains('com.linusu.flutter_web_auth_2.CallbackActivity')));
    expect(manifest, isNot(contains('android:scheme="videre-auth"')));
  });
}
