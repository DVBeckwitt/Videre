import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/music/services/music_artwork_cache.dart';
import 'package:clipious/music/services/music_community_cover_cache.dart';
import 'package:clipious/music/services/music_community_cover_preferences.dart';
import 'package:clipious/music/views/components/community_music_artwork.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _App extends Cubit<AppState> implements AppCubit {
  _App() : super(AppState(0, null, HomeLayout()));

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Cache extends MusicCommunityCoverCache {
  final requests =
      <({String id, bool Function() current, Completer<File?> done})>[];
  final reads = <String>[];
  @override
  final ValueNotifier<(String, String?)?> invalidated = ValueNotifier(null);
  @override
  final ValueNotifier<(String, String)?> savedCover = ValueNotifier(null);

  @override
  Future<File?> read(String profile, String videoId,
      {required bool Function() isCurrent}) async {
    reads.add(videoId);
    return null;
  }

  @override
  Future<File?> load(
      String profile, String videoId, MusicMetadata track, int? durationSeconds,
      {required bool Function() isCurrent}) {
    final done = Completer<File?>();
    requests.add((id: videoId, current: isCurrent, done: done));
    return done.future;
  }
}

class _Budget extends Fake implements MusicArtworkCache {
  final profiles = <String>[];

  @override
  void trackProfile(String profile) => profiles.add(profile);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'the default community store registers its profile before reading local covers',
      (tester) async {
    final app = _App();
    final budget = _Budget();
    final injected = _Cache();
    await tester.runAsync(() async {
      db = await SembastSqfDb.createInMemory();
      await setCommunityCoverArtEnabled(true);
    });
    addTearDown(db.close);
    addTearDown(app.close);
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final profilesAtRead = <List<String>>[];
    messenger.setMockMethodCallHandler(pathProvider, (call) async {
      if (call.method == 'getApplicationSupportDirectory') {
        profilesAtRead.add(List.of(budget.profiles));
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));

    const id = 'abcdefghijk';
    Future<void> show(MusicCommunityCoverCache? store) =>
        tester.pumpWidget(RepositoryProvider<MusicArtworkCache>.value(
            value: budget,
            child: BlocProvider<AppCubit>.value(
              value: app,
              child: MaterialApp(
                  home: CommunityMusicArtwork(
                      videoId: id,
                      music:
                          const MusicMetadata(title: 'Song', artist: 'Artist'),
                      cache: store,
                      fallback: const SizedBox.shrink())),
            )));

    await show(injected);
    expect(injected.reads, [id]);
    expect(budget.profiles, isEmpty);
    expect(profilesAtRead, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await show(null);
    await tester.pump();
    expect(profilesAtRead, isNotEmpty);
    expect(profilesAtRead, everyElement(contains(db.profileId)));
    expect(budget.profiles, everyElement(db.profileId));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('resuming Now Playing reacquires its cancelled cover lookup',
      (tester) async {
    final app = _App();
    final cache = _Cache();
    await tester.runAsync(() async {
      db = await SembastSqfDb.createInMemory();
      await setCommunityCoverArtEnabled(true);
    });
    addTearDown(db.close);
    addTearDown(app.close);
    final binding = tester.binding;
    final previous = binding.lifecycleState;
    addTearDown(() => binding
        .handleAppLifecycleStateChanged(previous ?? AppLifecycleState.resumed));
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    Future<void> show(String videoId, {bool allowLookup = true}) =>
        tester.pumpWidget(BlocProvider<AppCubit>.value(
            value: app,
            child: MaterialApp(
                home: CommunityMusicArtwork(
                    videoId: videoId,
                    music: const MusicMetadata(title: 'Song', artist: 'Artist'),
                    cache: cache,
                    allowLookup: allowLookup,
                    fallback: const SizedBox.shrink()))));

    const first = 'abcdefghijk';
    const second = 'abcdefghijL';
    await show(first);
    final initial = cache.requests.single;
    expect(initial.current(), isTrue);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(initial.current(), isFalse);
    initial.done.complete(null);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(cache.requests.map((request) => request.id), [first, first]);
    final resumed = cache.requests.last;
    expect(resumed.current(), isTrue);
    expect(initial.current(), isFalse);

    await show(second);
    expect(resumed.current(), isFalse);
    final replaced = cache.requests.last;
    await show(first);
    expect(cache.requests.map((request) => request.id),
        [first, first, second, first]);
    expect(resumed.current(), isFalse);
    expect(replaced.current(), isFalse);
    expect(cache.requests.last.current(), isTrue);

    await show(first, allowLookup: false);
    expect(cache.requests.last.current(), isFalse);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(cache.requests, hasLength(4));
    expect(cache.reads, [first]);
    for (final request
        in cache.requests.where((request) => !request.done.isCompleted)) {
      request.done.complete(null);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'Now Playing leaves a cleared or evicted cover alone until the song changes',
      (tester) async {
    final app = _App();
    final cache = _Cache();
    late Directory directory;
    late File cover;
    await tester.runAsync(() async {
      db = await SembastSqfDb.createInMemory();
      await setCommunityCoverArtEnabled(true);
      directory = await Directory.systemTemp.createTemp('videre-player-cover-');
      cover = await File('${directory.path}/cover.png').writeAsBytes(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII='));
    });
    addTearDown(() => directory.delete(recursive: true));
    addTearDown(db.close);
    addTearDown(app.close);
    final binding = tester.binding;
    final previous = binding.lifecycleState;
    addTearDown(() => binding
        .handleAppLifecycleStateChanged(previous ?? AppLifecycleState.resumed));
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final owner = db.profileId;
    const first = 'abcdefghijk';
    const second = 'abcdefghijL';
    Future<void> show(String id) =>
        tester.pumpWidget(BlocProvider<AppCubit>.value(
            value: app,
            child: MaterialApp(
                home: CommunityMusicArtwork(
                    videoId: id,
                    allowLookup: true,
                    music: const MusicMetadata(title: 'Song', artist: 'Artist'),
                    cache: cache,
                    fallback: const Text('Stock cover')))));

    await show(first);
    final original = cache.requests.single;
    cache.savedCover.value = ('other-profile', first);
    cache.invalidated.value = ('other-profile', null);
    await tester.pump();
    expect(original.current(), isTrue);
    expect(cache.requests, hasLength(1));
    original.done.complete(cover);
    // FutureBuilder schedules its frame from the completion microtask.
    await tester.idle();
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);

    cache.invalidated.value = (owner, null);
    await tester.pump();
    expect(original.current(), isFalse);
    await show(first);
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(find.text('Stock cover'), findsOneWidget);
    expect(cache.requests, hasLength(1));

    await show(second);
    final next = cache.requests.last;
    expect(next.id, second);
    expect(next.current(), isTrue);
    cache.invalidated.value = (owner, first);
    await tester.pump();
    expect(next.current(), isTrue);
    cache.invalidated.value = (owner, second);
    await tester.pump();
    expect(next.current(), isFalse);
    next.done.complete(null);
    await show(second);
    await tester.pump();
    expect(find.text('Stock cover'), findsOneWidget);
    expect(cache.requests.map((r) => r.id), [first, second]);

    await show(first);
    expect(cache.requests.map((r) => r.id), [first, second, first]);
    cache.requests.last.done.complete(null);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
