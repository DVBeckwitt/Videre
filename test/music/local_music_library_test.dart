import 'dart:async';

import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
  const codec = StandardMethodCodec();
  const tree = 'content://documents/tree/primary%3AMusic';
  const folder = {'uri': tree, 'name': 'Music'};
  const uri = '$tree/document/primary%3AMusic%2Ftrack.flac';
  const doc = {
    'uri': uri,
    'title': 'Title',
    'artist': 'Artist',
    'album': 'Album',
    'durationMs': 12345,
    'artPath': '/data/cache/art.jpg',
  };
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late LocalMusicLibrary library;
  late List<String> calls;
  Map<String, String>? saved;
  Map<String, String>? choice;
  late Future<List<Object?>> Function() scan;
  late Future<bool?> Function() checkAccess;
  Future<void> Function()? pickerWait;
  int? scanId;
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

  setUp(() {
    library = LocalMusicLibrary();
    calls = [];
    saved = null;
    choice = null;
    pickerWait = null;
    scanId = null;
    renamed = null;
    denySystem = false;
    scan = () async => [doc];
    checkAccess = () async => true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'getFolder':
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
          return scan();
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

  test('only valid documents in the granted tree enter the library', () async {
    saved = folder;
    scan = () async => [
          doc,
          doc,
          {...doc, 'uri': 'https://example.org/song'},
          {...doc, 'uri': 'content://other/tree/primary%3AMusic/document/song'},
          {...doc, 'uri': 'content://documents/tree/other/document/song'},
          {...doc, 'uri': '$tree/document/other', 'artPath': 'https://x/y.jpg'},
          7,
        ];
    await library.refresh();
    expect(library.tracks.length, 2);
    expect(library.tracks.last.artPath, isNull);
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
}
