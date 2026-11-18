import 'dart:async';

import 'package:clipious/music/services/local_music_library.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
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
  setUp(() {
    library = LocalMusicLibrary();
    calls = [];
    saved = null;
    choice = null;
    pickerWait = null;
    scan = () async => [doc];
    checkAccess = () async => true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'getFolder':
          return saved;
        case 'pickFolder':
          await pickerWait?.call();
          if (choice != null) saved = choice;
          return choice;
        case 'listTracks':
          expect(call.arguments['treeUri'], saved?['uri']);
          return scan();
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
}
