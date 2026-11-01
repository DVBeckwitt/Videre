import 'dart:async';

import 'package:clipious/globals.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/states/playlist.dart';
import 'package:clipious/service.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

class _PlaylistService extends Service {
  final deletions = <Completer<void>>[];

  @override
  Future<void> deleteUserPlaylistVideo(String playlistId, String indexId) {
    final response = Completer<void>();
    deletions.add(response);
    return response.future;
  }
}

class _UnusedPlayer implements PlayerCubit {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  const video = Video(videoId: 'saved', indexId: 'index');
  const playlist = Playlist(
      title: 'Saved',
      playlistId: 'private',
      author: '',
      videoCount: 1,
      videos: [video]);
  late Service previousService;
  late _PlaylistService playlists;
  late PlaylistCubit cubit;

  setUp(() {
    previousService = service;
    service = playlists = _PlaylistService();
    cubit = PlaylistCubit(
        const PlaylistState(playlist: playlist, playlistItemHeight: 0),
        _UnusedPlayer());
  });

  tearDown(() async {
    if (!cubit.isClosed) await cubit.close();
    service = previousService;
  });

  test('failed removal retains the video and releases loading for retry',
      () async {
    final removal = cubit.removeVideoFromPlayList(video);
    final failed = expectLater(removal, throwsStateError);
    playlists.deletions.single.completeError(StateError('offline'));
    await failed;
    expect(cubit.state.loading, isFalse);
    expect(cubit.state.playlist.videos, [video]);

    final retry = cubit.removeVideoFromPlayList(video);
    playlists.deletions.last.complete();
    await retry;
    expect(cubit.state.loading, isFalse);
    expect(cubit.state.playlist.videos, isEmpty);
    expect(cubit.state.playlist.videoCount, 0);
  });

  test('successful deletion after closing does not emit to a disposed screen',
      () async {
    final removal = cubit.removeVideoFromPlayList(video);
    await cubit.close();
    playlists.deletions.single.complete();
    await removal;
    await cubit.removeVideoFromPlayList(video);
    expect(playlists.deletions, hasLength(1));
  });
}
