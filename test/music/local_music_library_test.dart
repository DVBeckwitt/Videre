import 'dart:async';
import 'dart:convert';

import 'package:clipious/music/models/device_playlist_track.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
  const codec = StandardMethodCodec();
  const tree = 'content://documents/tree/primary%3AMusic';
  const secondTree = 'content://documents/tree/1234%3AAlbums';
  const folder = {'uri': tree, 'name': 'Music'};
  const secondFolder = {
    'uri': secondTree,
    'name': 'Albums',
    'selectionId': 'albums-grant',
  };
  const uri = '$tree/document/primary%3AMusic%2Ftrack.flac';
  const secondUri = '$secondTree/document/1234%3AAlbums%2Ftrack.flac';
  const doc = {
    'uri': uri,
    'title': 'Title',
    'artist': 'Artist',
    'album': 'Album',
    'durationMs': 12345,
    'artPath': '/data/cache/art.jpg',
    'adjacentArtPath': '/data/cache/adjacent.jpg',
  };
  Map<String, Object> selection(List<Map<String, String>> roots) => {
        'roots': roots,
        'selectionId': 'library-session',
      };
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late LocalMusicLibrary library;
  late List<String> calls;
  Map<String, String>? saved;
  Map<String, String>? choice;
  late Future<Object?> Function() scan;
  late Future<bool?> Function() checkAccess;
  Future<void> Function()? pickerWait;
  int? scanId;
  int? watchId;
  int? cancelledScanId;
  bool forceScan = false;
  bool savedAutomaticScan = false;
  Object? renamed;
  bool denySystem = false;
  Future<void> emitBatch(List<Object?> documents, {int? id}) async {
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall('trackBatch', {
        'scanId': id ?? scanId,
        'tracks': documents,
      })),
      null,
    );
  }

  Future<void> emitChange(int id) async {
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
          MethodCall('libraryChanged', {'watchId': id, 'treeUri': tree})),
      null,
    );
  }

  setUp(() {
    library = LocalMusicLibrary();
    calls = [];
    saved = null;
    choice = null;
    pickerWait = null;
    scanId = null;
    watchId = null;
    cancelledScanId = null;
    forceScan = false;
    savedAutomaticScan = false;
    renamed = null;
    denySystem = false;
    scan = () async => [doc];
    checkAccess = () async => true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'getFolder':
          if (call.arguments?['includeScanPreference'] == true) {
            return {'folder': saved, 'automaticScan': savedAutomaticScan};
          }
          return saved;
        case 'pickFolder' || 'pickSystem':
          if (call.method == 'pickSystem' && denySystem) {
            throw PlatformException(code: 'AUDIO_PERMISSION_DENIED');
          }
          await pickerWait?.call();
          if (choice != null) saved = choice;
          return choice;
        case 'listTracks':
          expect(call.arguments['treeUri'], saved?['uri']);
          scanId = call.arguments['scanId'] as int?;
          forceScan = call.arguments['force'] == true;
          return scan();
        case 'cancelScan':
          cancelledScanId = call.arguments['scanId'] as int?;
          return null;
        case 'setAutomaticScan':
          savedAutomaticScan = call.arguments['enabled'] as bool;
          return null;
        case 'watchLibrary':
          watchId = call.arguments['watchId'] as int?;
          return null;
        case 'renameTrack':
          expect(call.arguments['treeUri'], saved?['uri']);
          return renamed;
        case 'checkFolderAccess':
          expect(call.arguments['treeUri'], saved?['uri']);
          return checkAccess();
        case 'forgetFolder':
          expect(call.arguments['treeUri'], saved?['uri']);
          saved = null;
          return null;
      }
      throw MissingPluginException();
    });
  });
  tearDown(() {
    library.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('forced refresh rereads tags and retains a partial result', () async {
    saved = folder;
    await library.refresh();
    expect(forceScan, isFalse);
    final original = library.tracks.single;

    scan = () async => {
          'tracks': [
            {...doc, 'title': 'Retagged'},
          ],
          'partial': true,
        };
    await library.refresh(force: true);
    expect(forceScan, isTrue);
    expect(library.loaded, isTrue);
    expect(library.error, 'SCAN_PARTIAL');
    expect(library.tracks.single.title, 'Retagged');
    expect(library.tracks.single.playbackId, original.playbackId);

    scan = () async => {
          'tracks': [doc],
          'partial': false
        };
    await library.refresh();
    expect(forceScan, isFalse);
    expect(library.error, isNull);
  });

  test('cancel restores the previous catalog and ignores late batches',
      () async {
    saved = folder;
    await library.refresh();
    final completed = Completer<Object?>();
    final started = Completer<void>();
    scan = () {
      started.complete();
      return completed.future;
    };
    final refresh = library.refresh();
    await started.future;
    await emitBatch([
      {...doc, 'title': 'Provisional'},
    ]);
    expect(library.tracks.single.title, 'Provisional');
    expect(library.canCancelScan, isTrue);

    await library.cancelScan();
    expect(cancelledScanId, scanId);
    expect(library.canCancelScan, isFalse);
    await emitBatch([
      {...doc, 'title': 'Late'},
    ]);
    expect(library.tracks.single.title, 'Provisional');
    completed.complete([
      {...doc, 'title': 'Ignored'},
    ]);
    await refresh;
    expect(library.tracks.single.title, 'Title');
    expect(library.scanning, isFalse);
    expect(library.error, isNull);
  });

  test('revocation supersedes cancellation and clears playable membership',
      () async {
    saved = folder;
    await library.refresh();
    final playbackId = library.tracks.single.playbackId;
    final completed = Completer<Object?>();
    final started = Completer<void>();
    scan = () {
      started.complete();
      return completed.future;
    };
    final refresh = library.refresh(force: true);
    await started.future;
    await library.cancelScan();
    checkAccess = () async => false;
    await library.revalidate();
    completed.complete([doc]);
    await refresh;
    expect(library.unavailable, isTrue);
    expect(library.error, 'FOLDER_UNAVAILABLE');
    expect(library.trackById(playbackId), isNull);
    expect(library.acceptsSessionSelection(null), isFalse);
  });

  testWidgets('automatic scanning follows changes and foreground access',
      (tester) async {
    saved = folder;
    await library.initialize();
    expect(library.automaticScan, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(calls, isNot(contains('listTracks')));

    expect(await library.setAutomaticScan(true), isTrue);
    final foregroundWatch = watchId!;
    expect(savedAutomaticScan, isTrue);
    await emitChange(foregroundWatch);
    await emitChange(foregroundWatch);
    await tester.pump(const Duration(seconds: 1));
    expect(calls.where((call) => call == 'listTracks'), hasLength(1));
    expect(forceScan, isFalse);

    library.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(watchId, isNull);
    await emitChange(foregroundWatch);
    await tester.pump(const Duration(seconds: 2));
    expect(calls.where((call) => call == 'listTracks'), hasLength(1));

    library.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(watchId, isNot(foregroundWatch));
    await tester.pump(const Duration(seconds: 1));
    expect(calls.where((call) => call == 'listTracks'), hasLength(2));

    expect(await library.setAutomaticScan(false), isTrue);
    expect(savedAutomaticScan, isFalse);
    expect(watchId, isNull);
    checkAccess = () async => false;
    library.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 1));
    expect(library.unavailable, isTrue);
    expect(calls.where((call) => call == 'listTracks'), hasLength(2));
  });

  test('device ReplayGain is optional and filters invalid numeric values', () {
    final source = Uri.parse(tree);
    final legacy = LocalMusicTrack.fromDocument(doc, source)!;
    final tagged = LocalMusicTrack.fromDocument({
      ...doc,
      'replayGain': {
        'trackGainDb': -7.25,
        'albumGainDb': double.nan,
        'trackPeak': 0.825,
        'albumPeak': 0,
      },
    }, source)!;

    expect(legacy.replayGain, isNull);
    expect(tagged.playbackId, legacy.playbackId);
    expect(tagged.replayGain?.trackGainDb, -7.25);
    expect(tagged.replayGain?.trackPeak, 0.825);
    expect(tagged.replayGain?.albumGainDb, isNull);
    expect(tagged.replayGain?.albumPeak, isNull);
  });

  test(
      'album navigation metadata is optional and does not alter track identity',
      () {
    final source = Uri.parse(tree);
    final original = LocalMusicTrack.fromDocument(doc, source)!;
    final key = 'c' * 64;
    final tagged = LocalMusicTrack.fromDocument(
        {...doc, 'albumKey': key, 'albumArtist': 'Compilation'}, source)!;
    expect(tagged.albumKey, key);
    expect(tagged.albumArtist, 'Compilation');
    expect(tagged.playbackId, original.playbackId);
    expect(original.albumKey, isNull);
    for (final value in ['content://private/path', 42, 'f' * 65]) {
      final track =
          LocalMusicTrack.fromDocument({...doc, 'albumKey': value}, source)!;
      expect(track.playbackId, original.playbackId);
      expect(track.albumKey, isNull);
    }
  });

  test('fresh installs and cancellation never scan or grant access', () async {
    expect(library.enabled, isFalse);
    await library.initialize();
    await library.refresh();
    await library.revalidate();
    expect(calls, ['getFolder']);
    expect(await library.chooseFolder(), isFalse);
    expect(library.enabled, isFalse);
    expect(library.tracks, isEmpty);
    expect(calls, ['getFolder', 'pickFolder']);
  });

  test('overlapping SAF roots show one file and keep it hidden after removal',
      () async {
    const nestedTree = 'content://documents/tree/primary%3AMusic%2FJazz';
    const documentId = 'primary%3AMusic%2FJazz%2Ftrack.flac';
    final grants = [
      folder,
      {'uri': nestedTree, 'name': 'Jazz'}
    ];
    final factory = newDatabaseFactoryMemory();
    final database =
        SembastSqfDb(await factory.openDatabase('overlapping-saf'));
    addTearDown(database.close);
    await database.getProfiles();
    library.dispose();
    library = LocalMusicLibrary(visibilityDatabase: () => database);

    messenger.setMockMethodCallHandler(channel, (call) async {
      final root = (call.arguments as Map?)?['treeUri'];
      switch (call.method) {
        case 'getFolder':
          return selection(grants);
        case 'listTracks':
          final uri = '$root/document/$documentId';
          const modified = 1234567;
          const size = 800;
          final proof = ['document', uri, '$modified', '$size']
              .map((part) => '${part.length}:$part')
              .join();
          return [
            {
              ...doc,
              'uri': uri,
              'modifiedMs': modified,
              'sizeBytes': size,
              'visibilityKey': sha256.convert(utf8.encode(proof)).toString(),
            },
          ];
        case 'forgetFolder':
          grants.removeWhere((grant) => grant['uri'] == root);
          return selection(grants);
      }
      throw MissingPluginException();
    });

    await library.refresh();
    expect(library.visibleTracks.single.sourceUri, Uri.parse(tree));
    final playlistId =
        devicePlaylistVideo(library.visibleTracks.single)!.videoId;
    final hidden = await library.hideTrack(library.visibleTracks.single);
    expect(hidden, isNotNull);
    expect(await library.removeRoot(library.roots.first), isTrue);
    expect(library.tracks.single.sourceUri, Uri.parse(nestedTree));
    expect(devicePlaylistVideo(library.tracks.single)!.videoId, playlistId);
    expect(library.playlistTrackById(playlistId)?.sourceUri,
        Uri.parse(nestedTree));
    expect(library.visibleTracks, isEmpty);
    expect(library.hiddenTracks.single.isAvailable, isTrue);
    expect(await library.restoreTrack(library.hiddenTracks.single), isTrue);
    expect(library.visibleTracks.single.sourceUri, Uri.parse(nestedTree));
  });

  test('pick, resume and forget a folder without storing track paths in IDs',
      () async {
    choice = folder;
    expect(await library.chooseFolder(), isTrue);
    expect(library.folderName, 'Music');
    expect(library.loaded, isTrue);
    final track = library.tracks.single;
    expect(track.playbackId, matches(RegExp(r'^device:[0-9a-f]{64}$')));
    expect(library.trackById(track.playbackId), same(track));
    expect(library.containsUri(uri), isTrue);
    expect(track.artist, 'Artist');
    expect(track.album, 'Album');
    expect(track.durationMs, 12345);
    expect(track.artPath, '/data/cache/art.jpg');
    expect(track.adjacentArtPath, '/data/cache/adjacent.jpg');
    choice = null;
    expect(await library.chooseFolder(), isFalse);
    expect(library.trackById(track.playbackId), same(track));

    library.dispose();
    library = LocalMusicLibrary();
    calls.clear();
    await library.initialize();
    expect(library.enabled, isTrue);
    expect(library.loaded, isFalse);
    expect(library.containsUri(uri), isFalse);
    expect(calls, ['getFolder']);
    await library.refresh();
    expect(library.trackById(track.playbackId)?.uri, uri);
    final forgetting = library.disable();
    expect(library.enabled, isFalse);
    expect(library.containsUri(uri), isFalse);
    expect(library.trackById(track.playbackId), isNull);
    await forgetting;
    expect(saved, isNull);
  });

  test('device playlist metadata persists a file proof without storage paths',
      () {
    final proof = 'a' * 64;
    final track = LocalMusicTrack.fromDocument(
        {...doc, 'visibilityKey': proof}, Uri.parse(tree))!;
    final entry = devicePlaylistVideo(track)!;

    expect(entry.videoId, 'device:playlist:$proof');
    expect(entry.title, 'Title');
    expect(entry.author, 'Artist');
    expect(entry.lengthSeconds, 12);
    expect(entry.musicMetadata?.album, 'Album');
    expect(jsonEncode(entry.toJson()),
        allOf(isNot(contains('content://')), isNot(contains(track.artPath!))));
  });

  test('device playlist lookup rejects missing and replaced files', () async {
    final proof = 'a' * 64;
    saved = folder;
    scan = () async => [
          {...doc, 'visibilityKey': proof},
        ];
    await library.refresh();
    final original = library.tracks.single;
    final id = devicePlaylistVideo(original)!.videoId;
    expect(library.playlistTrackById(id), same(original));

    scan = () async => [];
    await library.refresh();
    expect(library.playlistTrackById(id), isNull);

    scan = () async => [
          {...doc, 'visibilityKey': 'b' * 64},
        ];
    await library.refresh();
    final replacement = library.tracks.single;
    expect(replacement.uri, original.uri);
    expect(replacement.playbackId, original.playbackId);
    expect(library.playlistTrackById(id), isNull);
    expect(library.playlistTrackById(devicePlaylistVideo(replacement)!.videoId),
        same(replacement));

    scan = () async => [doc];
    await library.refresh();
    final unverified = library.tracks.single;
    expect(devicePlaylistVideo(unverified), isNull);
    expect(library.playlistTrackById(unverified.playbackId), isNull);
    expect(library.playlistTrackById(id), isNull);
  });

  test('device playlist lookup requires a live grant and reconnects by proof',
      () async {
    final proof = 'a' * 64;
    saved = {...folder, 'selectionId': 'original-grant'};
    scan = () async => [
          {...doc, 'visibilityKey': proof},
        ];
    await library.refresh();
    final id = devicePlaylistVideo(library.tracks.single)!.videoId;

    checkAccess = () async => false;
    await library.revalidate();
    expect(library.playlistTrackById(id), isNull);

    checkAccess = () async => true;
    choice = {...folder, 'selectionId': 'new-grant'};
    expect(await library.chooseFolder(), isTrue);
    expect(library.selectionId, 'new-grant');
    expect(library.playlistTrackById(id), same(library.tracks.single));
  });

  test('only valid documents in the granted tree enter the library', () async {
    saved = folder;
    scan = () async => [
          doc,
          doc,
          {...doc, 'uri': 'https://example.org/song'},
          {...doc, 'uri': 'content://other/tree/primary%3AMusic/document/song'},
          {...doc, 'uri': 'content://documents/tree/other/document/song'},
          {
            ...doc,
            'uri': '$tree/document/other',
            'artPath': 'https://x/y.jpg',
            'adjacentArtPath': '//example.org/cover.jpg',
          },
          7,
        ];
    await library.refresh();
    expect(library.tracks.length, 2);
    expect(library.tracks.last.artPath, isNull);
    expect(library.tracks.last.adjacentArtPath, isNull);
  });

  test('granted CUE tracks retain separate clip identities on one document',
      () async {
    final first = {
      ...doc,
      'title': 'Opening',
      'identityKey': 'a' * 64,
      'visibilityKey': '1' * 64,
      'cueStartUs': 13333,
      'cueEndUs': 1026666,
      'canRename': true,
    };
    final last = {
      ...doc,
      'title': 'Finale',
      'identityKey': 'b' * 64,
      'cueStartUs': 1026666,
    };
    saved = folder;
    scan = () async => [
          doc,
          first,
          last,
          {...first, 'identityKey': null},
          {...first, 'identityKey': 'c' * 64, 'cueEndUs': 13333},
          {...first, 'identityKey': 'd' * 64, 'cueStartUs': -1},
          {...first, 'identityKey': 'e' * 64, 'cueStartUs': null},
          {...last, 'identityKey': 'f' * 64, 'uri': 'content://elsewhere/file'},
        ];
    await library.initialize();
    await library.refresh();

    expect(library.tracks.map((track) => track.title), [
      'Title',
      'Opening',
      'Finale',
    ]);
    expect(library.tracks.every((track) => track.uri == uri), isTrue);
    expect(library.tracks.first.isCueTrack, isFalse);
    final opening = library.trackById('device:${'a' * 64}')!;
    expect(opening.cueStartUs, 13333);
    expect(opening.cueEndUs, 1026666);
    expect(opening.canRename, isFalse);
    expect(opening.documentIdentity, isNull);
    expect(opening.documentVisibilityKey, isNull);
    final playlistTrack = devicePlaylistVideo(opening)!;
    expect(library.playlistTrackById(playlistTrack.videoId), same(opening));
    expect(await library.shareTrack(opening), isFalse);
    expect(await library.readTrackLyrics(opening), isNull);
    expect(library.trackById('device:${'b' * 64}')!.cueEndUs, isNull);
    expect(
      LocalMusicTrack.fromDocument(
        {...first, 'uri': 'content://media/external/audio/media/1'},
        LocalMusicTrack.systemSource,
      ),
      isNull,
    );
  });

  test('lost permission clears membership and picker can reconnect', () async {
    choice = folder;
    await library.chooseFolder();
    scan = () async => throw PlatformException(code: 'FOLDER_UNAVAILABLE');
    await library.refresh();
    expect(library.unavailable, isTrue);
    expect(library.tracks, isEmpty);
    expect(library.containsUri(uri), isFalse);
    scan = () async => [doc];
    expect(await library.chooseFolder(), isTrue);
    expect(library.unavailable, isFalse);
    expect(library.containsUri(uri), isTrue);
  });

  test('disable discards even a successful in-flight scan', () async {
    saved = folder;
    await library.refresh();
    final entered = Completer<void>();
    final blocked = Completer<List<Object?>>();
    scan = () {
      entered.complete();
      return blocked.future;
    };
    final refreshing = library.refresh();
    await entered.future;
    await library.disable();
    expect(saved, isNull);
    blocked.complete([doc]);
    await refreshing;
    expect(library.tracks, isEmpty);
    expect(library.enabled, isFalse);
  });

  test('external loss clears the library and invalidates an older scan',
      () async {
    saved = folder;
    await library.refresh();
    final track = library.tracks.single;
    final entered = Completer<void>();
    final blocked = Completer<List<Object?>>();
    scan = () {
      entered.complete();
      return blocked.future;
    };
    final scanning = library.refresh();
    await entered.future;
    checkAccess = () async => false;
    await library.revalidate();
    expect(library.unavailable, isTrue);
    expect(library.folderName, 'Music');
    expect(library.trackById(track.playbackId), isNull);
    blocked.complete([doc]);
    await scanning;
    expect(library.tracks, isEmpty);
    expect(calls.where((c) => c == 'pickFolder'), isEmpty);
    expect(calls.where((c) => c == 'listTracks'), hasLength(2));
  });

  test('temporary provider failure preserves confirmed membership', () async {
    saved = folder;
    await library.refresh();
    final track = library.tracks.single;
    checkAccess = () async => null;
    await library.revalidate();
    expect(library.trackById(track.playbackId), same(track));
    expect(library.unavailable, isFalse);
    expect(calls, ['getFolder', 'listTracks', 'checkFolderAccess']);
  });

  test('an interrupted child scan preserves the current queue source and art',
      () async {
    saved = folder;
    await library.refresh();
    final track = library.tracks.single;
    scan = () async => throw PlatformException(code: 'SCAN_UNAVAILABLE');
    await library.refresh();
    expect(library.error, 'SCAN_UNAVAILABLE');
    expect(library.unavailable, isFalse);
    expect(library.loaded, isTrue);
    expect(library.trackById(track.playbackId), same(track));
    expect(library.containsUri(track.uri), isTrue);
    expect(library.tracks.single.artPath, doc['artPath']);
    scan = () async => [doc];
    await library.refresh();
    expect(library.error, isNull);
  });

  test('switching folders removes old tracks before the replacement scan',
      () async {
    saved = folder;
    await library.refresh();
    const nextTree = 'content://documents/tree/SD';
    const nextUri = '$nextTree/document/track2';
    choice = {'uri': nextTree, 'name': 'SD'};
    final entered = Completer<void>();
    final blocked = Completer<List<Object?>>();
    scan = () {
      entered.complete();
      return blocked.future;
    };
    final selecting = library.chooseFolder();
    await entered.future;
    expect(library.folderName, 'SD');
    expect(library.containsUri(uri), isFalse);
    expect(library.trackById('device:missing'), isNull);
    blocked.complete([
      {...doc, 'uri': nextUri}
    ]);
    expect(await selecting, isTrue);
    expect(library.containsUri(nextUri), isTrue);
  });

  test('an open picker cannot re-enable the library after disable', () async {
    choice = folder;
    final entered = Completer<void>();
    final blocked = Completer<void>();
    pickerWait = () {
      entered.complete();
      return blocked.future;
    };
    final choosing = library.chooseFolder();
    await entered.future;
    final forgetting = library.disable();
    blocked.complete();
    expect(await choosing, isFalse);
    await forgetting;
    expect(saved, isNull);
    expect(library.enabled, isFalse);
    expect(calls, isNot(contains('listTracks')));
  });

  test('a batch supplies playable tracks before refresh finishes', () async {
    saved = folder;
    final entered = Completer<void>();
    final blocked = Completer<List<Object?>>();
    scan = () {
      entered.complete();
      return blocked.future;
    };
    final id = const LocalMusicTrack(uri: uri, title: 'Title').playbackId;
    final restoring = library.loadForPlayback([id]);
    await entered.future;
    expect(library.scanning, isTrue);
    final refreshing = library.refresh();
    await emitBatch([doc]);
    final track = library.tracks.single;
    await restoring;
    expect(library.loaded, isFalse);
    expect(library.containsUri(uri), isTrue);
    blocked.complete([
      {...doc, 'title': 'Enriched title'}
    ]);
    await refreshing;
    expect(library.scanning, isFalse);
    expect(library.trackById(track.playbackId)?.title, 'Enriched title');
  });

  test('refresh batches retain prior members until the final result', () async {
    saved = folder;
    await library.refresh();
    final entered = Completer<void>();
    final blocked = Completer<List<Object?>>();
    scan = () {
      entered.complete();
      return blocked.future;
    };
    final refreshing = library.refresh();
    await entered.future;
    final another = {...doc, 'uri': '$tree/document/another'};
    await emitBatch([another]);
    expect(library.tracks, hasLength(2));
    blocked.complete([another]);
    await refreshing;
    expect(library.tracks.single.uri, another['uri']);
    expect(library.containsUri(uri), isFalse);
    await emitBatch([doc]);
    expect(library.containsUri(uri), isFalse);
  });

  test('system music admits only MediaStore audio item URIs', () async {
    const system = 'content://media/external/audio/media';
    choice = {
      'uri': system,
      'name': 'Android music library',
      'selectionId': 'a'
    };
    scan = () async => [
          {
            ...doc,
            'uri': 'content://media/external_primary/audio/media/125',
            'fileName': 'track.flac',
            'addedMs': 12345,
            'modifiedMs': 23456,
            'canRename': true,
          },
          {...doc, 'uri': '$system/not-an-id'},
          {...doc, 'uri': '$system/1?limit=5'},
          {...doc, 'uri': 'content://media/external/video/media/1'},
          {...doc, 'uri': 'content://media/internal/audio/media/1'},
          doc,
        ];
    expect(await library.chooseSystem(), isTrue);
    expect(library.isSystem, isTrue);
    final track = library.tracks.single;
    expect(track.fileName, 'track.flac');
    expect(track.dateAdded?.millisecondsSinceEpoch, 12345);
    expect(track.dateModified?.millisecondsSinceEpoch, 23456);
    expect(track.canRename, isTrue);
    expect(library.acceptsSessionSelection('a'), isTrue);
  });

  test('recording exclusion is opt-in and requires a positive MediaStore label',
      () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    library.dispose();
    library = LocalMusicLibrary(visibilityDatabase: () => database);
    const system = 'content://media/external/audio/media';
    saved = {'uri': system, 'name': 'Android music library'};
    final indexed = {
      ...doc,
      'uri': 'content://media/external_primary/audio/media/1',
      'isRecording': true,
    };
    scan = () async => [
          indexed,
          {
            'uri': '$system/2',
            'title': 'Voice memo',
            'fileName': 'Voice memo.mp3',
            'isMusic': false,
          },
          {'uri': '$system/3', 'title': 'Untagged audio', 'isRecording': null},
          {...indexed, 'uri': '$system/4', 'isRecording': false},
          {...indexed, 'uri': '$system/5', 'isRecording': 'true'},
        ];
    await library.refresh();
    final recording = library.tracks.first;
    expect(recording.isRecording, isTrue);
    expect(library.tracks.skip(1).every((track) => !track.isRecording), isTrue);
    final safClaim = LocalMusicTrack.fromDocument(
        {...doc, 'isRecording': true}, Uri.parse(tree));
    expect(safClaim!.isRecording, isFalse);
    expect(library.excludesRecordings, isFalse);
    expect(library.visibleTracks, hasLength(5));

    await library.setExcludeRecordings(true);
    expect(library.excludesRecordings, isTrue);
    expect(library.excludedTracks.map((track) => track.uri), [recording.uri]);
    expect(library.visibleTracks.map((track) => track.uri),
        ['$system/2', '$system/3', '$system/4', '$system/5']);
    expect(library.visibleTrackById(recording.playbackId), isNull);
    expect(library.trackById(recording.playbackId), same(recording));
    expect(library.containsUri(recording.uri), isTrue);
    expect(library.hiddenTracks, isEmpty);

    await library.setExcludeRecordings(false);
    expect(library.excludedTracks, isEmpty);
    expect(library.visibleTracks, hasLength(5));
    expect(calls.where((method) => method == 'listTracks'), hasLength(1));
  });

  test(
      'folder ancestry and exact Keep overrides survive reopen for one profile',
      () async {
    final factory = newDatabaseFactoryMemory();
    const path = 'device-music-exclusions';
    var database = SembastSqfDb(await factory.openDatabase(path));
    addTearDown(() => database.close());
    await database.getProfiles();
    final owner = database.profileId;
    final other = await database.createProfile('Another listener');
    library.dispose();
    library = LocalMusicLibrary(visibilityDatabase: () => database);
    saved = folder;
    final selectedFolder = {'key': 'a' * 64, 'label': 'Music / Voice'};
    final nestedFolder = {'key': 'b' * 64, 'label': 'Music / Voice / Drafts'};
    final nearFolder = {'key': 'c' * 64, 'label': 'Music / VoiceArchive'};
    final sameLabelFolder = {'key': 'd' * 64, 'label': 'Music / Voice'};
    const childUri = '$tree/document/opaque-a4';
    const siblingUri = '$tree/document/opaque-f1';
    const sameLabelUri = '$tree/document/opaque-c9';
    const unprovenUri = '$tree/document/opaque-e6';
    final selected = {
      ...doc,
      'visibilityKey': 'e' * 64,
      'folderLocations': [selectedFolder],
    };
    final descendantsAndOtherFiles = [
      {
        ...doc,
        'uri': childUri,
        'visibilityKey': 'f' * 64,
        'folderLocations': [selectedFolder, nestedFolder],
      },
      {
        ...doc,
        'uri': siblingUri,
        'folderLocations': [nearFolder]
      },
      {
        ...doc,
        'uri': sameLabelUri,
        'folderLocations': [sameLabelFolder]
      },
      {
        ...doc,
        'uri': unprovenUri,
        'folderLocations': [
          selectedFolder,
          {'label': 'Unverified folder'},
        ],
      },
    ];
    scan = () async => [selected, ...descendantsAndOtherFiles];
    await library.refresh();
    final original = library.tracks.first;
    final location = original.folderLocations.single;
    expect(library.tracks.last.folderLocations, isEmpty);
    expect(library.visibleTracks, hasLength(5));

    await library.setFolderExcluded(location, true);
    expect(library.isFolderExcluded(location), isTrue);
    expect(library.excludedTracks.map((track) => track.uri), [uri, childUri]);
    const unaffected = [siblingUri, sameLabelUri, unprovenUri];
    expect(library.visibleTracks.map((track) => track.uri), unaffected);
    expect(library.canKeepExcludedTrack(original), isTrue);
    await library.setExclusionOverride(original, true);
    expect(library.hasExclusionOverride(original), isTrue);
    expect(
        library.visibleTracks.map((track) => track.uri), [uri, ...unaffected]);
    expect(library.excludedTracks.single.uri, childUri);
    await library.setExcludeRecordings(true);

    library.dispose();
    await database.close();
    database = SembastSqfDb(await factory.openDatabase(path));
    await database.getProfiles();
    library = LocalMusicLibrary(visibilityDatabase: () => database);
    await library.refresh();
    final reopened = library.trackById(original.playbackId)!;
    expect(library.excludesRecordings, isTrue);
    expect(library.isFolderExcluded(location), isTrue);
    expect(library.hasExclusionOverride(reopened), isTrue);
    expect(
        library.visibleTracks.map((track) => track.uri), [uri, ...unaffected]);

    await database.useProfile(other.id);
    library.visibilityProfileChanged();
    expect(library.excludesRecordings, isFalse);
    expect(library.isFolderExcluded(location), isFalse);
    expect(library.hasExclusionOverride(reopened), isFalse);
    expect(library.visibleTracks, hasLength(5));
    await database.useProfile(owner);
    library.visibilityProfileChanged();

    final hidden = (await library.hideTrack(reopened))!;
    expect(library.visibleTrackById(reopened.playbackId), isNull);
    expect(library.trackById(reopened.playbackId), same(reopened));
    expect(library.hiddenTracks.single.id, hidden.id);
    await library.restoreTrack(hidden);
    expect(library.visibleTrackById(reopened.playbackId), same(reopened));

    scan = () async => [
          {...selected, 'visibilityKey': '0' * 64},
          ...descendantsAndOtherFiles,
        ];
    await library.refresh();
    final replacement = library.tracks.first;
    expect(replacement.uri, uri);
    expect(library.hasExclusionOverride(replacement), isFalse);
    expect(library.visibleTracks.map((track) => track.uri), unaffected);
    await library.setFolderExcluded(location, false);
    expect(library.visibleTracks, hasLength(5));
  });

  test(
      'added locations share a session and losing one keeps the other playable',
      () async {
    final configured = [folder];
    final scans = <String>[];
    final secondScanStarted = Completer<void>();
    final pending = Completer<List<Object?>>();
    var revokeSecond = false;
    var pauseSecond = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getFolder':
          return selection(configured);
        case 'pickFolder':
          if (!configured.contains(secondFolder)) configured.add(secondFolder);
          return selection(configured);
        case 'listTracks':
          final source = call.arguments['treeUri'] as String;
          scans.add(source);
          if (source == tree) {
            return pauseSecond
                ? [
                    {...doc, 'title': 'Refreshed'}
                  ]
                : [doc];
          }
          expect(source, secondTree);
          if (pauseSecond) {
            scanId = call.arguments['scanId'] as int;
            secondScanStarted.complete();
            return pending.future;
          }
          return [
            const {'uri': secondUri, 'title': 'Other'}
          ];
        case 'checkFolderAccess':
          return !(revokeSecond && call.arguments['treeUri'] == secondTree);
        case 'cancelScan':
          expect(call.arguments['scanId'], scanId);
          return null;
        case 'shareTrack' || 'readTrackLyrics':
          expect(call.arguments['treeUri'], secondTree);
          expect(call.arguments['selectionId'], 'albums-grant');
          expect(call.arguments['trackId'], library.tracks.last.playbackId);
          if (call.method == 'shareTrack') {
            expect(call.arguments['uri'], secondUri);
            return true;
          }
          expect(call.arguments['trackUri'], secondUri);
          return {'sidecar': 'Approved lyrics'};
        case 'forgetFolder':
          expect(call.arguments['treeUri'], secondTree);
          configured.remove(secondFolder);
          return selection(configured);
        case 'forgetFolders':
          configured.clear();
          return {'roots': [], 'selectionId': null};
        default:
          fail('Unexpected ${call.method}');
      }
    });

    await library.initialize();
    final session = library.selectionId;
    expect(library.roots.map((root) => root.uri.toString()), [tree]);
    expect(library.roots.single.selectionId, isNull);
    expect(scans, isEmpty);
    await library.refresh();
    final originalId = library.tracks.single.playbackId;

    expect(await library.chooseFolder(), isTrue);
    expect(library.acceptsSessionSelection(session), isTrue);
    expect(
        library.roots.map((root) => root.uri.toString()), [tree, secondTree]);
    expect(library.tracks.map((track) => track.uri), [uri, secondUri]);
    expect(library.tracks.map((track) => track.sourceUri.toString()),
        [tree, secondTree]);
    expect(scans, [tree, tree, secondTree]);
    final secondTrack = library.tracks.last;
    expect(await library.shareTrack(secondTrack), isTrue);
    expect((await library.readTrackLyrics(secondTrack))?.sidecar,
        'Approved lyrics');

    pauseSecond = true;
    final refresh = library.refresh();
    await secondScanStarted.future;
    await library.cancelScan();
    revokeSecond = true;
    await library.revalidate();
    final secondRoot = library.roots.last;
    expect(library.isRootUnavailable(secondRoot), isTrue);
    expect(library.unavailable, isFalse);
    expect(library.acceptsSessionSelection(session), isTrue);
    expect(library.trackById(originalId)?.uri, uri);
    expect(library.containsUri(secondUri), isFalse);

    const staleDocument = {'uri': secondUri, 'title': 'Stale'};
    await emitBatch([staleDocument]);
    pending.complete([staleDocument]);
    await refresh;
    expect(library.tracks.map((track) => track.uri), [uri]);
    expect(library.tracks.single.title, 'Refreshed');
    expect(await library.shareTrack(secondTrack), isFalse);
    expect(await library.readTrackLyrics(secondTrack), isNull);

    expect(await library.removeRoot(secondRoot), isTrue);
    expect(library.roots.map((root) => root.uri.toString()), [tree]);
    expect(library.acceptsSessionSelection(session), isTrue);
    expect(library.trackById(originalId)?.uri, uri);
    await library.disable();
    expect(configured, isEmpty);
    expect(library.roots, isEmpty);
    expect(library.acceptsSessionSelection(session), isFalse);
  });

  test('inclusions and exact hides persist per profile across library reopen',
      () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    await database.getProfiles();
    final owner = database.profileId;
    final other = await database.createProfile('Other profile');
    final included = {'key': 'a' * 64, 'label': 'Music'};
    final nested = {'key': 'b' * 64, 'label': 'Music / Live'};
    final otherFolder = {'key': 'c' * 64, 'label': 'Albums'};
    const nestedUri = '$tree/document/primary%3AMusic%2FLive%2Ftrack.flac';
    final documents = {
      tree: [
        {
          ...doc,
          'visibilityKey': '1' * 64,
          'folderLocations': [included],
        },
        {
          ...doc,
          'uri': nestedUri,
          'visibilityKey': '2' * 64,
          'folderLocations': [included, nested],
        },
      ],
      secondTree: [
        {
          ...doc,
          'uri': secondUri,
          'visibilityKey': '3' * 64,
          'folderLocations': [otherFolder],
        },
      ],
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getFolder':
          return selection([folder, secondFolder]);
        case 'listTracks':
          return documents[call.arguments['treeUri']];
        default:
          fail('Unexpected ${call.method}');
      }
    });
    library.dispose();
    library = LocalMusicLibrary(visibilityDatabase: () => database);
    await library.refresh();
    final parent = library.tracks.first.folderLocations.single;
    final child = library.tracks[1].folderLocations.last;
    final outside = library.tracks.last;

    expect(await library.setFolderIncluded(parent, true), isTrue);
    expect(library.visibleTracks.map((track) => track.uri), [uri, nestedUri]);
    expect(library.isExcludedByInclusion(outside), isTrue);
    expect(await library.setFolderExcluded(child, true), isTrue);
    expect(library.visibleTracks.map((track) => track.uri), [uri]);
    expect(await library.setExclusionOverride(outside, true), isTrue);
    expect(await library.hideTrack(outside), isNotNull);
    expect(library.visibleTracks.map((track) => track.uri), [uri]);

    library.dispose();
    library = LocalMusicLibrary(visibilityDatabase: () => database);
    await library.refresh();
    expect(library.inclusionFolders.single.key, parent.key);
    expect(library.visibleTracks.map((track) => track.uri), [uri]);
    expect(library.hiddenTracks.single.isAvailable, isTrue);

    await database.useProfile(other.id);
    library.visibilityProfileChanged();
    expect(library.roots, hasLength(2));
    expect(library.inclusionFolders, isEmpty);
    expect(library.hiddenTracks, isEmpty);
    expect(library.visibleTracks.map((track) => track.uri),
        [uri, nestedUri, secondUri]);

    await database.useProfile(owner);
    library.visibilityProfileChanged();
    expect(library.visibleTracks.map((track) => track.uri), [uri]);
    expect(await library.restoreTrack(library.hiddenTracks.single), isTrue);
    expect(library.visibleTracks.map((track) => track.uri), [uri, secondUri]);
  });

  test('denying the Android library preserves a selected folder', () async {
    saved = folder;
    await library.refresh();
    final track = library.tracks.single;
    denySystem = true;
    expect(await library.chooseSystem(), isFalse);
    expect(library.error, 'AUDIO_PERMISSION_DENIED');
    expect(library.isSystem, isFalse);
    expect(library.folderName, 'Music');
    expect(library.trackById(track.playbackId), same(track));
    expect(calls.where((method) => method == 'listTracks'), hasLength(1));
  });

  test('provider rename replaces the live URI and preserves playback identity',
      () async {
    saved = folder;
    scan = () async => [
          {...doc, 'fileName': 'track.flac', 'canRename': true},
        ];
    await library.refresh();
    final original = library.tracks.single;
    const newUri = '$tree/document/primary%3AMusic%2Fnew.flac';
    renamed = {
      ...doc,
      'uri': newUri,
      'identityUri': uri,
      'fileName': 'new.flac',
      'canRename': true,
    };
    expect(await library.renameTrack(original, 'new.flac'), isTrue);
    expect(library.containsUri(uri), isFalse);
    expect(library.trackById(original.playbackId)?.uri, newUri);
    expect(library.tracks.single.title, 'Title');
  });

  test('device visibility survives database and library reopen per profile',
      () async {
    final factory = newDatabaseFactoryMemory();
    const path = 'hidden-device-music';
    var database = SembastSqfDb(await factory.openDatabase(path));
    addTearDown(() => database.close());
    await database.getProfiles();
    final originalProfile = database.profileId;
    final other = await database.createProfile('Another listener');
    library.dispose();
    library = LocalMusicLibrary(visibilityDatabase: () => database);

    saved = folder;
    const copyUri = '$tree/document/primary%3AMusic%2Fcopy.flac';
    scan = () async => [
          {...doc, 'visibilityKey': 'a' * 64},
          {...doc, 'uri': copyUri, 'visibilityKey': 'b' * 64},
        ];
    await library.refresh();
    final original = library.tracks.first;
    final playlistId = devicePlaylistVideo(original)!.videoId;
    expect(library.tracks.map((track) => track.title), ['Title', 'Title']);
    final hidden = (await library.hideTrack(original))!;
    expect(library.playlistTrackById(playlistId), same(original));
    expect(library.playlistTrackById(playlistId, visibleOnly: true), isNull);
    expect(library.visibleTracks.map((track) => track.uri), [copyUri]);
    expect(library.hiddenTracks.single.title, 'Title');
    expect(library.trackById(original.playbackId), same(original));
    expect(library.containsUri(uri), isTrue);

    library.dispose();
    await database.close();
    database = SembastSqfDb(await factory.openDatabase(path));
    await database.getProfiles();
    library = LocalMusicLibrary(visibilityDatabase: () => database);
    await library.refresh();
    expect(library.visibleTracks.map((track) => track.uri), [copyUri]);
    expect(library.hiddenTracks.single.id, hidden.id);
    expect(library.hiddenTracks.single.isAvailable, isTrue);

    final storedHidden = library.hiddenTracks.single;
    await database.useProfile(other.id);
    library.visibilityProfileChanged();
    expect(library.playlistTrackById(playlistId, visibleOnly: true)?.uri, uri);
    expect(library.visibleTracks.map((track) => track.uri), [uri, copyUri]);
    expect(library.hiddenTracks, isEmpty);
    expect(await library.restoreTrack(storedHidden), isFalse);
    final otherHidden = (await library.hideTrack(library.tracks.last))!;
    expect(library.visibleTracks.map((track) => track.uri), [uri]);

    await database.useProfile(originalProfile);
    library.visibilityProfileChanged();
    expect(library.visibleTracks.map((track) => track.uri), [copyUri]);
    expect(await library.restoreTrack(otherHidden), isFalse);
    expect(await library.restoreTrack(library.hiddenTracks.single), isTrue);
    expect(library.hiddenTracks, isEmpty);
    expect(library.visibleTracks.map((track) => track.uri), [uri, copyUri]);
    expect(calls, isNot(contains('forgetFolder')));
  });

  test(
      'hiding survives a verified rename and grant loss without hiding a replacement',
      () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    library.dispose();
    library = LocalMusicLibrary(visibilityDatabase: () => database);
    saved = folder;
    final proof = 'a' * 64;
    final originalDocument = {
      ...doc,
      'canRename': true,
      'fileName': 'track.flac',
      'visibilityKey': proof,
    };
    const unverifiedUri = '$tree/document/unverified';
    final unverifiedDocument = {...doc, 'uri': unverifiedUri};
    scan = () async => [originalDocument, unverifiedDocument];
    await library.refresh();
    final original = library.tracks.first;
    expect(library.canHideTrack(library.tracks.last), isFalse);
    expect(await library.hideTrack(library.tracks.last), isNull);
    expect(await library.hideTrack(original), isNotNull);

    const newUri = '$tree/document/primary%3AMusic%2Fnew.flac';
    final renamedDocument = {
      ...originalDocument,
      'uri': newUri,
      'identityUri': uri,
      'fileName': 'new.flac',
    };
    renamed = renamedDocument;
    expect(await library.renameTrack(original, 'new.flac'), isTrue);
    expect(library.hiddenTracks.single.fileName, 'new.flac');
    expect(library.visibleTracks.map((track) => track.uri), [unverifiedUri]);
    expect(library.trackById(original.playbackId)?.uri, newUri);
    expect(library.containsUri(newUri), isTrue);

    checkAccess = () async => false;
    await library.revalidate();
    expect(library.unavailable, isTrue);
    expect(library.hiddenTracks.single.isAvailable, isFalse);
    expect(library.visibleTracks, isEmpty);
    expect(library.trackById(original.playbackId), isNull);

    choice = folder;
    checkAccess = () async => true;
    scan = () async => [renamedDocument, unverifiedDocument];
    expect(await library.chooseFolder(), isTrue);
    expect(library.hiddenTracks.single.isAvailable, isTrue);
    expect(library.visibleTracks.map((track) => track.uri), [unverifiedUri]);

    scan = () async => [
          {...renamedDocument, 'visibilityKey': 'b' * 64},
          unverifiedDocument,
        ];
    await library.refresh();
    expect(library.hiddenTracks.single.isAvailable, isFalse);
    expect(library.visibleTracks.map((track) => track.uri),
        [newUri, unverifiedUri]);
    expect(await library.restoreTrack(library.hiddenTracks.single), isTrue);
    expect(library.hiddenTracks, isEmpty);
    expect(library.visibleTracks.map((track) => track.uri),
        [newUri, unverifiedUri]);
  });
}
