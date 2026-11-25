import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/download_playback_provenance.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/views/components/music_status_title.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';

class _App extends TestAppCubit {
  _App() : super(AppState(0, _server, HomeLayout())) {
    intentDataStreamSubscription = const Stream<void>.empty().listen((_) {});
  }

  void changeOwner(Server server) => emit(state.copyWith(
      profileId: server.profileId,
      server: server,
      sessionRevision: state.sessionRevision + 1));
}

class _Downloads extends Cubit<DownloadManagerState>
    implements DownloadManagerCubit {
  _Downloads() : super(const DownloadManagerState());

  void replace(DownloadedVideo file) => emit(state.copyWith(videos: [file]));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _server = Server(url: 'https://example.test', id: 'first', inUse: true);
const _song = Video(videoId: 'exact-song', title: 'One song');
const _music = MusicMetadata(title: 'One song', artist: 'An artist');
const _folder = 'content://documents/tree/primary%3AMusic';
const _uri = '$_folder/document/primary%3AMusic%2Fone.webm';
final _sha = 'a' * 64;
final _identity = 'b' * 64;

DownloadedVideo _download({String uri = _uri}) {
  final audio = AdaptiveFormat(
      null,
      '128000',
      null,
      '${_server.url}/videoplayback?itag=251',
      '251',
      'audio/webm; codecs="opus"',
      '12345',
      '1700000000000',
      'RECTANGULAR',
      'webm',
      'opus',
      null,
      null);
  return DownloadedVideo(
    videoId: _song.videoId,
    title: _music.title,
    musicMetadata: _music,
    accountId: _server.accountId,
    audioOnly: true,
    downloadComplete: true,
    container: DownloadContainer.webm,
    folderUri: _folder,
    storageUri: uri,
    playbackProvenance: DownloadPlaybackProvenance.create(
      video: _song.copyWith(adaptiveFormats: [audio]),
      server: _server,
      audioOnly: true,
      container: DownloadContainer.webm,
      audio: audio,
      byteLength: 50,
      sha256: _sha,
    )!,
    lengthSeconds: 20,
    quality: 'audio',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final android = TargetPlatformVariant.only(TargetPlatform.android);
  const channel = MethodChannel('videre/download_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final saved = find.byTooltip('Saved');
  final offline = find.byTooltip('Playable offline');
  final approved = {
    _song.videoId: {'identity': _identity, 'byteLength': 50},
  };
  late SembastSqfDb database;
  late _App app;
  late _Downloads manager;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    await database.upsertServer(_server);
    db = database;
    app = _App();
    manager = _Downloads();
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await app.close();
    await manager.close();
    await database.close();
  });

  Future<void> show(WidgetTester tester, Widget title) =>
      tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<AppCubit>.value(value: app),
          BlocProvider<DownloadManagerCubit>.value(value: manager),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ListTile(title: title)),
        ),
      ));

  Future<void> replace(WidgetTester tester, DownloadedVideo file) async {
    await tester.runAsync(() => database.upsertDownload(file));
    manager.replace(file);
    await tester.pumpAndSettle();
  }

  testWidgets('saved status follows exact bookmark and profile',
      (tester) async {
    final library = MusicLibraryService.forProfile(database, _server.profileId);
    await show(tester,
        MusicStatusTitle.song(video: _song, child: const Text('One song')));
    expect(saved, findsNothing);
    Future<void> save(String id) => library.save(MusicLibraryEntry(
          kind: MusicLibraryKind.song,
          id: id,
          title: _music.title,
          subtitle: _music.artist,
        ));

    await tester.runAsync(() => save('different-song'));
    await tester.pumpAndSettle();
    expect(saved, findsNothing);
    await tester.runAsync(() => save(_song.videoId));
    await tester.pumpAndSettle();
    expect(saved, findsOneWidget);
    expect(offline, findsNothing);
    await tester
        .runAsync(() => library.remove(MusicLibraryKind.song, _song.videoId));
    await tester.pumpAndSettle();
    expect(saved, findsNothing);

    await tester.runAsync(() => save(_song.videoId));
    await tester.pumpAndSettle();
    final other = await tester.runAsync(() async {
      final person = await database.createProfile('Another person');
      await database.useProfile(person.id);
      return _server.copyWith(profileId: person.id);
    });
    app.changeOwner(other!);
    await tester.pumpAndSettle();
    expect(saved, findsNothing);
  });

  testWidgets('catalog status requires checksum, the active account and grant',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var available = true;
    var probes = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'probeMusicFiles');
      final args = call.arguments as Map;
      expect(args['profileId'], _server.profileId);
      expect((args['files'] as List).single, {
        'key': _song.videoId,
        'videoId': _song.videoId,
        'uri': _uri,
        'folderUri': _folder,
        'expectedSha256': _sha,
      });
      probes++;
      return available ? approved : <String, Object>{};
    });

    await show(tester,
        MusicStatusTitle.song(video: _song, child: const Text('One song')));
    final file = _download();
    await replace(tester, file.copyWith(authenticationRequired: true));
    await replace(tester, file.copyWith(playbackProvenance: null));
    await replace(tester, file.copyWith(accountId: 'second'));
    expect(probes, 0);
    expect(offline, findsNothing);

    await replace(tester, file);
    expect(offline, findsOneWidget);
    expect(saved, findsNothing);

    available = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(probes, 2);
    expect(offline, findsNothing);
  }, variant: android);

  testWidgets('explicit status rejects stale and mismatched file proofs',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final held = Completer<Map<String, Object>>();
    var probes = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      probes++;
      return probes == 1 ? held.future : approved;
    });
    final file = _download();
    await replace(tester, file);
    await show(
        tester,
        MusicStatusTitle.download(
            file: file, fileProof: _identity, child: const Text('One song')));
    await tester.pumpAndSettle();
    expect(probes, 1);
    expect(offline, findsNothing);

    final replacement = _download(uri: '$_uri.replacement');
    await replace(tester, replacement);
    held.complete(approved);
    await tester.pumpAndSettle();
    expect(offline, findsNothing);

    await show(
        tester,
        MusicStatusTitle.download(
            file: replacement,
            fileProof: 'c' * 64,
            child: const Text('One song')));
    await tester.pumpAndSettle();
    expect(offline, findsNothing);

    await show(
        tester,
        MusicStatusTitle.download(
            file: replacement,
            fileProof: _identity,
            child: const Text('One song')));
    await tester.pumpAndSettle();
    expect(offline, findsOneWidget);
  }, variant: android);
}
