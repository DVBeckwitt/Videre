import 'dart:async';

import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/states/playlist.dart';
import 'package:clipious/playlists/views/screens/playlist.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _Player extends Fake implements PlayerCubit {}

class _PausedBatchDownloads extends DownloadManagerCubit {
  final firstAdded = Completer<void>();
  final release = Completer<void>();

  _PausedBatchDownloads() : super(const DownloadManagerState(), _Player());

  @override
  Future<bool> addDownload(String videoId,
      {String quality = '720p', bool audioOnly = false, Video? video}) async {
    final added = await super.addDownload(videoId,
        quality: quality, audioOnly: audioOnly, video: video);
    if (added && !firstAdded.isCompleted) {
      firstAdded.complete();
      await release.future;
    }
    return added;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const song = Video(
      videoId: 'saved-song1',
      title: 'Catalog song',
      musicMetadata: MusicMetadata(
          title: 'Catalog song', artist: 'Artist', album: 'Album'));
  const ordinary = Video(videoId: 'saved-video', title: 'Ordinary video');
  const hidden = Video(videoId: 'hidden-song', filterHide: true);
  const playlist = Playlist(
      playlistId: 'local:saved',
      title: 'Mixed saved playlist',
      author: '',
      videoCount: 4,
      videos: [song, ordinary, hidden, song]);
  late DownloadManagerCubit downloads;
  late PlaylistCubit state;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    await db.upsertServer(
        const Server(url: 'https://instance.invalid', inUse: true));
    // Queue the real jobs without starting network/file transfers.
    await db.saveSetting(SettingsValue('downloads-wifi-only', 'true'));
    downloads = DownloadManagerCubit(const DownloadManagerState(), _Player());
    await downloads.addDownloads([]);
    state = PlaylistCubit(
        const PlaylistState(playlist: playlist, loading: false), _Player());
    await state.loader.ready;
  });

  tearDown(() async {
    await downloads.close();
    await state.close();
    await db.close();
  });

  testWidgets('saved playlist bulk download preserves Music metadata and mode',
      (tester) async {
    late BuildContext actionContext;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MultiBlocProvider(
        providers: [
          BlocProvider<PlaylistCubit>.value(value: state),
          BlocProvider<DownloadManagerCubit>.value(value: downloads),
        ],
        child: Scaffold(body: Builder(builder: (context) {
          actionContext = context;
          return const SizedBox.shrink();
        })),
      ),
    ));
    const screen =
        PlaylistViewScreen(playlist: playlist, canDeleteVideos: true);

    await tester.runAsync(() => screen.downloadPlaylist(actionContext));

    final queuedSong = db.getDownloadByVideoId(song.videoId)!;
    expect(queuedSong.musicMetadata?.toJson(), song.musicMetadata!.toJson());
    expect(queuedSong.title, 'Catalog song');
    expect(queuedSong.author, 'Artist');
    final queuedVideo = db.getDownloadByVideoId(ordinary.videoId)!;
    expect(queuedVideo.musicMetadata, isNull);
    expect(queuedVideo.title, 'Ordinary video');
    expect(downloads.state.videos, hasLength(2));
    expect(downloads.state.videos.every((job) => !job.audioOnly), isTrue);
    expect(
        downloads.state.videos.every((job) => job.quality == '720p'), isTrue);
    expect(db.getDownloadByVideoId(hidden.videoId), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('metadata-preserving batch stops before entering another profile',
      () async {
    await downloads.close();
    final batch = _PausedBatchDownloads();
    downloads = batch;
    await batch.addDownloads([]);
    final original = db.forProfile(db.profileId);
    final next = await db.createProfile('Another person');
    final adding = batch.addDownloads([song.videoId, ordinary.videoId],
        videosById: {song.videoId: song, ordinary.videoId: ordinary});
    await batch.firstAdded.future;
    await batch.pauseForProfileSwitch();
    await db.useProfile(next.id);
    await batch.reloadForProfile();
    batch.release.complete();

    expect(await adding, 1);
    expect(original.getDownloadByVideoId(song.videoId)?.musicMetadata?.album,
        'Album');
    expect(original.getDownloadByVideoId(ordinary.videoId), isNull);
    expect(db.getAllDownloads(), isEmpty);
  });
}
