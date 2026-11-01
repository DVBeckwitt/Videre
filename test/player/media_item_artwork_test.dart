import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_player_cubit.dart';
import '../test_settings_cubit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestAppCubit app;
  late TestSettingsCubit settings;
  TestPlayerCubit? player;
  const selectedServer = Server(
      url: 'https://selected.example',
      customHeaders: {'X-Instance-Access': 'selected-access'});

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    await db.upsertServer(selectedServer);
    await db.useServer(selectedServer);
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    await app.initState();
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
  });

  tearDown(() async {
    await player?.close();
    player = null;
    await settings.close();
    await app.close();
    await db.close();
  });

  Video video(String thumbnail, {Server? server}) => Video(
      videoId: 'artwork-video',
      title: 'Artwork video',
      author: 'Channel',
      lengthSeconds: 42,
      videoThumbnails: [ImageObject('default', thumbnail, 320, 180)],
      backendPlayback: server == null ? null : BackendPlayback(server));

  TestPlayerCubit createPlayer(Video queued, {Video? playing}) {
    return player = TestPlayerCubit(
        PlayerState.init([queued]).copyWith(currentlyPlaying: playing),
        settings);
  }

  test('notification artwork uses the selected instance and its headers',
      () async {
    final controller =
        createPlayer(video('https://i.ytimg.com/vi/artwork-video/default.jpg'));

    final item = (await controller.getMediaItem(0))!;

    expect(item.artUri,
        Uri.parse('https://selected.example/vi/artwork-video/default.jpg'));
    expect(item.artHeaders, selectedServer.customHeaders);
    expect(item.id, 'artwork-video');
    expect(item.title, 'Artwork video');
    expect(item.artist, 'Channel');
    expect(item.duration, const Duration(seconds: 42));
  });

  test('queued artwork preserves the metadata server snapshot', () async {
    const metadataServer = Server(
        url: 'https://metadata.example',
        customHeaders: {'Cookie': 'backend=original'});
    final controller = createPlayer(
        video('https://yt3.ggpht.com/avatar=s88', server: metadataServer));

    final item = (await controller.getMediaItem(0))!;

    expect(item.artUri, Uri.parse('https://metadata.example/ggpht/avatar=s88'));
    expect(item.artHeaders, metadataServer.customHeaders);
  });

  test('active artwork uses the recovered backend headers', () async {
    const queuedServer = Server(
        url: 'https://selected.example',
        customHeaders: {'Cookie': 'backend=original'});
    const recoveredServer = Server(
        url: 'https://selected.example',
        customHeaders: {'Cookie': 'backend=recovered'});
    final controller = createPlayer(
        video('/vi/artwork-video/default.jpg', server: queuedServer),
        playing:
            video('/vi/artwork-video/default.jpg', server: recoveredServer));

    final item = (await controller.getMediaItem(0))!;

    expect(item.artUri,
        Uri.parse('https://selected.example/vi/artwork-video/default.jpg'));
    expect(item.artHeaders, recoveredServer.customHeaders);
  });

  test('unrelated external artwork never receives instance headers', () async {
    const imageUrl = 'https://cdn.example/artwork.jpg';
    final controller = createPlayer(video(imageUrl));

    final item = (await controller.getMediaItem(0))!;

    expect(item.artUri, Uri.parse(imageUrl));
    expect(item.artHeaders, isNull);
  });

  test('missing artwork does not become an empty network request', () async {
    final controller = createPlayer(const Video(videoId: 'without-artwork'));

    final item = (await controller.getMediaItem(0))!;

    expect(item.artUri, isNull);
    expect(item.artHeaders, isNull);
  });

  test('malformed artwork does not prevent notification metadata', () async {
    final controller = createPlayer(video('https://[invalid'));

    final item = (await controller.getMediaItem(0))!;

    expect(item.id, 'artwork-video');
    expect(item.artUri, isNull);
    expect(item.artHeaders, isNull);
  });
}
