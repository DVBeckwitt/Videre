import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart' as globals;
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:clipious/search/states/search.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/states/add_to_playlist.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_settings_cubit.dart';

class _LibraryService extends Service {
  final playlists = <String, Playlist>{
    'local:chosen': const Playlist(
        title: 'Chosen', playlistId: 'local:chosen', author: '', videoCount: 0),
    'local:likes': const Playlist(
        title: likePlaylistName,
        playlistId: 'local:likes',
        author: '',
        videoCount: 0),
  };
  bool fail = false;

  @override
  Future<List<Playlist>> getUserPlaylists({bool postProcessing = true}) async =>
      playlists.values.toList();

  @override
  Future<void> addVideoToPlaylist(String playListId, String videoId,
      {Video? video}) async {
    if (fail) throw StateError('Fixture save failed');
    final previous = playlists[playListId]!;
    if (!previous.videos.any((item) => item.videoId == videoId)) {
      playlists[playListId] = previous.copyWith(
          videos: [...previous.videos, video!],
          videoCount: previous.videoCount + 1);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('videre/recommendations');
  const video =
      Video(videoId: 'abcdefghijk', title: 'A video', author: 'A creator');
  late SembastSqfDb database;
  late _LibraryService library;
  late List<Map<Object?, Object?>> calls;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    globals.db = database;
    globals.service = library = _LibraryService();
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final request = call.arguments as Map<Object?, Object?>;
      calls.add(request);
      return {
        'state': {
          'schemaVersion': 1,
          'domain': request['domain'],
          'totalInteractions': calls.length,
        },
        'ranked': <Object?>[],
        'summary': <String, Object?>{},
      };
    });
  });

  tearDown(() async {
    await RecommendationService.flushPending();
    RecommendationService.forgetProfile(database, database.profileId);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await database.close();
  });

  test('submitted video search learns, typing and disabled history do not',
      () async {
    final app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription = const Stream.empty().listen((_) {});
    final settings = TestSettingsCubit(SettingsState.init(), app);
    final search = SearchCubit(SearchState.init(query: 'space'), settings);
    try {
      expect(calls, isEmpty);
      await search.search('space');
      expect(calls, hasLength(1));
      final event = (calls.single['events'] as List).single as Map;
      expect(event['type'], 'search');
      expect(event['query'], 'space');
      await settings.setUseSearchHistory(false);
      await search.search('space');
      expect(calls, hasLength(1));
    } finally {
      await search.close();
      await settings.close();
      await app.close();
    }
  });

  test('successful explicit playlist save learns once, repeated save does not',
      () async {
    final cubit = AddToPlaylistCubit(
        const AddToPlaylistController('abcdefghijk'),
        video: video);
    try {
      await cubit.onReady();
      expect(calls, isEmpty);
      await cubit.addToPlaylist('local:chosen');
      expect(calls, hasLength(1));
      expect(((calls.single['events'] as List).single as Map)['type'], 'save');
      await cubit.saveVideoToPlaylist('local:chosen');
      expect(calls, hasLength(1));
    } finally {
      await cubit.close();
    }
  });

  test('failed save does not train and explicit like has its own signal',
      () async {
    final cubit = AddToPlaylistCubit(
        const AddToPlaylistController('abcdefghijk'),
        video: video);
    try {
      await cubit.onReady();
      library.fail = true;
      await expectLater(cubit.addToPlaylist('local:chosen'), throwsStateError);
      expect(calls, isEmpty);
      library.fail = false;
      await cubit.toggleLike();
      expect(calls, hasLength(1));
      expect(((calls.single['events'] as List).single as Map)['type'], 'like');
    } finally {
      await cubit.close();
    }
  });
}
