import 'dart:async';

import 'package:clipious/globals.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_song_radio.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/models/errors/no_server_selected.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

const _artist = 'UC0123456789012345678901';
const _relatedArtist = 'UCabcdefghijklmnopqrstuv';

MusicTrack _track(int index, {String? artist}) => MusicTrack(
    videoId: index.toString().padLeft(11, 'r'),
    title: 'Song $index',
    artists: const ['Local display name'],
    uploaderChannelId: artist);

class _Catalog extends MusicCatalogService {
  final related = <MusicTrack>[];
  final artistSongs = <MusicTrack>[];
  final relatedRequests = <List<String>>[];
  final artistRequests = <List<String>>[];
  Object? relatedError;
  Object? artistError;
  Completer<void>? artistStarted;
  Completer<List<MusicTrack>>? pendingArtistSongs;
  bool Function()? artistRequestIsCurrent;

  @override
  Future<List<MusicTrack>> getRelatedSongs(Iterable<String> seedIds,
      {bool Function()? isCurrent}) async {
    relatedRequests.add(seedIds.toList());
    if (relatedError case final error?) throw error;
    return related;
  }

  @override
  Future<List<MusicTrack>> getArtistMixSongs(Iterable<String> artistIds,
      {bool Function()? isCurrent}) async {
    artistRequests.add(artistIds.toList());
    artistRequestIsCurrent = isCurrent;
    artistStarted?.complete();
    if (artistError case final error?) throw error;
    final pending = pendingArtistSongs;
    return pending == null ? artistSongs : await pending.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Catalog catalog;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    catalog = _Catalog();
  });
  tearDown(() async => db.close());

  Future<List<Video>> load({
    Video? seed,
    bool Function()? isCurrent,
    Iterable<MusicTrack> Function(Iterable<MusicTrack>)? eligible,
  }) =>
      loadMusicSongRadio(seed ?? _track(0, artist: _artist).toVideo(),
          catalog: catalog,
          isCurrent: isCurrent ?? () => true,
          eligible: eligible ?? (tracks) => tracks);

  List<String> ids(Iterable<Video> videos) =>
      videos.map((video) => video.videoId).toList();
  List<String> trackIds(Iterable<int> indices) =>
      [for (final index in indices) _track(index).videoId];

  test('a sparse radio adds one bounded batch of eligible artist tracks',
      () async {
    catalog.related.addAll([_track(0), _track(1), _track(1), _track(9)]);
    catalog.artistSongs.addAll([
      _track(1),
      _track(0),
      _track(9),
      for (var index = 2; index <= 8; index++) _track(index),
    ]);
    final songs = await load(
        eligible: (tracks) =>
            tracks.where((track) => track.videoId != _track(9).videoId));
    expect(ids(songs), trackIds([0, 1, 2, 3, 4, 5, 6]));
    expect(catalog.relatedRequests, [
      trackIds([0])
    ]);
    expect(catalog.artistRequests, [
      [_artist]
    ]);
  });

  test('at least three related rows skip the optional request', () async {
    catalog.related.addAll([_track(1), _track(2), _track(3)]);
    expect(ids(await load()), trackIds([0, 1, 2, 3]));
    expect(catalog.artistRequests, isEmpty);
  });

  test('the first eligible related artist can anchor the extra batch',
      () async {
    catalog.related.addAll(
        [_track(1, artist: _artist), _track(2, artist: _relatedArtist)]);
    catalog.artistSongs.add(_track(3));
    expect(
        ids(await load(
            seed: _track(0).toVideo(),
            eligible: (tracks) =>
                tracks.where((track) => track.videoId != _track(1).videoId))),
        trackIds([0, 2, 3]));
    expect(catalog.artistRequests, [
      [_relatedArtist]
    ]);
  });

  test('a display name alone does not authorize a broad fallback', () async {
    final seed = _track(0).toVideo();
    expect(await load(seed: seed), isEmpty);
    expect(catalog.artistRequests, isEmpty);
  });

  test('the optional batch can supply a tail, but never a seed-only queue',
      () async {
    catalog.artistSongs.addAll([_track(0), _track(0)]);
    expect(await load(), isEmpty);
    catalog.artistSongs.add(_track(1));
    expect(ids(await load()), trackIds([0, 1]));
  });

  test('optional failure keeps the available related rows', () async {
    catalog.related.add(_track(1));
    catalog.artistError = const MusicCatalogConnectionFailure('Unavailable');
    expect(ids(await load()), trackIds([0, 1]));
  });

  test('optional failure without any eligible rows remains unavailable',
      () async {
    catalog.artistError = const MusicCatalogConnectionFailure('Unavailable');
    await expectLater(load(), throwsA(same(catalog.artistError)));
  });

  for (final error in [
    NoServerSelected(),
    InvidiousServiceError('Rate limited', statusCode: 429),
  ]) {
    test('a primary ${error.runtimeType} never starts fallback', () async {
      catalog.relatedError = error;
      await expectLater(load(), throwsA(same(error)));
      expect(catalog.artistRequests, isEmpty);
    });
  }

  test('route cancellation discards the pending artist batch', () async {
    catalog.related.add(_track(1));
    final requested = catalog.artistStarted = Completer<void>();
    final pending = catalog.pendingArtistSongs = Completer<List<MusicTrack>>();
    var current = true;
    final result = load(isCurrent: () => current);
    await requested.future;
    current = false;
    expect(catalog.artistRequestIsCurrent?.call(), isFalse);
    pending.complete([_track(2)]);
    expect(await result, isEmpty);
  });
}
