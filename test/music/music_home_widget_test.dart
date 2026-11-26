import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_home_widget.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

class _WidgetPlayer extends TestPlayerCubit {
  _WidgetPlayer(super.initialState, super.settings);

  void showDownload(DownloadedVideo download) {
    emit(PlayerState.init(null).copyWith(
        offlineCurrentlyPlaying: download,
        offlineVideos: [download],
        isAudio: true,
        isHidden: false));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('videre/music_home_widget');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<Map<Object?, Object?>?> snapshots;
  late List<MusicHomeWidgetAction> actions;
  late List<Completer<String?>> artworkRequests;
  late MusicHomeWidgetPlayback? playback;
  late MusicHomeWidgetShuffle shuffle;

  MusicHomeWidgetShuffle queue({
    bool enabled = true,
    bool selected = false,
    int generation = 1,
    int sessionRevision = 1,
  }) =>
      (
        enabled: enabled,
        selected: selected,
        generation: generation,
        selectionRevision: 1,
        sessionRevision: sessionRevision,
      );
  MusicHomeWidget? widget;

  MusicHomeWidgetPlayback song(String profile, String id, int generation,
      {MusicHomeWidgetStatus status = MusicHomeWidgetStatus.playing,
      bool canNext = true,
      bool canSave = true,
      bool? liked,
      String? deviceArtworkPath}) {
    return (
      owner: (profile, id, generation),
      title: 'Song $id',
      artist: 'Artist',
      status: status,
      canPrevious: true,
      canNext: canNext,
      canSave: canSave,
      liked: liked,
      deviceArtworkPath: deviceArtworkPath,
    );
  }

  Future<bool> tap(Object? token, String action) async {
    final reply = Completer<bool>();
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(
          MethodCall('transport', {'token': token, 'action': action})),
      (data) => reply.complete(channel.codec.decodeEnvelope(data!) as bool),
    );
    return reply.future;
  }

