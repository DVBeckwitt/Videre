import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/models/saved_playlist.dart';
import 'package:clipious/playlists/services/playlist_library_service.dart';
import 'package:clipious/playlists/views/components/playlist_bookmark_button.dart';
import 'package:clipious/playlists/views/components/playlist_in_list.dart';
import 'package:clipious/playlists/views/components/playlist_list.dart';
import 'package:clipious/playlists/views/tv/screens/playlist_grid.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/models/paginated_list.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _App extends AppCubit {
  _App() : super(AppState(0, null, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  onReady() {}

  @override
  initState() {}
}

class _FailingWrite implements IDbClient {
  final IDbClient database;
  _FailingWrite(this.database);

  @override
  String get profileId => database.profileId;

  @override
  IDbClient forProfile(String id) => this;

  @override
  SettingsValue? getSettings(String name) => database.getSettings(name);

  @override
  Future<void> saveSetting(SettingsValue setting) async =>
      throw StateError('Disk unavailable');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PendingWrite implements IDbClient {
  final IDbClient database;
  final pending = Completer<void>();
  var writes = 0;

  _PendingWrite(this.database);

  @override
  String get profileId => database.profileId;

  @override
  IDbClient forProfile(String id) => this;

  @override
  SettingsValue? getSettings(String name) => database.getSettings(name);

  @override
  Future<void> saveSetting(SettingsValue setting) async {
    writes++;
    await pending.future;
    await database.saveSetting(setting);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Router extends AppRouter {
  PageRouteInfo? pushed;
  final returned = Completer<void>();

  _Router() : super(hasServer: true);

  @override
  Future<T?> push<T extends Object?>(PageRouteInfo route,
      {OnNavigationFailure? onFailure}) {
    pushed = route;
    return returned.future.then<T?>((_) => null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SembastSqfDb database;
  late _App app;
  const source = Playlist(
      playlistId: 'PLsaved',
      title: 'A saved playlist',
      author: 'Creator',
      videoCount: 0);
  const reference = PlaylistReference(
      kind: PlaylistSourceKind.public,
      playlistId: 'PLsaved',
      profileId: 'default');

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    db = database;
    app = _App();
  });

  tearDown(() async {
    await app.close();
    await database.close();
  });

  Widget host(Widget child) => BlocProvider<AppCubit>.value(
        value: app,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: child),
        ),
      );

  testWidgets('save button updates immediately and removes the same bookmark',
      (tester) async {
    await tester.pumpWidget(host(
        const PlaylistBookmarkButton(playlist: source, reference: reference)));
    expect(find.text('Save playlist'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('playlist-bookmark')));
    await tester.pumpAndSettle();
    final library =
        PlaylistLibraryService.forProfile(database, database.profileId);
    expect(library.contains(reference), isTrue);
    expect(find.text('Saved'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('playlist-bookmark')));
    await tester.pumpAndSettle();
    expect(library.contains(reference), isFalse);
    expect(find.text('Save playlist'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed save stays unsaved and displays retry guidance',
      (tester) async {
    db = _FailingWrite(database);
    await tester.pumpWidget(host(
        const PlaylistBookmarkButton(playlist: source, reference: reference)));
    await tester.tap(find.byKey(const ValueKey('playlist-bookmark')));
    await tester.pumpAndSettle();
    expect(find.text('Save playlist'), findsOneWidget);
    expect(find.text('Could not update saved playlists. Try again.'),
        findsOneWidget);
    expect(
        PlaylistLibraryService.forProfile(database, database.profileId).entries,
        isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending save disables repeated taps until persisted',
      (tester) async {
    final pending = _PendingWrite(database);
    db = pending;
    await tester.pumpWidget(host(
        const PlaylistBookmarkButton(playlist: source, reference: reference)));
    await tester.tap(find.byKey(const ValueKey('playlist-bookmark')));
    await tester.pump();
    expect(pending.writes, 1);
    expect(
        tester
            .widget<OutlinedButton>(
                find.byKey(const ValueKey('playlist-bookmark')))
            .onPressed,
        isNull);
    pending.pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
    expect(pending.writes, 1);
  });

  testWidgets('library retains saved cards while remote listing is unavailable',
      (tester) async {
    final library =
        PlaylistLibraryService.forProfile(database, database.profileId);
    await tester.runAsync(
        () => library.save(SavedPlaylist.fromPlaylist(source, reference)));
    await tester.pumpWidget(host(PlaylistList(
        paginatedList:
            SingleEndpointList(() async => throw StateError('Offline')),
        includeSavedPlaylists: true,
        canDeleteVideos: true)));
    await tester.pumpAndSettle();
    expect(find.text(source.title), findsOneWidget);
    expect(find.textContaining('Saved on this device'), findsOneWidget);
    final card = tester.widget<PlaylistInList>(find.byType(PlaylistInList));
    expect(card.reference, reference);
    expect(card.canDeleteVideos, isFalse);
    await tester.runAsync(() => library.remove(reference));
    await tester.pumpAndSettle();
    expect(find.text(source.title), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search and channel playlist lists do not include saved library',
      (tester) async {
    final library =
        PlaylistLibraryService.forProfile(database, database.profileId);
    await tester.runAsync(
        () => library.save(SavedPlaylist.fromPlaylist(source, reference)));
    await tester.pumpWidget(host(PlaylistList(
        paginatedList: FixedItemList<Playlist>([]), canDeleteVideos: false)));
    await tester.pumpAndSettle();
    expect(find.text(source.title), findsNothing);
    expect(find.byType(PlaylistInList), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening a saved library card preserves its source reference',
      (tester) async {
    final router = _Router();
    addTearDown(router.dispose);
    final library =
        PlaylistLibraryService.forProfile(database, database.profileId);
    await tester.runAsync(
        () => library.save(SavedPlaylist.fromPlaylist(source, reference)));
    await tester.pumpWidget(host(StackRouterScope(
      controller: router,
      stateHash: 0,
      child: PlaylistList(
          paginatedList: FixedItemList<Playlist>([]),
          includeSavedPlaylists: true,
          canDeleteVideos: true),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text(source.title));
    expect(router.pushed?.routeName, PlaylistViewRoute.name);
    final args = router.pushed!.args as PlaylistViewRouteArgs;
    expect(args.reference, reference);
    expect(args.canDeleteVideos, isFalse);
    expect(args.bookmarkOwner, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'server bookmark card keeps delete ownership and read-only videos',
      (tester) async {
    const server = Server(url: 'https://instance.example', id: 'owner');
    app.setServer(server);
    final router = _Router();
    addTearDown(router.dispose);
    await tester.pumpWidget(host(StackRouterScope(
      controller: router,
      stateHash: 0,
      child: PlaylistList(
          paginatedList: FixedItemList<Playlist>([
            source.copyWith(type: invidiousPlaylist),
          ]),
          includeSavedPlaylists: true,
          canDeleteVideos: true),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text(source.title));
    final args = router.pushed!.args as PlaylistViewRouteArgs;
    expect(args.reference, reference);
    expect(args.canDeleteVideos, isFalse);
    expect(args.bookmarkOwner?.accountId, server.accountId);
    expect(args.bookmarkOwner?.origin, server.url);
    expect(tester.takeException(), isNull);
  });

  for (final tv in [false, true]) {
    testWidgets('${tv ? 'TV' : 'phone'} library refreshes after detail returns',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      app.setServer(const Server(url: 'https://instance.example', id: 'owner'));
      final router = _Router();
      addTearDown(router.dispose);
      var remote = [source.copyWith(type: invidiousPlaylist)];
      var requests = 0;
      final endpoint = SingleEndpointList<Playlist>(() async {
        requests++;
        return remote;
      });
      await tester.pumpWidget(host(StackRouterScope(
        controller: router,
        stateHash: 0,
        child: tv
            ? TvPlaylistGridScreen(
                playlistList: endpoint, includeSavedPlaylists: true)
            : PlaylistList(
                paginatedList: endpoint,
                includeSavedPlaylists: true,
                canDeleteVideos: true),
      )));
      await tester.pumpAndSettle();
      if (tv) {
        Focus.of(tester.element(find.text(source.title))).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
      } else {
        await tester.tap(find.text(source.title));
      }
      expect(router.pushed?.routeName,
          tv ? TvPlaylistRoute.name : PlaylistViewRoute.name);
      if (tv) {
        final args = router.pushed!.args as TvPlaylistRouteArgs;
        expect(args.canDeleteVideos, isFalse);
        expect(args.bookmarkOwner?.accountId, 'owner');
      }
      remote = [];
      router.returned.complete();
      await tester.pumpAndSettle();
      expect(requests, 2);
      expect(find.byType(PlaylistInList), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('TV search cards open without a playlist library provider',
      (tester) async {
    final router = _Router();
    addTearDown(router.dispose);
    await tester.pumpWidget(host(StackRouterScope(
      controller: router,
      stateHash: 0,
      child: const SizedBox(
        width: 380,
        height: 320,
        child: PlaylistInList(
            playlist: source, canDeleteVideos: false, isTv: true),
      ),
    )));
    await tester.pumpAndSettle();
    Focus.of(tester.element(find.text(source.title))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(router.pushed?.routeName, TvPlaylistRoute.name);
    router.returned.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
