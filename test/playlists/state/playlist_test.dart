import 'dart:async';

import 'package:clipious/globals.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_progress.dart';
import 'package:clipious/playlists/states/playlist.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:flutter_test/flutter_test.dart';

class _PlaylistService extends Service {
  final deletions = <Completer<void>>[];
  final pages = <Completer<Playlist>>[];
  final mutationOwners = <({IDbClient? database, Server? server})>[];
  final deletedPlaylists = <String>[];

  @override
  Future<Playlist> getUserPlaylist(String playlistId,
      {int? page, Server? serverOverride}) {
    final response = Completer<Playlist>();
    pages.add(response);
    return response.future;
  }

  @override
  Future<void> deleteUserPlaylistVideo(String playlistId, String indexId,
      {IDbClient? database, Server? serverOverride}) {
    mutationOwners.add((database: database, server: serverOverride));
    final response = Completer<void>();
    deletions.add(response);
    return response.future;
  }

  @override
  Future<void> deleteUserPlaylist(String playlistId,
      {IDbClient? database, Server? serverOverride}) async {
    mutationOwners.add((database: database, server: serverOverride));
    deletedPlaylists.add(playlistId);
  }
}

class _UnusedPlayer implements PlayerCubit {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  const video = Video(videoId: 'saved', indexId: 'index');
  const playlist = Playlist(
      type: invidiousPlaylist,
      title: 'Saved',
      playlistId: 'private',
      author: '',
      videoCount: 1,
      videos: [video]);
  late Service previousService;
  late _PlaylistService playlists;
  late PlaylistCubit cubit;

  Future<void> replacePlaylist(Playlist value,
      {PlaylistReference? bookmarkOwner}) async {
    await cubit.close();
    cubit = PlaylistCubit(PlaylistState(playlist: value), _UnusedPlayer(),
        bookmarkOwner: bookmarkOwner);
    await cubit.loader.ready;
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> waitForDeletion(int count) async {
    for (var i = 0; i < 20 && playlists.deletions.length < count; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(playlists.deletions, hasLength(count));
  }

  Future<void> waitForPages(int count) async {
    for (var i = 0; i < 20 && playlists.pages.length < count; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(playlists.pages, hasLength(count));
  }

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    await db.upsertServer(const Server(url: 'https://playlist.example'));
    previousService = service;
    service = playlists = _PlaylistService();
    cubit =
        PlaylistCubit(const PlaylistState(playlist: playlist), _UnusedPlayer());
    await cubit.loader.ready;
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    if (!cubit.isClosed) await cubit.close();
    service = previousService;
    await db.close();
  });

  test('failed removal retains the video and releases loading for retry',
      () async {
    final removal = cubit.removeVideoFromPlayList(video);
    final failed = expectLater(removal, throwsStateError);
    await waitForDeletion(1);
    playlists.deletions.single.completeError(StateError('offline'));
    await failed;
    expect(cubit.state.loading, isFalse);
    expect(cubit.state.playlist.videos.single.videoId, video.videoId);

    final retry = cubit.removeVideoFromPlayList(video);
    await waitForDeletion(2);
    playlists.deletions.last.complete();
    await waitForPages(1);
    playlists.pages.single
        .complete(playlist.copyWith(videoCount: 0, videos: []));
    await retry;
    expect(cubit.loader.error, isNull);
    expect(cubit.loader.videos, isEmpty);
    expect(cubit.state.loading, isFalse);
    expect(cubit.state.playlist.videos, isEmpty);
    expect(cubit.state.playlist.videoCount, 0);
  });

  test('successful deletion invalidates a late page from the previous list',
      () async {
    const survivor = Video(videoId: 'survivor', indexId: 'survivor');
    final partial = playlist.copyWith(videoCount: 3);
    await replacePlaylist(partial);
    await waitForPages(1);
    playlists.pages[0].complete(partial.copyWith(videos: [video, survivor]));
    await waitForPages(2);
    final removal =
        cubit.removeVideoFromPlayList(cubit.state.playlist.videos.first);
    await waitForDeletion(1);
    playlists.deletions.single.complete();
    await waitForPages(3);
    playlists.pages[2]
        .complete(playlist.copyWith(videoCount: 1, videos: [survivor]));
    await removal;
    playlists.pages[1].complete(partial.copyWith(videos: [video]));
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.playlist.videos.map((entry) => entry.videoId),
        ['survivor']);
    expect(cubit.loader.videos.map((entry) => entry.videoId), ['survivor']);
    expect(cubit.state.loading, isFalse);
  });

