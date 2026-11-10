import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_load_session.dart';
import 'package:clipious/playlists/states/playlist.dart';
import 'package:clipious/playlists/views/screens/playlist.dart';
import 'package:clipious/router.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  final calls = <({
    List<Video> videos,
    bool? audio,
    int index,
    PlaylistReference reference
  })>[];

  _Player() : super(PlayerState.init(null));

  @override
  Future<void> playPlaylist(List<Video> entries,
      {required PlaylistReference reference,
      int startIndex = 0,
      Duration? startAt,
      bool? audio,
      bool? playing,
      PlaylistLoadSession? playlistLoader}) async {
    calls.add((
      videos: entries,
      audio: audio,
      index: startIndex,
      reference: reference
    ));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Router extends AppRouter {
  PageRouteInfo? pushed;

  _Router() : super(hasServer: true);

  @override
  Future<T?> push<T extends Object?>(PageRouteInfo route,
      {OnNavigationFailure? onFailure}) {
    pushed = route;
    return Completer<T?>().future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async => db = await SembastSqfDb.createInMemory());
  tearDown(() => db.close());
  const song = Video(
      videoId: 'saved-song1',
      title: 'Song',
      musicMetadata:
          MusicMetadata(title: 'Song', artist: 'Artist', album: 'Album'));
  const video = Video(videoId: 'saved-video');
  const playlist = Playlist(
      playlistId: 'local:saved',
      title: 'Saved',
      author: '',
      videoCount: 2,
      videos: [song, video]);

  testWidgets(
      'saved song and video selections preserve the full playlist context',
      (tester) async {
    final player = _Player();
    final router = _Router();
    final cubit =
        PlaylistCubit(const PlaylistState(playlist: playlist), player);
    addTearDown(cubit.close);
    addTearDown(player.close);
    addTearDown(router.dispose);
    late BuildContext selectionContext;
    await tester.pumpWidget(MaterialApp(
      home: MultiBlocProvider(
        providers: [
          BlocProvider<PlayerCubit>.value(value: player),
          BlocProvider<PlaylistCubit>.value(value: cubit),
        ],
        child: StackRouterScope(
          controller: router,
          stateHash: 0,
          child: Builder(builder: (context) {
            selectionContext = context;
            return const SizedBox.shrink();
          }),
        ),
      ),
    ));
    const screen =
        PlaylistViewScreen(playlist: playlist, canDeleteVideos: true);

    await screen.openVideo(selectionContext, cubit.state.playlist.videos.first);
    expect(player.calls.single.videos.map((entry) => entry.videoId),
        [song.videoId, video.videoId]);
    expect(player.calls.single.videos.first.musicMetadata?.album, 'Album');
    expect(player.calls.single.index, 0);
    expect(player.calls.single.reference.playlistId, playlist.playlistId);
    expect(router.pushed, isNull);

    await screen.openVideo(selectionContext, cubit.state.playlist.videos.last);
    expect(player.calls, hasLength(2));
    expect(player.calls.last.index, 1);
    expect(player.calls.last.videos.map((entry) => entry.videoId),
        [song.videoId, video.videoId]);
    expect(router.pushed, isNull);
  });

  test('playlist video and audio buttons keep their explicit playback choice',
      () async {
    final player = _Player();
    final cubit =
        PlaylistCubit(const PlaylistState(playlist: playlist), player);
    addTearDown(cubit.close);
    addTearDown(player.close);

    await cubit.play(false);
    await cubit.play(true);

    expect(player.calls.map((call) => call.audio), [false, true]);
    expect(player.calls.every((call) => call.index == 0), isTrue);
    expect(
        player.calls.map((call) => call.videos.map((video) => video.videoId)), [
      [song.videoId, video.videoId],
      [song.videoId, video.videoId]
    ]);
  });
}
