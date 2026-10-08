import 'dart:convert';

import 'package:clipious/globals.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/states/playlist.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/models/paginated_list.dart';
import 'package:clipious/utils/states/item_list.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/states/add_to_playlist.dart';
import 'package:clipious/videos/states/history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late MockClient client;
  late Service library;
  final requests = <http.Request>[];

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    requests.clear();
    client = MockClient((request) async {
      requests.add(request);
      throw StateError('Local library requested ${request.url}');
    });
    service = library = Service(httpClient: client);
  });

  tearDown(() async {
    // Even a swallowed network error would leak local library activity.
    expect(requests, isEmpty);
    client.close();
    service = Service();
    await db.close();
  });

  test('local playlist CRUD survives replacing the service', () async {
    final id = (await library.createPlayList('Train rides', 'local'))!;
    const video = Video(
      videoId: 'first',
      title: 'A saved video',
      author: 'A channel',
      lengthSeconds: 300,
    );
    await library.addVideoToPlaylist(id, video.videoId, video: video);

    library = Service(httpClient: client);
    final restored = await library.getUserPlaylist(id);
    expect(restored.title, 'Train rides');
    expect(restored.videoCount, 1);
    expect(restored.videos.single.title, video.title);
    expect(restored.videos.single.lengthSeconds, video.lengthSeconds);
    expect(restored.videos.single.indexId, video.videoId);
    expect(db.getSettings(localPlaylistsSetting), isNotNull);
    expect((await library.getPublicPlaylists(id)).videos.single.videoId,
        video.videoId);

    await library.deleteUserPlaylistVideo(id, video.videoId);
    expect((await library.getUserPlaylist(id)).videos, isEmpty);
    expect((await library.getUserPlaylist(id)).videoCount, 0);
    await library.deleteUserPlaylist(id);
    expect((await library.getUserPlaylists()).map((p) => p.playlistId),
        isNot(contains(id)));
  });

  test('cached video details can be saved without an instance', () async {
    await db.upsertHistoryVideo(HistoryVideoCache(
        'cached', 'Already watched', 'A channel', 'https://example.com/image'));

    await library.addVideoToPlaylist(localWatchLaterId, 'cached');

    final video =
        (await library.getUserPlaylist(localWatchLaterId)).videos.single;
    expect(video.title, 'Already watched');
    expect(video.author, 'A channel');
    expect(video.videoThumbnails.single.url, 'https://example.com/image');
  });

  test(
      'saved local videos use current filters without changing stored metadata',
      () async {
    const video = Video(videoId: 'blocked', title: 'A spoiler');
    await library.addVideoToPlaylist(localWatchLaterId, video.videoId,
        video: video);
    await db.saveSetting(SettingsValue(dearrowSettingName, 'true'));
    final filter = VideoFilter(value: 'spoiler')..hideFromFeed = true;
    await db.saveFilter(filter);

    final list = (await library.getUserPlaylists()).single;
    expect(list.videos.single.filtered, isTrue);
    expect(list.videos.single.filterHide, isTrue);
    expect(
        (await library.getUserPlaylist(localWatchLaterId))
            .videos
            .single
            .filterHide,
        isTrue);
    expect(library.getLocalPlaylists().single.videos.single.filtered, isFalse);
    expect(
        (await library.getUserPlaylists(postProcessing: false))
            .single
            .videos
            .single
            .filtered,
        isFalse);

    await db.deleteFilter(filter);
    final restored = await library.getUserPlaylist(localWatchLaterId);
    expect(restored.videoCount, 1);
    expect(restored.videos.single.filtered, isFalse);
    expect(restored.videos.single.filterHide, isFalse);
  });

  test('restored metadata without server indexes can be removed and unliked',
      () async {
    const video = Video(videoId: 'restored', title: 'Saved before restore');
    const playlist = Playlist(
        title: likePlaylistName,
        playlistId: 'local:likes',
        author: '',
        videoCount: 1,
        videos: [video]);
    Future<void> restoreMetadata() async {
      await db.saveSetting(SettingsValue(
          localPlaylistsSetting, jsonEncode([playlist.toJson()])));
    }

    await restoreMetadata();
    expect((await library.getUserPlaylist(localWatchLaterId)).isLocal, isTrue);
    final restored = await library.getUserPlaylist(playlist.playlistId);
    expect(restored.isLocal, isTrue);
    expect(restored.videos.single.indexId, isNull);
    final playlistCubit = PlaylistCubit(
        PlaylistState(playlist: restored, playlistItemHeight: 0),
        _UnusedPlayer());
    await playlistCubit.removeVideoFromPlayList(restored.videos.single);
    expect(
        (await library.getUserPlaylist(playlist.playlistId)).videos, isEmpty);
    await playlistCubit.close();

    await restoreMetadata();
    final likes = AddToPlaylistCubit(const AddToPlaylistController('restored'));
    await likes.onReady();
    expect(likes.state.isVideoLiked, isTrue);
    await likes.toggleLike();
    expect(likes.state.isVideoLiked, isFalse);
    expect(
        (await library.getUserPlaylist(playlist.playlistId)).videos, isEmpty);
    await likes.close();
  });

  test('concurrent saves retain distinct videos and ignore duplicates',
      () async {
    final id = (await library.createPlayList('Favorites', 'local'))!;
    const first = Video(videoId: 'first', title: 'First');
    const second = Video(videoId: 'second', title: 'Second');

    await Future.wait([
      library.addVideoToPlaylist(id, first.videoId, video: first),
      library.addVideoToPlaylist(id, second.videoId, video: second),
      library.addVideoToPlaylist(id, first.videoId, video: first),
    ]);

    final playlist = await library.getUserPlaylist(id);
    expect(playlist.videoCount, 2);
    expect(playlist.videos.map((v) => v.videoId),
        unorderedEquals(['first', 'second']));
  });

  test('Watch Later is always available, including after deletion', () async {
    expect((await library.getUserPlaylists()).map((p) => p.playlistId),
        [localWatchLaterId]);

    await library.deleteUserPlaylist(localWatchLaterId);

    final playlists = await Service(httpClient: client).getUserPlaylists();
    expect(playlists.map((p) => p.playlistId), [localWatchLaterId]);
    expect((await library.getUserPlaylist(localWatchLaterId)).videos, isEmpty);
  });

  test('guest history can be read, removed and cleared without auth', () async {
    for (final id in ['first', 'second']) {
      await db.upsertHistoryVideo(HistoryVideoCache(id, id, 'A channel', ''));
      await db.saveProgress(Progress.named(progress: 0.4, videoId: id));
    }

    expect(await library.getUserHistory(1, 20),
        unorderedEquals(['first', 'second']));
    expect(await library.getUserHistory(2, 20), isEmpty);

    await library.deleteFromUserHistory('first');
    expect(await library.getUserHistory(1, 20), ['second']);
    expect(db.getVideoProgress('first'), 0);

    await library.clearUserHistory();
    expect(await library.getUserHistory(1, 20), isEmpty);
    expect(db.getVideoProgress('second'), 0);
  });

  test('private playlists load every page before and after refresh', () async {
    final pages = _PagedPlaylists();
    service = pages;
    final cubit = PlaylistCubit(
        PlaylistState(playlist: pages.first, playlistItemHeight: 0),
        _UnusedPlayer());
    await cubit.stream.firstWhere((state) => !state.loading);
    expect(
        cubit.state.playlist.videos.map((v) => v.videoId), ['first', 'second']);
    expect(pages.requests, [1, 2]);

    cubit.refreshPlaylist(userPlaylist: true);
    await cubit.stream.firstWhere((state) => !state.loading);
    expect(cubit.state.playlist.videos.length, 2);
    expect(pages.requests, [1, 2, null, 1, 2]);
    await cubit.close();
  });

  test('local history changes refresh Continue Watching after deleting data',
      () async {
    for (final id in ['first', 'second']) {
      await db.upsertHistoryVideo(HistoryVideoCache(id, id, '', ''));
    }
    final list =
        ItemListCubit<String>(ItemListState(itemList: FixedItemList([])));
    final cubit = HistoryCubit(null, list, local: true);
    final observed = <List<String>>[];
    void onChanged() =>
        observed.add(db.getLocalHistory().map((v) => v.videoId).toList());
    playbackHistoryRevision.addListener(onChanged);
    try {
      await cubit.removeFromHistory('first');
      await cubit.clearHistory();
      expect(observed, [
        ['second'],
        <String>[]
      ]);
    } finally {
      playbackHistoryRevision.removeListener(onChanged);
      await cubit.close();
      await list.close();
    }
  });
}

class _PagedPlaylists extends Service {
  final requests = <int?>[];
  final first = const Playlist(
      type: invidiousPlaylist,
      title: 'Private',
      playlistId: 'private',
      author: '',
      videoCount: 2,
      videos: [Video(videoId: 'first')]);

  @override
  Future<Playlist> getUserPlaylist(String playlistId, {int? page}) async {
    requests.add(page);
    return page == 2
        ? first.copyWith(videos: [const Video(videoId: 'second')])
        : first;
  }

  @override
  Future<Playlist> getPublicPlaylists(String playlistId,
          {int? page, bool saveLastSeen = true}) async =>
      throw StateError('Private playlists must use the authenticated endpoint');
}

class _UnusedPlayer implements PlayerCubit {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