  test('successful deletion after closing does not emit to a disposed screen',
      () async {
    final removal = cubit.removeVideoFromPlayList(video);
    await waitForDeletion(1);
    await cubit.close();
    playlists.deletions.single.complete();
    await removal;
    await cubit.removeVideoFromPlayList(video);
    expect(playlists.deletions, hasLength(1));
  });

  test('switching accounts at the same origin blocks a stale detail mutation',
      () async {
    const other = Server(url: 'https://playlist.example', id: 'other');
    await db.upsertServer(other);
    await db.useServer(other);
    await expectLater(cubit.removeVideoFromPlayList(video), throwsStateError);
    await expectLater(cubit.deletePlaylist(), throwsStateError);
    expect(playlists.deletions, isEmpty);
  });

  test('profile changes block stale detail mutations', () async {
    expect(cubit.canPlayEntries, isTrue);
    final other = await db.createProfile('Other');
    await db.useProfile(other.id);
    expect(cubit.canPlayEntries, isFalse);
    expect(await cubit.playbackRequest(video: video), isNull);
    await expectLater(cubit.removeVideoFromPlayList(video), throwsStateError);
    expect(playlists.deletions, isEmpty);
  });

  test('public playlist details cannot mutate the source', () async {
    await replacePlaylist(playlist.copyWith(playlistId: 'PLpublic'));
    await expectLater(cubit.removeVideoFromPlayList(video), throwsStateError);
    await expectLater(cubit.deletePlaylist(), throwsStateError);
    expect(playlists.deletions, isEmpty);
  });

  test('remote public bookmarks delete only their captured account bookmark',
      () async {
    final account = await db.getCurrentlySelectedServer();
    final owner = PlaylistReference(
        kind: PlaylistSourceKind.account,
        playlistId: 'PLpublic',
        profileId: db.profileId,
        accountId: account.accountId,
        origin: Uri.parse(account.url).origin);
    await replacePlaylist(playlist.copyWith(playlistId: 'PLpublic'),
        bookmarkOwner: owner);
    expect(cubit.reference!.kind, PlaylistSourceKind.public);
    await expectLater(cubit.removeVideoFromPlayList(video), throwsStateError);
    await cubit.deletePlaylist();
    expect(playlists.deletedPlaylists, ['PLpublic']);
    expect(
        playlists.mutationOwners.single.server?.accountId, account.accountId);
    expect(
        playlists.mutationOwners.single.database?.profileId, owner.profileId);

    const other = Server(url: 'https://playlist.example', id: 'other');
    await db.upsertServer(other);
    await db.useServer(other);
    await expectLater(cubit.deletePlaylist(), throwsStateError);
    expect(playlists.deletedPlaylists, ['PLpublic']);
  });

  test('mismatched bookmark identity cannot authorize a public deletion',
      () async {
    final account = await db.getCurrentlySelectedServer();
    await replacePlaylist(playlist.copyWith(playlistId: 'PLpublic'),
        bookmarkOwner: PlaylistReference(
            kind: PlaylistSourceKind.account,
            playlistId: 'PLanother',
            profileId: db.profileId,
            accountId: account.accountId,
            origin: Uri.parse(account.url).origin));
    await expectLater(cubit.deletePlaylist(), throwsStateError);
    expect(playlists.deletedPlaylists, isEmpty);
  });

  test('pending deletion retains its captured account and fixed profile view',
      () async {
    final account = await db.getCurrentlySelectedServer();
    final removal = cubit.removeVideoFromPlayList(video);
    await waitForDeletion(1);
    final other = await db.createProfile('Other');
    await db.useProfile(other.id);
    final captured = playlists.mutationOwners.single;
    expect(captured.server?.accountId, account.accountId);
    expect(captured.database?.profileId, account.profileId);
    expect(captured.database?.profileId, isNot(db.profileId));
    playlists.deletions.single.complete();
    await removal;
  });

