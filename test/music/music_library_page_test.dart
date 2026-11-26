import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/downloads/services/explicit_music_download.dart';
import 'package:clipious/downloads/models/music_playlist_offline.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' as app_globals;
import 'package:clipious/music/models/music_catalog_search.dart';
import 'package:clipious/music/models/music_download_order.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_layout.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/cached_music.dart';
import 'package:clipious/music/models/on_device_music_entry.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_visibility.dart';
import 'package:clipious/music/services/music_listening_history.dart';
import 'package:clipious/music/views/components/community_music_artwork.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/music/views/screens/music_library.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/models/named_music_queue.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/services/playlist_load_session.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

const _cacheChannel = MethodChannel('videre/proxy');
const _cacheServer =
    Server(url: 'https://offline-music.example', id: 'music', inUse: true);

Map<String, Object> _cachedSong(Video video, String digit) => {
      'videoId': video.videoId,
      'title': 'Cache metadata',
      'artist': 'Cached artist',
      'lengthSeconds': 84,
      'rendition': digit * 64,
    };

class _App extends AppCubit {
  _App() : super(AppState(0, null, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  onReady() {}

  @override
  initState() {}

  void profileChanged(String id) => emit(state.copyWith(profileId: id));

  void selectServer(Server server) => emit(state.copyWith(
      profileId: server.profileId,
      server: server,
      sessionRevision: state.sessionRevision + 1));
}

class _PlaylistSuggestionsCatalog extends MusicCatalogService {
  final List<MusicTrack> tracks;
  final requests = <List<String>>[];
  Completer<List<MusicTrack>>? pending;

  _PlaylistSuggestionsCatalog(this.tracks);

  @override
  Future<List<MusicTrack>> getRelatedSongs(Iterable<String> seedIds,
      {bool Function()? isCurrent}) async {
    requests.add(seedIds.toList());
    return pending == null ? tracks : await pending!.future;
  }
}

class _DeletionApproval extends Fake implements MusicDownloadDeletionApproval {
  _DeletionApproval(List<DownloadedVideo> rows)
      : rows = List.unmodifiable(rows);

  final List<DownloadedVideo> rows;
}

class _Downloads extends Cubit<DownloadManagerState>
    implements DownloadManagerCubit {
  _Downloads(super.initialState);

  final capturedApprovals = <_DeletionApproval>[];
  final removalRequests = <MusicDownloadDeletionApproval>[];
  int? removalResult;

  @override
  Listenable get playlistOfflineChanges => kAlwaysCompleteAnimation;

  @override
  MusicPlaylistOfflineProgress? playlistOfflineProgress(Playlist playlist) =>
      null;

  @override
  bool isMusicDownloadRequiredByPlaylist(String videoId) => false;

  @override
  bool isMusicDownloadPlaylistOnly(String videoId) => false;

  void replaceVideos(List<DownloadedVideo> videos) =>
      emit(state.copyWith(videos: videos));

  void setTransferring(String? id) => emit(state.copyWith(downloadProgresses: {
        if (id != null) id: DownloadProgress(CancelToken()),
      }));

  @override
  _DeletionApproval captureMusicDeletion(List<DownloadedVideo> selection) {
    final approval = _DeletionApproval(selection);
    capturedApprovals.add(approval);
    return approval;
  }

  @override
  Future<int> deleteMusicSelection(MusicDownloadDeletionApproval approval,
      {required bool Function() isCurrent}) async {
    if (!isCurrent()) return 0;
    removalRequests.add(approval);
    return removalResult ?? (approval as _DeletionApproval).rows.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Player extends Cubit<PlayerState> implements PlayerCubit {
  final offline = <DownloadedVideo>[];
  final online = <Video>[];
  final collections = <({List<Video> entries, int startIndex, String title})>[];
  final recapFiles = <OnDeviceMusicEntry>[];
  String? recapQueueTitle;
  bool Function()? recapIsCurrent;
  final downloadShuffles = <List<DownloadedVideo>>[];
  bool Function()? downloadShuffleIsCurrent;
  final downloadQueueAdds = <List<DownloadedVideo>>[];
  bool Function()? downloadQueueAddIsCurrent;
  Completer<void>? holdDownloadQueueAdd;
  bool downloadQueueAddResult = true;
  @override
  bool canAddMusicDownloadsToQueue = true;
  int offlineCalls = 0;
  int? start;
  PlaylistReference? source;
  bool shuffledPlaylist = false;
  final queuedPlaylists = <({bool next, List<Video> videos})>[];
  PlaylistReference? learningSource;
  final collectionQueues = <List<Video>>[];
  String? collectionQueueTitle;
  @override
  int musicSelectionRequestRevision = 0;
  @override
  final musicSelectionFailureRevision = ValueNotifier(0);
  _Player() : super(PlayerState.init(null));

  void showCurrentSong(Video song) =>
      emit(state.copyWith(currentlyPlaying: song, isAudio: true));

  @override
  int get playlistGeneration => 1;

  @override
  bool canAddMusicRequest(IdedVideo entry) => false;

  @override
  bool canEnqueueMusicSongs(List<Video> selection,
          {List<DownloadedVideo>? downloads}) =>
      state.currentlyPlaying != null;

  @override
  Future<bool> enqueueMusicSongs(List<Video> selection,
      {required bool next,
      List<DownloadedVideo>? downloads,
      PlaylistReference? recommendationSource}) async {
    queuedPlaylists.add((next: next, videos: List.of(selection)));
    return true;
  }

  @override
  Future<void> close() {
    musicSelectionFailureRevision.dispose();
    return super.close();
  }

  @override
  Future<bool> addMusicDownloadsToQueue(List<DownloadedVideo> files,
      {required bool Function() isCurrent}) async {
    expect(isCurrent(), isTrue);
    downloadQueueAddIsCurrent = isCurrent;
    downloadQueueAdds.add(List.of(files));
    await holdDownloadQueueAdd?.future;
    return isCurrent() && downloadQueueAddResult;
  }

  @override
  Future<void> shuffleMusicDownloads(List<DownloadedVideo> files,
      {required bool Function() isCurrent}) async {
    downloadShuffles.add(List.of(files));
    expect(isCurrent(), isTrue);
    downloadShuffleIsCurrent = isCurrent;
  }

  @override
  Future<void> playOfflineVideos(List<DownloadedVideo> videos,
      {int startIndex = 0,
      bool fromMusic = false,
      bool songTap = false}) async {
    offlineCalls++;
    start = startIndex;
    offline.addAll(videos);
  }

  @override
  Future<void> playVideo(List<Video> videos,
      {bool? audio,
      Duration? startAt,
      bool? playing,
      int? startIndex,
      String? queueTitle,
      bool fromMusic = false,
      PlaylistReference? recommendationSource,
      bool songTap = false,
      bool collectionDetail = false}) async {
    start = startIndex;
    learningSource = recommendationSource;
    online.addAll(videos);
  }

  @override
  Future<void> playMusicCollectionQueue(List<Video> entries,
      {required String queueTitle,
      bool shuffle = false,
      bool songTap = false,
      bool collectionDetail = false,
      int? startIndex,
      bool Function()? isCurrent,
      List<PlaylistReference?>? recommendationSources}) async {
    expect(isCurrent?.call(), isTrue);
    final tracks = List<Video>.of(entries);
    final index = startIndex ?? 0;
    collections.add((entries: tracks, startIndex: index, title: queueTitle));
    collectionQueues.add(tracks);
    collectionQueueTitle = queueTitle;
    recapIsCurrent = isCurrent;
    recapQueueTitle = queueTitle;
    emit(state.copyWith(
      videos: tracks,
      currentlyPlaying: tracks[index],
      isAudio: true,
      isHidden: false,
      isMini: false,
    ));
  }

  @override
  Future<void> playOnDeviceMusic(List<OnDeviceMusicEntry> tracks,
      {int startIndex = 0,
      String? queueTitle,
      bool retainQueueOrder = false,
      bool songTap = false,
      bool collectionDetail = false,
      bool Function()? isCurrent}) async {
    expect(retainQueueOrder, isTrue);
    expect(isCurrent?.call(), isTrue);
    recapIsCurrent = isCurrent;
    recapQueueTitle = queueTitle;
    recapFiles.addAll(tracks);
  }

  @override
  Future<void> playPlaylist(List<Video> entries,
      {required PlaylistReference reference,
      int startIndex = 0,
      Duration? startAt,
      bool? audio,
      bool? playing,
      bool shuffleOnce = false,
      PlaylistLoadSession? playlistLoader,
      bool fromMusic = false,
      bool songTap = false,
      bool collectionDetail = false}) async {
    start = startIndex;
    source = reference;
    shuffledPlaylist = shuffleOnce;
    online.addAll(entries);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _DetailsCatalog extends MusicCatalogService {
  _DetailsCatalog(this.responses);

  final Map<String, MusicLibraryEntry> responses;
  final requests = <String>[];
  Completer<void>? hold;
  bool cancelled = false;

  @override
  Future<void> loadSavedSongDetails(Iterable<String> ids,
      {required bool Function() isCurrent,
      required Future<void> Function(String id, MusicLibraryEntry? details)
          onResult}) async {
    for (final id in ids) {
      requests.add(id);
      await hold?.future;
      if (!isCurrent()) {
        cancelled = true;
        return;
      }
      await onResult(id, responses[id]);
    }
  }
}

class _ReplacementCatalog extends MusicCatalogService {
  _ReplacementCatalog(this.originalId, this.candidate, Iterable<Object> checks)
      : originalChecks = Queue.of(checks);

  final String originalId;
  final MusicTrack candidate;
  final Queue<Object> originalChecks;
  final requestedIds = <String>[];
  final searches = <String>[];

  @override
  Future<MusicRecordingAvailability> checkRecordingAvailability(String videoId,
      {required bool Function() isCurrent}) async {
    expect(isCurrent(), isTrue);
    requestedIds.add(videoId);
    final result = videoId == originalId
        ? originalChecks.removeFirst()
        : MusicRecordingAvailability.available;
    if (result is MusicRecordingAvailability) return result;
    throw result;
  }

  @override
  Future<MusicCatalogSearchPage> searchPage(
      String query, MusicCatalogSearchType type, int page,
      {bool Function()? isCurrent}) async {
    expect(isCurrent?.call(), isTrue);
    expect(type, MusicCatalogSearchType.songs);
    expect(page, 1);
    searches.add(query);
    return MusicCatalogSearchPage(hits: [
      MusicCatalogSongHit(MusicTrack(videoId: originalId, title: 'Same ID')),
      MusicCatalogSongHit(candidate),
    ], rawKeys: []);
  }
}

class _DownloadsQueuePlayer extends TestPlayerCubit {
  _DownloadsQueuePlayer(super.initialState, super.settings);

  final _enqueueZone = Zone.current;
  Future<bool>? enqueueResult;

  @override
  Future<bool> enqueueMusicSongs(List<Video> selection,
      {required bool next,
      List<DownloadedVideo>? downloads,
      PlaylistReference? recommendationSource}) {
    final operation = _enqueueZone.run(() => super.enqueueMusicSongs(selection,
        next: next,
        downloads: downloads,
        recommendationSource: recommendationSource));
    enqueueResult = operation;
    return operation;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const song = Video(
      videoId: 'abcdefghijk',
      title: 'Saved song',
      musicMetadata: MusicMetadata(title: 'Saved song', artist: 'Artist'));
  late _App app;
  late _Player player;
  late TestSettingsCubit settings;
  late MusicLibraryService library;
  late Service previousService;
  late bool previousTv;

  setUp(() async {
    previousService = service;
    previousTv = app_globals.isTv;
    service = Service();
    app_globals.isTv = false;
    db = await SembastSqfDb.createInMemory();
    // Run the profile's queue setup on the real database clock.
    await db.saveSetting(SettingsValue(
        namedMusicQueuesSetting, NamedMusicQueue.encodeAll(const [])));
    library = MusicLibraryService.forProfile(db, db.profileId);
    app = _App();
    player = _Player();
    settings = TestSettingsCubit(SettingsState.init(), app);
  });

  tearDown(() async {
    await player.close();
    await settings.close();
    await app.close();
    await db.close();
    service = previousService;
    app_globals.isTv = previousTv;
  });

  Future<void> show(WidgetTester tester,
      {Widget body = const MusicLibraryPage(),
      _Downloads? downloads,
      PlayerCubit? playback}) async {
    await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<AppCubit>.value(value: app),
          BlocProvider<PlayerCubit>.value(value: playback ?? player),
          BlocProvider<SettingsCubit>.value(value: settings),
          if (downloads != null)
            BlocProvider<DownloadManagerCubit>.value(value: downloads),
        ],
        child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: body))));
    await tester.pumpAndSettle();
  }

  Future<void> waitFor(bool Function() ready) => Future.doWhile(() async {
        if (ready()) return false;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return true;
      }).timeout(const Duration(seconds: 5));

  testWidgets('Statistics plays exact song rows and keeps the chosen period',
      (tester) async {
    const title = 'Same title';
    const first = 'abcdefghijk';
    const second = 'abcdefghijz';
    final source = await tester.runAsync(() async {
      final playlistId = (await service
          .createLocalPlaylistWithEntries('Current playlist name', []))!;
      final reference = PlaylistReference(
          kind: PlaylistSourceKind.local,
          playlistId: playlistId,
          profileId: db.profileId,
          displayTitle: 'Recorded playlist name');
      for (final (id, artist) in [(first, 'Artist A'), (second, 'Artist B')]) {
        final write = db.beginMusicListening(id)!;
        await write.record(
            HistoryVideoCache(id, title, 'Uploader', '',
                authorId: 'UC0000000000000000000001',
                musicMetadata: MusicMetadata(title: title, artist: artist)),
            playlist: reference);
      }
      return reference;
    });

    await show(tester);
    await tester.tap(find.byKey(const ValueKey('music-library-statistics')));
    await tester.pumpAndSettle();
    final period = find.widgetWithText(ChoiceChip, 'Last 7 days');
    await tester.tap(period);
    await tester.pumpAndSettle();
    expect(find.text(title), findsNWidgets(2));
    for (final (artist, id) in [('Artist A', first), ('Artist B', second)]) {
      await tester.tap(find.widgetWithText(ListTile, artist));
      await tester.pumpAndSettle();
      expect(player.online.single.videoId, id);
      expect(tester.widget<ChoiceChip>(period).selected, isTrue);
      player.online.clear();
    }

    await tester.tap(find.widgetWithText(ChoiceChip, 'Artists'));
    await tester.pumpAndSettle();
    final unresolved = find.widgetWithText(ListTile, 'Artist A');
    expect(tester.widget<ListTile>(unresolved).onTap, isNull);
    await tester.tap(unresolved);
    await tester.pumpAndSettle();
    expect(find.text('Listening statistics'), findsOneWidget);

    final playlists = find.widgetWithText(ChoiceChip, 'Playlists');
    await tester.tap(playlists);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Recorded playlist name'));
    await tester.pumpAndSettle();
    final detail =
        tester.widget<MusicLibraryPage>(find.byType(MusicLibraryPage));
    expect(detail.source, source);
    expect(find.text('Current playlist name'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(period).selected, isTrue);
    expect(tester.widget<ChoiceChip>(playlists).selected, isTrue);
  });

  testWidgets(
      'Library editor moves and hides categories and overview shortcuts',
      (tester) async {
    final downloads = _Downloads(const DownloadManagerState());
    addTearDown(downloads.close);
    const songs = MusicLibraryCategory.songs;
    const savedDownloads = MusicLibraryCategory.downloads;
    final layout = MusicLayout(
      destinations: MusicDestination.values.reversed.toList(),
      shortcuts: const [MusicShortcut.charts],
      libraryCategories: [
        savedDownloads,
        songs,
        for (final category in MusicLibraryCategory.values)
          if (category != songs && category != savedDownloads) category,
      ],
    );
    await tester.runAsync(() => settings.setMusicLayout(layout));
    await show(tester, downloads: downloads);

    Finder control(String key) => find.byKey(ValueKey(key));
    final songsTab = control('music-library-tab-songs');
    final downloadsTab = control('music-library-tab-downloads');
    final songsShortcut = control('music-library-shortcut-songs');
    final downloadsShortcut = control('music-library-shortcut-downloads');
    final arrange = control('music-library-arrange');
    final songsToggle = control('music-library-category-songs-toggle');

    Future<void> tap(Finder target) async {
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    Future<void> settleSave() async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
    }

    expect(tester.getTopLeft(downloadsTab).dx,
        lessThan(tester.getTopLeft(songsTab).dx));
    expect(tester.getTopLeft(downloadsShortcut).dx,
        lessThan(tester.getTopLeft(songsShortcut).dx));
    await tap(songsTab);
    await tap(arrange);
    await tap(control('music-library-category-songs-move'));
    await tap(find.text('Move earlier'));
    await tap(songsToggle);
    await settleSave();
    expect(settings.state.musicLayout.libraryCategories.first, songs);
    expect(settings.state.musicLayout.hiddenLibraryCategories, contains(songs));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(songsTab, findsNothing);
    expect(songsShortcut, findsNothing);
    expect(downloadsShortcut, findsOneWidget);

    await tap(arrange);
    expect(tester.widget<SwitchListTile>(songsToggle).value, isFalse);
    await tap(songsToggle);
    await settleSave();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(songsTab).dx,
        lessThan(tester.getTopLeft(downloadsTab).dx));
    expect(tester.getTopLeft(songsShortcut).dx,
        lessThan(tester.getTopLeft(downloadsShortcut).dx));

    await tap(arrange);
    await tap(control('music-layout-reset'));
    await settleSave();
    expect(settings.state.musicLayout.libraryCategories,
        MusicLibraryCategory.values);
    expect(settings.state.musicLayout.hiddenLibraryCategories, isEmpty);
    expect(settings.state.musicLayout.destinations, layout.destinations);
    expect(settings.state.musicLayout.shortcuts, layout.shortcuts);
  });

  testWidgets('TV selects an available category after hiding the active one',
      (tester) async {
    app_globals.isTv = true;
    const defaults = MusicLayout.defaults();
    const playlists = MusicLibraryCategory.playlists;
    const songs = MusicLibraryCategory.songs;
    await show(tester);
    ChoiceChip chip(MusicLibraryCategory category) => tester.widget<ChoiceChip>(
        find.byKey(ValueKey('music-library-tab-${category.name}')));

    expect(chip(playlists).selected, isTrue);
    await tester.runAsync(() => settings.setMusicLayout(
        defaults.copyWith(hiddenLibraryCategories: const {playlists})));
    await tester.pumpAndSettle();
    expect(chip(songs).selected, isTrue);
    expect(find.byKey(const ValueKey('music-library-tab-downloads')),
        findsNothing);

    await tester.runAsync(() => settings.setMusicLayout(defaults.copyWith(
        hiddenLibraryCategories: MusicLibraryCategory.values.toSet())));
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byKey(const ValueKey('music-library-arrange')), findsOneWidget);
    await tester.runAsync(() => settings.setMusicLayout(defaults));
    await tester.pumpAndSettle();
    expect(chip(playlists).selected, isTrue);
  });

  String? savedLibraryOrder(String collection) => settings
      .state.settings['music-collection-library-order:$collection']?.value;

  Future<void> chooseOrder(WidgetTester tester, String menu, String label,
      bool Function() saved) async {
    await tester.tap(find.byKey(ValueKey(menu)));
    await tester.pumpAndSettle();
    final option = find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem));
    await tester.runAsync(() async {
      await tester.tap(option);
      await tester.pumpAndSettle();
      await waitFor(saved);
    });
    await tester.pumpAndSettle();
  }

  testWidgets('deletes and restores one playlist from Music Library',
      (tester) async {
    final id = (await tester.runAsync(() async {
      final id = (await service.createPlayList('Trip songs', 'local'))!;
      await service.addVideoToPlaylist(id, song.videoId, video: song);
      final other = (await service.createPlayList('Other deletion', 'local'))!;
      await library.markLocalPlaylist(other);
      await service.deleteUserPlaylist(other);
      return id;
    }))!;
    await show(tester);
    final playlistTile = find.byKey(ValueKey('music-local-$id'));
    final recentlyDeleted = find.byTooltip('Recently deleted playlists');
    await tester.tap(playlistTile);
    await tester.pumpAndSettle();

    final delete = find.text('Delete playlist');
    await tester.ensureVisible(delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(find.text('Delete “Trip songs”?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Saved song'), findsOneWidget);

    await tester.runAsync(() => tester.tap(delete));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Delete'));
      await waitFor(() => service
          .getRecentlyDeletedMusicPlaylists()
          .any((item) => item.playlist.playlistId == id));
    });
    await tester.pumpAndSettle();
    expect(playlistTile, findsNothing);
    await tester.tap(recentlyDeleted);
    await tester.pumpAndSettle();
    expect(find.text('Other deletion'), findsOneWidget);
    final restore = find.byTooltip('Restore Trip songs');
    expect(restore, findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(restore);
      await waitFor(() => service
          .getLocalPlaylists()
          .any((playlist) => playlist.playlistId == id));
    });
    await tester.pumpAndSettle();
    expect(restore, findsNothing);
    expect(find.text('Other deletion'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(playlistTile);
    await tester.pumpAndSettle();
    expect(find.text('Saved song'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  final saveResults = find.byTooltip('Save results as a playlist');
  final createPlaylistDialog =
      find.widgetWithText(AlertDialog, 'Create new playlist');
  final playlistName = find.descendant(
      of: createPlaylistDialog, matching: find.byType(TextField));

  Future<Playlist> saveFilteredResults(WidgetTester tester, String name) async {
    await tester.tap(saveResults);
    await tester.pumpAndSettle();
    expect(createPlaylistDialog, findsOneWidget);
    expect(find.text('Playlist name'), findsOneWidget);
    await tester.enterText(playlistName, '  $name  ');
    await tester.runAsync(() async {
      await tester.tap(find.text('Add'));
      await waitFor(() => service.getLocalPlaylists().any((playlist) =>
          playlist.title == name &&
          library.localPlaylistIds.contains(playlist.playlistId)));
    });
    await tester.pumpAndSettle();
    expect(createPlaylistDialog, findsNothing);
    expect(find.text('Saved to playlist'), findsOneWidget);
    return service
        .getLocalPlaylists()
        .singleWhere((item) => item.title == name);
  }

  testWidgets(
      'playlist suggestions are explicit, dismissible and duplicate-safe',
      (tester) async {
    const addedElsewhere = MusicTrack(
        videoId: 'suggestion3',
        title: 'Added elsewhere',
        artists: ['Artist C']);
    final catalog = _PlaylistSuggestionsCatalog(const [
      MusicTrack(videoId: 'abcdefghijk', title: 'Existing candidate'),
      MusicTrack(videoId: 'videoonly01', title: 'Existing video'),
      MusicTrack(
          videoId: 'suggestion1', title: 'Add this', artists: ['Artist A']),
      MusicTrack(videoId: 'suggestion1', title: 'Duplicate candidate'),
      MusicTrack(
          videoId: 'suggestion2', title: 'Dismiss this', artists: ['Artist B']),
      addedElsewhere,
      MusicTrack(
          videoId: 'suggestion4', title: 'Lock target', artists: ['Artist D']),
    ]);
    final previousCatalog = musicCatalogService;
    addTearDown(() => musicCatalogService = previousCatalog);
    musicCatalogService = catalog;
    app.selectServer(const Server(url: 'https://music.example'));
    const videoOnly = Video(videoId: 'videoonly01', title: 'Video only');
    final id = (await tester.runAsync(() async {
      final id = (await service.createPlayList('Trip songs', 'local'))!;
      await service.addVideoToPlaylist(id, song.videoId, video: song);
      await service.addVideoToPlaylist(id, videoOnly.videoId, video: videoOnly);
      return id;
    }))!;
    List<String> membership() => service
        .getLocalPlaylists()
        .singleWhere((playlist) => playlist.playlistId == id)
        .videos
        .map((video) => video.videoId)
        .toList();

    await show(tester);
    await tester.tap(find.text('Trip songs'));
    await tester.pumpAndSettle();
    final request =
        find.byKey(const ValueKey('music-playlist-find-suggestions'));
    expect(catalog.requests, isEmpty);
    await tester.tap(request);
    await tester.pumpAndSettle();
    expect(catalog.requests, [
      [song.videoId]
    ]);
    expect(find.text('Existing candidate'), findsNothing);
    expect(find.text('Existing video'), findsNothing);
    expect(find.text('Duplicate candidate'), findsNothing);
    expect(find.text('Artist A'), findsOneWidget);

    Finder row(String id) =>
        find.byKey(ValueKey('music-playlist-suggestion-$id'));
    Finder action(String id, String tooltip) => find.descendant(
          of: row(id),
          matching: find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == tooltip),
        );
    await tester.ensureVisible(row('suggestion2'));
    await tester.tap(action('suggestion2', 'Dismiss suggestion'));
    await tester.pumpAndSettle();
    expect(membership(), [song.videoId, videoOnly.videoId]);
    await tester.tap(request);
    await tester.pumpAndSettle();
    expect(row('suggestion2'), findsNothing);

    await tester.runAsync(() async {
      await tester.tap(action('suggestion1', 'Add to playlist'));
      await waitFor(() => membership().contains('suggestion1'));
    });
    await tester.pumpAndSettle();
    expect(row('suggestion1'), findsNothing);
    expect(find.text('Add this'), findsOneWidget);
    expect(membership(), [song.videoId, videoOnly.videoId, 'suggestion1']);

    await tester.ensureVisible(row('suggestion3'));
    await tester.runAsync(() async {
      // The shelf has already rendered by the time another caller saves it.
      await service.appendLocalPlaylistEntries(id, [addedElsewhere.toVideo()]);
      final refreshed = Completer<void>();
      void onRefresh() => refreshed.complete();
      library.changes.addListener(onRefresh);
      try {
        await tester.tap(action('suggestion3', 'Add to playlist'));
        await refreshed.future.timeout(const Duration(seconds: 5));
      } finally {
        library.changes.removeListener(onRefresh);
      }
    });
    await tester.pumpAndSettle();
    expect(row('suggestion3'), findsNothing);
    expect(membership(),
        [song.videoId, videoOnly.videoId, 'suggestion1', 'suggestion3']);

    await tester.ensureVisible(row('suggestion4'));
    final addLocked = tester
        .widget<IconButton>(action('suggestion4', 'Add to playlist'))
        .onPressed!;
    final dismissLocked = tester
        .widget<IconButton>(action('suggestion4', 'Dismiss suggestion'))
        .onPressed!;
    final reference = PlaylistReference(
      kind: PlaylistSourceKind.local,
      profileId: db.profileId,
      playlistId: id,
    );
    await tester.runAsync(() async {
      expect(
          await service.setLocalPlaylistEditLocked(reference,
              locked: true, isCurrent: () => true),
          isTrue);
      // Exercise actions rendered before the lock notification is delivered.
      addLocked();
      dismissLocked();
    });
    await tester.pumpAndSettle();
    expect(row('suggestion4'), findsOneWidget);
    expect(membership(),
        [song.videoId, videoOnly.videoId, 'suggestion1', 'suggestion3']);
    library.notifyChanged();
    await tester.pumpAndSettle();
    expect(request, findsNothing);
    expect(row('suggestion4'), findsNothing);
  });

  testWidgets(
      'saved song menu refreshes metadata only when explicitly selected',
      (tester) async {
    const id = 'abcdefghijk';
    final original = musicCatalogService;
    final catalog = _DetailsCatalog({
      id: const MusicLibraryEntry(
          kind: MusicLibraryKind.song,
          id: id,
          title: 'Current catalog title',
          subtitle: 'Current uploader'),
    });
    musicCatalogService = catalog;
    addTearDown(() => musicCatalogService = original);
    await tester.runAsync(() => library.save(MusicLibraryEntry.song(song)));
    await show(tester);
    await tester.tap(find.text('Songs'));
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('music-saved-song-$id'));
    final menu =
        find.descendant(of: row, matching: find.byIcon(Icons.more_vert));
    final refresh = find.byKey(const ValueKey('music-song-refresh-metadata'));
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(refresh, findsOneWidget);
    expect(catalog.requests, isEmpty);

    Future<void> refreshUntilNotice(Finder notice) async {
      await tester.tap(refresh);
      // Let the library write complete while also advancing the popup route.
      for (var frame = 0; frame < 250 && notice.evaluate().isEmpty; frame++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(notice, findsOneWidget);
      await tester.pumpAndSettle();
    }

    final success = find.text('Saved song metadata refreshed.');
    await refreshUntilNotice(success);
    expect(catalog.requests, [id]);
    expect(library.savedSong(id)?.title, 'Current catalog title');
    expect(find.text('Current catalog title'), findsOneWidget);
    expect(success, findsOneWidget);
    expect(player.online, isEmpty);

    // Let the first snackbar close before expecting the next one to appear.
    final snackbar =
        find.widgetWithText(SnackBar, 'Saved song metadata refreshed.');
    await tester.pump(tester.widget<SnackBar>(snackbar).duration);
    await tester.pumpAndSettle();
    expect(success, findsNothing);

    catalog.responses.clear();
    await tester.tap(menu);
    await tester.pumpAndSettle();
    final failure = find.text(
        'Could not refresh song metadata from your selected Invidious server.');
    await refreshUntilNotice(failure);
    expect(catalog.requests, [id, id]);
    expect(find.text('Current catalog title'), findsOneWidget);
    expect(failure, findsOneWidget);
  });

  testWidgets('Suggested shuffle plays a transient queue with exact copies',
      (tester) async {
    const videoOnly = Video(videoId: 'videoonly01', title: 'Video only');
    const suggestion = MusicTrack(
        videoId: 'suggestion1', title: 'Related song', artists: ['Artist']);
    final catalog = _PlaylistSuggestionsCatalog(const [
      MusicTrack(videoId: 'abcdefghijk', title: 'Already in playlist'),
      MusicTrack(videoId: 'videoonly01', title: 'Already saved as video'),
      suggestion,
      suggestion,
    ]);
    final previousCatalog = musicCatalogService;
    addTearDown(() => musicCatalogService = previousCatalog);
    musicCatalogService = catalog;
    app.selectServer(const Server(url: 'https://music.example'));
    final id = (await tester.runAsync(() async {
      final id = (await service.createPlayList('Trip songs', 'local'))!;
      await service.appendLocalPlaylistEntries(id, [song, videoOnly, song],
          allowDuplicates: true);
      return id;
    }))!;
    List<Video> membership() => service
        .getLocalPlaylists()
        .singleWhere((playlist) => playlist.playlistId == id)
        .videos;
    final original = membership();
    final originalIds = original
        .where((entry) => entry.musicMetadata != null)
        .map(playbackQueueId)
        .toList();
    expect(originalIds.toSet(), hasLength(2));

    await show(tester);
    await tester.tap(find.text('Trip songs'));
    await tester.pumpAndSettle();
    final shuffle =
        find.byKey(const ValueKey('music-playlist-suggested-shuffle'));
    expect(catalog.requests, isEmpty);
    await tester.tap(shuffle);
    await tester.pumpAndSettle();

    expect(catalog.requests, [
      [song.videoId]
    ]);
    expect(player.collectionQueueTitle, 'Trip songs');
    final queue = player.collectionQueues.single;
    expect(queue.take(2).map(playbackQueueId), unorderedEquals(originalIds));
    expect(queue.take(2).any(isMusicQueueSuggestion), isFalse);
    expect(queue.last.videoId, suggestion.videoId);
    expect(isMusicQueueSuggestion(queue.last), isTrue);
    expect(jsonEncode(membership()), jsonEncode(original));

    // A later playback selection owns the player, even if discovery completes.
    final pending = catalog.pending = Completer<List<MusicTrack>>();
    await tester.tap(shuffle);
    await tester.pump();
    expect(tester.widget<OutlinedButton>(shuffle).onPressed, isNull);
    player.musicSelectionRequestRevision++;
    pending.complete([suggestion]);
    await tester.pumpAndSettle();
    expect(player.collectionQueues, hasLength(1));

    catalog.pending = Completer<List<MusicTrack>>()..complete([]);
    await tester.tap(shuffle);
    await tester.pumpAndSettle();
    expect(find.text('No more suggestions for this playlist.'), findsOneWidget);
    expect(player.collectionQueues, hasLength(1));
    expect(jsonEncode(membership()), jsonEncode(original));

    catalog.pending = null;
    final reference = PlaylistReference(
        kind: PlaylistSourceKind.local,
        profileId: db.profileId,
        playlistId: id);
    await show(tester,
        body: Builder(
            builder: (context) => TextButton(
                onPressed: () => MusicScreen.openPlayingSource(
                    context, MusicLibraryPage(source: reference),
                    television: false),
                child: const Text('Open playing source'))));
    await tester.tap(find.text('Open playing source'));
    await tester.pumpAndSettle();
    expect(shuffle, findsOneWidget);
    await tester.tap(shuffle);
    await tester.pumpAndSettle();
    expect(shuffle, findsNothing);
    expect(find.text('Open playing source'), findsOneWidget);
    expect(player.collectionQueues, hasLength(2));
    expect(jsonEncode(membership()), jsonEncode(original));
  });

  testWidgets('Now Playing opens its exact local playlist and Back returns',
      (tester) async {
    final id = (await tester.runAsync(() async {
      final id = (await service.createPlayList('Trip songs', 'local'))!;
      await service.addVideoToPlaylist(id, song.videoId, video: song);
      await service.createPlayList('Unrelated playlist', 'local');
      return id;
    }))!;
    final reference = PlaylistReference(
        kind: PlaylistSourceKind.local,
        profileId: db.profileId,
        playlistId: id);
    await show(tester,
        body: Builder(
            builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                          builder: (_) => MusicLibraryPage(source: reference))),
                  child: const Text('Open source'),
                )));
    await tester.tap(find.text('Open source'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Trip songs'), findsOneWidget);
    expect(find.text('Saved song'), findsOneWidget);
    expect(find.text('Play all'), findsOneWidget);
    expect(find.text('Unrelated playlist'), findsNothing);
    expect(find.byKey(const ValueKey('music-library-history')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('music-local-playlist-search')));
    await tester.pumpAndSettle();
    final query = find.byKey(const ValueKey('music-local-playlist-query'));
    await tester.enterText(query, 'absent');
    await tester.pumpAndSettle();
    expect(find.text('No results found.'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(query, findsNothing);
    expect(find.widgetWithText(AppBar, 'Trip songs'), findsOneWidget);
    expect(find.text('Saved song'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Open source'), findsOneWidget);
  });

  testWidgets(
      'local playlist search plays the exact filtered occurrence in its full queue',
      (tester) async {
    const repeated = Video(
        videoId: 'abcdefghijk',
        title: 'Provider title',
        musicMetadata: MusicMetadata(title: 'Étoile', artist: 'Lúcia'));
    const artistOnly = Video(
        videoId: 'lmnoprstuvw',
        title: 'Intro',
        musicMetadata: MusicMetadata(title: 'Intro', artist: 'Lúcia'));
    const titleOnly = Video(
        videoId: '12345678901',
        title: 'Morning',
        musicMetadata:
            MusicMetadata(title: 'Étoile du matin', artist: 'Hélène'));
    const playlist = Playlist(
        playlistId: 'local:evening',
        title: 'Evening set',
        author: '',
        videoCount: 5,
        videos: [
          Video(videoId: 'abcdefghijk', title: 'Untagged copy'),
          artistOnly,
          repeated,
          titleOnly,
          repeated,
        ]);
    await tester.runAsync(() => db.saveSetting(
        SettingsValue(localPlaylistsSetting, jsonEncode([playlist.toJson()]))));
    await show(tester);
    await tester.tap(find.text(playlist.title));
    await tester.pumpAndSettle();
    bool savedOrder(String order) =>
        settings.state.settings.values.any((setting) => setting.value == order);
    await chooseOrder(tester, 'music-playlist-sort', 'Title',
        () => savedOrder('title:ascending'));
    await chooseOrder(tester, 'music-playlist-sort', 'Descending',
        () => savedOrder('title:descending'));
    expect(tester.getTopLeft(find.text('Étoile du matin')).dy,
        lessThan(tester.getTopLeft(find.text('Étoile').first).dy));
    await tester.tap(find.byTooltip('Search playlist'));
    await tester.pumpAndSettle();
    final query = find.byKey(const ValueKey('music-local-playlist-query'));
    await tester.enterText(query, 'not in this playlist');
    await tester.pumpAndSettle();
    expect(find.text('No results found.'), findsOneWidget);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(740, 360);
    tester.view.viewInsets = const FakeViewPadding(bottom: 235);
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();
    expect(query.hitTestable(), findsOneWidget);
    expect(find.byTooltip('Close').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Clear text'));
    await tester.pumpAndSettle();
    tester.view.reset();
    await tester.pumpAndSettle();
    expect(find.text('Intro'), findsOneWidget);
    expect(find.text('No results found.'), findsNothing);

    // Both tokens must match; title and artist can satisfy one token each.
    await tester.enterText(query, ' LUCIA   etoile ');
    await tester.pumpAndSettle();
    expect(find.text('Étoile'), findsNWidgets(2));
    expect(find.text('Intro'), findsNothing);
    expect(find.text('Étoile du matin'), findsNothing);
    expect(find.text('Untagged copy'), findsNothing);
    final source = service
        .getLocalPlaylists()
        .singleWhere((item) => item.playlistId == playlist.playlistId)
        .videos;
    final secondCopy = find.byKey(ValueKey(source.last.queueEntryId!));
    await tester.ensureVisible(secondCopy);
    await tester.tap(secondCopy);
    await tester.pumpAndSettle();
    expect(player.source?.playlistId, playlist.playlistId);
    final queue = assignPlaylistEntryIds(player.online);
    final expected = source.where((entry) => entry.musicMetadata != null);
    expect(queue.map((entry) => entry.queueEntryId),
        expected.map((entry) => entry.queueEntryId));
    expect(player.start, 3);
    expect(queue[player.start!].queueEntryId, expected.last.queueEntryId);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await chooseOrder(tester, 'music-playlist-sort', 'Default order',
        () => savedOrder('source:descending'));
    expect(player.online.map((song) => song.videoId),
        expected.map((song) => song.videoId));
    expect(
        service
            .getLocalPlaylists(database: db)
            .singleWhere((stored) => stored.playlistId == playlist.playlistId)
            .videos
            .map((song) => song.videoId),
        playlist.videos.map((song) => song.videoId));
  });

  testWidgets(
      'listening time sorts saved playlist rows without moving occurrences',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1150);
    addTearDown(tester.view.reset);
    Video track(String id, String title, int seconds) => Video(
        videoId: id,
        lengthSeconds: seconds,
        musicMetadata: MusicMetadata(title: title, artist: 'Artist'));
    final skipped = track('longskip001', 'Long song', 300);
    final legacy = track('legacy00001', 'Older song', 600);
    final first = track('short000001', 'First short song', 15);
    final second = track('short000002', 'Second short song', 20);
    final zero = track('zeroplay001', 'No advancement', 30);
    final tracks = [skipped, legacy, first, second, first, zero];
    final playlist = Playlist(
        playlistId: 'local:listening-time',
        title: 'Listening time fixture',
        author: '',
        videoCount: tracks.length,
        videos: tracks);
    final history = MusicListeningHistory.forProfile(db, db.profileId);
    MusicListeningEvent listen(Video track, int at, int seconds) =>
        MusicListeningEvent(
          id: 'play-$at',
          entry: HistoryVideoCache(track.videoId, '', null, '')
            ..created = DateTime.utc(2026, 1, 1, 0, at),
          source: MusicListeningSource.catalog,
          elapsed: Duration(seconds: seconds),
        );
    await tester.runAsync(() async {
      await db.saveSetting(SettingsValue(
          localPlaylistsSetting, jsonEncode([playlist.toJson()])));
      await history.merge([
        listen(skipped, 1, 3),
        listen(first, 2, 15),
        listen(second, 3, 20),
        listen(first, 4, 15),
        listen(zero, 5, 0),
        MusicListeningEvent.legacy(
            HistoryVideoCache(legacy.videoId, '', null, '')
              ..created = DateTime.utc(2026)),
      ]);
    });
    await show(tester);
    await tester.tap(find.text(playlist.title));
    await tester.pumpAndSettle();
    List<String?> storedIds() => service
        .getLocalPlaylists(database: db)
        .singleWhere((stored) => stored.playlistId == playlist.playlistId)
        .videos
        .map((track) => track.queueEntryId)
        .toList();
    final source = storedIds();
    Finder row(int index) => find.byKey(ValueKey(source[index]!));
    void expectOrder(List<int> indices) {
      final positions = [
        for (final index in indices) tester.getTopLeft(row(index)).dy
      ];
      expect(positions, orderedEquals(positions.toList()..sort()));
      expect(positions.toSet(), hasLength(indices.length));
    }

    bool savedOrder(String order) =>
        settings.state.settings.values.any((setting) => setting.value == order);
    await chooseOrder(tester, 'music-playlist-sort', 'Listening time',
        () => savedOrder('listeningTime:descending'));
    expectOrder([2, 4, 3, 0, 5, 1]);

    await tester.runAsync(() => history.merge([listen(second, 6, 20)]));
    await tester.pumpAndSettle();
    expectOrder([3, 2, 4, 0, 5, 1]);

    await chooseOrder(tester, 'music-playlist-sort', 'Ascending',
        () => savedOrder('listeningTime:ascending'));
    expectOrder([5, 0, 2, 4, 3, 1]);
    await tester.tap(row(4));
    await tester.pumpAndSettle();
    expect(player.start, 4);
    expect(
        assignPlaylistEntryIds(player.online)
            .map((track) => track.queueEntryId),
        source);
    expect(storedIds(), source);
  });

  testWidgets('hiding a song leaves playlist entries available to restore',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 800);
    addTearDown(tester.view.reset);
    const repeated = Video(
        videoId: 'abcdefghijk',
        title: 'Repeated song',
        musicMetadata: MusicMetadata(title: 'Repeated song', artist: 'Artist'));
    const kept = Video(
        videoId: 'lmnoprstuvw',
        title: 'Kept song',
        musicMetadata: MusicMetadata(title: 'Kept song', artist: 'Artist'));
    const playlist = Playlist(
        playlistId: 'local:scoped-hide',
        title: 'A playlist',
        author: '',
        videoCount: 3,
        videos: [repeated, kept, repeated]);
    await tester.runAsync(() => db.saveSetting(
        SettingsValue(localPlaylistsSetting, jsonEncode([playlist.toJson()]))));
    final reference = PlaylistReference.forPlaylist(playlist, db);
    await show(tester, body: MusicLibraryPage(source: reference));
    final visibility = MusicVisibility.forProfile(db, db.profileId);
    Future<void> change(Finder action) async {
      await tester.runAsync(() async {
        final saved = Completer<void>();
        void changed() {
          if (!saved.isCompleted) saved.complete();
        }

        visibility.addListener(changed);
        try {
          await tester.tap(action);
          await tester.pumpAndSettle();
          await saved.future.timeout(const Duration(seconds: 5));
        } finally {
          visibility.removeListener(changed);
        }
      });
      await tester.pumpAndSettle();
    }

    final rows = find.widgetWithText(ListTile, 'Repeated song');
    final menu = find.descendant(
        of: rows.first, matching: find.byTooltip('Music actions'));
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await change(find.text('Hide in this playlist'));
    expect(rows, findsNothing);
    await tester.tap(find.text('Kept song'));
    await tester.pumpAndSettle();
    expect(player.online.map((entry) => entry.videoId), [kept.videoId]);

    await tester.tap(find.text('Show hidden songs'));
    await tester.pumpAndSettle();
    await change(find.byTooltip('Restore to this playlist'));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(rows, findsNWidgets(2));
    player.online.clear();
    await tester.tap(find.text('Kept song'));
    await tester.pumpAndSettle();
    expect(player.online.map((entry) => entry.videoId),
        [repeated.videoId, kept.videoId, repeated.videoId]);
    expect(player.start, 1);
  });

  testWidgets(
      'whole local playlist actions keep duplicate songs in source order',
      (tester) async {
    final playlist = Playlist(
        playlistId: 'local:queue-actions',
        title: 'Queue actions',
        author: '',
        videoCount: 4,
        videos: [
          song.copyWith(indexId: 'one'),
          const Video(videoId: 'lmnoprstuvw', title: 'Untagged'),
          song.copyWith(indexId: 'two'),
          song.copyWith(videoId: '12345678901', indexId: 'three'),
        ]);
    await tester.runAsync(() => db.saveSetting(
        SettingsValue(localPlaylistsSetting, jsonEncode([playlist.toJson()]))));
    player.showCurrentSong(song);
    await show(tester);
    await tester.tap(find.text(playlist.title));
    await tester.pumpAndSettle();

    final actions = find.byKey(const ValueKey('music-whole-playlist-actions'));
    Future<void> choose(String label) async {
      await tester.tap(actions);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    await choose('Play next');
    await choose('Add to queue');
    expect(
        player.queuedPlaylists.map((request) => request.next), [true, false]);
    for (final request in player.queuedPlaylists) {
      expect(request.videos.map((entry) => entry.indexId),
          ['one', 'two', 'three']);
    }
    expect(player.online, isEmpty);

    await choose('Shuffle');
    expect(player.shuffledPlaylist, isTrue);
    expect(player.source?.playlistId, playlist.playlistId);
    expect(
        player.online.map((entry) => entry.indexId), ['one', 'two', 'three']);

    await tester.tap(actions);
    await tester.pumpAndSettle();
    final edited = playlist.copyWith(videos: playlist.videos.take(3).toList());
    await tester.runAsync(() => db.saveSetting(
        SettingsValue(localPlaylistsSetting, jsonEncode([edited.toJson()]))));
    await tester.tap(find.text('Play next'));
    await tester.pumpAndSettle();
    expect(player.queuedPlaylists, hasLength(2));
  });

  testWidgets(
      'Playable offline only filters a sorted playlist and plays exact duplicate occurrences',
      (tester) async {
    const lastTake = Video(
        videoId: 'recording01',
        musicMetadata: MusicMetadata(title: 'Zulu take', artist: 'Ensemble'));
    const firstTake = Video(
        videoId: 'recording01',
        musicMetadata: MusicMetadata(title: 'Alpha take', artist: 'Ensemble'));
    const bridge = Video(
        videoId: 'bridge00001',
        musicMetadata: MusicMetadata(title: 'Middle bridge', artist: 'Solo'));
    const unavailable = Video(
        videoId: 'stream00001',
        musicMetadata: MusicMetadata(title: 'Live stream', artist: 'Solo'));
    const playlist = Playlist(
        playlistId: 'local:offline-takes',
        title: 'Offline session',
        author: '',
        videoCount: 4,
        videos: [lastTake, unavailable, bridge, firstTake]);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_cacheChannel, (call) async {
      expect(call.method, 'cachedMusicSongs');
      expect(call.arguments['accountId'], _cacheServer.accountId);
      return [_cachedSong(lastTake, 'a'), _cachedSong(bridge, 'b')];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_cacheChannel, null));
    await tester.runAsync(() async {
      await db.upsertServer(_cacheServer);
      await db.saveSetting(SettingsValue(
          localPlaylistsSetting, jsonEncode([playlist.toJson()])));
    });
    app.selectServer(_cacheServer);
    await show(tester);
    await tester.tap(find.text(playlist.title));
    await tester.pumpAndSettle();
    await chooseOrder(
        tester,
        'music-playlist-sort',
        'Title',
        () => settings.state.settings.values
            .any((setting) => setting.value == 'title:ascending'));
    final filter =
        find.byKey(const ValueKey('music-local-playlist-offline-filter'));
    await tester.ensureVisible(filter);
    await tester.tap(filter);
    await tester.pumpAndSettle();
    expect(find.text('Live stream'), findsNothing);

    final source = service
        .getLocalPlaylists()
        .singleWhere((entry) => entry.playlistId == playlist.playlistId)
        .videos;
    final expected = [
      source[3].queueEntryId,
      source[2].queueEntryId,
      source[0].queueEntryId,
    ];
    void expectFilteredQueue(int startIndex) {
      final call = player.collections.last;
      expect(call.title, playlist.title);
      expect(call.entries.map((entry) => entry.queueEntryId), expected);
      expect(call.entries.map((entry) => entry.musicMetadata!.title),
          ['Alpha take', 'Middle bridge', 'Zulu take']);
      expect(
          call.entries.map((entry) => CachedMusicPlayback.of(entry)?.rendition),
          ['a' * 64, 'b' * 64, 'a' * 64]);
      expect(call.startIndex, startIndex);
    }

    final lastRow = find.text('Zulu take');
    await tester.ensureVisible(lastRow);
    await tester.tap(lastRow);
    await tester.pumpAndSettle();
    expect(player.collections, hasLength(1));
    expectFilteredQueue(2);
    await tester.longPress(lastRow);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Select all'));
    await tester.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('music-playlist-selection-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    expect(player.collections, hasLength(2));
    expectFilteredQueue(0);
    expect(player.online, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('an unavailable device track stays in its saved playlist',
      (tester) async {
    const playlistTitle = 'Local files';
    const title = 'Missing file';
    final device = Video(
        videoId: 'device:playlist:${'e' * 64}',
        musicMetadata: const MusicMetadata(title: title, artist: ''));
    final id = await tester.runAsync(
        () => service.createLocalPlaylistWithEntries(playlistTitle, [device]));
    await show(tester);
    await tester.tap(find.text(playlistTitle));
    await tester.pumpAndSettle();

    expect(find.text('File unavailable'), findsOneWidget);
    final row = find.widgetWithText(ListTile, title);
    expect(tester.widget<ListTile>(row).onTap, isNull);
    expect(
        service
            .getLocalPlaylists()
            .singleWhere((playlist) => playlist.playlistId == id)
            .videos
            .single
            .videoId,
        device.videoId);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets(
      'filtered playlist selection plays duplicate occurrences in display order',
      (tester) async {
    const playlist = Playlist(
        playlistId: 'local:takes',
        title: 'Session',
        author: '',
        videoCount: 6,
        videos: [
          Video(videoId: 'recording01', title: 'Untagged'),
          Video(
              videoId: 'recording01',
              musicMetadata:
                  MusicMetadata(title: 'First take', artist: 'Ensemble')),
          Video(
              videoId: 'interlude01',
              musicMetadata: MusicMetadata(title: 'Interlude', artist: 'Solo')),
          Video(
              videoId: 'bridge00001',
              musicMetadata:
                  MusicMetadata(title: 'Bridge', artist: 'Ensemble')),
          Video(
              videoId: 'outtake0001',
              musicMetadata:
                  MusicMetadata(title: 'Outtake', artist: 'Ensemble')),
          Video(
              videoId: 'recording01',
              musicMetadata:
                  MusicMetadata(title: 'Last take', artist: 'Ensemble')),
        ]);
    await tester.runAsync(() => db.saveSetting(
        SettingsValue(localPlaylistsSetting, jsonEncode([playlist.toJson()]))));
    final downloads = _Downloads(const DownloadManagerState());
    addTearDown(downloads.close);
    await show(tester, downloads: downloads);
    await tester.tap(find.text(playlist.title));
    await tester.pumpAndSettle();
    await chooseOrder(
        tester,
        'music-playlist-sort',
        'Title',
        () => settings.state.settings.values
            .any((setting) => setting.value == 'title:ascending'));
    await tester.tap(find.byTooltip('Search playlist'));
    await tester.pumpAndSettle();
    final query = find.byKey(const ValueKey('music-local-playlist-query'));
    await tester.enterText(query, 'ensemble');
    await tester.pumpAndSettle();
    expect(find.text('Interlude'), findsNothing);
    await tester.longPress(find.text('Last take'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.byTooltip('Select all'));
    await tester.pumpAndSettle();
    expect(find.text('4 selected'), findsOneWidget);
    await tester.tap(find.byTooltip('Deselect all'));
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);
    for (final title in ['Last take', 'Bridge', 'First take']) {
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
    }
    expect(find.text('3 selected'), findsOneWidget);
    expect(player.online, isEmpty);
    await tester
        .tap(find.byKey(const ValueKey('music-playlist-selection-actions')));
    await tester.pumpAndSettle();
    for (final label in [
      'Play',
      'Shuffle',
      'Play next',
      'Add to queue',
      'Save to playlist',
      'Download audio'
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    expect(player.online.map((entry) => entry.musicMetadata!.title),
        ['Bridge', 'First take', 'Last take']);
    expect(player.online.map((entry) => entry.videoId),
        ['bridge00001', 'recording01', 'recording01']);
    expect(player.source, isNull,
        reason: 'A subset cannot own the progress of the whole playlist.');
    expect(player.learningSource, PlaylistReference.forPlaylist(playlist, db));
  });

  testWidgets(
      'filtered playlist saves and reopens the named snapshot in occurrence order',
      (tester) async {
    Video take(String id, String title, [String artist = 'Énsemble']) => Video(
        videoId: id,
        musicMetadata: MusicMetadata(title: title, artist: artist));
    final playlist = Playlist(
        playlistId: 'local:rehearsal',
        title: 'Rehearsal',
        author: '',
        videoCount: 4,
        videos: [
          take('recording01', 'First take'),
          take('interlude01', 'Interlude', 'Solo'),
          take('bridge00001', 'Bridge'),
          take('recording01', 'Last take'),
        ]);
    await tester.runAsync(() => db.saveSetting(
        SettingsValue(localPlaylistsSetting, jsonEncode([playlist.toJson()]))));
    await show(tester);
    await tester.tap(find.text(playlist.title));
    await tester.pumpAndSettle();
    expect(saveResults, findsNothing);
    await tester.tap(find.byTooltip('Search playlist'));
    await tester.pumpAndSettle();
    expect(saveResults, findsNothing);

    final query = find.byKey(const ValueKey('music-local-playlist-query'));
    await tester.enterText(query, 'absent');
    await tester.pumpAndSettle();
    expect(find.text('No results found.'), findsOneWidget);
    expect(saveResults, findsNothing);
    await tester.enterText(query, 'ensemble');
    await tester.pumpAndSettle();
    expect(find.text('Interlude'), findsNothing);

    await tester.tap(saveResults);
    await tester.pumpAndSettle();
    await tester.enterText(playlistName, 'Cancelled set');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(createPlaylistDialog, findsNothing);
    expect(service.getLocalPlaylists().map((item) => item.title),
        isNot(contains('Cancelled set')));

    final saved = await saveFilteredResults(tester, 'Ensemble takes');
    expect(saved.videos.map((entry) => entry.videoId),
        ['recording01', 'bridge00001', 'recording01']);
    expect(saved.videos.map((entry) => entry.indexId).toSet(), hasLength(3));
    expect(tester.widget<TextField>(query).controller!.text, 'ensemble');
    expect(find.text('Interlude'), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(query, findsNothing);
    expect(find.text('Interlude'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ensemble takes'));
    await tester.pumpAndSettle();
    expect(find.text('Interlude'), findsNothing);
    await tester.tap(find.text('Play all'));
    await tester.pumpAndSettle();
    expect(player.source?.playlistId, saved.playlistId);
    expect(player.online.map((entry) => entry.musicMetadata!.title),
        ['First take', 'Bridge', 'Last take']);
  });

  testWidgets(
      'Undo restores the exact occurrences removed from a playlist selection',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 900);
    addTearDown(tester.view.reset);
    const videoOnly = Video(videoId: 'videoonly01', title: 'Video only');
    const otherSong = Video(
        videoId: 'secondsong2',
        musicMetadata: MusicMetadata(title: 'Second song', artist: 'Artist'));
    final playlistId = (await tester.runAsync(() => service
        .createLocalPlaylistWithEntries(
            'Rehearsal', [song, videoOnly, otherSong, song])))!;
    final source = PlaylistReference(
        kind: PlaylistSourceKind.local,
        profileId: db.profileId,
        playlistId: playlistId);
    List<Video> entries() => service
        .getLocalPlaylists()
        .singleWhere((playlist) => playlist.playlistId == playlistId)
        .videos;
    final before = entries();
    final firstCopy = find.byKey(ValueKey(before.first.queueEntryId!));
    final secondCopy = find.byKey(ValueKey(before.last.queueEntryId!));
    final otherRow = find.text('Second song');

    await show(tester, body: MusicLibraryPage(source: source));
    await tester.ensureVisible(secondCopy);
    await tester.longPress(secondCopy);
    await tester.pumpAndSettle();
    await tester.tap(otherRow);
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('music-playlist-selection-actions')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Remove selected from playlist'));
      await tester.pumpAndSettle();
      await waitFor(() => entries().length == 2);
    });
    await tester.pumpAndSettle();

    expect(entries().map((entry) => entry.indexId),
        [before[0].indexId, before[1].indexId]);
    expect(firstCopy, findsOneWidget);
    expect(secondCopy, findsNothing);
    expect(otherRow, findsNothing);
    expect(find.text('2 selected'), findsNothing);
    expect(find.text('Songs removed from playlist'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
      await waitFor(() => entries().length == before.length);
      await tester.pumpAndSettle();
    });
    await tester.pumpAndSettle();

    expect(entries().map((entry) => entry.indexId),
        before.map((entry) => entry.indexId));
    expect(firstCopy, findsOneWidget);
    expect(secondCopy, findsOneWidget);
    expect(otherRow, findsOneWidget);
  });

  testWidgets('Find duplicates keeps exceptions and Undo restores stored order',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 900);
    addTearDown(tester.view.reset);
    const bridge = Video(
      videoId: 'bridge00001',
      musicMetadata: MusicMetadata(title: 'Bridge', artist: 'Artist'),
    );
    final sameTitle = song.copyWith(videoId: 'sameTitle02');
    final playlistId = (await tester.runAsync(() => service
        .createLocalPlaylistWithEntries(
            'Rehearsal', [song, bridge, song, song, sameTitle])))!;
    final source = PlaylistReference(
        kind: PlaylistSourceKind.local,
        profileId: db.profileId,
        playlistId: playlistId);
    List<Video> entries() => service
        .getLocalPlaylists()
        .singleWhere((playlist) => playlist.playlistId == playlistId)
        .videos;
    List<String> order() => [for (final entry in entries()) entry.indexId!];
    final before = order();

    await show(tester, body: MusicLibraryPage(source: source));
    final edit = find.byKey(const ValueKey('music-playlist-edit'));
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find duplicates'));
    await tester.pumpAndSettle();

    final third = find.widgetWithText(CheckboxListTile, 'Remove position 3');
    final fourth = find.widgetWithText(CheckboxListTile, 'Remove position 4');
    expect(find.text('Keep position 1'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(third).value, isTrue);
    expect(tester.widget<CheckboxListTile>(fourth).value, isTrue);
    expect(find.text('Remove position 5'), findsNothing);
    expect(order(), before);

    await tester.tap(third);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(third).value, isFalse);
    expect(tester.widget<CheckboxListTile>(fourth).value, isTrue);
    expect(order(), before);

    await tester.runAsync(() async {
      await tester.tap(find.text('Remove selected'));
      await tester.pumpAndSettle();
      await waitFor(() => entries().length == 4);
      await tester.pumpAndSettle();
    });
    await tester.pumpAndSettle();

    expect(order(), [before[0], before[1], before[2], before[4]]);
    expect(entries().last.videoId, sameTitle.videoId);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
      await waitFor(() => entries().length == before.length);
      await tester.pumpAndSettle();
    });
    await tester.pumpAndSettle();

    expect(order(), before);
  });

  testWidgets('Undo restores the playlist order after saving a reorder',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 900);
    addTearDown(tester.view.reset);
    const otherSong = Video(
        videoId: 'secondsong2',
        musicMetadata: MusicMetadata(title: 'Second song', artist: 'Artist'));
    final playlistId = (await tester.runAsync(() => service
        .createLocalPlaylistWithEntries(
            'Rehearsal', [song, otherSong, song])))!;
    final source = PlaylistReference(
        kind: PlaylistSourceKind.local,
        profileId: db.profileId,
        playlistId: playlistId);
    List<String> order() => service
        .getLocalPlaylists()
        .singleWhere((playlist) => playlist.playlistId == playlistId)
        .videos
        .map((entry) => entry.indexId!)
        .toList();
    final before = order();

    await show(tester, body: MusicLibraryPage(source: source));
    final edit = find.byKey(const ValueKey('music-playlist-edit'));
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reorder songs'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(ValueKey(('music-playlist-move', before.last))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move up'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester
          .tap(find.byKey(const ValueKey('music-playlist-reorder-save')));
      await waitFor(() => order()[1] == before.last);
    });
    await tester.pumpAndSettle();

    expect(order(), [before[0], before[2], before[1]]);
    expect(find.text('Playlist reordered'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
      await waitFor(() => order()[1] == before[1]);
      await tester.pumpAndSettle();
    });
    await tester.pumpAndSettle();
    expect(order(), before);
  });

  testWidgets(
      'playlist selection menu rejects Play after the open source is deleted',
      (tester) async {
    final id = (await tester.runAsync(() async {
      final id = (await service.createPlayList('Rehearsal', 'local'))!;
      await service.addVideoToPlaylist(id, song.videoId, video: song);
      return id;
    }))!;
    final source = PlaylistReference(
        kind: PlaylistSourceKind.local,
        profileId: db.profileId,
        playlistId: id);
    await show(tester, body: MusicLibraryPage(source: source));
    await tester.longPress(find.text('Saved song'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('music-playlist-selection-actions')));
    await tester.pumpAndSettle();
    expect(find.text('Play').hitTestable(), findsOneWidget);
    await tester.runAsync(() => service.deleteUserPlaylist(id));
    // The menu is still displaying the old snapshot when the command fires.
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    expect(player.online, isEmpty);
    expect(player.offline, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tablet local playlist scrolls details and songs independently',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1060, 720);
    addTearDown(tester.view.reset);
    final title = List.filled(88, 'Tablet playlist').join(' ');
    final songs = List.generate(40, (index) {
      final title = '${index.isEven ? 'Evening' : 'Morning'} song $index';
      return Video(
          videoId: 't${index.toString().padLeft(10, '0')}',
          title: title,
          musicMetadata: MusicMetadata(title: title, artist: 'Artist'));
    });
    final playlist = Playlist(
        playlistId: 'local:tablet-playlist',
        title: title,
        author: '',
        videoCount: songs.length,
        videos: songs);
    await tester.runAsync(() => db.saveSetting(
        SettingsValue(localPlaylistsSetting, jsonEncode([playlist.toJson()]))));
    await show(tester);
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();

    final details = find.byKey(const ValueKey('music-collection-details-pane'));
    final tracks = find.byKey(const ValueKey('music-collection-tracks-pane'));
    final detailsList = find.descendant(
        of: details, matching: find.byType(SingleChildScrollView));
    final tracksList =
        find.descendant(of: tracks, matching: find.byType(CustomScrollView));
    final detailsScroll = tester
        .state<ScrollableState>(
            find.descendant(of: detailsList, matching: find.byType(Scrollable)))
        .position;
    final tracksScroll =
        tester.widget<CustomScrollView>(tracksList).controller!.position;
    expect(
        tester.getRect(details).right, lessThan(tester.getRect(tracks).left));
    expect(find.descendant(of: details, matching: find.text(title)),
        findsOneWidget);
    expect(find.text(title), findsOneWidget);
    expect(find.descendant(of: details, matching: find.text('Play all')),
        findsOneWidget);
    expect(find.descendant(of: tracks, matching: find.text('Play all')),
        findsNothing);
    expect(detailsScroll.maxScrollExtent, greaterThan(220));
    expect(tracksScroll.pixels, 0);
    await tester.drag(detailsList, const Offset(0, -220));
    await tester.pumpAndSettle();
    final detailsOffset = detailsScroll.pixels;
    expect(detailsOffset, greaterThan(0));
    expect(tracksScroll.pixels, 0);
    await tester.drag(tracksList, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tracksScroll.pixels, greaterThan(0));
    expect(detailsScroll.pixels, detailsOffset);

    final search = find.byKey(const ValueKey('music-local-playlist-search'));
    final select = find.byKey(const ValueKey('music-local-playlist-select'));
    final query = find.byKey(const ValueKey('music-local-playlist-query'));
    await tester.tap(search);
    await tester.pumpAndSettle();
    await tester.enterText(query, 'Evening');
    await tester.pumpAndSettle();
    expect(find.descendant(of: tracks, matching: query), findsOneWidget);
    expect(find.text('Evening song 0'), findsOneWidget);
    expect(find.text('Morning song 1'), findsNothing);
    expect(tracksScroll.pixels, 0);
    expect(detailsScroll.pixels, detailsOffset);
    await tester.tap(select);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Evening song 0'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(query).controller!.text, 'Evening');
    expect(detailsScroll.pixels, detailsOffset);
    await tester.tap(find.text('Evening song 2'));
    await tester.pumpAndSettle();
    expect(player.source?.playlistId, playlist.playlistId);
    expect(player.online.map((video) => video.videoId),
        songs.map((video) => video.videoId));
    expect(player.start, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'playlist search retains its results across routes and restores the original scroll position',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1060, 720);
    addTearDown(tester.view.reset);
    final songs = List.generate(40, (index) {
      final title = '${index.isEven ? 'Evening' : 'Morning'} song $index';
      return Video(
          videoId: 'd${index.toString().padLeft(10, '0')}',
          title: title,
          musicMetadata: MusicMetadata(title: title, artist: 'Artist'));
    });
    final playlist = Playlist(
        playlistId: 'local:day',
        title: 'All day',
        author: '',
        videoCount: songs.length,
        videos: songs);
    await tester.runAsync(() => db.saveSetting(
        SettingsValue(localPlaylistsSetting, jsonEncode([playlist.toJson()]))));
    final reference = PlaylistReference(
        kind: PlaylistSourceKind.local,
        profileId: db.profileId,
        playlistId: playlist.playlistId);
    await show(tester, body: MusicLibraryPage(source: reference));
    final list = find.byType(CustomScrollView);
    final details = find.byKey(const ValueKey('music-collection-details-pane'));
    expect(details, findsOneWidget);
    final position = tester.widget<CustomScrollView>(list).controller!.position;
    double offset() => tester.widget<CustomScrollView>(list).controller!.offset;
    await tester.drag(list, const Offset(0, -500));
    await tester.pumpAndSettle();
    final playlistOffset = offset();
    expect(playlistOffset, greaterThan(0));
    final search = find.byKey(const ValueKey('music-local-playlist-search'));
    final query = find.byKey(const ValueKey('music-local-playlist-query'));
    await tester.tap(search);
    await tester.pumpAndSettle();
    await tester.enterText(query, 'Evening');
    await tester.pumpAndSettle();
    expect(offset(), 0);
    await tester.drag(list, const Offset(0, -200));
    await tester.pumpAndSettle();
    final resultsOffset = offset();
    expect(resultsOffset, greaterThan(0));
    tester.view.physicalSize = const Size(700, 720);
    await tester.pumpAndSettle();
    expect(details, findsNothing);
    expect(tester.widget<CustomScrollView>(list).controller!.position,
        same(position));
    expect(tester.widget<TextField>(query).controller!.text, 'Evening');
    expect(offset(), resultsOffset);
    tester.view.physicalSize = const Size(1060, 720);
    await tester.pumpAndSettle();
    expect(details, findsOneWidget);
    expect(tester.widget<CustomScrollView>(list).controller!.position,
        same(position));
    expect(offset(), resultsOffset);

    final select = find.byKey(const ValueKey('music-local-playlist-select'));
    expect(find.byTooltip('Select songs').hitTestable(), findsOneWidget);
    final selectIcon = find.descendant(of: select, matching: find.byType(Icon));
    Focus.of(tester.element(selectIcon)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);
    await tester.tap(find.textContaining('Evening song').hitTestable().first);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsNothing);
    expect(tester.widget<TextField>(query).controller!.text, 'Evening');
    expect(offset(), resultsOffset);
    expect(Focus.of(tester.element(selectIcon)).hasFocus, isTrue);

    final navigator = Navigator.of(tester.element(query));
    unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => const Scaffold(body: Text('Other page')))));
    await tester.pumpAndSettle();
    expect(find.text('Other page'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(query).controller!.text, 'Evening');
    expect(offset(), resultsOffset);
    await tester.tap(search);
    await tester.pumpAndSettle();
    expect(query, findsNothing);
    expect(offset(), playlistOffset);
    expect(tester.widget<IconButton>(search).focusNode!.hasFocus, isTrue);
  });

  testWidgets('deleted source and a replaced session cannot open another list',
      (tester) async {
    final id = (await tester.runAsync(() async {
      final id = (await service.createPlayList('Original playlist', 'local'))!;
      await service.addVideoToPlaylist(id, song.videoId, video: song);
      return id;
    }))!;
    final reference = PlaylistReference(
        kind: PlaylistSourceKind.local,
        profileId: db.profileId,
        playlistId: id);
    await show(tester, body: MusicLibraryPage(source: reference));
    expect(find.text('Saved song'), findsOneWidget);
    final navigator = Navigator.of(tester.element(find.text('Saved song')));
    unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => const Scaffold(body: Text('Other page')))));
    await tester.pumpAndSettle();
    await tester.runAsync(() => service.deleteUserPlaylist(id));
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text('Original playlist'), findsNothing);
    expect(find.text('This source is no longer available.'), findsOneWidget);
    expect(find.text('Saved song'), findsNothing);
    expect(find.text('Watch Later'), findsNothing);

    final otherSource = PlaylistReference(
        kind: PlaylistSourceKind.local,
        profileId: db.profileId,
        playlistId: localWatchLaterId);
    await tester.runAsync(() => service
        .addVideoToPlaylist(localWatchLaterId, song.videoId, video: song));
    await show(tester, body: MusicLibraryPage(source: otherSource));
    expect(find.text('Saved song'), findsOneWidget);
    app.profileChanged('other-profile');
    await tester.pumpAndSettle();
    expect(find.text('This source is no longer available.'), findsOneWidget);
    expect(find.text('Saved song'), findsNothing);
    expect(find.text('Watch Later'), findsNothing);
  });

  testWidgets(
      'Music history opens from Library and clears only local listening',
      (tester) async {
    await tester.runAsync(() async {
      await db.recordPlaybackHistory(PlaybackHistoryOrigin.music,
          HistoryVideoCache('both', 'Song title', 'Artist', ''));
      await db.recordPlaybackHistory(PlaybackHistoryOrigin.video,
          HistoryVideoCache('both', 'Video title', 'Uploader', ''));
    });
    await show(tester);
    await tester.tap(find.byTooltip('Music history'));
    await tester.pumpAndSettle();
    expect(find.text('Song title'), findsOneWidget);
    expect(find.text('Video title'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('music-history-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear history ?'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'OK'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    expect(
        find.text('Songs played from Music will appear here.'), findsOneWidget);
    expect(db.getPlaybackHistory(PlaybackHistoryOrigin.video).single.title,
        'Video title');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'the Music Library opens the on-device setup without launching a picker',
      (tester) async {
    const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final nativeCalls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await show(tester);
    expect(nativeCalls, isEmpty);
    final device = find.byKey(const ValueKey('music-library-tab-onDevice'));
    await tester.ensureVisible(device);
    await tester.tap(device);
    await tester.pumpAndSettle();
    expect(find.text('Choose music folder'), findsOneWidget);
    expect(nativeCalls.where((method) => method != 'pendingRenames'),
        ['getFolder']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
      'Listening statistics periods follow Music history and profile changes',
      (tester) async {
    final playlist = PlaylistReference(
        kind: PlaylistSourceKind.local,
        playlistId: 'local:fixture',
        profileId: db.profileId,
        displayTitle: 'The playlist');
    Future<void> recordPlay(DateTime at, {String? trackId}) async {
      final id = trackId ?? song.videoId;
      final write = db.beginMusicListening(id)!;
      final entry = HistoryVideoCache(id, 'The song', 'The artist', '',
          musicMetadata: const MusicMetadata(
              title: 'The song', artist: 'The artist', album: 'The album'))
        ..created = at;
      await write.record(entry, playlist: playlist);
    }

    Future<void> selectChip(String label) async {
      await tester.tap(find.widgetWithText(ChoiceChip, label));
      await tester.pumpAndSettle();
    }

    const periods = [('Last 3 months', 2), ('Last 6 months', 3)];
    const groups = [
      ('Songs', 'The song'),
      ('Artists', 'The artist'),
      ('Albums', 'The album'),
      ('Playlists', 'The playlist'),
    ];
    final now = DateTime.now();
    await tester.runAsync(() async {
      for (final days in [0, 45, 120]) {
        await recordPlay(now.subtract(Duration(days: days)));
      }
      await recordPlay(now.subtract(const Duration(days: 240)),
          trackId: 'olderSong01');
    });
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('music-library-statistics')));
    await tester.pumpAndSettle();
    expect(find.text('Listening statistics'), findsOneWidget);
    expect(find.text('1 play · 1 song'), findsOneWidget);
    expect(find.text('The song'), findsOneWidget);

    await selectChip('Last 7 days');
    expect(find.text('1 play · 1 song'), findsOneWidget);
    await selectChip('All time');
    expect(find.text('4 plays · 2 songs'), findsOneWidget);

    await tester.runAsync(() => db.setMusicHistoryRecordingPaused(true));
    expect(db.beginMusicListening('otherSong01'), isNull);
    await tester.pumpAndSettle();
    expect(find.text('Music history is paused. New plays won’t count.'),
        findsOneWidget);
    for (final (period, count) in periods) {
      await selectChip(period);
      expect(find.text('$count plays · 1 song'), findsOneWidget);
      for (final (group, title) in groups) {
        await selectChip(group);
        final row = find.widgetWithText(ListTile, title);
        expect(row, findsOneWidget);
        expect(find.descendant(of: row, matching: find.text('$count plays')),
            findsOneWidget);
      }
    }

    await tester.runAsync(() =>
        db.deletePlaybackHistory(PlaybackHistoryOrigin.music, song.videoId));
    await tester.pumpAndSettle();
    for (final (period, _) in periods) {
      await selectChip(period);
      for (final (group, title) in groups) {
        await selectChip(group);
        expect(find.text('No recorded plays in this period.'), findsOneWidget);
        expect(find.text(title), findsNothing);
      }
    }

    await selectChip('All time');
    expect(find.text('1 play · 1 song'), findsOneWidget);
    await tester
        .runAsync(() => db.clearPlaybackHistory(PlaybackHistoryOrigin.music));
    await tester.pumpAndSettle();
    expect(find.text('No recorded plays in this period.'), findsOneWidget);
    expect(find.text('The playlist'), findsNothing);

    final next = (await tester.runAsync(() async {
      await db.setMusicHistoryRecordingPaused(false);
      await recordPlay(now);
      return db.createProfile('Another listener');
    }))!;
    await tester.pumpAndSettle();
    await selectChip('Last 6 months');
    expect(find.text('The playlist'), findsOneWidget);
    await tester.runAsync(() => db.useProfile(next.id));
    app.profileChanged(next.id);
    await tester.pumpAndSettle();
    expect(find.text('Listening statistics are unavailable for this session.'),
        findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('The playlist'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-library-statistics')));
    await tester.pumpAndSettle();
    for (final (period, _) in periods) {
      await selectChip(period);
      expect(find.text('No recorded plays in this period.'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('Recap queues the selected year and skips the missing file',
      (tester) async {
    const consent = ValueKey('music-listening-recap-consent');
    const replay = ValueKey('music-listening-recap-replay');
    const yearPicker = ValueKey('music-listening-recap-year');
    const storage = MethodChannel('videre/download_storage');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final proof = List.filled(64, 'a').join();
    final year = DateTime.now().year - 1;
    const readyId = 'ready';
    const missingId = 'missing';
    DownloadedVideo download(String id) => DownloadedVideo(
          videoId: id,
          title: id,
          accountId: 'test-account',
          lengthSeconds: 90,
          quality: 'audio',
          audioOnly: true,
          downloadComplete: true,
          storageUri: 'content://downloads/file/$id',
          folderUri: 'content://downloads/tree/music',
          musicMetadata: MusicMetadata(title: id, artist: 'Artist'),
        );
    final ready = download(readyId);
    final missing = download(missingId);
    final probed = <String>{};
    Completer<void>? holdProbe;
    messenger.setMockMethodCallHandler(storage, (call) async {
      expect(call.method, 'probeMusicFiles');
      final args = call.arguments as Map;
      expect(args['profileId'], db.profileId);
      final requested = (args['files'] as List).cast<Map>();
      probed.addAll(requested.map((file) => file['videoId'] as String));
      await holdProbe?.future;
      return {
        readyId: {'identity': proof, 'byteLength': 200},
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(storage, null));

    Future<void> listen(String id, DateTime playedAt,
        {DownloadedVideo? from}) async {
      final row = HistoryVideoCache(id, id, 'Artist', '',
          playedFromDownload: from != null, downloadAccountId: from?.accountId)
        ..created = playedAt;
      await db.beginMusicListening(id)!.record(row);
    }

    final newest = DateTime(year, 9, 1, 12);
    await tester.runAsync(() async {
      await db.upsertDownload(ready);
      await db.upsertDownload(missing);
      await listen('alpha', newest);
      await listen('beta', newest);
      await listen('alpha', DateTime(year, 3, 1));
      await listen(readyId, DateTime(year, 6, 1), from: ready);
      await listen(missingId, DateTime(year, 5, 1), from: missing);
      await listen(readyId, DateTime(year - 1, 7, 1), from: ready);
      await listen('future', DateTime(year + 2));
      await db.recordPlaybackHistory(
          PlaybackHistoryOrigin.music,
          HistoryVideoCache('legacy', 'Legacy', 'Artist', '')
            ..created = newest);
    });
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('music-library-statistics')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Listening recap'));
    await tester.pumpAndSettle();
    expect(find.byKey(replay), findsNothing);
    expect(probed, isEmpty);

    Future<void> toggleConsent(bool enabled) async {
      await tester.runAsync(() async {
        await tester.tap(find.byKey(consent));
        await waitFor(() =>
            db.getSettings('music-listening-recap-enabled')?.value ==
            '$enabled');
      });
      await tester.pumpAndSettle();
    }

    await toggleConsent(true);
    holdProbe = Completer<void>();
    await tester.tap(find.byKey(replay));
    await tester.pumpAndSettle();
    expect(probed, {readyId, missingId});
    await toggleConsent(false);
    await toggleConsent(true);
    holdProbe.complete();
    holdProbe = null;
    await tester.pumpAndSettle();
    expect(player.collections, isEmpty);

    await tester.tap(find.byKey(replay));
    await tester.pumpAndSettle();
    expect(player.recapQueueTitle, '$year listening recap');
    final recap = player.collections.single.entries;
    expect(recap.map((track) => track.videoId), [
      'alpha',
      'beta',
      readyId,
    ]);
    expect(recap.last.explicitMusicDownload,
        musicDownloadFileFingerprint(ready, proof));
    expect(probed, {readyId, missingId});
    expect(find.text('1 unavailable recording was skipped.'), findsOneWidget);
    expect(player.recapIsCurrent!(), isTrue);
    await tester.runAsync(() => db.removeMusicListeningTracks({'alpha'}));
    expect(player.recapIsCurrent!(), isFalse);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(yearPicker));
    await tester.pumpAndSettle();
    await tester.tap(find.text('${year - 1}').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(replay));
    await tester.pumpAndSettle();
    expect(player.recapQueueTitle, '${year - 1} listening recap');
    expect(player.recapFiles.single.download?.videoId, readyId);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
      'Listening recap uses opt-in, observed dates and the active profile',
      (tester) async {
    const consent = ValueKey('music-listening-recap-consent');
    const yearPicker = ValueKey('music-listening-recap-year');
    const save = ValueKey('music-listening-recap-save');
    const preview = ValueKey('music-listening-recap-preview');
    const setting = 'music-listening-recap-enabled';
    const files = MethodChannel('videre/files');
    const share = MethodChannel('dev.fluttercommunity.plus/share');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final temporary = Directory.systemTemp.createTempSync('recap-card-test-');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final fileCalls = <MethodCall>[];
    final shareCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(files, (call) async {
      fileCalls.add(call);
      return true;
    });
    messenger.setMockMethodCallHandler(paths, (_) async => temporary.path);
    messenger.setMockMethodCallHandler(share, (call) async {
      shareCalls.add(call);
      return ''; // The platform chooser was dismissed.
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(files, null);
      messenger.setMockMethodCallHandler(paths, null);
      messenger.setMockMethodCallHandler(share, null);
    });

    final year = DateTime.now().year - 1;
    final first = DateTime(year, 2, 5, 12);
    final last = DateTime(year, 8, 8, 12);
    HistoryVideoCache play(String id, String title, DateTime when) =>
        HistoryVideoCache(id, title, 'A performer', '')..created = when;

    await tester.runAsync(() async {
      await db
          .beginMusicListening('track')!
          .record(play('track', 'A song', last));
      await db
          .beginMusicListening('track')!
          .record(play('track', 'A song', first));
      await db.beginMusicListening('older')!.record(
          play('older', 'Previous song', DateTime(year - 1, 12, 31, 23, 59)));
      await db
          .beginMusicListening('future')!
          .record(play('future', 'Future play', DateTime(year + 2)));
      await db.recordPlaybackHistory(PlaybackHistoryOrigin.music,
          play('legacy', 'Legacy snapshot', DateTime(year, 1, 1)));
    });

    Future<void> openRecap() async {
      await tester.tap(find.byKey(const ValueKey('music-library-statistics')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Listening recap'));
      await tester.pumpAndSettle();
    }

    bool optedIn() => tester.widget<SwitchListTile>(find.byKey(consent)).value;
    Future<void> toggleConsent(bool enabled) async {
      await tester.runAsync(() async {
        await tester.tap(find.byKey(consent));
        await waitFor(
            () => db.getSettings(setting)?.value == enabled.toString());
      });
      await tester.pumpAndSettle();
    }

    await show(tester);
    await openRecap();
    expect(optedIn(), isFalse);
    expect(find.byKey(yearPicker), findsNothing);
    expect(find.byKey(preview), findsNothing);
    expect(fileCalls, isEmpty);

    await toggleConsent(true);
    final material =
        MaterialLocalizations.of(tester.element(find.byKey(consent)));
    expect(find.text('2 plays · 1 song'), findsOneWidget);
    expect(
        find.text('First recorded play ${material.formatFullDate(first)} · '
            'Last recorded play ${material.formatFullDate(last)}'),
        findsOneWidget);
    expect(find.textContaining('Coverage may have gaps'), findsOneWidget);

    await tester.tap(find.byKey(yearPicker));
    await tester.pumpAndSettle();
    await tester.tap(find.text('${year - 1}').last);
    await tester.pumpAndSettle();
    expect(find.text('1 play · 1 song'), findsOneWidget);
    expect(
        find.text('Plays recorded on '
            '${material.formatFullDate(DateTime(year - 1, 12, 31))}'),
        findsOneWidget);

    await tester.dragUntilVisible(find.byKey(save).hitTestable(),
        find.byType(ListView), const Offset(0, -160));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(save));
    await tester.pumpAndSettle();
    expect(fileCalls.single.method, 'save');
    expect(fileCalls.single.arguments['name'],
        'videre-music-recap-${year - 1}.json');
    final exported = jsonDecode(fileCalls.single.arguments['text'] as String);
    expect(exported['recordedPlays'], 1);
    expect(exported['coverage'], {
      'basis': 'recorded-events-only',
      'firstRecordedDate': '${year - 1}-12-31',
      'lastRecordedDate': '${year - 1}-12-31',
    });
    expect(exported['topSongs'], [
      {'title': 'Previous song', 'subtitle': 'A performer', 'recordedPlays': 1},
    ]);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    Future<void> openPreview() async {
      await tester.scrollUntilVisible(find.byKey(preview), 100);
      await tester.tap(find.byKey(preview));
      await tester.pumpAndSettle();
    }

    Finder previewText(String text) => find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(text),
        );

    await openPreview();
    expect(previewText('${year - 1}'), findsOneWidget);
    expect(previewText('1 play · 1 song'), findsOneWidget);
    expect(previewText('Previous song'), findsOneWidget);
    expect(previewText('A song'), findsNothing);
    expect(
      previewText(
          'This recap uses plays available in Music history. Coverage may have gaps.'),
      findsOneWidget,
    );
    expect(shareCalls, isEmpty);
    expect(temporary.listSync(), isEmpty);
    await tester.tap(previewText('Cancel'));
    await tester.pumpAndSettle();
    expect(shareCalls, isEmpty);

    await openPreview();
    await tester.runAsync(() async {
      await tester.tap(previewText('Share image'));
      await waitFor(() => shareCalls.isNotEmpty);
    });
    await tester.pumpAndSettle();
    expect(shareCalls.single.method, 'share');
    final imagePath = (shareCalls.single.arguments['paths'] as List).single;
    final png = File(imagePath as String);
    expect(png.uri.pathSegments.last, 'videre-music-recap-${year - 1}.png');
    expect(shareCalls.single.arguments['mimeTypes'], ['image/png']);
    expect(png.readAsBytesSync().take(8),
        [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    expect(fileCalls, hasLength(1));
    await tester.tap(previewText('Cancel'));
    await tester.pumpAndSettle();

    await tester.dragUntilVisible(find.byKey(consent).hitTestable(),
        find.byType(ListView), const Offset(0, 160));
    await tester.pumpAndSettle();
    await toggleConsent(false);
    expect(find.byKey(yearPicker), findsNothing);
    await toggleConsent(true);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Listening recap'));
    await tester.pumpAndSettle();
    expect(optedIn(), isTrue);
    expect(find.text('2 plays · 1 song'), findsOneWidget);

    await tester.runAsync(() => db.setMusicHistoryRecordingPaused(true));
    await tester.pumpAndSettle();
    expect(find.text('Music history is paused. New plays won’t count.'),
        findsOneWidget);
    expect(find.text('2 plays · 1 song'), findsOneWidget);

    await tester
        .runAsync(() => db.clearPlaybackHistory(PlaybackHistoryOrigin.music));
    await tester.pumpAndSettle();
    expect(find.text('No recorded plays in this period.'), findsOneWidget);
    expect(find.byKey(save), findsNothing);
    expect(find.byKey(preview), findsNothing);

    await tester.runAsync(() async {
      await db.setMusicHistoryRecordingPaused(false);
      await db
          .beginMusicListening('track')!
          .record(play('track', 'A song', last));
    });
    await tester.pumpAndSettle();
    await openPreview();
    expect(previewText('A song'), findsOneWidget);
    final next = (await tester.runAsync(() async {
      final profile = await db.createProfile('Another listener');
      await db.useProfile(profile.id);
      return profile;
    }))!;
    app.profileChanged(next.id);
    await tester.pumpAndSettle();
    expect(
        previewText('The recap card is no longer available.'), findsOneWidget);
    expect(previewText('A song'), findsNothing);
    expect(previewText('Share image'), findsNothing);
    expect(shareCalls, hasLength(1));
    await tester.tap(previewText('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Listening recap is unavailable for this session.'),
        findsOneWidget);
    expect(find.text('A song'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await openRecap();
    expect(optedIn(), isFalse);
    expect(find.byKey(yearPicker), findsNothing);
  });

  testWidgets('a saved playlist filters rows, counts and its Play all queue',
      (tester) async {
    const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
    const tree = 'content://provider/tree/music';
    const title = 'Local editions';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final devices = LocalMusicLibrary(visibilityDatabase: () => db);
    final rows = [
      for (final (index, label) in ['Edit A', 'Edit B', 'Explicit Mix'].indexed)
        {
          'uri': '$tree/document/edit-$index.m4a',
          'title': 'Same chorus ($label)',
          'visibilityKey': '${index + 1}' * 64,
          if (index < 2) 'contentAdvisory': index + 1,
        },
    ];
    final saved = [
      for (final row in rows)
        Video(
          videoId: 'device:playlist:${row['visibilityKey']}',
          musicMetadata:
              MusicMetadata(title: row['title'] as String, artist: ''),
        ),
    ];
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'getFolder' || 'pickFolder' => {
            'uri': tree,
            'name': 'Music',
            'selectionId': 'local-editions',
          },
        'checkFolderAccess' => true,
        'listTracks' => rows,
        _ => null,
      };
    });
    addTearDown(() {
      devices.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });
    final picked = devices.chooseFolder();
    await tester.pumpAndSettle();
    expect(await picked, isTrue);
    final id = await tester
        .runAsync(() => service.createLocalPlaylistWithEntries(title, saved));
    await show(tester, body: MusicLibraryPage(deviceLibrary: devices));
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    expect(find.text('3 videos'), findsOneWidget);
    expect(find.text('Same chorus (Edit A)'), findsOneWidget);

    await tester.runAsync(() => devices.setHideExplicitTracks(true));
    await tester.pumpAndSettle();
    expect(find.text('2 videos'), findsOneWidget);
    expect(find.text('Same chorus (Edit A)'), findsNothing);
    final search = find.byKey(const ValueKey('music-local-playlist-search'));
    await tester.tap(search);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'same chorus');
    await tester.pumpAndSettle();
    expect(find.text('Same chorus (Edit A)'), findsNothing);
    expect(find.text('Same chorus (Edit B)'), findsOneWidget);
    expect(find.text('Same chorus (Explicit Mix)'), findsOneWidget);
    await tester.tap(search);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play all'));
    await tester.pumpAndSettle();
    expect(player.online.map((video) => video.videoId),
        saved.skip(1).map((video) => video.videoId));
    expect(player.start, 0);
    expect(
        service
            .getLocalPlaylists()
            .singleWhere((playlist) => playlist.playlistId == id)
            .videos
            .map((video) => video.videoId),
        saved.map((video) => video.videoId));
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Library statistics applies and edits a one-day custom range',
      (tester) async {
    final day = DateTime(2025, 11, 2);
    final nextDay = DateTime(2025, 11, 3);
    final profileId = db.profileId;
    await tester.runAsync(() => db.mergeMusicListeningEvents([
          for (final (eventId, label, at, legacy) in [
            (
              'before',
              'Before',
              day.subtract(const Duration(seconds: 1)),
              false
            ),
            ('start', 'Inside', day, false),
            ('late', 'Inside', DateTime(2025, 11, 2, 23, 30), false),
            ('after', 'After', nextDay, false),
            ('legacy', 'Legacy', DateTime(2025, 11, 2, 12), true),
          ])
            MusicListeningEvent(
              id: eventId,
              source: MusicListeningSource.catalog,
              isLegacy: legacy,
              entry:
                  HistoryVideoCache(label, '$label song', '$label artist', '',
                      musicMetadata: MusicMetadata(
                        title: '$label song',
                        artist: '$label artist',
                        album: '$label album',
                      ))
                    ..created = at,
              playlist: PlaylistReference(
                kind: PlaylistSourceKind.local,
                playlistId: 'local:$label',
                profileId: profileId,
                displayTitle: '$label playlist',
              ),
            ),
        ]));
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('music-library-statistics')));
    await tester.pumpAndSettle();

    final custom = find.byKey(const ValueKey('music-listening-custom-dates'));
    final material = MaterialLocalizations.of(tester.element(custom));
    final inputDate = material.formatCompactDate(day);
    await tester.tap(custom);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(material.inputDateModeButtonLabel));
    await tester.pumpAndSettle();
    final fields = find.descendant(
        of: find.byType(DateRangePickerDialog),
        matching: find.byType(TextField));
    await tester.enterText(fields.at(0), inputDate);
    await tester.enterText(fields.at(1), inputDate);
    await tester.tap(find.text(material.okButtonLabel));
    await tester.pumpAndSettle();

    expect(tester.widget<ChoiceChip>(custom).selected, isTrue);
    expect(find.text(material.formatShortDate(day)), findsOneWidget);
    expect(find.text('2 plays · 1 song'), findsOneWidget);
    for (final (group, title) in [
      ('Songs', 'Inside song'),
      ('Artists', 'Inside artist'),
      ('Albums', 'Inside album'),
      ('Playlists', 'Inside playlist'),
    ]) {
      await tester.tap(find.widgetWithText(ChoiceChip, group));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile), findsOneWidget);
      final row = find.widgetWithText(ListTile, title);
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('2 plays')),
          findsOneWidget);
    }

    await tester.tap(custom);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(material.inputDateModeButtonLabel));
    await tester.pumpAndSettle();
    for (final field in tester.widgetList<TextField>(fields)) {
      expect(field.controller?.text, inputDate);
    }
    await tester.enterText(fields.at(1), material.formatCompactDate(nextDay));
    await tester.tap(find.text(material.cancelButtonLabel));
    await tester.pumpAndSettle();
    expect(find.text('2 plays · 1 song'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'All time'));
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(custom).selected, isFalse);
    expect(find.text('4 plays · 3 songs'), findsOneWidget);
  });

  for (final cancel in [false, true]) {
    testWidgets(
        cancel
            ? 'cancelling song details leaves the imported bookmark intact'
            : 'explicit song details display a proxied video thumbnail in both library layouts',
        (tester) async {
      const missing = 'abcdefghijk';
      const unavailable = 'zzzzzzzzzzz';
      const artwork = '/vi/$missing/mqdefault.jpg';
      final original = musicCatalogService;
      final catalog = _DetailsCatalog({
        missing: MusicLibraryEntry(
          kind: MusicLibraryKind.song,
          id: missing,
          title: 'Recovered recording',
          subtitle: 'Recovered uploader',
          thumbnails: [ImageObject(null, artwork, 320, 180)],
          usesVideoThumbnails: true,
        ),
      });
      musicCatalogService = catalog;
      addTearDown(() => musicCatalogService = original);
      await tester.runAsync(() => library.importSongs(const [
            MusicLibraryEntry(
                kind: MusicLibraryKind.song, id: missing, title: missing),
            MusicLibraryEntry(
                kind: MusicLibraryKind.song,
                id: unavailable,
                title: unavailable),
          ]));
      await show(tester);
      await tester.tap(find.text('Songs'));
      await tester.pumpAndSettle();
      expect(find.text(missing), findsOneWidget);
      expect(catalog.requests, isEmpty);

      await tester.tap(find.text('Load song details'));
      await tester.pumpAndSettle();
      expect(find.textContaining('selected Invidious server'), findsOneWidget);
      expect(catalog.requests, isEmpty);

      if (cancel) {
        catalog.hold = Completer<void>();
        await tester.tap(find.text('Load details'));
        await tester.pump();
        expect(find.text('Checked 0 of 2 songs'), findsOneWidget);
        expect(catalog.requests, [missing]);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        catalog.hold!.complete();
        await tester.pumpAndSettle();
        expect(catalog.cancelled, isTrue);
        expect(catalog.requests, [missing]);
        expect(library.entries.first.title, missing);
      } else {
        await tester.runAsync(() async {
          await tester.tap(find.text('Load details'));
          await waitFor(
              () => library.entries.first.title == 'Recovered recording');
        });
        await tester.pumpAndSettle();
        expect(find.text('Updated 1 of 2 songs.'), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.text('Recovered recording'), findsOneWidget);
        expect(find.text('Recovered uploader'), findsOneWidget);
        expect(find.text(unavailable), findsOneWidget);
        final row = find.byKey(const ValueKey('music-saved-song-$missing'));
        final idOnly =
            find.byKey(const ValueKey('music-saved-song-$unavailable'));
        final frame =
            find.descendant(of: row, matching: find.byType(Thumbnail));
        void expectProxiedFrame() {
          CommunityMusicArtwork communityArtwork(Finder row) =>
              tester.widget(find.descendant(
                  of: row, matching: find.byType(CommunityMusicArtwork)));
          expect(communityArtwork(row).allowLookup, isFalse);
          expect(communityArtwork(idOnly).allowLookup, isFalse);
          final thumbnail = tester.widget<Thumbnail>(frame);
          expect(thumbnail.images!.single.url, artwork);
          expect(thumbnail.useInvidiousProxy, isTrue);
          expect(find.descendant(of: idOnly, matching: find.byType(Thumbnail)),
              findsNothing);
        }

        expectProxiedFrame();
        await tester.tap(find.byKey(const ValueKey('music-library-layout')));
        await tester.pumpAndSettle();
        expectProxiedFrame();
        expect(library.entries.first.thumbnails.single.url, artwork);
        expect(library.coversBySongId, isEmpty);
        expect(catalog.requests, [missing, unavailable]);
        expect(
            library.entries.map((entry) => entry.id), [missing, unavailable]);
      }
    });
  }

  testWidgets(
      'library shows music playlists and explicitly created empty lists',
      (tester) async {
    await tester.runAsync(() async {
      final unrelated = await service.createPlayList('Video list', 'local');
      await service.addVideoToPlaylist(unrelated!, 'videoonly01',
          video: const Video(videoId: 'videoonly01', title: 'Video only'));
      await service.createPlayList('Unmarked empty list', 'local');
      await MusicLibrarySession(app).createPlaylist('Music list', [song]);
      await MusicLibrarySession(app).createPlaylist('Empty music list', []);
    });
    await show(tester);
    expect(find.text('Music list'), findsOneWidget);
    expect(find.text('Empty music list'), findsOneWidget);
    expect(find.text('Video list'), findsNothing);
    expect(find.text('Unmarked empty list'), findsNothing);
    expect(find.text('Watch Later'), findsNothing);
    expect(find.byType(Scaffold), findsOneWidget);

    await tester.tap(find.text('Music list'));
    await tester.pumpAndSettle();
    expect(find.text('Saved song'), findsOneWidget);
    await tester.tap(find.text('Play all'));
    await tester.pump();
    final storedEntry = service
        .getLocalPlaylists()
        .singleWhere((playlist) => playlist.title == 'Music list')
        .videos
        .single;
    expect(storedEntry.indexId, isNotEmpty);
    expect(jsonDecode(jsonEncode(player.online.single)),
        jsonDecode(jsonEncode(song.copyWith(indexId: storedEntry.indexId))));
  });

  testWidgets('local playlist pins use the current sort in list and grid',
      (tester) async {
    const alpha = 'Alpha list';
    const middle = 'Middle list';
    const zulu = 'Zulu list';
    final ids = <String, String>{};
    await tester.runAsync(() async {
      for (final title in [middle, zulu, alpha]) {
        final id = (await service.createPlayList(title, 'local'))!;
        ids[title] = id;
        await library.markLocalPlaylist(id);
      }
    });
    Finder row(String title) =>
        find.byKey(ValueKey('music-local-${ids[title]}'));
    void expectOrder(List<String> titles, {bool grid = false}) {
      final positions = titles.map((title) => tester.getTopLeft(row(title)));
      final offsets =
          positions.map((position) => grid ? position.dx : position.dy);
      expect(offsets, orderedEquals(offsets.toList()..sort()));
    }

    Future<void> changePin(String title, {required bool pinned}) async {
      await tester.tap(row(title));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text(pinned ? 'Pin playlist' : 'Unpin playlist'));
        await waitFor(() =>
            library.pinnedLocalPlaylistIds.contains(ids[title]) == pinned);
      });
      await tester.pumpAndSettle();
      expect(find.text(pinned ? 'Unpin playlist' : 'Pin playlist'),
          findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
    }

    await show(tester);
    const layout = ValueKey('music-library-layout');
    await tester.tap(find.byKey(layout));
    await tester.pumpAndSettle();
    expectOrder([middle, zulu, alpha]);
    await changePin(zulu, pinned: true);
    await changePin(alpha, pinned: true);
    expectOrder([zulu, alpha, middle]);
    expect(tester.getTopLeft(find.text('Songs')).dy,
        lessThan(tester.getTopLeft(row(zulu)).dy));

    await tester.tap(find.text('Playlists'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-library-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Title'));
    await tester.pumpAndSettle();
    expectOrder([alpha, zulu, middle]);
    expect(find.byIcon(Icons.push_pin), findsNWidgets(2));

    await tester.tap(find.byKey(layout));
    await tester.pumpAndSettle();
    expectOrder([alpha, zulu, middle], grid: true);
    await changePin(zulu, pinned: false);
    expectOrder([alpha, middle, zulu], grid: true);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local playlist grid previews reject an external song image',
      (tester) async {
    const id = 'abcdefghijk';
    const external =
        'https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=$id';
    const poster = '/vi/$id/mqdefault.jpg';
    final keys = <bool, ValueKey<String>>{};
    await tester.runAsync(() async {
      for (final hasPoster in [true, false]) {
        final name = hasPoster ? 'With stock poster' : 'Without stock poster';
        await MusicLibrarySession(app).createPlaylist(name, [
          Video(
              videoId: id,
              title: 'Legacy recording',
              musicMetadata: MusicMetadata(
                  title: 'Legacy recording',
                  artist: 'Artist',
                  thumbnails: [ImageObject(null, external, 1280, 720)]),
              videoThumbnails: [
                if (hasPoster) ImageObject(null, poster, 320, 180),
              ]),
        ]);
        final playlist =
            service.getLocalPlaylists().singleWhere((p) => p.title == name);
        expect(playlist.videos.single.musicMetadata!.thumbnails.single.url,
            external);
        keys[hasPoster] = ValueKey('music-local-${playlist.playlistId}');
      }
    });
    await show(tester);
    await tester.tap(find.text('Playlists'));
    await tester.pumpAndSettle();

    for (final hasPoster in [true, false]) {
      final card = find.byKey(keys[hasPoster]!);
      expect(card, findsOneWidget);
      final images =
          find.descendant(of: card, matching: find.byType(Thumbnail));
      if (hasPoster) {
        final image = tester.widget<Thumbnail>(images);
        expect(image.images!.single.url, poster);
        expect(image.useInvidiousProxy, isTrue);
      } else {
        expect(images, findsNothing);
        expect(
            find.descendant(
                of: card, matching: find.byIcon(Icons.queue_music_rounded)),
            findsOneWidget);
      }
      final wrappers = tester.widgetList<CommunityMusicArtwork>(find.descendant(
          of: card, matching: find.byType(CommunityMusicArtwork)));
      expect(wrappers.any((art) => art.allowLookup), isFalse);
    }
  });

  testWidgets(
      'local playlist rows and playback use the active profile’s saved covers',
      (tester) async {
    const staleId = 'aaaaaaaaaaa';
    const emptyId = 'bbbbbbbbbbb';
    const posterId = 'ccccccccccc';
    const cover = 'https://lh3.googleusercontent.com/saved-cover';
    const staleCover = 'https://lh3.googleusercontent.com/old-cover';
    const otherCover = 'https://lh3.googleusercontent.com/other-profile-cover';
    String frame(String id) => '/vi/$id/mqdefault.jpg';
    ImageObject image(String url) => ImageObject(null, url, 320, 320);
    Video track(String id, String title, {String? oldCover}) => Video(
        videoId: id,
        title: title,
        musicMetadata: MusicMetadata(
            title: title,
            artist: 'Artist',
            thumbnails: [if (oldCover != null) image(oldCover)]),
        videoThumbnails: [image(frame(id))]);
    final songs = [
      track(staleId, 'Older cover', oldCover: staleCover),
      track(emptyId, 'Missing cover'),
      track(posterId, 'Poster only'),
    ];

    await tester.runAsync(() async {
      await MusicLibrarySession(app).createPlaylist('Local recordings', songs);
      for (final video in songs.take(2)) {
        await library.save(MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: video.videoId,
            title: video.title!,
            thumbnails: [image(cover)]));
      }
      await library.save(MusicLibraryEntry.song(songs.last));
      final other = await db.createProfile('Another listener');
      await MusicLibraryService.forProfile(db, other.id).save(MusicLibraryEntry(
          kind: MusicLibraryKind.song,
          id: posterId,
          title: 'Other recording',
          thumbnails: [image(otherCover)]));
    });
    await show(tester);
    await tester.tap(find.text('Playlists'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local recordings'));
    await tester.pumpAndSettle();

    for (final song in songs) {
      final row = find.widgetWithText(ListTile, song.title!);
      final thumbnail = tester.widget<Thumbnail>(
          find.descendant(of: row, matching: find.byType(Thumbnail)));
      final urls = thumbnail.images!.map((image) => image.url);
      expect(urls, [if (song.videoId != posterId) cover, frame(song.videoId)]);
      expect(thumbnail.useInvidiousProxy, isTrue);
    }
    await tester.tap(find.text('Play all'));
    await tester.pump();
    expect(player.online.map((song) => song.videoId),
        [staleId, emptyId, posterId]);
    for (final song in player.online) {
      expect(song.musicMetadata!.thumbnails.map((image) => image.url),
          [if (song.videoId != posterId) cover]);
      expect(song.videoThumbnails.single.url, frame(song.videoId));
    }
  });

  testWidgets(
      'songs remain explicit saves and refresh after removal and profile switch',
      (tester) async {
    await tester.runAsync(
        () => MusicLibrarySession(app).createPlaylist('Music list', [song]));
    await show(tester);
    await tester.tap(find.text('Songs'));
    await tester.pumpAndSettle();
    expect(find.text('Saved song'), findsNothing);
    await tester.runAsync(() => library.save(MusicLibraryEntry.song(song)));
    await tester.pumpAndSettle();
    expect(find.text('Saved song'), findsOneWidget);

    await tester.tap(find.byTooltip('Music actions'));
    await tester.pumpAndSettle();
    expect(find.text('Remove saved song'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Remove saved song'));
      await tester.pumpAndSettle();
      await waitFor(() => library.entries.isEmpty);
    });
    await tester.pumpAndSettle();
    expect(find.text('Saved song'), findsNothing);

    await tester.runAsync(() => library.save(MusicLibraryEntry.song(song)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Search saved songs'));
    await tester.pumpAndSettle();
    final query = find.byKey(const ValueKey('music-saved-songs-query'));
    await tester.enterText(query, 'Saved song');
    await tester.pumpAndSettle();
    await tester
        .longPress(find.byKey(ValueKey('music-saved-song-${song.videoId}')));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    final next = (await tester.runAsync(() => db.createProfile('Second')))!;
    await tester.runAsync(() async {
      await db.useProfile(next.id);
      await MusicLibraryService.forProfile(db, next.id).save(
          const MusicLibraryEntry(
              kind: MusicLibraryKind.song,
              id: 'othersong01',
              title: 'Other library',
              subtitle: 'New artist'));
    });
    app.profileChanged(next.id);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsNothing);
    expect(query, findsNothing);
    expect(find.text('Other library'), findsOneWidget);
    expect(find.text('Saved song'), findsNothing);
    expect(library.entries.single.id, song.videoId);
  });

  testWidgets(
      'Playable offline only filters Saved Songs in place and queues a complete cache',
      (tester) async {
    const unavailable = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: 'partial0001', title: 'Partial song');
    final pendingCache = Completer<List<Map<String, Object>>>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final owners = <String>[];
    messenger.setMockMethodCallHandler(_cacheChannel, (call) async {
      expect(call.method, 'cachedMusicSongs');
      expect(call.arguments['profileId'], _cacheServer.profileId);
      owners.add(call.arguments['accountId'] as String);
      return pendingCache.future;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_cacheChannel, null));
    await tester.runAsync(() async {
      await db.upsertServer(_cacheServer);
      await library.save(MusicLibraryEntry.song(song));
      await library.save(unavailable);
    });
    app.selectServer(_cacheServer);
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('music-library-tab-songs')));
    await tester.pumpAndSettle();
    final filter =
        find.byKey(const ValueKey('music-saved-songs-offline-filter'));
    expect(tester.widget<IconButton>(filter).tooltip, 'Playable offline only');
    expect(find.text('Saved song'), findsOneWidget);
    expect(find.text(unavailable.title), findsOneWidget);
    expect(owners, isEmpty);

    await tester.tap(filter);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text(unavailable.title), findsNothing);
    pendingCache.complete([_cachedSong(song, 'a')]);
    await tester.pumpAndSettle();
    expect(owners, isNotEmpty);
    expect(owners, everyElement(_cacheServer.accountId));
    expect(find.text('Saved song'), findsOneWidget);
    expect(find.text(unavailable.title), findsNothing);
    expect(find.text('Cache metadata'), findsNothing);
    await tester.tap(find.text('Saved song'));
    await tester.pumpAndSettle();
    final call = player.collections.single;
    final cached = CachedMusicPlayback.of(call.entries.single)!;
    expect(call.title, 'Saved songs');
    expect(call.startIndex, 0);
    expect(cached.owner, cachedMusicOwner(_cacheServer));
    expect(cached.rendition, 'a' * 64);

    await tester.tap(filter);
    await tester.pumpAndSettle();
    expect(find.text(unavailable.title), findsOneWidget);
    expect(find.text('Saved song'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
      'Playable offline only filters the current profile after a late cache result',
      (tester) async {
    const newSong = MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'abcdefghijk',
        title: 'Another profile song');
    final newServer = (await tester.runAsync(() async {
      await db.upsertServer(_cacheServer);
      await library.save(MusicLibraryEntry.song(song));
      final other = await db.createProfile('Second listener');
      final server = _cacheServer.copyWith(profileId: other.id, id: 'second');
      await db.forProfile(other.id).upsertServer(server);
      await MusicLibraryService.forProfile(db, other.id).save(newSong);
      return server;
    }))!;
    final oldProfileCache = Completer<List<Map<String, Object>>>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final owners = <String>[];
    messenger.setMockMethodCallHandler(_cacheChannel, (call) async {
      expect(call.method, 'cachedMusicSongs');
      final profile = call.arguments['profileId'] as String;
      owners.add(profile);
      return profile == _cacheServer.profileId
          ? oldProfileCache.future
          : <Map<String, Object>>[];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_cacheChannel, null));

    app.selectServer(_cacheServer);
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('music-library-tab-songs')));
    await tester.pumpAndSettle();
    final filter =
        find.byKey(const ValueKey('music-saved-songs-offline-filter'));
    await tester.tap(filter);
    await tester.pump();
    expect(owners, [_cacheServer.profileId]);

    await tester.runAsync(() => db.useProfile(newServer.profileId));
    app.selectServer(newServer);
    await tester.pumpAndSettle();
    // The filter can reset or check the new owner on a profile switch.
    if (find.text(newSong.title).evaluate().isNotEmpty) {
      await tester.tap(filter);
      await tester.pumpAndSettle();
    }
    expect(owners, contains(newServer.profileId));
    expect(find.text(newSong.title), findsNothing);
    oldProfileCache.complete([_cachedSong(song, 'a')]);
    await tester.pumpAndSettle();
    expect(find.text(newSong.title), findsNothing);
    expect(find.text('Saved song'), findsNothing);
    expect(player.collections, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('saved song title edits update the row and Find until reset',
      (tester) async {
    const editedTitle = 'Étoile Live';
    await tester.runAsync(() => library.save(MusicLibraryEntry.song(song)));
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('music-library-tab-songs')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-library-layout')));
    await tester.pumpAndSettle();

    final row = find.byKey(ValueKey('music-saved-song-${song.videoId}'));
    final actions =
        find.descendant(of: row, matching: find.byTooltip('Music actions'));
    final input = find.byKey(const ValueKey('music-saved-song-title-input'));
    Finder rowTitle(String title) =>
        find.descendant(of: row, matching: find.text(title));

    await tester.tap(actions);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit title'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: input, matching: find.text(song.title!)),
        findsOneWidget);
    await tester.enterText(input, '  $editedTitle  ');
    await tester.runAsync(() async {
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await waitFor(() => library.entries.single.savedTitle == editedTitle);
    });
    await tester.pumpAndSettle();
    expect(rowTitle(editedTitle), findsOneWidget);
    expect(rowTitle(song.title!), findsNothing);
    expect(library.entries.single.title, song.title);
    expect(library.entries.single.id, song.videoId);

    await tester.tap(find.byKey(const ValueKey('music-saved-songs-search')));
    await tester.pumpAndSettle();
    final query = find.byKey(const ValueKey('music-saved-songs-query'));
    await tester.enterText(query, 'etoile live');
    await tester.pumpAndSettle();
    expect(rowTitle(editedTitle), findsOneWidget);

    await tester.tap(actions);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit title'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Use original title'));
      await tester.pumpAndSettle();
      await waitFor(() => library.entries.single.savedTitle == null);
    });
    await tester.pumpAndSettle();
    expect(row, findsNothing);
    expect(find.text('No results found.'), findsOneWidget);

    await tester.enterText(query, 'saved song');
    await tester.pumpAndSettle();
    expect(rowTitle(song.title!), findsOneWidget);
  });

  testWidgets('title sorting is local and grid actions preserve saved songs',
      (tester) async {
    const first = MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'firstsong01',
        title: 'Alpha song',
        subtitle: 'First artist');
    const last = MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'lastsong001',
        title: 'Zulu song',
        subtitle: 'Last artist');
    await tester.runAsync(() async {
      await library.save(first);
      await library.save(last);
    });
    await show(tester);
    await tester.tap(find.text('Songs'));
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('music-library-layout')));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Zulu song')).dy,
        lessThan(tester.getTopLeft(find.text('Alpha song')).dy));

    await chooseOrder(tester, 'music-library-sort', 'Title',
        () => savedLibraryOrder('songs') == 'title:ascending');
    expect(tester.getTopLeft(find.text('Alpha song')).dy,
        lessThan(tester.getTopLeft(find.text('Zulu song')).dy));
    expect(library.entries.map((entry) => entry.id), [last.id, first.id]);

    await tester.tap(find.byKey(const ValueKey('music-library-layout')));
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);
    await tester.tap(find.text('Zulu song'));
    await tester.pump();
    expect(player.online.map((song) => song.videoId), [first.id, last.id]);
    expect(player.start, 1);
    expect(find.byTooltip('Music actions'), findsNWidgets(2));
    expect(tester.takeException(), isNull);

    await chooseOrder(tester, 'music-library-sort', 'Descending',
        () => savedLibraryOrder('songs') == 'title:descending');
    expect(player.online.map((song) => song.videoId), [first.id, last.id]);
    await tester.tap(find.byKey(const ValueKey('music-library-tab-channels')));
    await tester.pumpAndSettle();
    expect(find.text('Saved order'), findsOneWidget);
    expect(savedLibraryOrder('channels'), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await settings.close();
    settings = TestSettingsCubit(SettingsState.init(), app);
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('music-library-tab-songs')));
    await tester.pumpAndSettle();
    expect(savedLibraryOrder('songs'), 'title:descending');
    expect(tester.getTopLeft(find.text('Zulu song')).dx,
        lessThan(tester.getTopLeft(find.text('Alpha song')).dx));

    final next = (await tester.runAsync(() => db.createProfile('Second')))!;
    await tester.pumpWidget(const SizedBox.shrink());
    await settings.close();
    await tester.runAsync(() => db.useProfile(next.id));
    app.profileChanged(next.id);
    settings = TestSettingsCubit(SettingsState.init(), app);
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('music-library-tab-songs')));
    await tester.pumpAndSettle();
    expect(savedLibraryOrder('songs'), isNull);
    expect(find.text('Saved order'), findsOneWidget);
  });

  for (final listMenu in [false, true]) {
    testWidgets(
        'Saved Songs search plays a match in the full sorted ${listMenu ? 'list from its menu' : 'grid'}',
        (tester) async {
      const sorted = [
        MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: 'prelude0001',
            title: 'Aube',
            subtitle: 'Solo'),
        MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: 'ballade0001',
            title: 'Ballade Étude',
            subtitle: 'Lúcia'),
        MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: 'cadence0001',
            title: 'Coda Étude',
            subtitle: 'Hélène'),
        MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: 'finale00001',
            title: 'Dune',
            subtitle: 'Lúcia'),
      ];
      await tester.runAsync(() async {
        for (final entry in sorted) {
          await library.save(entry);
        }
      });
      await show(tester);
      final search = find.byKey(const ValueKey('music-saved-songs-search'));
      final query = find.byKey(const ValueKey('music-saved-songs-query'));
      expect(search, findsNothing);
      await tester.tap(find.byKey(const ValueKey('music-library-tab-songs')));
      await tester.pumpAndSettle();
      await chooseOrder(tester, 'music-library-sort', 'Title',
          () => savedLibraryOrder('songs') == 'title:ascending');
      expect(
          find.byTooltip('Search saved songs').hitTestable(), findsOneWidget);
      await tester.tap(search);
      await tester.pumpAndSettle();
      await tester.enterText(query, 'unknown song');
      await tester.pumpAndSettle();
      expect(find.text('No results found.'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear text'));
      await tester.pumpAndSettle();
      expect(find.text('Aube'), findsOneWidget);
      await tester.enterText(query, ' LUCIA   etude ');
      await tester.pumpAndSettle();
      if (listMenu) {
        await tester.tap(find.byKey(const ValueKey('music-library-layout')));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(query).controller!.text,
            ' LUCIA   etude ');
      }
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('music-saved-songs-results')),
              matching: find.byType(listMenu ? SliverList : SliverGrid)),
          findsOneWidget);
      expect(find.text('Coda Étude'), findsNothing);
      expect(find.text('Dune'), findsNothing);
      final match = find.text('Ballade Étude');
      expect(match, findsOneWidget);
      if (listMenu) {
        await tester.tap(find.byTooltip('Music actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('music-song-play')));
      } else {
        await tester.tap(match);
      }
      await tester.pumpAndSettle();
      expect(player.online.map((entry) => entry.videoId),
          sorted.map((entry) => entry.id));
      expect(player.start, 1);
    });
  }

  for (final list in [false, true]) {
    testWidgets(
        'filtered Saved Songs ${list ? 'list' : 'grid'} plays the selected subset in title order',
        (tester) async {
      const titles = ['Aube', 'Bridge', 'Interlude', 'Zulu'];
      await tester.runAsync(() async {
        for (final title in titles) {
          await library.save(MusicLibraryEntry(
              kind: MusicLibraryKind.song,
              id: title.toLowerCase().padRight(11, '0'),
              title: title,
              subtitle: title == 'Interlude' ? 'Solo' : 'Choir'));
        }
      });
      await show(tester);
      final select = find.byKey(const ValueKey('music-saved-songs-select'));
      expect(select, findsNothing);
      await tester.tap(find.byKey(const ValueKey('music-library-tab-songs')));
      await tester.pumpAndSettle();
      expect(select.hitTestable(), findsOneWidget);
      await chooseOrder(tester, 'music-library-sort', 'Title',
          () => savedLibraryOrder('songs') == 'title:ascending');
      if (list) {
        await tester.tap(find.byKey(const ValueKey('music-library-layout')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('Search saved songs'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('music-saved-songs-query')), 'choir');
      await tester.pumpAndSettle();
      expect(select.hitTestable(), findsOneWidget);
      expect(find.text('Interlude'), findsNothing);
      await tester.longPress(find.text('Zulu'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      bool selected(String title) =>
          tester.getSemantics(find.text(title)).flagsCollection.isSelected;
      expect(selected('Zulu'), isTrue);
      expect(selected('Aube'), isFalse);
      await tester.tap(find.byTooltip('Select all'));
      await tester.pumpAndSettle();
      expect(find.text('3 selected'), findsOneWidget);
      await tester.tap(find.byTooltip('Deselect all'));
      await tester.pumpAndSettle();
      expect(find.text('0 selected'), findsOneWidget);
      for (final title in ['Zulu', 'Aube']) {
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
      }
      expect(selected('Aube'), isTrue);
      expect(selected('Bridge'), isFalse);
      expect(player.online, isEmpty);
      await tester
          .tap(find.byKey(const ValueKey('music-playlist-selection-actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      expect(
          player.online.map((v) => v.musicMetadata!.title), ['Aube', 'Zulu']);
      expect(player.source, isNull);
    });
  }

  testWidgets(
      'filtered Saved Songs save matching bookmarks in the current title order',
      (tester) async {
    await tester.runAsync(() async {
      for (final (id, title, artist) in [
        ('aube0000001', 'Aube', 'Choir'),
        ('interlude01', 'Interlude', 'Solo'),
        ('zulu0000001', 'Zulu', 'Choir'),
      ]) {
        await library.save(MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: id,
            title: title,
            subtitle: artist));
      }
    });
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('music-library-tab-songs')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-library-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Title'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Search saved songs'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('music-saved-songs-query')), 'choir');
    await tester.pumpAndSettle();

    final saved = await saveFilteredResults(tester, 'Choir songs');
    expect(saved.videos.map((entry) => entry.musicMetadata!.title),
        ['Aube', 'Zulu']);
  });

  testWidgets(
      'Saved Songs keyboard selection rejects a menu snapshot after a bookmark is removed',
      (tester) async {
    await tester.runAsync(() async {
      await library.save(MusicLibraryEntry.song(song));
      await library.save(const MusicLibraryEntry(
          kind: MusicLibraryKind.song,
          id: 'othersong01',
          title: 'Saved song',
          subtitle: 'Other artist'));
    });
    await show(tester);
    await tester.tap(find.text('Songs'));
    await tester.pumpAndSettle();
    final select = find.byKey(const ValueKey('music-saved-songs-select'));
    expect(find.byTooltip('Select songs').hitTestable(), findsOneWidget);
    final icon = find.descendant(of: select, matching: find.byType(Icon));
    Focus.of(tester.element(icon)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);
    await tester.tap(find.byTooltip('Select all'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('music-playlist-selection-actions')));
    await tester.pumpAndSettle();
    await tester
        .runAsync(() => library.remove(MusicLibraryKind.song, song.videoId));
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    expect(player.online, isEmpty);
    expect(
        find.byKey(ValueKey('music-saved-song-${song.videoId}')), findsNothing);
    expect(find.text('Other artist'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Library song selection adds in display order and confirms bookmark removal',
      (tester) async {
    final destination = (await tester.runAsync(() async {
      for (final (id, title) in [
        ('zulu0000001', 'Zulu'),
        ('middle00001', 'Middle'),
        ('alpha000001', 'Alpha'),
      ]) {
        await library.save(MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: id,
            title: title,
            subtitle: 'Band'));
      }
      return service
          .createLocalPlaylistWithEntries('Selection destination', []);
    }))!;
    player.showCurrentSong(song);
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('music-library-layout')));
    await tester.pumpAndSettle();

    Future<void> selectPair() async {
      await tester.longPress(find.text('Zulu'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      final second = find.widgetWithText(ListTile, 'Alpha');
      expect(tester.widget<ListTile>(second).selected, isFalse);
      await tester.ensureVisible(second);
      await tester.tap(second);
      await tester.pumpAndSettle();
      expect(player.online, isEmpty);
      expect(tester.widget<ListTile>(second).selected, isTrue);
      expect(find.text('2 selected'), findsOneWidget);
    }

    Future<void> choose(String label) async {
      await tester
          .tap(find.byKey(const ValueKey('music-playlist-selection-actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    await selectPair();
    await choose('Add to queue');
    expect(player.queuedPlaylists.single.next, isFalse);
    expect(
      player.queuedPlaylists.single.videos.map((entry) => entry.videoId),
      ['alpha000001', 'zulu0000001'],
    );
    expect(player.state.currentlyPlaying?.videoId, song.videoId);

    await selectPair();
    await choose('Save to playlist');
    Iterable<Video> saved() => service
        .getLocalPlaylists()
        .singleWhere((list) => list.playlistId == destination)
        .videos;
    await tester.runAsync(() async {
      await tester.tap(find.text('Selection destination').last);
      await waitFor(() => saved().length == 2);
      await tester.pumpAndSettle();
    });
    await tester.pumpAndSettle();
    expect(
        saved().map((entry) => entry.videoId), ['alpha000001', 'zulu0000001']);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsNothing);

    await selectPair();
    await tester.tap(find.text('Zulu'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await choose('Remove from Saved Songs');
    expect(find.text('Remove this song from Saved Songs?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(library.entries, hasLength(3));

    await choose('Remove from Saved Songs');
    await tester.runAsync(() async {
      await tester
          .tap(find.widgetWithText(FilledButton, 'Remove from Saved Songs'));
      await tester.pumpAndSettle();
      await waitFor(() => library.entries.length == 2);
    });
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('1 selected'), findsNothing);
    expect(find.text('Middle'), findsOneWidget);
    expect(find.text('Zulu'), findsOneWidget);
    expect(
        saved().map((entry) => entry.videoId), ['alpha000001', 'zulu0000001']);

    await tester.longPress(find.text('Zulu'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsNothing);
    await tester.tap(find.text('Middle'));
    await tester.pumpAndSettle();
    expect(player.online[player.start!].videoId, 'middle00001');
  });

  Future<void> seedChorusSongs(WidgetTester tester) async {
    await tester.runAsync(() => db.saveSetting(SettingsValue(
        musicLibrarySettingName,
        jsonEncode({
          'version': 1,
          'entries': [
            for (var index = 0; index < 40; index++)
              MusicLibraryEntry(
                      kind: MusicLibraryKind.song,
                      id: 'song${index.toString().padLeft(7, '0')}',
                      title: 'Recording $index',
                      subtitle: index.isEven ? 'Chorus' : 'Solo')
                  .toJson(),
          ],
          'playlists': []
        }))));
  }

  testWidgets(
      'Back from Saved Songs Find restores its list position and leaves search scoped to Songs',
      (tester) async {
    await seedChorusSongs(tester);
    await show(tester);
    final songs = find.byKey(const ValueKey('music-library-tab-songs'));
    final search = find.byKey(const ValueKey('music-saved-songs-search'));
    final query = find.byKey(const ValueKey('music-saved-songs-query'));
    await tester.tap(songs);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-library-layout')));
    await tester.pumpAndSettle();
    final list = find.byType(ListView);
    final results = find.byKey(const ValueKey('music-saved-songs-results'));
    double normalOffset() => tester
        .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)))
        .position
        .pixels;
    await tester.drag(list, const Offset(0, -325));
    await tester.pumpAndSettle();
    final originalOffset = normalOffset();
    expect(originalOffset, greaterThan(0));
    await tester.tap(search);
    await tester.pumpAndSettle();
    await tester.enterText(query, 'chorus');
    await tester.pumpAndSettle();
    double findOffset() =>
        tester.widget<CustomScrollView>(results).controller!.offset;
    expect(findOffset(), 0);
    await tester.drag(results, const Offset(0, -180));
    await tester.pumpAndSettle();
    final resultsOffset = findOffset();
    expect(resultsOffset, greaterThan(0));
    await tester
        .longPress(find.textContaining('Recording ').hitTestable().first);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsNothing);
    expect(findOffset(), resultsOffset);
    final navigator = Navigator.of(tester.element(results));
    final resultScroll = tester.widget<CustomScrollView>(results).controller!;
    unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => const Scaffold(body: Text('Other page')))));
    await tester.pumpAndSettle();
    expect(resultScroll.offset, resultsOffset,
        reason: 'The covered list keeps its position.');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(findOffset(), resultsOffset);
    await tester.drag(results, const Offset(0, 90));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(query).controller!.text, 'chorus');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(query, findsNothing);
    expect(tester.widget<ChoiceChip>(songs).selected, isTrue);
    expect(normalOffset(), originalOffset);
    await tester.tap(find.byKey(const ValueKey('music-library-tab-playlists')));
    await tester.pumpAndSettle();
    expect(search, findsNothing);
    await tester.tap(songs);
    await tester.pumpAndSettle();
    await tester.tap(search);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(query).controller!.text, isEmpty);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(query, findsNothing);
    expect(tester.widget<ChoiceChip>(songs).selected, isTrue);
  });

  testWidgets(
      'large-text Saved Songs results remain reachable above a landscape keyboard',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(740, 360);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await seedChorusSongs(tester);
    await show(tester);
    await tester.tap(find.byKey(const ValueKey('music-library-tab-songs')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-library-layout')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-saved-songs-search')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('music-saved-songs-query')), 'chorus');
    tester.view.viewInsets = const FakeViewPadding(bottom: 302);
    await tester.pumpAndSettle();
    final results = find.byKey(const ValueKey('music-saved-songs-results'));
    expect(tester.getSize(results).height, 58);
    expect(tester.takeException(), isNull);
    final match = find.text('Recording 8').hitTestable();
    final scroller =
        find.descendant(of: results, matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(match, 32,
        scrollable: scroller, maxScrolls: 45);
    expect(match, findsOneWidget);
    final controller = tester.widget<CustomScrollView>(results).controller!;
    final shortOffset = controller.offset;
    expect(shortOffset, greaterThan(0));
    await tester.tap(match);
    await tester.pumpAndSettle();
    expect(player.start, 8);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(controller.offset, shortOffset);
    expect(tester.takeException(), isNull);
  });

  testWidgets('music cards adapt to a narrow screen with large text',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => library.save(const MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'longtitle01',
        title: 'A long recording title that wraps across the card',
        subtitle: 'A long artist and collaborator name')));
    await show(tester,
        body: const MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: MusicLibraryPage()));
    await tester.ensureVisible(find.text('Songs'));
    await tester.tap(find.text('Songs'));
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(680, 800);
    await tester.pumpAndSettle();
    int columns() =>
        (tester.widget<GridView>(find.byType(GridView)).gridDelegate
                as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount;
    expect(columns(), 2);
    const longTitle = 'A long recording title that wraps across the card';
    expect(tester.widget<Text>(find.text(longTitle)).maxLines, 2);
    await tester.runAsync(() => settings.setMusicLayout(
        const MusicLayout.defaults().copyWith(
            gridSize: MusicGridSize.small,
            songTitleLines: MusicSongTitleLines.one,
            compactRows: true)));
    await tester.pumpAndSettle();
    expect(columns(), 3);
    expect(tester.widget<Text>(find.text(longTitle)).maxLines, 1);
    tester.view.physicalSize = const Size(360, 800);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-library-layout')));
    await tester.pumpAndSettle();
    expect(find.byType(ListView), findsOneWidget);
    final row = find.byKey(const ValueKey('music-saved-song-longtitle01'));
    expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
    expect(tester.widget<Text>(find.text(longTitle)).maxLines, 1);
    expect(tester.takeException(), isNull);
  });

  for (final kind in [MusicLibraryKind.song, MusicLibraryKind.playlist]) {
    testWidgets('large $kind libraries allocate rows only near the viewport',
        (tester) async {
      const count = 1000;
      await tester.runAsync(() => db.saveSetting(SettingsValue(
          musicLibrarySettingName,
          jsonEncode({
            'version': 1,
            'entries': [
              for (var index = 0; index < count; index++)
                MusicLibraryEntry(
                        kind: kind,
                        id: 'song${index.toString().padLeft(7, '0')}',
                        title: 'Saved entry $index')
                    .toJson(),
            ],
            'playlists': [],
          }))));
      await show(tester);
      if (kind == MusicLibraryKind.song) {
        await tester.tap(find.text('Songs'));
      } else {
        await tester.tap(find.text('Playlists'));
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('music-library-layout')));
      await tester.pumpAndSettle();
      final list = tester.widget<ListView>(find.byType(ListView));
      final delegate = list.childrenDelegate;
      final eagerRows =
          delegate is SliverChildListDelegate ? delegate.children.length : 0;
      // Count allocated row widgets, including offscreen children retained by
      // a list delegate. Mounted elements alone hide eager construction.
      expect(eagerRows, lessThan(30),
          reason: 'Opening a library must not allocate all $count rows');
      expect(find.text('Saved entry 0'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Saved entry 999'), 800,
          scrollable: find.descendant(
              of: find.byType(ListView), matching: find.byType(Scrollable)),
          maxScrolls: 100);
      await tester.pumpAndSettle();
      expect(find.text('Saved entry 999'), findsOneWidget);
      if (kind == MusicLibraryKind.song) {
        await tester.tap(find.text('Saved entry 999'));
        await tester.pump();
        expect(player.online, hasLength(count));
        expect(player.start, count - 1);
        expect(player.online.last.videoId, 'song0000999');
      }
      expect(library.entries, hasLength(count));
      expect(tester.takeException(), isNull);
    });
  }

  Future<void> revealLocalPlaylistTrack(
      WidgetTester tester, Finder trackTitle) async {
    final tracks = find.byKey(const ValueKey('music-collection-tracks-pane'));
    await tester.scrollUntilVisible(trackTitle, 160,
        scrollable:
            find.descendant(of: tracks, matching: find.byType(Scrollable)));
    await tester.pumpAndSettle();
  }

  for (final tv in [false, true]) {
    testWidgets(
        'local playlist Back only consumes the active Library (TV: $tv)',
        (tester) async {
      app_globals.isTv = tv;
      await tester.runAsync(
          () => MusicLibrarySession(app).createPlaylist('Music list', [song]));
      final active = ValueNotifier(true);
      await show(tester,
          body: ValueListenableBuilder<bool>(
              valueListenable: active,
              child: const MusicLibraryPage(),
              builder: (context, value, child) =>
                  TickerMode(enabled: value, child: child!)));
      await tester.tap(find.text('Music list'));
      await tester.pumpAndSettle();
      await revealLocalPlaylistTrack(tester, find.text('Saved song'));
      expect(find.text('Saved song'), findsOneWidget);
      final navigator =
          Navigator.of(tester.element(find.byType(MusicLibraryPage)));

      active.value = false;
      await tester.pumpAndSettle();
      expect(await navigator.maybePop(), isFalse);
      active.value = true;
      await tester.pumpAndSettle();
      expect(find.text('Saved song'), findsOneWidget);

      expect(await navigator.maybePop(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('Saved song'), findsNothing);
      expect(find.text('Music list'), findsOneWidget);
      expect(find.byTooltip('Create new playlist'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      active.dispose();
    });
  }

  testWidgets('song and channel buttons preserve hidden legacy album bookmarks',
      (tester) async {
    const album = MusicLibraryEntry(
        kind: MusicLibraryKind.album, id: 'MPREalbum', title: 'Album');
    const channel = MusicLibraryEntry(
        kind: MusicLibraryKind.artist, id: 'UCchannel', title: 'Channel');
    await tester.runAsync(() => library.save(album));
    await show(tester,
        body: Column(children: [
          const MusicLibraryActions(videos: [song], compact: false),
          const MusicBookmarkButton(entry: channel),
          const MusicBookmarkButton(entry: album),
        ]));
    expect(find.text('Save album'), findsNothing);
    expect(find.text('Remove saved album'), findsNothing);
    await tester.runAsync(() async {
      await tester.tap(find.text('Save song'));
      await waitFor(
          () => library.contains(MusicLibraryKind.song, song.videoId));
    });
    await tester.pumpAndSettle();
    expect(find.text('Remove saved song'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Save channel'));
      await waitFor(
          () => library.contains(MusicLibraryKind.artist, channel.id));
    });
    await tester.pumpAndSettle();
    expect(find.text('Remove saved channel'), findsOneWidget);
    expect(library.entries.map((entry) => entry.kind), [
      MusicLibraryKind.artist,
      MusicLibraryKind.song,
      MusicLibraryKind.album
    ]);
    expect(library.entries.last.toJson(), album.toJson());
  });

  testWidgets('empty Music playlist creation is visible immediately',
      (tester) async {
    await show(tester);
    await tester.tap(find.byTooltip('Create new playlist'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'My music');
    await tester.runAsync(() async {
      await tester.tap(find.text('Add'));
      await waitFor(() => service.getLocalPlaylists().any((playlist) =>
          playlist.title == 'My music' && library.isMusicPlaylist(playlist)));
    });
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('My music'), findsOneWidget);
  });

  testWidgets(
      'supported bookmarks can be removed while legacy albums stay stored',
      (tester) async {
    const album = MusicLibraryEntry(
        kind: MusicLibraryKind.album, id: 'MPREalbum', title: 'Saved album');
    const artist = MusicLibraryEntry(
        kind: MusicLibraryKind.artist, id: 'UCartist', title: 'Saved artist');
    const playlist = MusicLibraryEntry(
        kind: MusicLibraryKind.playlist,
        id: 'PLpublic',
        title: 'Public playlist');
    await tester.runAsync(() async {
      for (final entry in [album, artist, playlist]) {
        await library.save(entry);
      }
    });
    await show(tester);
    expect(find.text('Albums'), findsNothing);
    expect(find.text('Artists'), findsNothing);
    expect(find.text('Saved album'), findsNothing);
    for (final item in [
      (tab: 'Playlists', label: 'Remove saved playlist', entry: playlist),
      (tab: 'Channels', label: 'Remove saved channel', entry: artist),
    ]) {
      await tester.tap(find.text(item.tab));
      await tester.pumpAndSettle();
      expect(find.text(item.entry.title), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip(item.label));
        await waitFor(() => !library.contains(item.entry.kind, item.entry.id));
      });
      await tester.pumpAndSettle();
      expect(find.text(item.entry.title), findsNothing);
    }
    expect(library.entries.single.toJson(), album.toJson());
  });

  for (final recovers in [false, true]) {
    testWidgets(
        'playlist replacement verifies the selected copy and rechecks availability (recovery: $recovers)',
        (tester) async {
      tester.view.physicalSize = const Size(800, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const candidate = MusicTrack(
        videoId: 'alternate01',
        title: 'Alternate recording',
        artists: ['Another artist'],
        albumTitle: 'Live album',
        durationSeconds: 265,
      );
      const videoOnly = Video(videoId: 'videoonly01', title: 'Video only');
      final previous = musicCatalogService;
      final catalog = _ReplacementCatalog(song.videoId, candidate, [
        if (recovers) StateError('Temporary provider outage'),
        MusicRecordingAvailability.missing,
        recovers
            ? MusicRecordingAvailability.available
            : MusicRecordingAvailability.missing,
      ]);
      musicCatalogService = catalog;
      addTearDown(() => musicCatalogService = previous);
      final id = await tester.runAsync(() => service
          .createLocalPlaylistWithEntries(
              'Repair list', [song, videoOnly, candidate.toVideo(), song]));
      Playlist current() => service
          .getLocalPlaylists()
          .singleWhere((playlist) => playlist.playlistId == id);

      final before = current();
      await show(tester,
          body: MusicLibraryPage(
            source: PlaylistReference.forPlaylist(before, db),
          ));
      final selected = find.byKey(ValueKey(before.videos.last.queueEntryId!));
      await tester.tap(find.descendant(
          of: selected, matching: find.byTooltip('Music actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Replace unavailable song'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      Finder dialogText(String text) =>
          find.descendant(of: dialog, matching: find.text(text));
      const search = ValueKey('music-playlist-replacement-search');
      if (recovers) {
        expect(
            dialogText('Could not verify recording availability. Try again.'),
            findsOneWidget);
        expect(find.byKey(search), findsNothing);
        expect(catalog.searches, isEmpty);
        await tester.tap(dialogText('Retry'));
        await tester.pumpAndSettle();
      }
      expect(find.byKey(search), findsOneWidget);
      await tester
          .tap(find.descendant(of: dialog, matching: find.byTooltip('Search')));
      await tester.pumpAndSettle();
      expect(dialogText('Same ID'), findsNothing);
      await tester.tap(dialogText(candidate.title));
      await tester.pumpAndSettle();
      expect(dialogText('Another artist · Live album · 04:25'), findsOneWidget);
      expect(jsonEncode(current().videos), jsonEncode(before.videos));

      final confirm = dialogText('Replace this entry');
      if (recovers) {
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(
            dialogText('This recording is still available.'), findsOneWidget);
        expect(confirm, findsNothing);
        expect(jsonEncode(current().videos), jsonEncode(before.videos));
      } else {
        await tester.runAsync(() async {
          await tester.tap(confirm);
          await waitFor(
              () => current().videos.last.videoId == candidate.videoId);
        });
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);
        final after = current();
        expect(jsonEncode(after.videos.take(3).toList()),
            jsonEncode(before.videos.take(3).toList()));
        expect(after.videos.last.videoId, candidate.videoId);
        expect(after.videos.last.indexId, before.videos.last.indexId);
        expect(after.videoCount, before.videoCount);
      }
      expect(catalog.requestedIds, [
        song.videoId,
        if (recovers) song.videoId,
        candidate.videoId,
        song.videoId,
      ]);
    });
  }

  for (final tv in [false, true]) {
    testWidgets(
        'Music removes the selected song from a mixed local playlist (TV: $tv)',
        (tester) async {
      app_globals.isTv = tv;
      const otherSong = Video(
          videoId: 'secondsong2',
          musicMetadata:
              MusicMetadata(title: 'Second song', artist: 'Other channel'));
      const nonMusic = Video(videoId: 'videoonly01', title: 'Video only');
      await tester.runAsync(() async {
        await MusicLibrarySession(app)
            .createPlaylist('Mixed music list', [nonMusic, song, otherSong]);
        await library.save(MusicLibraryEntry.song(song));
      });
      final playlistId = service
          .getLocalPlaylists()
          .singleWhere((playlist) => playlist.title == 'Mixed music list')
          .playlistId;
      await show(tester);
      expect(find.text('Albums'), findsNothing);
      expect(find.text('Channels'), findsOneWidget);
      await tester.tap(find.text('Mixed music list'));
      await tester.pumpAndSettle();
      expect(find.text('Video only'), findsNothing);
      final savedTitle = find.text('Saved song');
      await revealLocalPlaylistTrack(tester, savedTitle);
      final savedTrack =
          find.ancestor(of: savedTitle, matching: find.byType(ListTile));
      await tester.tap(find.descendant(
          of: savedTrack, matching: find.byTooltip('Music actions')));
      await tester.pumpAndSettle();
      expect(find.text('Remove saved song'), findsOneWidget);
      final remove = find.ancestor(
        of: find.text('Remove from playlist'),
        matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
      );
      await tester.ensureVisible(remove);
      await tester.pumpAndSettle();
      expect(remove.hitTestable(), findsOneWidget);
      await tester.runAsync(() => tester.tap(remove.hitTestable()));
      await tester.pumpAndSettle();
      await tester.runAsync(() => waitFor(() =>
          service
              .getLocalPlaylists()
              .singleWhere((playlist) => playlist.playlistId == playlistId)
              .videos
              .length ==
          2));
      await tester.pumpAndSettle();
      expect(find.text('Saved song'), findsNothing);
      expect(find.text('Second song'), findsOneWidget);
      final remaining = service.getLocalPlaylists().singleWhere(
            (playlist) => playlist.playlistId == playlistId,
          );
      expect(remaining.videos.map((video) => video.videoId),
          [nonMusic.videoId, otherSong.videoId]);
      expect(remaining.videos.last.musicMetadata?.toJson(),
          otherSong.musicMetadata?.toJson());
      expect(library.contains(MusicLibraryKind.song, song.videoId), isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'the Downloads shortcut shows current-profile music and plays completed files',
      (tester) async {
    const complete = DownloadedVideo(
        videoId: 'abcdefghijk',
        title: 'Downloaded song',
        musicMetadata:
            MusicMetadata(title: 'Downloaded song', artist: 'Artist'),
        audioOnly: true,
        downloadComplete: true,
        lengthSeconds: 90,
        quality: 'audio');
    final downloads = _Downloads(DownloadManagerState(videos: [
      complete,
      complete.copyWith(
          videoId: 'queuedmusic',
          title: 'Queued',
          musicMetadata: const MusicMetadata(title: 'Queued', artist: 'Artist'),
          downloadComplete: false),
      complete.copyWith(
          videoId: 'foreignsong', profileId: 'another', title: 'Other person'),
      complete.copyWith(
          videoId: 'alreadyshared',
          musicFormat: MusicDownloadFormat.mp3,
          storageUri: 'content://documents/public-track'),
      complete.copyWith(
          videoId: 'legacyshared',
          storageUri: 'content://documents/legacy-track'),
      complete.copyWith(
          videoId: 'videofile01', audioOnly: false, title: 'Video'),
      complete.copyWith(
          videoId: 'spokenword1', musicMetadata: null, title: 'Speech'),
    ]));
    await show(tester, downloads: downloads);
    await tester
        .tap(find.byKey(const ValueKey('music-library-shortcut-downloads')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('music-download-abcdefghijk')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('music-download-queuedmusic')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('export-music-abcdefghijk')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('export-music-queuedmusic')), findsNothing);
    expect(
        find.byKey(const ValueKey('export-music-alreadyshared')), findsNothing);
    expect(find.byKey(const ValueKey('export-music-legacyshared')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('music-download-foreignsong')), findsNothing);
    expect(
        find.byKey(const ValueKey('music-download-videofile01')), findsNothing);
    expect(
        find.byKey(const ValueKey('music-download-spokenword1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('music-download-queuedmusic')));
    expect(player.offline, isEmpty);
    await tester
        .tap(find.byKey(const ValueKey('music-download-alreadyshared')));
    await tester.pump();
    expect(player.offline.map((song) => song.videoId),
        [complete.videoId, 'alreadyshared', 'legacyshared']);
    expect(player.start, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await downloads.close();
  });

  DownloadedVideo downloadedSong(String id, String title, String artist,
          {bool complete = true}) =>
      DownloadedVideo(
          videoId: id,
          title: 'Provider title for $id',
          musicMetadata: MusicMetadata(title: title, artist: artist),
          audioOnly: true,
          downloadComplete: complete,
          lengthSeconds: 90,
          quality: 'audio');

  Future<void> showDownloads(WidgetTester tester, _Downloads manager,
      {Widget body = const MusicLibraryPage(), PlayerCubit? playback}) async {
    addTearDown(manager.close);
    await show(tester, body: body, downloads: manager, playback: playback);
    expect(find.byKey(const ValueKey('music-downloads-search')), findsNothing);
    await tester
        .tap(find.byKey(const ValueKey('music-library-shortcut-downloads')));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'Downloads collection actions cancel on Android Back and are hidden during selection',
      (tester) async {
    final pending =
        downloadedSong('pending0001', 'Pending', 'Ensemble', complete: false);
    final file = downloadedSong('complete001', 'Concert', 'Ensemble');
    final manager = _Downloads(DownloadManagerState(videos: [
      pending,
      file.copyWith(profileId: 'another'),
      file.copyWith(videoId: '../invalid'),
    ]));
    await showDownloads(tester, manager);
    final actions = find.byKey(const ValueKey('music-downloads-actions'));
    expect(tester.widget<PopupMenuButton<dynamic>>(actions).enabled, isFalse);
    manager.replaceVideos([pending, file]);
    await tester.pumpAndSettle();
    expect(tester.widget<PopupMenuButton<dynamic>>(actions).enabled, isTrue);
    await tester.tap(actions);
    await tester.pumpAndSettle();
    expect(find.text('Shuffle all'), findsOneWidget);
    expect(find.text('Add all to queue'), findsOneWidget);
    expect(player.downloadShuffles, isEmpty);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Shuffle all'), findsNothing);
    expect(find.text('Add all to queue'), findsNothing);
    expect(actions.hitTestable(), findsOneWidget);
    expect(player.downloadShuffles, isEmpty);
    expect(player.downloadQueueAdds, isEmpty);
    expect(player.offlineCalls, 0);
    expect(player.online, isEmpty);

    await tester.tap(find.byKey(const ValueKey('music-downloads-select')));
    await tester.pumpAndSettle();
    expect(actions, findsNothing);
  });

  testWidgets(
      'Downloads Shuffle all uses the latest whole collection when Find has no results',
      (tester) async {
    const order = MusicDownloadOrder(
        field: MusicDownloadSortField.duration, descending: true);
    await tester.runAsync(() => settings.setMusicDownloadOrder(order));
    final stale = downloadedSong('removed0001', 'An old download', 'Live');
    final kept = downloadedSong('concert0001', 'Concert', 'Live');
    final pending =
        downloadedSong('pending0001', 'Overture', 'Guest', complete: false);
    final manager =
        _Downloads(DownloadManagerState(videos: [stale, kept, pending]));
    await showDownloads(tester, manager);
    await tester.tap(find.byTooltip('Search downloads'));
    await tester.pumpAndSettle();
    final query = find.byKey(const ValueKey('music-downloads-query'));
    await tester.enterText(query, 'no matching song');
    await tester.pumpAndSettle();
    expect(find.text('No results found.'), findsOneWidget);
    final actions = find.byKey(const ValueKey('music-downloads-actions'));
    await tester.tap(actions);
    await tester.pumpAndSettle();
    expect(find.text('Shuffle all'), findsOneWidget);
    expect(player.downloadShuffles, isEmpty);
    final refreshed = kept.copyWith(storageUri: 'content://music/latest');
    final nowReady = pending.copyWith(downloadComplete: true);
    final unmeasured = downloadedSong('unknown0001', 'Finale', 'Guest')
        .copyWith(lengthSeconds: 0);
    manager.replaceVideos([
      unmeasured,
      nowReady,
      refreshed,
      stale.copyWith(profileId: 'another'),
      kept.copyWith(videoId: 'failed00001', downloadFailed: true),
      kept.copyWith(videoId: 'storage0001', storageFailed: true),
      kept.copyWith(videoId: 'unauth00001', authenticationRequired: true),
      kept.copyWith(videoId: 'queued00001', downloadComplete: false),
      kept.copyWith(videoId: 'video000001', audioOnly: false),
      kept.copyWith(videoId: 'spoken00001', musicMetadata: null),
      kept.copyWith(videoId: '../invalid'),
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shuffle all'));
    await tester.pumpAndSettle();
    expect(player.downloadShuffles, hasLength(1));
    expect(player.downloadShuffles.single,
        unorderedEquals([refreshed, nowReady, unmeasured]));
    expect(player.offlineCalls, 0);
    expect(player.online, isEmpty);
    expect(
        tester.widget<TextField>(query).controller!.text, 'no matching song');
    expect(find.text('No results found.'), findsOneWidget);
    expect(settings.state.musicDownloadOrder, order);
  });

  testWidgets(
      'Downloads Shuffle all can commit only while the originating tab is visible',
      (tester) async {
    final downloads = _Downloads(DownloadManagerState(
        videos: [downloadedSong('concert0001', 'Concert', 'Live')]));
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await showDownloads(tester, downloads,
        body: ValueListenableBuilder(
          valueListenable: active,
          builder: (context, enabled, child) =>
              TickerMode(enabled: enabled, child: child!),
          child: const MusicLibraryPage(),
        ));
    await tester.tap(find.byKey(const ValueKey('music-downloads-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shuffle all'));
    await tester.pumpAndSettle();
    expect(player.downloadShuffles, hasLength(1));
    final canCommit = player.downloadShuffleIsCurrent!;
    expect(canCommit(), isTrue);

    active.value = false;
    await tester.pumpAndSettle();
    expect(canCommit(), isFalse);
  });

  testWidgets(
      'Downloads Add all queues current completed files in saved order while preserving Find',
      (tester) async {
    const order = MusicDownloadOrder(field: MusicDownloadSortField.title);
    await tester.runAsync(() => settings.setMusicDownloadOrder(order));
    final opening = downloadedSong('opening0001', 'Opening', 'Luna');
    final encore = downloadedSong('encore00001', 'Encore', 'Live');
    final removed = downloadedSong('removed0001', 'Removed', 'Live');
    final paused =
        downloadedSong('paused00001', 'Paused', 'Live', complete: false);
    final manager = _Downloads(DownloadManagerState(
        videos: [opening, removed, paused], pausedVideoIds: {paused.videoId}));
    await showDownloads(tester, manager);
    await tester.tap(find.byTooltip('Search downloads'));
    await tester.pumpAndSettle();
    final query = find.byKey(const ValueKey('music-downloads-query'));
    await tester.enterText(query, 'Luna');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('music-downloads-actions')));
    await tester.pumpAndSettle();
    final refreshed = opening.copyWith(storageUri: 'content://music/latest');
    manager.replaceVideos([
      refreshed,
      removed.copyWith(profileId: 'other'),
      paused,
      opening.copyWith(videoId: 'failed00001', downloadFailed: true),
      encore,
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add all to queue'));
    await tester.pumpAndSettle();
    expect(player.downloadQueueAdds, [
      [encore, refreshed]
    ]);
    expect(tester.widget<TextField>(query).controller!.text, 'Luna');
    expect(find.byKey(ValueKey('music-download-${opening.videoId}')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('music-download-failed00001')),
        findsOneWidget);
    expect(find.text('Encore'), findsNothing);
    expect(player.offlineCalls, 0);
    expect(player.downloadShuffles, isEmpty);
  });

  testWidgets(
      'Downloads Add all cannot append to an incompatible player even when the menu was already open',
      (tester) async {
    final file = downloadedSong('concert0001', 'Concert', 'Live');
    await showDownloads(
        tester, _Downloads(DownloadManagerState(videos: [file])));
    final actions = find.byKey(const ValueKey('music-downloads-actions'));
    final add = find.text('Add all to queue');
    await tester.tap(actions);
    await tester.pumpAndSettle();
    player.canAddMusicDownloadsToQueue = false;
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(player.downloadQueueAdds, isEmpty);

    await tester.tap(actions);
    await tester.pumpAndSettle();
    PopupMenuItem<dynamic> item(String label) => tester.widget(find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem)));
    expect(item('Add all to queue').enabled, isFalse);
    expect(item('Shuffle all').enabled, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(player.downloadQueueAdds, isEmpty);
    expect(player.offlineCalls, 0);
  });

  testWidgets('Downloads Add all reports a rejected queue update',
      (tester) async {
    final file = downloadedSong('concert0001', 'Concert', 'Live');
    await showDownloads(
        tester, _Downloads(DownloadManagerState(videos: [file])));
    player.downloadQueueAddResult = false;
    await tester.tap(find.byKey(const ValueKey('music-downloads-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add all to queue'));
    await tester.pumpAndSettle();
    expect(find.text('Could not update your music library. Try again.'),
        findsOneWidget);
    expect(player.offlineCalls, 0);
  });

  for (final changeProfile in [false, true]) {
    testWidgets(
        'Downloads Add all rejects an open menu and an in-flight command after the ${changeProfile ? 'profile' : 'tab'} changes',
        (tester) async {
      final file = downloadedSong('concert0001', 'Concert', 'Live');
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      await showDownloads(
          tester, _Downloads(DownloadManagerState(videos: [file])),
          body: ValueListenableBuilder(
            valueListenable: active,
            builder: (context, enabled, child) =>
                TickerMode(enabled: enabled, child: child!),
            child: const MusicLibraryPage(),
          ));
      final actions = find.byKey(const ValueKey('music-downloads-actions'));
      final add = find.text('Add all to queue');
      final hold = player.holdDownloadQueueAdd = Completer<void>();
      await tester.tap(actions);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(player.downloadQueueAdds, [
        [file]
      ]);
      final canCommit = player.downloadQueueAddIsCurrent!;
      expect(canCommit(), isTrue);

      await tester.tap(actions);
      await tester.pumpAndSettle();
      if (changeProfile) {
        final next = (await tester.runAsync(() => db.createProfile('Second')))!;
        await tester.runAsync(() => db.useProfile(next.id));
        app.profileChanged(next.id);
      } else {
        active.value = false;
      }
      await tester.pumpAndSettle();
      expect(canCommit(), isFalse);
      hold.complete();
      await tester.pumpAndSettle();
      if (add.evaluate().isNotEmpty) {
        await tester.tap(add);
        await tester.pumpAndSettle();
      }
      expect(find.byType(SnackBar), findsNothing);
      expect(player.downloadQueueAdds, [
        [file]
      ]);
    });
  }

  testWidgets(
      'filtered Downloads save ready matches in the current download order',
      (tester) async {
    final short = downloadedSong('short000001', 'Short take', 'Studio')
        .copyWith(lengthSeconds: 60);
    final long = downloadedSong('long0000001', 'Long take', 'Studio')
        .copyWith(lengthSeconds: 125);
    final pending = downloadedSong('pending0001', 'Pending take', 'Studio',
        complete: false);
    final outside = downloadedSong('live0000001', 'Concert', 'Live');
    const order = MusicDownloadOrder(
        field: MusicDownloadSortField.duration, descending: true);
    await tester.runAsync(() => settings.setMusicDownloadOrder(order));
    await showDownloads(
        tester,
        _Downloads(
            DownloadManagerState(videos: [short, pending, outside, long])));
    await tester.tap(find.byTooltip('Search downloads'));
    await tester.pumpAndSettle();
    final query = find.byKey(const ValueKey('music-downloads-query'));
    await tester.enterText(query, 'pending');
    await tester.pumpAndSettle();
    expect(find.text('Pending take'), findsOneWidget);
    expect(saveResults, findsNothing);
    await tester.enterText(query, 'studio');
    await tester.pumpAndSettle();

    final saved = await saveFilteredResults(tester, 'Studio downloads');
    expect(saved.videos.map((entry) => entry.videoId),
        [long.videoId, short.videoId]);
  });

  testWidgets(
      'Downloads sort persists and filtered playback follows the displayed order',
      (tester) async {
    final unknown = downloadedSong('unknown0001', 'Unmeasured', 'Studio')
        .copyWith(lengthSeconds: 0);
    final short = downloadedSong('short000001', 'Short take', 'Studio')
        .copyWith(lengthSeconds: 60);
    final long = downloadedSong('long0000001', 'Long take', 'Studio')
        .copyWith(lengthSeconds: 125);
    final outside = downloadedSong('live0000001', 'Concert', 'Live')
        .copyWith(lengthSeconds: 80);
    final manager = _Downloads(
        DownloadManagerState(videos: [unknown, short, long, outside]));
    await showDownloads(tester, manager);
    final sort = find.byKey(const ValueKey('music-downloads-sort'));
    expect(sort.hitTestable(), findsOneWidget);
    await tester.tap(sort);
    await tester.pumpAndSettle();
    Finder option(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem));
    for (final label in [
      'Default order',
      'Title',
      'Artist',
      'Album',
      'Duration',
      'Ascending',
      'Descending'
    ]) {
      expect(option(label), findsOneWidget);
    }
    Future<void> choose(String label, MusicDownloadOrder order) async {
      await tester.runAsync(() async {
        await tester.tap(option(label));
        await tester.pumpAndSettle();
        await waitFor(() => settings.state.musicDownloadOrder == order);
      });
      await tester.pumpAndSettle();
    }

    const ascending =
        MusicDownloadOrder(field: MusicDownloadSortField.duration);
    const descending = MusicDownloadOrder(
        field: MusicDownloadSortField.duration, descending: true);
    await choose('Duration', ascending);
    await tester.tap(find.byTooltip('Search downloads'));
    await tester.pumpAndSettle();
    final query = find.byKey(const ValueKey('music-downloads-query'));
    await tester.enterText(query, 'studio');
    await tester.pumpAndSettle();
    double top(String title) => tester.getTopLeft(find.text(title)).dy;
    expect(top('Short take'), lessThan(top('Long take')));
    await tester.tap(sort);
    await tester.pumpAndSettle();
    await choose('Descending', descending);
    expect(tester.widget<TextField>(query).controller!.text, 'studio');
    expect(top('Long take'), lessThan(top('Short take')));
    expect(top('Short take'), lessThan(top('Unmeasured')));
    await tester.tap(find.text('Short take'));
    await tester.pumpAndSettle();
    expect(player.offline, [long, outside, short, unknown]);
    expect(player.start, 2);
    await tester.longPress(find.text('Unmeasured'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Long take'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('music-playlist-selection-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    expect(player.offline.skip(4), [long, unknown]);

    await tester.pumpWidget(const SizedBox.shrink());
    await settings.close();
    settings = TestSettingsCubit(SettingsState.init(), app);
    expect(settings.state.musicDownloadOrder, descending);
    await show(tester, downloads: manager);
    await tester
        .tap(find.byKey(const ValueKey('music-library-shortcut-downloads')));
    await tester.pumpAndSettle();
    expect(top('Long take'), lessThan(top('Concert')));
    expect(top('Concert'), lessThan(top('Short take')));
    expect(top('Short take'), lessThan(top('Unmeasured')));
  });

  group('Downloads storage', () {
    const storageKey = ValueKey('music-downloads-storage');
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    const storageChannel = MethodChannel('videre/download_storage');
    const folder = 'content://documents/tree/Music';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late Directory documents;
    late Map<String, FutureOr<int?>> sizes;
    late List<String> requests;

    setUp(() async {
      documents =
          await Directory.systemTemp.createTemp('videre-music-storage-');
      sizes = {};
      requests = [];
      messenger.setMockMethodCallHandler(
          pathChannel, (_) async => documents.path);
      messenger.setMockMethodCallHandler(storageChannel, (call) async {
        if (call.method != 'documentSize') throw MissingPluginException();
        final uri = call.arguments['uri'] as String;
        requests.add(uri);
        expect(call.arguments['folderUri'], folder);
        return await sizes[uri];
      });
    });

    tearDown(() async {
      messenger.setMockMethodCallHandler(storageChannel, null);
      messenger.setMockMethodCallHandler(pathChannel, null);
      await documents.delete(recursive: true);
    });

    DownloadedVideo stored(String id, String title,
            {String profile = 'default'}) =>
        downloadedSong(id, title, 'Band').copyWith(
            profileId: profile,
            folderUri: folder,
            storageUri: '$folder/document/$id');

    Future<void> expectStorage(WidgetTester tester, String label) async {
      final elapsed = Stopwatch()..start();
      while (elapsed.elapsed < const Duration(seconds: 4)) {
        await tester.pump(const Duration(milliseconds: 30));
        final text = find.byKey(storageKey);
        if (text.evaluate().isNotEmpty &&
            tester.widget<Text>(text).data == label) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(tester.widget<Text>(find.byKey(storageKey)).data, label);
    }

    testWidgets(
        'uses the whole collection while finding and sorting and reflects removals',
        (tester) async {
      await tester.runAsync(() async {
        final first = stored('stored-a', 'First song');
        final second = stored('stored-b', 'Second song');
        final inaccessible = stored('stored-c', 'Unreadable song');
        final foreign = stored('foreign', 'Other profile', profile: 'another');
        final movie = stored('movie', 'A movie').copyWith(audioOnly: false);
        sizes.addAll({
          first.storageUri!: 12,
          second.storageUri!: 45,
          inaccessible.storageUri!: null
        });
        final manager = _Downloads(
            DownloadManagerState(videos: [first, second, foreign, movie]));
        await showDownloads(tester, manager);
        await expectStorage(tester, 'Download storage: 57 B');
        final initial = List.of(requests);
        expect(initial, unorderedEquals([first.storageUri, second.storageUri]));
        await tester.tap(find.byKey(const ValueKey('music-downloads-search')));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const ValueKey('music-downloads-query')), 'First');
        await settings.setMusicDownloadOrder(
            const MusicDownloadOrder(field: MusicDownloadSortField.title));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('music-download-stored-b')),
            findsNothing);
        await expectStorage(tester, 'Download storage: 57 B');
        expect(requests, initial);
        await tester.tap(find.byKey(const ValueKey('music-downloads-select')));
        await tester.pumpAndSettle();
        expect(find.byKey(storageKey), findsNothing);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await expectStorage(tester, 'Download storage: 57 B');

        manager.replaceVideos([second, inaccessible, foreign, movie]);
        await expectStorage(tester, 'Download storage: at least 45 B');
        expect(find.text('No results found.'), findsOneWidget);
        manager.replaceVideos([inaccessible, foreign, movie]);
        await expectStorage(tester, 'Download storage: size unavailable');
        manager.replaceVideos([foreign, movie]);
        await tester.pumpAndSettle();
        expect(find.byKey(storageKey), findsNothing);
        expect(requests, isNot(contains(foreign.storageUri)));
        expect(requests, isNot(contains(movie.storageUri)));
      });
    });

    testWidgets(
        'refreshes a growing transfer only while Downloads is visible and foregrounded',
        (tester) async {
      // Keep the native measurements on the widget test clock. An inaccessible
      // private directory leaves the growing provider file as a lower bound.
      messenger.setMockMethodCallHandler(pathChannel,
          (_) async => throw PlatformException(code: 'storage-unavailable'));
      final binding = tester.binding;
      final previous = binding.lifecycleState;
      addTearDown(() => binding.handleAppLifecycleStateChanged(
          previous ?? AppLifecycleState.resumed));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      final job =
          stored('growing', 'Live transfer').copyWith(downloadComplete: false);
      final location = job.storageUri!;
      sizes[location] = 11;
      final manager = _Downloads(DownloadManagerState(videos: [job]));
      await showDownloads(tester, manager,
          body: ValueListenableBuilder(
              valueListenable: visible,
              builder: (_, enabled, child) =>
                  TickerMode(enabled: enabled, child: child!),
              child: const MusicLibraryPage()));
      Future<void> expectBytes(int value) async {
        final label = 'Download storage: at least $value B';
        // The manager, the platform reply and the FutureBuilder each schedule
        // their own frame. Flush them without advancing the transfer timer.
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump();
          if (tester.widget<Text>(find.byKey(storageKey)).data == label) {
            return;
          }
        }
        expect(tester.widget<Text>(find.byKey(storageKey)).data, label,
            reason: 'Document size requests: $requests');
      }

      await expectBytes(11);
      sizes[location] = 23;
      manager.setTransferring(job.videoId);
      await expectBytes(23);
      final started = requests.length;
      sizes[location] = 44;
      await tester.pump(const Duration(milliseconds: 500));
      expect(requests.length, started);
      await tester.pump(const Duration(seconds: 2));
      await expectBytes(44);
      expect(requests.length, started + 1);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      sizes[location] = 62;
      await tester.pump(const Duration(seconds: 8));
      expect(requests.length, started + 1);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await expectBytes(62);
      visible.value = false;
      await tester.pump();
      final hidden = requests.length;
      sizes[location] = 79;
      await tester.pump(const Duration(seconds: 8));
      expect(requests.length, hidden);
      visible.value = true;
      await expectBytes(79);

      sizes[location] = 93;
      manager.setTransferring(null);
      await expectBytes(93);
      final stopped = requests.length;
      await tester.pump(const Duration(seconds: 8));
      expect(requests.length, stopped);
    });

    testWidgets(
        'ignores late sizes from the previous profile and remeasures on reopening',
        (tester) async {
      await tester.runAsync(() async {
        final other = await db.createProfile('Second');
        final old = stored('shared-id', 'Old song');
        final current = stored('current', 'New song', profile: other.id);
        final pending = Completer<int?>();
        sizes[old.storageUri!] = pending.future;
        sizes[current.storageUri!] = 0;
        final manager =
            _Downloads(DownloadManagerState(videos: [old, current]));
        await showDownloads(tester, manager);
        await expectStorage(tester, 'Checking download storage…');
        await waitFor(() => requests.contains(old.storageUri));
        await db.useProfile(other.id);
        app.profileChanged(other.id);
        await expectStorage(tester, 'Download storage: 0 B');
        pending.complete(97);
        await tester.pumpAndSettle();
        await expectStorage(tester, 'Download storage: 0 B');
        expect(find.byKey(const ValueKey('music-download-shared-id')),
            findsNothing);
        expect(find.byKey(const ValueKey('music-download-current')),
            findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        sizes[current.storageUri!] = 73;
        await show(tester, downloads: manager);
        await tester.tap(
            find.byKey(const ValueKey('music-library-shortcut-downloads')));
        await expectStorage(tester, 'Download storage: 73 B');
      });
    });
  });

  testWidgets(
      'Downloads duration counts healthy completed music and updates when durations become known',
      (tester) async {
    final known = downloadedSong('measured001', 'Measured', 'Artist')
        .copyWith(lengthSeconds: 125);
    final unknown = downloadedSong('unknown0001', 'Unmeasured', 'Artist')
        .copyWith(lengthSeconds: 0);
    final excluded = [
      known.copyWith(videoId: 'pending0001', downloadComplete: false),
      known.copyWith(videoId: 'failed00001', downloadFailed: true),
      known.copyWith(videoId: 'storage0001', storageFailed: true),
      known.copyWith(videoId: 'foreign0001', profileId: 'other'),
      known.copyWith(videoId: 'video000001', audioOnly: false),
      known.copyWith(videoId: 'spoken00001', musicMetadata: null),
    ];
    final manager =
        _Downloads(DownloadManagerState(videos: [known, unknown, ...excluded]));
    await showDownloads(tester, manager);
    expect(find.text('Known duration 02:05'), findsOneWidget);
    for (final (id, failure) in [
      ('failed00001', 'Download failed'),
      ('storage0001', 'Cannot access the download folder'),
    ]) {
      final row = find.byKey(ValueKey('music-download-$id'));
      await tester.ensureVisible(row);
      expect(find.descendant(of: row, matching: find.textContaining(failure)),
          findsOneWidget);
      expect(tester.widget<ListTile>(row).onTap, isNull);
      expect(find.byKey(ValueKey('music-download-actions-$id')), findsNothing);
      expect(find.byKey(ValueKey('export-music-$id')), findsNothing);
    }
    manager.replaceVideos(
        [known, unknown.copyWith(lengthSeconds: 60), ...excluded]);
    await tester.pumpAndSettle();
    expect(find.text('Total duration 03:05'), findsOneWidget);
    manager.replaceVideos([unknown, ...excluded]);
    await tester.pumpAndSettle();
    expect(find.text('Duration unavailable'), findsOneWidget);
  });

  testWidgets(
      'Downloads Find matches Music metadata across live statuses and plays the full completed queue',
      (tester) async {
    final lead = downloadedSong('opening0001', 'Prelude', 'Lúcia');
    final ready = downloadedSong('complete001', 'First Étude', 'Lúcia');
    final queued =
        downloadedSong('queued00001', 'Second Étude', 'Lúcia', complete: false);
    final paused =
        downloadedSong('paused00001', 'Third Étude', 'Lúcia', complete: false);
    final failed =
        downloadedSong('failed00001', 'Fourth Étude', 'Lúcia', complete: false)
            .copyWith(downloadFailed: true);
    final tail = downloadedSong('ending00001', 'Last Étude', 'Hélène');
    final foreign = ready.copyWith(profileId: 'other', videoId: 'foreign0001');
    final nonMusic = ready.copyWith(videoId: 'video000001', audioOnly: false);
    final speech = ready.copyWith(videoId: 'speech00001', musicMetadata: null);
    final manager = _Downloads(DownloadManagerState(videos: [
      lead,
      ready,
      queued,
      paused,
      failed,
      tail,
      foreign,
      nonMusic,
      speech
    ], pausedVideoIds: {
      paused.videoId
    }));
    await showDownloads(tester, manager);
    await tester.tap(find.byTooltip('Search downloads'));
    await tester.pumpAndSettle();
    final query = find.byKey(const ValueKey('music-downloads-query'));
    await tester.enterText(query, 'no such song');
    await tester.pumpAndSettle();
    expect(find.text('No results found.'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear text'));
    await tester.pumpAndSettle();
    expect(find.text('Prelude'), findsOneWidget);
    await tester.enterText(query, '  LUCIA   etude  ');
    await tester.pumpAndSettle();
    Finder row(DownloadedVideo item) =>
        find.byKey(ValueKey('music-download-${item.videoId}'));
    for (final item in [ready, queued, paused, failed]) {
      expect(row(item), findsOneWidget);
    }
    for (final item in [lead, tail, foreign, nonMusic, speech]) {
      expect(row(item), findsNothing);
    }
    for (final (item, label) in [
      (queued, 'Queued'),
      (paused, 'Paused'),
      (failed, 'Download failed, tap to retry')
    ]) {
      expect(find.descendant(of: row(item), matching: find.text(label)),
          findsOneWidget);
    }
    await tester.tap(row(queued));
    expect(player.offlineCalls, 0);
    final completed = queued.copyWith(downloadComplete: true);
    manager.replaceVideos([
      tail,
      paused,
      completed,
      foreign,
      lead,
      failed,
      ready,
      nonMusic,
      speech
    ]);
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(query).controller!.text, '  LUCIA   etude  ');
    expect(find.descendant(of: row(queued), matching: find.text('Lúcia')),
        findsOneWidget);
    await tester.tap(row(completed));
    await tester.pumpAndSettle();
    expect(player.offline, [tail, completed, lead, ready]);
    expect(player.start, 1);
  });

  testWidgets(
      'Downloads Find menu re-resolves a refreshed song and ignores a removed profile occurrence',
      (tester) async {
    final first = downloadedSong('opening0001', 'Opening', 'Artist');
    final target = downloadedSong('target00001', 'Target song', 'Artist');
    final manager = _Downloads(DownloadManagerState(videos: [first, target]));
    await showDownloads(tester, manager);
    await tester.tap(find.byTooltip('Search downloads'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('music-downloads-query')), 'target');
    await tester.pumpAndSettle();
    final actions =
        find.byKey(ValueKey('music-download-actions-${target.videoId}'));
    final play = find.byKey(const ValueKey('music-song-play'));
    await tester.tap(actions);
    await tester.pumpAndSettle();
    expect(play.hitTestable(), findsOneWidget);
    final refreshed = target.copyWith(
        lengthSeconds: 117, storageUri: 'content://music/refreshed');
    final extra = downloadedSong('encore00001', 'Encore', 'Artist');
    manager.replaceVideos([refreshed, extra, first]);
    await tester.pumpAndSettle();
    await tester.tap(play);
    await tester.pumpAndSettle();
    expect(player.offline, [refreshed, extra, first]);
    expect(player.start, 0);
    await tester.tap(actions);
    await tester.pumpAndSettle();
    manager.replaceVideos([first, refreshed.copyWith(profileId: 'different')]);
    await tester.pumpAndSettle();
    await tester.tap(play);
    await tester.pumpAndSettle();
    expect(player.offlineCalls, 1);
    expect(find.text('No results found.'), findsOneWidget);
  });

  testWidgets('Downloads Find Back restores the unfiltered scroll position',
      (tester) async {
    final manager = _Downloads(DownloadManagerState(videos: [
      for (var i = 0; i < 40; i++)
        downloadedSong('song${i.toString().padLeft(7, '0')}', 'Recording $i',
            i.isEven ? 'Chorus' : 'Solo'),
    ]));
    await showDownloads(tester, manager);
    final vertical = find.byWidgetPredicate((widget) =>
        widget is Scrollable && widget.axisDirection == AxisDirection.down);
    double offset() => tester.state<ScrollableState>(vertical).position.pixels;
    await tester.drag(vertical, const Offset(0, -320));
    await tester.pumpAndSettle();
    final prior = offset();
    expect(prior, greaterThan(0));
    await tester.tap(find.byKey(const ValueKey('music-downloads-search')));
    await tester.pumpAndSettle();
    final query = find.byKey(const ValueKey('music-downloads-query'));
    await tester.enterText(query, 'chorus');
    await tester.pumpAndSettle();
    expect(offset(), 0);
    await tester.drag(vertical, const Offset(0, -180));
    await tester.pumpAndSettle();
    final resultsOffset = offset();
    expect(resultsOffset, greaterThan(0));
    await tester
        .longPress(find.textContaining('Recording ').hitTestable().first);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsNothing);
    expect(offset(), resultsOffset);
    await tester.drag(vertical, const Offset(0, 90));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(query).controller!.text, 'chorus');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(query, findsNothing);
    expect(
        tester
            .widget<ChoiceChip>(
                find.byKey(const ValueKey('music-library-tab-downloads')))
            .selected,
        isTrue);
    expect(offset(), prior);
    await tester.tap(find.byTooltip('Search downloads'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(query).controller!.text, isEmpty);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(query, findsNothing);
  });

  testWidgets(
      'Downloads selection plays only selected completed files in current manager order',
      (tester) async {
    final a = downloadedSong('studio00001', 'A', 'Studio');
    final b = downloadedSong('studio00002', 'B', 'Studio');
    final c = downloadedSong('studio00003', 'C', 'Studio');
    final queued =
        downloadedSong('studio00004', 'Waiting', 'Studio', complete: false);
    final failed =
        downloadedSong('studio00005', 'Failed', 'Studio', complete: false)
            .copyWith(downloadFailed: true);
    final paused =
        downloadedSong('studio00006', 'Paused file', 'Studio', complete: false);
    final skipped = downloadedSong('studio00007', 'Skipped', 'Studio');
    final outside = downloadedSong('concert0001', 'Concert', 'Live');
    final manager = _Downloads(DownloadManagerState(
        videos: [a, queued, b, c, failed, paused, skipped, outside],
        pausedVideoIds: {paused.videoId}));
    await showDownloads(tester, manager);
    final select = find.byKey(const ValueKey('music-downloads-select'));
    expect(select.hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('Search downloads'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('music-downloads-query')), 'studio');
    await tester.pumpAndSettle();
    expect(select.hitTestable(), findsOneWidget);
    Finder row(DownloadedVideo file) =>
        find.byKey(ValueKey('music-download-${file.videoId}'));
    await tester.longPress(row(queued));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(tester.getSemantics(find.text('Waiting')).flagsCollection.isSelected,
        isTrue);
    await tester.tap(find.byTooltip('Select all'));
    await tester.pumpAndSettle();
    expect(find.text('7 selected'), findsOneWidget);
    await tester.tap(find.byTooltip('Deselect all'));
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);
    for (final job in [c, b, queued, a]) {
      await tester.tap(row(job));
      await tester.pumpAndSettle();
    }
    expect(find.text('4 selected'), findsOneWidget);
    expect(player.offlineCalls, 0);
    await tester
        .tap(find.byKey(const ValueKey('music-playlist-selection-actions')));
    await tester.pumpAndSettle();
    for (final label in [
      'Play',
      'Shuffle',
      'Play next',
      'Add to queue',
      'Save to playlist'
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    final newC = c.copyWith(lengthSeconds: 121);
    manager
        .replaceVideos([b, skipped, newC, a, queued, failed, paused, outside]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    expect(player.offlineCalls, 0,
        reason: 'The open menu displayed a different order.');
    await tester
        .tap(find.byKey(const ValueKey('music-playlist-selection-actions')));
    await tester.pumpAndSettle();
    final refreshed = newC.copyWith(lengthSeconds: 127);
    manager.replaceVideos(
        [b, skipped, refreshed, a, queued, failed, paused, outside]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    expect(player.offline, [b, refreshed, a]);
    expect(player.start, 0);
    expect(player.online, isEmpty);
  });

  for (final next in [true, false]) {
    final action = next ? 'Play next' : 'Add to queue';
    testWidgets('Downloads selection $action pins the chosen catalog copies',
        (tester) async {
      final owned = downloadedSong('studio00001', 'Concert', 'Band').copyWith(
          accountId: 'another-account',
          storageUri: 'content://files/music/concert');
      final legacy = downloadedSong('studio00002', 'Encore', 'Band');
      final catalogCopy = Video(
          videoId: owned.videoId,
          title: 'Catalog recording',
          musicMetadata: owned.musicMetadata);
      final playback = (await tester.runAsync(() async {
        await db.upsertDownload(owned);
        await db.upsertDownload(legacy);
        return _DownloadsQueuePlayer(
            PlayerState.init([song, catalogCopy]).copyWith(
              isAudio: true,
              isHidden: false,
              currentlyPlaying: song,
              playQueue: ListQueue.of([catalogCopy.videoId]),
              position: const Duration(seconds: 7),
            ),
            settings);
      }))!;

      Finder row(DownloadedVideo file) =>
          find.byKey(ValueKey('music-download-${file.videoId}'));
      Future<void> selectFiles() async {
        await tester.longPress(row(owned));
        await tester.pumpAndSettle();
        await tester.tap(row(legacy));
        await tester.pumpAndSettle();
        await tester.tap(
            find.byKey(const ValueKey('music-playlist-selection-actions')));
        await tester.pumpAndSettle();
      }

      try {
        final manager =
            _Downloads(DownloadManagerState(videos: [legacy, owned]));
        await showDownloads(tester, manager, playback: playback);
        final before = playback.state;
        await selectFiles();
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
        expect(playback.enqueueResult, isNotNull);
        expect(await tester.runAsync(() => playback.enqueueResult!), isTrue);
        await tester.pumpAndSettle();
        expect(find.text('2 selected'), findsNothing);

        final after = playback.state;
        final copies = after.videos.where((entry) =>
            playbackQueueId(entry) != playbackQueueId(song) &&
            playbackQueueId(entry) != playbackQueueId(catalogCopy));
        expect(copies.map((entry) => entry.videoId),
            [legacy.videoId, owned.videoId]);
        expect(copies.map((entry) => entry.explicitMusicDownload), [
          musicDownloadFingerprint(legacy),
          musicDownloadFingerprint(owned)
        ]);
        expect(after.videos.map(playbackQueueId).toSet(), hasLength(4));
        expect(
            after.videos
                .singleWhere((entry) => entry == catalogCopy)
                .explicitMusicDownload,
            isNull);
        expect(
            after.playQueue,
            next
                ? [...copies.map(playbackQueueId), ...before.playQueue]
                : [...before.playQueue, ...copies.map(playbackQueueId)]);
        expect(after.currentlyPlaying, same(before.currentlyPlaying));
        expect(after.position, before.position);

        await selectFiles();
        final replacement =
            owned.copyWith(storageUri: 'content://files/music/replacement');
        await tester.runAsync(() => db.upsertDownload(replacement));
        if (next) {
          manager.replaceVideos([legacy, replacement]);
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
        expect(playback.state, same(after));
        expect(find.byType(SnackBar), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(playback.close);
      }
    });
  }

  for (final replaced in [false, true]) {
    testWidgets(
        replaced
            ? 'Downloads removal confirmation never approves a replacement file'
            : 'Downloads removal confirmation includes completed and queued selections',
        (tester) async {
      final ready = downloadedSong('studio00001', 'Recorded music', 'Studio')
          .copyWith(storageUri: 'content://music/original');
      final queued = downloadedSong('studio00002', 'Waiting music', 'Studio',
          complete: false);
      final outside = downloadedSong('other000001', 'Unselected music', 'Live');
      final manager =
          _Downloads(DownloadManagerState(videos: [ready, queued, outside]));
      await showDownloads(tester, manager);
      final select = find.byKey(const ValueKey('music-downloads-select'));
      Focus.of(tester.element(
              find.descendant(of: select, matching: find.byType(Icon))))
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('0 selected'), findsOneWidget);
      await tester.tap(find.text('Waiting music'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recorded music'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
      Future<_DeletionApproval> openConfirmation() async {
        final prior = manager.capturedApprovals.length;
        await tester.tap(
            find.byKey(const ValueKey('music-playlist-selection-actions')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete downloads'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
            find.text('Delete 2 downloads from this device?'), findsOneWidget);
        expect(manager.capturedApprovals, hasLength(prior + 1));
        final approval = manager.capturedApprovals.last;
        expect(approval.rows, [ready, queued]);
        return approval;
      }

      var approval = await openConfirmation();
      if (!replaced) {
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(manager.removalRequests, isEmpty);
        final cancelled = approval;
        approval = await openConfirmation();
        expect(approval, isNot(same(cancelled)));
      } else {
        manager.removalResult =
            1; // Only the unchanged queued job is removable.
        manager.replaceVideos([
          ready.copyWith(storageUri: 'content://music/replacement'),
          queued,
          outside
        ]);
        await tester.pumpAndSettle();
      }
      await tester.tap(find
          .descendant(
              of: find.byType(AlertDialog),
              matching: find.text('Delete downloads'))
          .last);
      await tester.pumpAndSettle();
      expect(manager.capturedApprovals, hasLength(replaced ? 1 : 2));
      expect(manager.removalRequests.single, same(approval));
      expect(player.offlineCalls, 0);
    });
  }

  testWidgets(
      'TV library renders without a download manager and hides Downloads',
      (tester) async {
    app_globals.isTv = true;
    await show(tester);
    expect(find.text('Downloads'), findsNothing);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Channels'), findsOneWidget);
    expect(find.text('Albums'), findsNothing);
  });
}
