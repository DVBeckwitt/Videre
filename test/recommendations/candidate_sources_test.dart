import 'dart:async';
import 'dart:convert';

import 'package:clipious/globals.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/recommendations/candidate_sources.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String _id(int index) => index.toString().padLeft(11, 'v');

Map<String, Object?> _video(int index, {String? title}) => {
      'type': 'video',
      'videoId': _id(index),
      'title': title ?? 'Video $index',
      'author': 'Uploader',
      'lengthSeconds': 180,
    };

Future<void> _savePlaylists(List<Playlist> playlists) =>
    db.saveSetting(SettingsValue(localPlaylistsSetting,
        jsonEncode(playlists.map((playlist) => playlist.toJson()).toList())));

class _MusicCatalog extends MusicCatalogService {
  int calls = 0;
  String? artist;
  List<MusicTrack> tracks = [];
  Completer<List<MusicTrack>>? pending;

  @override
  Future<List<MusicTrack>> getDiscoverySongs(
      {String? artist, bool Function()? isCurrent}) async {
    calls++;
    this.artist = artist;
    return pending == null ? tracks : await pending!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockClient client;
  late Service api;
  late Future<http.Response> Function(http.Request) respond;
  final requests = <http.Request>[];

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
    await db.upsertServer(const Server(url: 'https://invidious.example'));
    requests.clear();
    respond = (request) async => http.Response('[]', 200,
        request: request, headers: {'content-type': 'application/json'});
    client = MockClient((request) {
      requests.add(request);
      expect(request.url.origin, 'https://invidious.example');
      return respond(request);
    });
    api = Service(httpClient: client);
  });

  tearDown(() async {
    client.close();
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
    await db.close();
  });

  test('local pools keep music separate and never fetch playback metadata',
      () async {
    await db.upsertHistoryVideo(HistoryVideoCache(
        _id(1), 'Watched video', 'Uploader', '',
        lengthSeconds: 120));
    await db.upsertHistoryVideo(HistoryVideoCache(
        _id(2), 'Listened song', 'Artist', '',
        musicMetadata:
            const MusicMetadata(title: 'Listened song', artist: 'Artist')));
    await MusicLibraryService.forProfile(db, db.profileId).save(
        MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: _id(3),
            title: 'Saved song',
            subtitle: 'Saved artist'));
    final candidates = RecommendationCandidates(db, api: api);

    expect(candidates.localVideos().map((item) => item.videoId), [_id(1)]);
    expect(
        candidates.localMusic().map((item) => item.videoId), [_id(3), _id(2)]);
    expect(candidates.localMusic().every((item) => item.playbackVideo == null),
        isTrue);
    expect(requests, isEmpty);
  });

  test('local music deduplicates saved/history entries and respects limits',
      () async {
    await MusicLibraryService.forProfile(db, db.profileId).save(
        MusicLibraryEntry(
            kind: MusicLibraryKind.song, id: _id(1), title: 'Song'));
    await db.upsertHistoryVideo(HistoryVideoCache(_id(1), 'Song', 'Artist', '',
        musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist')));
    await db.upsertHistoryVideo(HistoryVideoCache(
        _id(2), 'Song 2', 'Artist', '',
        musicMetadata: const MusicMetadata(title: 'Song 2', artist: 'Artist')));
    final candidates = RecommendationCandidates(db, api: api);

    expect(
        candidates.localMusic().map((item) => item.videoId), [_id(1), _id(2)]);
    expect(
        candidates.localMusic(limit: 1).map((item) => item.videoId), [_id(1)]);
    expect(candidates.localMusic(limit: 0), isEmpty);
    expect(
        candidates.localMusic(limit: 1, ids: {_id(2)}).single.videoId, _id(2));
    expect(requests, isEmpty);
  });

  test(
      'unplayed saved playlists seed only their matching domain without learning',
      () async {
    await _savePlaylists([
      Playlist(
          title: 'Videos',
          playlistId: 'local:videos',
          author: '',
          videoCount: 1,
          videos: [Video(videoId: _id(1), title: 'Saved video')]),
      Playlist(
          title: 'Music',
          playlistId: 'local:music',
          author: '',
          videoCount: 1,
          videos: [
            Video(videoId: _id(2), title: 'Marked song', author: 'Artist')
          ]),
      Playlist(
          title: 'Mixed',
          playlistId: 'local:mixed',
          author: '',
          videoCount: 2,
          videos: [
            Video(videoId: _id(3), title: 'Another video'),
            Video(
                videoId: _id(4),
                title: 'Tagged song',
                musicMetadata: const MusicMetadata(
                    title: 'Tagged song', artist: 'Artist')),
          ]),
    ]);
    await MusicLibraryService.forProfile(db, db.profileId)
        .markLocalPlaylist('local:music');
    final candidates = RecommendationCandidates(db, api: api);
    final stored = db.getSettings(localPlaylistsSetting)?.value;

    expect(
        candidates.localVideos().map((item) => item.videoId), [_id(1), _id(3)]);
    final music = candidates.localMusic();
    expect(music.map((item) => item.videoId), [_id(2), _id(4)]);
    expect(music.first.artists, ['Artist']);
    expect(music.every((item) => item.playbackVideo == null), isTrue);
    expect(candidates.listeningHistory(), isEmpty);
    expect(db.getLocalHistory(), isEmpty);
    expect(db.getSettings('recommendations-video-v1'), isNull);
    expect(db.getSettings('recommendations-music-v1'), isNull);
    expect(db.getSettings(localPlaylistsSetting)?.value, stored);
    expect(requests, isEmpty);
  });

  test('playlist seeds follow saved songs and history within each shared cap',
      () async {
    await MusicLibraryService.forProfile(db, db.profileId).save(
        MusicLibraryEntry(
            kind: MusicLibraryKind.song, id: _id(1), title: 'Bookmarked song'));
    await db.upsertHistoryVideo(HistoryVideoCache(
        _id(2), 'Listen', 'Artist', '',
        musicMetadata: const MusicMetadata(title: 'Listen', artist: 'Artist')));
    await db.upsertHistoryVideo(
        HistoryVideoCache(_id(3), 'Watched video', 'Uploader', ''));
    await _savePlaylists([
      Playlist(
          title: 'Videos',
          playlistId: 'local:videos',
          author: '',
          videoCount: 101,
          videos: [
            Video(videoId: _id(3), title: 'Duplicate watched video'),
            for (var i = 10; i < 110; i++)
              Video(videoId: _id(i), title: 'Saved video $i'),
          ]),
      Playlist(
          title: 'Music',
          playlistId: 'local:music',
          author: '',
          videoCount: 102,
          videos: [
            Video(videoId: _id(1), title: 'Duplicate bookmark'),
            Video(videoId: _id(2), title: 'Duplicate listen'),
            for (var i = 110; i < 210; i++)
              Video(videoId: _id(i), title: 'Saved song $i'),
          ]),
    ]);
    await MusicLibraryService.forProfile(db, db.profileId)
        .markLocalPlaylist('local:music');
    final candidates = RecommendationCandidates(db, api: api);

    final videos = candidates.localVideos(limit: 1000);
    expect(videos, hasLength(80));
    expect(videos.take(2).map((item) => item.videoId), [_id(3), _id(10)]);
    expect(videos.map((item) => item.videoId).toSet(), hasLength(80));
    final music = candidates.localMusic(limit: 1000);
    expect(music, hasLength(80));
    expect(
        music.take(3).map((item) => item.videoId), [_id(1), _id(2), _id(110)]);
    expect(music.map((item) => item.videoId).toSet(), hasLength(80));
    expect(requests, isEmpty);
  });

  test('saved songs cannot starve the separate recent listening pool',
      () async {
    await MusicLibraryService.forProfile(db, db.profileId).importSongs([
      for (var i = 0; i < 20; i++)
        MusicLibraryEntry(
            kind: MusicLibraryKind.song, id: _id(i), title: 'Saved song $i'),
    ]);
    await db.upsertHistoryVideo(HistoryVideoCache(
        _id(21), 'Older listen', 'Artist', '',
        musicMetadata:
            const MusicMetadata(title: 'Older listen', artist: 'Artist'))
      ..created = DateTime(2026, 1, 1));
    await db.upsertHistoryVideo(HistoryVideoCache(
        _id(22), 'Recent listen', 'Artist', '',
        musicMetadata:
            const MusicMetadata(title: 'Recent listen', artist: 'Artist'))
      ..created = DateTime(2026, 1, 2));
    await db.upsertHistoryVideo(
        HistoryVideoCache(_id(23), 'Recent video', 'Uploader', '')
          ..created = DateTime(2026, 1, 3));
    final candidates = RecommendationCandidates(db, api: api);

    expect(candidates.localMusic(limit: 2).map((item) => item.videoId),
        isNot(contains(_id(22))));
    expect(candidates.listeningHistory().map((item) => item.videoId),
        [_id(22), _id(21)]);
    expect(candidates.listeningHistory(limit: 1).single.videoId, _id(22));
    expect(candidates.listeningHistory(limit: 0), isEmpty);
    expect(requests, isEmpty);
  });

  test('history keeps the linked occurrence of two identically named artists',
      () async {
    const id = 'UCabcdefghijklmnopqrstuv';
    const metadata =
        MusicMetadata(title: 'Duet', artist: 'River, River', artistCredits: [
      MusicArtistCredit(name: 'River'),
      MusicArtistCredit(name: 'River', id: id),
    ]);
    await db.upsertHistoryVideo(HistoryVideoCache(
        _id(21), 'Duet', 'River, River', '',
        musicMetadata: metadata));
    final track =
        RecommendationCandidates(db, api: api).listeningHistory().single;
    expect(
        track.toVideo().musicMetadata!.artistCredits.map((credit) => credit.id),
        [null, id]);
    final ambiguous = MusicArtistCredit.fromCatalog(
        ['River', 'River'], [const MusicArtist(name: 'River', id: id)]);
    expect(ambiguous.map((credit) => credit.id), [null, null]);
  });

  test('older listens reuse a verified cover from the active profile',
      () async {
    const cover = 'https://lh3.googleusercontent.com/saved-cover';
    final frame = '/vi/${_id(1)}/default.jpg';
    final listen = HistoryVideoCache(_id(1), 'Song', 'Artist', frame,
        musicMetadata:
            MusicMetadata(title: 'Song', artist: 'Artist', thumbnails: [
          ImageObject(null, frame, 320, 180),
        ]));
    await db.upsertHistoryVideo(listen);
    final candidates = RecommendationCandidates(db, api: api);
    final uncached = candidates.listeningHistory().single;
    expect(uncached.thumbnails, isEmpty);
    expect(uncached.displayThumbnails.single.url, frame);

    await MusicLibraryService.forProfile(db, db.profileId).save(
        MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: _id(1),
            title: 'Saved title',
            thumbnails: [ImageObject(null, cover, 512, 512)]));
    final current = candidates.listeningHistory().single;
    expect(current.title, 'Song');
    expect(current.thumbnails.single.url, cover);
    expect(current.displayThumbnails.map((image) => image.url), [cover, frame]);
    expect(current.videoThumbnails.single.url, frame);

    final other = await db.createProfile('Another listener');
    await db.useProfile(other.id);
    await db.upsertHistoryVideo(listen);
    expect(candidates.listeningHistory(), isEmpty);
    final otherListen =
        RecommendationCandidates(db, api: api).listeningHistory().single;
    expect(otherListen.thumbnails, isEmpty);
    expect(otherListen.displayThumbnails.single.url, frame);
    expect(requests, isEmpty);
  });

  test('old profile providers cannot read the newly selected library',
      () async {
    await db.upsertHistoryVideo(
        HistoryVideoCache(_id(1), 'Old profile', 'Uploader', ''));
    await _savePlaylists([
      Playlist(
          title: 'Old playlist',
          playlistId: 'local:saved',
          author: '',
          videoCount: 1,
          videos: [Video(videoId: _id(2), title: 'Old saved video')]),
    ]);
    final candidates = RecommendationCandidates(db, api: api);
    final next = await db.createProfile('Next person');
    await db.useProfile(next.id);
    await _savePlaylists([
      Playlist(
          title: 'New playlist',
          playlistId: 'local:saved',
          author: '',
          videoCount: 1,
          videos: [Video(videoId: _id(3), title: 'New saved video')]),
    ]);

    expect(candidates.localVideos(), isEmpty);
    expect(candidates.localMusic(), isEmpty);
    expect(candidates.listeningHistory(), isEmpty);
    await expectLater(candidates.discoverVideos(query: 'test'),
        throwsA(isA<RecommendationCandidatesCancelled>()));
    expect(
        RecommendationCandidates(db, api: api)
            .localVideos()
            .map((item) => item.videoId),
        [_id(3)]);
    expect(requests, isEmpty);
  });

  test('cold profile without a query does not invent a remote seed', () async {
    expect(
        await RecommendationCandidates(db, api: api).discoverVideos(), isEmpty);
    expect(requests, isEmpty);
  });

  test('video search makes one bounded unenriched selected-instance request',
      () async {
    respond = (request) async => http.Response(
        jsonEncode([
          _video(0, title: '[Private video]'),
          _video(1, title: 'Blocked title'),
          for (var i = 2; i < 65; i++) _video(i),
          _video(2),
        ]),
        200,
        request: request);
    await db.saveFilter(VideoFilter(value: 'Blocked')..hideFromFeed = true);
    final videos = await RecommendationCandidates(db, api: api)
        .discoverVideos(query: '  sample\nquery  ');

    expect(requests, hasLength(1));
    expect(requests.single.url.path, '/api/v1/search');
    expect(requests.single.url.queryParameters['q'], 'sample query');
    expect(videos, hasLength(40));
    expect(videos.first.videoId, _id(2));
    expect(videos.map((item) => item.videoId).toSet(), hasLength(40));
    expect(videos.every((item) => item.playbackConnection == null), isTrue);
  });

  test('related pool reads one seed and strips stream-bearing metadata',
      () async {
    respond = (request) async => http.Response(
        jsonEncode({
          ..._video(1),
          'recommendedVideos': [
            _video(1),
            {
              ..._video(2),
              'likeCount': 12,
              'publishedText': '2 days ago',
              'dashUrl': 'https://invidious.example/manifest?token=temporary',
              'hlsUrl': 'https://invidious.example/live?token=temporary',
            },
          ],
        }),
        200,
        request: request);
    final videos = await RecommendationCandidates(db, api: api)
        .discoverVideos(seed: Video(videoId: _id(1), title: 'Seed'));

    expect(requests, hasLength(1));
    expect(requests.single.url.path, '/api/v1/videos/${_id(1)}');
    expect(videos.map((item) => item.videoId), [_id(2)]);
    expect(videos.single.dashUrl, isNull);
    expect(videos.single.hlsUrl, isNull);
    expect(videos.single.likeCount, 12);
    expect(videos.single.publishedText, '2 days ago');
  });

  test('Flow queries and selected subscription feed share three requests',
      () async {
    const account = Server(
        id: 'followed-profile-account',
        url: 'https://invidious.example',
        authToken: 'test-only');
    await db.upsertServer(account);
    await db.useServer(account);
    respond = (request) async {
      final feed = request.url.path == '/api/v1/auth/feed';
      final index =
          request.url.queryParameters['q'] == 'first interest' ? 1 : 2;
      return http.Response(
          jsonEncode(feed
              ? {
                  'videos': [_video(3)],
                  'notifications': [],
                }
              : [_video(index)]),
          200,
          request: request);
    };
    final provider = RecommendationCandidates(db, api: api);
    final videos = await provider.discoverVideos(
      queries: [
        'first interest',
        'first interest',
        'second interest',
        'unused'
      ],
      includeSubscriptions: true,
    );
    expect(requests.map((request) => request.url.path),
        ['/api/v1/search', '/api/v1/search', '/api/v1/auth/feed']);
    expect(videos.map((video) => video.videoId), [_id(1), _id(2), _id(3)]);

    await provider
        .discoverVideos(queries: ['first interest', 'second interest']);
    expect(requests, hasLength(3), reason: 'reuse in-connection query results');
  });

  test('invalidating discovery prevents pending 429 retry and next query',
      () async {
    var current = true;
    api = Service(
        httpClient: client,
        wait: (_) async {
          current = false;
        });
    respond = (request) async =>
        http.Response('', 429, request: request, headers: {'retry-after': '1'});
    await expectLater(
        RecommendationCandidates(db, api: api).discoverVideos(
            queries: ['first', 'second'], isCurrent: () => current),
        throwsA(isA<RecommendationCandidatesCancelled>()));
    expect(requests, hasLength(1));
    expect(requests.single.url.queryParameters['q'], 'first');
  });

  test('changing account discards an in-flight discovery response', () async {
    final response = Completer<http.Response>();
    final started = Completer<void>();
    respond = (request) {
      started.complete();
      return response.future;
    };
    final future =
        RecommendationCandidates(db, api: api).discoverVideos(query: 'pending');
    final expectation = expectLater(future, throwsA(anything));
    await started.future;
    const next = Server(
        id: 'second-account',
        url: 'https://invidious.example',
        authToken: 'test-only-token');
    await db.upsertServer(next);
    await db.useServer(next);
    response.complete(
        http.Response(jsonEncode([_video(1)]), 200, request: requests.single));

    await expectation;
    expect(requests, hasLength(1));
  });

  test('music discovery delegates once and returns bounded catalog-only tracks',
      () async {
    final catalog = _MusicCatalog()
      ..tracks = [
        for (var i = 0; i < 12; i++)
          MusicTrack(
            videoId: _id(i),
            title: 'Song $i',
            artists: const ['Artist', 'Guest', 'Artist'],
            artistLinks: const [
              MusicArtist(name: 'Artist', id: 'UC1234567890123456789012'),
              MusicArtist(name: 'Artist', id: 'UCabcdefghijklmnopqrstuv'),
            ],
            playbackVideo: Video(
                videoId: _id(i), hlsUrl: 'https://invidious.example/stream'),
          ),
      ];
    final tracks =
        await RecommendationCandidates(db, api: api, musicCatalog: catalog)
            .discoverMusic(artist: '  Artist  ');

    expect(catalog.calls, 1);
    expect(catalog.artist, 'Artist');
    expect(tracks, hasLength(6));
    expect(tracks.first.artists, ['Artist', 'Guest', 'Artist']);
    expect(tracks.first.musicMetadata.artistCredits.map((credit) => credit.id),
        ['UC1234567890123456789012', null, 'UCabcdefghijklmnopqrstuv']);
    expect(tracks.every((track) => track.playbackVideo == null), isTrue);
    expect(requests, isEmpty);
  });

  test('a revoked shelf discards a pending music batch', () async {
    var current = true;
    final catalog = _MusicCatalog()..pending = Completer<List<MusicTrack>>();
    final source = RecommendationCandidates(db,
        api: api, musicCatalog: catalog, isCurrent: () => current);
    final result = source.discoverMusic();
    final expectation =
        expectLater(result, throwsA(isA<RecommendationCandidatesCancelled>()));
    await Future<void>.delayed(Duration.zero);
    current = false;
    catalog.pending!.complete([MusicTrack(videoId: _id(1), title: 'Old song')]);

    await expectation;
  });
}
