import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/states/playlist.dart';
import 'package:clipious/playlists/views/screens/playlist.dart';
import 'package:clipious/router.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  final calls = <({List<Video> videos, bool? audio})>[];

  _Player() : super(PlayerState.init(null));

  @override
  Future<void> playVideo(List<Video> videos,
      {bool? audio, Duration? startAt, bool? playing}) async {
    calls.add((videos: videos, audio: audio));
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
      'saved song selection preserves metadata and video selection routes',
      (tester) async {
    final player = _Player();
    final router = _Router();
    addTearDown(player.close);
    addTearDown(router.dispose);
    late BuildContext selectionContext;
    await tester.pumpWidget(MaterialApp(
      home: BlocProvider<PlayerCubit>.value(
        value: player,
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

    screen.openVideo(selectionContext, song);
    expect(player.calls.single.videos.single, same(song));
    expect(player.calls.single.videos.single.musicMetadata?.album, 'Album');
    expect(router.pushed, isNull);

    screen.openVideo(selectionContext, video);
    expect(player.calls, hasLength(1));
    expect(router.pushed?.routeName, VideoRoute.name);
    expect((router.pushed!.args as VideoRouteArgs).videoId, video.videoId);
  });

  test('playlist video and audio buttons keep their explicit playback choice',
      () async {
    final player = _Player();
    final cubit = PlaylistCubit(
        const PlaylistState(playlist: playlist, playlistItemHeight: 0), player);
    addTearDown(cubit.close);
    addTearDown(player.close);

    cubit.play(false);
    cubit.play(true);

    expect(player.calls.map((call) => call.audio), [false, true]);
    expect(player.calls.map((call) => call.videos),
        [playlist.videos, playlist.videos]);
  });
}