  test('revealing one filtered occurrence preserves every other filter',
      () async {
    await replacePlaylist(playlist.copyWith(videoCount: 3, videos: [
      const Video(videoId: 'same', indexId: 'first', filtered: true),
      const Video(videoId: 'same', indexId: 'second', filtered: true),
      const Video(videoId: 'hidden', filterHide: true, filtered: true),
    ]));
    final entries = cubit.state.playlist.videos;
    expect(await cubit.playbackRequest(video: entries[1]), isNull);
    final request = await cubit.playbackRequest(
        video: entries[1].copyWith(filtered: false, title: 'Untrusted title'));
    expect(request?.startIndex, 1);
    expect(request?.videos.map((entry) => entry.filtered), [true, false, true]);
    expect(request?.videos[1].title, entries[1].title);
    expect(entries[1].filtered, isTrue);
    expect(
        await cubit.playbackRequest(
            video: entries[2].copyWith(filtered: false, filterHide: false)),
        isNull);
    expect(
        await cubit.playbackRequest(
            video: entries[1].copyWith(videoId: 'different', filtered: false)),
        isNull);
  });

  test(
      'selected duplicate maps to its occurrence while hidden rows stay indexed',
      () async {
    await replacePlaylist(playlist.copyWith(videoCount: 4, videos: [
      const Video(videoId: 'same', indexId: 'first'),
      const Video(videoId: 'hidden', filterHide: true),
      const Video(videoId: 'same', indexId: 'second'),
      const Video(videoId: 'future', isUpcoming: true),
    ]));
    final entries = cubit.state.playlist.videos;
    final request = await cubit.playbackRequest(video: entries[2]);
    expect(request?.startIndex, 2);
    expect(request?.videos, hasLength(4));
    expect(await cubit.playbackRequest(video: entries[1]), isNull);
    expect(await cubit.playbackRequest(video: entries[3]), isNull);
    expect(cubit.playableVideos, hasLength(2));
  });

  test('explicit resume keeps precise time beyond the watched threshold',
      () async {
    await replacePlaylist(
        playlist.copyWith(videos: [video.copyWith(lengthSeconds: 1000)]));
    final selected = cubit.state.playlist.videos.single;
    await db.saveProgress(Progress(.946, selected.videoId,
        positionSeconds: 946, durationSeconds: 1000));
    await PlaylistProgressService.forProfile(db, db.profileId)
        .save(cubit.reference!, selected, entries: cubit.state.playlist.videos);
    expect((await cubit.playbackRequest(resume: true))?.startAt,
        const Duration(seconds: 946));
    expect((await cubit.playbackRequest(resume: true))?.audio, isNull);
    expect((await cubit.playbackRequest(fromBeginning: true))?.startAt,
        Duration.zero);
  });

  for (final audio in [true, false]) {
    test('resume restores saved ${audio ? 'audio' : 'video'} mode', () async {
      final entries = cubit.state.playlist.videos;
      await PlaylistProgressService.forProfile(db, db.profileId).save(
          cubit.reference!, entries.first,
          entries: entries, audio: audio);
      expect((await cubit.playbackRequest(resume: true))?.audio, audio);
      expect((await cubit.playbackRequest(resume: true, audio: !audio))?.audio,
          !audio);
      expect((await cubit.playbackRequest(fromBeginning: true))?.audio, isNull);
      expect(
          (await cubit.playbackRequest(video: entries.first))?.audio, isNull);
      expect(
          (await cubit.playbackRequest(fromBeginning: true, audio: !audio))
              ?.audio,
          !audio);
    });
  }

  test('completed entry continues at the next occurrence from its beginning',
      () async {
    await replacePlaylist(playlist.copyWith(videoCount: 2, videos: [
      video.copyWith(indexId: 'first', lengthSeconds: 1000),
      video.copyWith(indexId: 'second', lengthSeconds: 1000),
    ]));
    final entries = cubit.state.playlist.videos;
    await db.saveProgress(Progress(1, video.videoId,
        positionSeconds: 1000, durationSeconds: 1000));
    await PlaylistProgressService.forProfile(db, db.profileId).save(
        cubit.reference!, entries.first,
        entries: entries, completed: true);
    final request = await cubit.playbackRequest(resume: true);
    expect(request?.startIndex, 1);
    expect(request?.startAt, Duration.zero);
  });
}
