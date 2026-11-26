import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/download_storage.dart';
import 'package:clipious/downloads/services/explicit_music_download.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/views/screens/music_offline.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

const _firstAccount = Server(url: 'https://example.test', id: 'first');
const _secondAccount = Server(url: 'https://example.test', id: 'second');
const _cache = MethodChannel('videre/proxy');

class _App extends AppCubit {
  _App() : super(AppState(0, _firstAccount, HomeLayout())) {
    intentDataStreamSubscription = const Stream.empty().listen((_) {});
  }

  @override
  void onReady() {}

  @override
  void initState() {}

  void select(Server? server) => emit(state.copyWith(
        server: server,
        sessionRevision: state.sessionRevision + 1,
      ));
}

class _Storage extends DownloadStorage {
  final proofs = <String, String>{};

  @override
  Future<List<MusicFileProbe>> probeMusicFiles(
          String profileId, Iterable<DownloadedVideo> downloads) async =>
      [
        for (final file in downloads)
          if (proofs[file.videoId] case final proof?)
            (
              download: file,
              uri: 'file:///tmp/\${file.videoId}.flac',
              identity: proof,
              byteLength: 93,
            ),
      ];
}

class _Downloads extends Cubit<DownloadManagerState>
    implements DownloadManagerCubit {
  _Downloads() : super(const DownloadManagerState());

  @override
  final _Storage storage = _Storage();

  void show(List<DownloadedVideo> files) => emit(state.copyWith(videos: files));

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

DownloadedVideo _download(String id, String title) => DownloadedVideo(
      videoId: id,
      title: title,
      lengthSeconds: 20,
      quality: 'audio',
      musicMetadata: MusicMetadata(title: title, artist: 'Artist'),
      audioOnly: true,
      downloadComplete: true,
    );

Map<String, Object> _song(String id, String title) => {
      'videoId': id,
      'title': title,
      'artist': 'Artist',
      'lengthSeconds': 93,
      'rendition': 'a' * 64,
    };

void main() {
  late _App app;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = _App();
  });

  tearDown(() async {
    await app.close();
    await db.close();
  });

  testWidgets('download selection uses file proofs and clears on source change',
      (tester) async {
    final downloads = _Downloads();
    addTearDown(downloads.close);
    final first = _download('firstSong', 'First download');
    final middle = _download('middleSong', 'Untouched download');
    final last = _download('lastSong', 'Last download');
    final firstProof = 'a' * 64;
    downloads.storage.proofs
      ..[first.videoId] = firstProof
      ..[middle.videoId] = 'b' * 64
      ..[last.videoId] = 'c' * 64;
    downloads.show([first, middle, last]);
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<DownloadManagerCubit>.value(value: downloads),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: OfflineMusicPage(),
      ),
    ));
    await tester.pumpAndSettle();

    Finder tile(DownloadedVideo download, String proof) =>
        find.byKey(ValueKey(musicDownloadFileFingerprint(download, proof)!));
    await tester.longPress(tile(first, firstProof));
    await tester.pumpAndSettle();
    await tester.tap(tile(last, 'c' * 64));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    expect(tester.widget<ListTile>(tile(middle, 'b' * 64)).selected, isFalse);

    final replacement = first.copyWith(title: 'Replaced file');
    final secondProof = 'd' * 64;
    downloads.storage.proofs[first.videoId] = secondProof;
    downloads.show([replacement, middle, last]);
    await tester.pumpAndSettle();
    expect(tile(first, firstProof), findsNothing);
    expect(tester.widget<ListTile>(tile(replacement, secondProof)).selected,
        isFalse);
    expect(find.text('1 selected'), findsOneWidget);

    app.select(_secondAccount);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsNothing);
    expect(tester.widget<ListTile>(tile(last, 'c' * 64)).selected, isFalse);
  });

  testWidgets('Offline Music shows cached songs for the current account',
      (tester) async {
    final previous = Completer<List<Map<String, Object>>>();
    final accounts = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_cache, (call) async {
      expect(call.method, 'cachedMusicSongs');
      expect(call.arguments['profileId'], 'default');
      final account = call.arguments['accountId'] as String;
      accounts.add(account);
      return account == _firstAccount.accountId
          ? await previous.future
          : [_song('current', 'Current cached song')];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_cache, null));

    await tester.pumpWidget(BlocProvider<AppCubit>.value(
      value: app,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: OfflineMusicPage(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('No playable songs in this collection.'), findsOneWidget);
    expect(accounts, isEmpty);

    await tester.tap(find.text('Cached songs'));
    await tester.pump();
    expect(accounts, ['first']);
    app.select(_secondAccount);
    await tester.pumpAndSettle();
    previous.complete([_song('previous', 'Previous cached song')]);
    await tester.pumpAndSettle();
    expect(accounts, ['first', 'second']);
    expect(find.text('Current cached song'), findsOneWidget);
    expect(find.text('Previous cached song'), findsNothing);

    app.select(null);
    await tester.pumpAndSettle();
    expect(find.text('Playback cache is unavailable on this device.'),
        findsOneWidget);
    expect(find.text('Current cached song'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