  setUp(() {
    snapshots = [];
    actions = [];
    artworkRequests = [];
    playback = null;
    shuffle = queue();
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'setPlayback');
      snapshots.add(call.arguments as Map<Object?, Object?>?);
      return null;
    });
    widget = null;
  });

  MusicHomeWidget startWidget() => widget = MusicHomeWidget(
        readPlayback: () => playback,
        resolveArtwork: (_) {
          final request = Completer<String?>();
          artworkRequests.add(request);
          return request.future;
        },
        onAction: (action) {
          actions.add(action);
          if (action == MusicHomeWidgetAction.shuffle) {
            shuffle = queue(selected: !shuffle.selected);
            widget?.refresh();
          }
        },
        readShuffle: () => shuffle,
        updates: const [],
      );

  tearDown(() async {
    await widget?.close();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('withdraws playback and rejects delayed clicks across profile changes',
      () async {
    final widget = startWidget();
    playback = song('first profile', 'same song', 1, liked: false);
    widget.refresh();
    final old = snapshots.single!;
    expect(old.values, isNot(contains('first profile')));
    expect(await tap(old['token'], 'next'), isTrue);

    playback = null;
    expect(await tap(old['token'], 'next'), isFalse);
    expect(await tap(old['likeToken'], 'like'), isFalse);
    widget.refresh();
    expect(snapshots.last, isNull);

    playback = song('second profile', 'same song', 1, liked: false);
    expect(await tap(old['likeToken'], 'like'), isFalse);
    widget.refresh();
    final current = snapshots.last!;
    expect(current['token'], isNot(old['token']));
    expect(await tap(old['token'], 'save'), isFalse);
    expect(await tap(old['likeToken'], 'like'), isFalse);
    expect(await tap(current['token'], 'save'), isTrue);
    expect(actions, [MusicHomeWidgetAction.next, MusicHomeWidgetAction.save]);
  });

  test(
      'shuffle shows the live mode and rejects an earlier tap after each change',
      () async {
    final widget = startWidget();
    playback = song('profile', 'first song', 1);
    widget.refresh();
    final off = snapshots.last!;
    final first = off['shuffleToken'];
    expect(off['shuffleSelected'], false);
    expect(first, isNotNull);
    expect(await tap(off['token'], 'shuffle'), isFalse);
    expect(await tap(first, 'shuffle'), isTrue);
    final on = snapshots.last!;
    expect(on['shuffleSelected'], true);
    expect(on['token'], off['token']);
    expect(await tap(first, 'shuffle'), isFalse);
    expect(await tap(on['shuffleToken'], 'shuffle'), isTrue);
    expect(snapshots.last!['shuffleSelected'], false);
    expect(snapshots.last!['shuffleToken'], isNot(first));
    expect(await tap(first, 'shuffle'), isFalse);
    expect(actions,
        [MusicHomeWidgetAction.shuffle, MusicHomeWidgetAction.shuffle]);
  });

  test('shuffle rejects a live lock and changes of queue or profile session',
      () async {
    final widget = startWidget();
    playback = song('profile', 'same song', 1);
    shuffle = queue(selected: true);
    widget.refresh();
    final unlocked = snapshots.last!['shuffleToken'];
    shuffle = queue(enabled: false, selected: true);
    expect(await tap(unlocked, 'shuffle'), isFalse);
    widget.refresh();
    expect(snapshots.last!['shuffleToken'], isNull);
    expect(snapshots.last!['shuffleSelected'], true);
    shuffle = queue(selected: true);
    widget.refresh();
    expect(snapshots.last!['shuffleToken'], isNot(unlocked));
    final beforeReplacement = snapshots.last!['shuffleToken'];
    shuffle = queue(generation: 2, selected: true);
    expect(await tap(beforeReplacement, 'shuffle'), isFalse);
    widget.refresh();
    final beforeSession = snapshots.last!['shuffleToken'];
    shuffle = queue(generation: 2, sessionRevision: 2, selected: true);
    expect(await tap(beforeSession, 'shuffle'), isFalse);
    playback = song('other profile', 'same song', 1);
    expect(await tap(beforeSession, 'shuffle'), isFalse);
    expect(actions, isEmpty);
  });

  test('publishes play state and checks live transport availability', () async {
    final widget = startWidget();
    playback = song('profile', 'first song', 1);
    widget.refresh();
    widget.refresh();
    final loaded = snapshots.single!;
    final token = loaded['token'];
    expect(loaded['playAction'], 'pause');
    expect(await tap(token, 'pause'), isTrue);

    playback = song('profile', 'first song', 1,
        status: MusicHomeWidgetStatus.paused, canNext: false, canSave: false);
    expect(await tap(token, 'pause'), isFalse);
    expect(await tap(token, 'next'), isFalse);
    expect(await tap(token, 'save'), isFalse);
    widget.refresh();
    expect(snapshots.last!['playAction'], 'play');
    expect(snapshots.last!['token'], token);
    expect(await tap(token, 'play'), isTrue);

    playback = song('profile', 'another song', 2);
    expect(await tap(token, 'previous'), isFalse);
    widget.refresh();
    expect(snapshots.last!['title'], 'Song another song');
    expect(actions, [MusicHomeWidgetAction.pause, MusicHomeWidgetAction.play]);
  });

  test(
      'Like refresh preserves transport and rejects stale states and occurrences',
      () async {
    final widget = startWidget();
    playback = song('profile', 'device song', 1, canSave: false, liked: false);
    widget.refresh();
    final token = snapshots.single!['token'];
    final likeToken = snapshots.single!['likeToken'];
    expect(snapshots.single!['liked'], isFalse);
    expect(likeToken, isA<String>());
    expect(await tap(token, 'save'), isFalse);
    expect(await tap(token, 'like'), isFalse);
    expect(await tap(likeToken, 'unlike'), isFalse);
    expect(await tap(likeToken, 'like'), isTrue);

    playback = song('profile', 'device song', 1, canSave: false, liked: true);
    expect(await tap(likeToken, 'like'), isFalse);
    widget.refresh();
    expect(snapshots.last!['token'], token);
    expect(snapshots.last!['liked'], isTrue);
    final unlikeToken = snapshots.last!['likeToken'];
    expect(unlikeToken, isNot(likeToken));
    expect(await tap(unlikeToken, 'unlike'), isTrue);

    playback = song('profile', 'device song', 1, canSave: false, liked: false);
    widget.refresh();
    final refreshedLikeToken = snapshots.last!['likeToken'];
    expect(refreshedLikeToken, isNot(likeToken));
    expect(await tap(likeToken, 'like'), isFalse);

    playback = song('profile', 'device song', 2, canSave: false, liked: false);
    expect(await tap(refreshedLikeToken, 'like'), isFalse);
    widget.refresh();
    expect(snapshots.last!['token'], isNot(token));
    expect(await tap(refreshedLikeToken, 'like'), isFalse);

    playback = song('profile', 'device song', 2, canSave: false);
    widget.refresh();
    expect(snapshots.last!['liked'], isNull);
    expect(snapshots.last!['likeToken'], isNull);
    expect(await tap(snapshots.last!['token'], 'like'), isFalse);
    expect(actions, [MusicHomeWidgetAction.like, MusicHomeWidgetAction.unlike]);
  });

  test('player shares download Likes with the current profile library',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final database = await SembastSqfDb.createInMemory();
    db = database;
    addTearDown(database.close);
    final app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    addTearDown(app.close);
    final settings = TestSettingsCubit(SettingsState.init(), app);
    addTearDown(settings.close);
    final player = _WidgetPlayer(PlayerState.init(null), settings);
    addTearDown(player.close);
    final library =
        MusicLibraryService.forProfile(database, database.profileId);
    final other = await database.createProfile('Other listener');
    final otherLibrary = MusicLibraryService.forProfile(database, other.id);
    const download = DownloadedVideo(
        videoId: 'abcdefghijk',
        queueEntryId: 'abcdefghijk#2',
        title: 'Downloaded song',
        lengthSeconds: 180,
        quality: 'audio',
        musicMetadata:
            MusicMetadata(title: 'Downloaded song', artist: 'Artist'));
    const song = MusicLibraryEntry(
        kind: MusicLibraryKind.song,
        id: 'abcdefghijk',
        title: 'Downloaded song');

    player.showDownload(download);
    await Future<void>.value();
    expect(snapshots.last!['liked'], isFalse);
    final token = snapshots.last!['token'];
    await library.setSongLiked(song, liked: true);
    expect(snapshots.last!['liked'], isTrue);
    expect(snapshots.last!['token'], token);
    final unlikeToken = snapshots.last!['likeToken'];

    final unliked = Completer<void>();
    void onChange() => unliked.complete();
    library.changes.addListener(onChange);
    try {
      expect(await tap(unlikeToken, 'unlike'), isTrue);
      await unliked.future.timeout(const Duration(seconds: 5));
    } finally {
      library.changes.removeListener(onChange);
    }
    expect(library.isLiked(download.videoId), isFalse);
    expect(library.entries, isEmpty);
    expect(snapshots.last!['liked'], isFalse);
    final oldLikeToken = snapshots.last!['likeToken'];

    await player.prepareForProfileSwitch();
    await database.useProfile(other.id);
    await player.reloadForProfile();
    player.showDownload(download.copyWith(profileId: other.id));
    await Future<void>.value();
    final otherToken = snapshots.last!['token'];
    expect(otherToken, isNot(token));
    expect(await tap(oldLikeToken, 'like'), isFalse);
    await library.setSongLiked(song, liked: true);
    expect(snapshots.last!['liked'], isFalse);
    await otherLibrary.setSongLiked(song, liked: true);
    expect(snapshots.last!['liked'], isTrue);
    expect(snapshots.last!['token'], otherToken);
  });

  test(
      'shows fallback immediately and discards artwork from the previous track',
      () async {
    final widget = startWidget();
    playback = song('profile', 'first song', 1);
    widget.refresh();
    expect(snapshots.single!['artworkPath'], isNull);

    playback = song('profile', 'second song', 2);
    widget.refresh();
    expect(snapshots.last!['artworkPath'], isNull);
    final token = snapshots.last!['token'];

    playback =
        song('profile', 'second song', 2, status: MusicHomeWidgetStatus.paused);
    widget.refresh();
    expect(artworkRequests, hasLength(2));
    final snapshotCount = snapshots.length;
    artworkRequests.first.complete('/artwork/first');
    await Future<void>.delayed(Duration.zero);
    expect(snapshots, hasLength(snapshotCount));

    artworkRequests.last.complete('/artwork/second');
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.last, containsPair('artworkPath', '/artwork/second'));
    expect(snapshots.last, containsPair('status', 'paused'));
    expect(snapshots.last, containsPair('token', token));

    playback = song('profile', 'no cover', 3);
    widget.refresh();
    expect(snapshots.last!['artworkPath'], isNull);
    artworkRequests.last.complete(null);
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.last!['artworkPath'], isNull);
  });

  test('drops late artwork as soon as the live profile changes', () async {
    final widget = startWidget();
    playback = song('first profile', 'shared song', 1);
    widget.refresh();
    final oldToken = snapshots.single!['token'];

    playback = song('second profile', 'shared song', 1);
    artworkRequests.first.complete('/artwork/old-profile');
    await Future<void>.delayed(Duration.zero);
    expect(snapshots, hasLength(1));

    widget.refresh();
    expect(snapshots.last!['token'], isNot(oldToken));
    expect(snapshots.last!['artworkPath'], isNull);

    await widget.close();
    final closedCount = snapshots.length;
    artworkRequests.last.complete('/artwork/after-close');
    await Future<void>.delayed(Duration.zero);
    expect(snapshots, hasLength(closedCount));
    expect(snapshots.last, isNull);
  });

  test('updates a repaired device cover while preserving the transport token',
      () async {
    final widget = startWidget();
    playback = song('profile', 'device song', 1);
    widget.refresh();
    final token = snapshots.last!['token'];
    artworkRequests.single.complete(null);
    await Future<void>.delayed(Duration.zero);

    const path = '/artwork/repaired-device-cover';
    playback = song('profile', 'device song', 1, deviceArtworkPath: path);
    widget.refresh();
    expect(artworkRequests, hasLength(2));
    artworkRequests.last.complete(path);
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.last, containsPair('artworkPath', path));
    expect(snapshots.last, containsPair('token', token));
    expect(await tap(token, 'next'), isTrue);
  });
}
