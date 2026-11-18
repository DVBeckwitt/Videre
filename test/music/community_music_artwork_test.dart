import 'dart:async';
import 'dart:io';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/music/services/music_community_cover_cache.dart';
import 'package:clipious/music/services/music_community_cover_preferences.dart';
import 'package:clipious/music/views/components/community_music_artwork.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/material.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
}
