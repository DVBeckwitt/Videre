import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clipious/music/services/music_community_cover_cache.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

const _track = MusicMetadata(title: 'Song', artist: 'Artist');
const _videoId = 'ABCDEFGHIJK';
final _cover = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('videre-cover-test-');
    addTearDown(() => directory.delete(recursive: true));
  });

  test('a local cover is reusable within its profile without a request',
      () async {
    var calls = 0;
    final cache = MusicCommunityCoverCache(
        supportDirectory: () async => directory,
        loader: (_, __, {required isCurrent}) async {
          calls++;
          return _cover;
        });

    expect(await cache.read('one', _videoId, isCurrent: () => true), isNull);
    expect(calls, 0);
    final saved =
        await cache.load('one', _videoId, _track, 180, isCurrent: () => true);
    expect(cache.savedCover.value, ('one', _videoId));
    expect(await saved!.readAsBytes(), _cover);
    expect((await cache.read('one', _videoId, isCurrent: () => true))!.path,
        saved.path);
    expect(await cache.read('two', _videoId, isCurrent: () => true), isNull);
    expect(await cache.read('one', _videoId, isCurrent: () => false), isNull);
    expect(calls, 1);
    final other =
        await cache.load('two', _videoId, _track, 180, isCurrent: () => true);
    await cache.removeProfile('one');
    expect(await saved.exists(), isFalse);
    expect(await other!.exists(), isTrue);
  });

  test('revoking permission during a lookup discards the late cover', () async {
    var admitted = false;
    final started = Completer<void>();
    final response = Completer<Uint8List?>();
    final cache = MusicCommunityCoverCache(
        supportDirectory: () async => directory,
        loader: (_, __, {required isCurrent}) {
          started.complete();
          return response.future;
        });
    expect(
        await cache.load('one', _videoId, _track, 180,
            isCurrent: () => admitted),
        isNull);
    expect(started.isCompleted, isFalse);
    admitted = true;
    final pending =
        cache.load('one', _videoId, _track, 180, isCurrent: () => admitted);
    await started.future;
    admitted = false;
    response.complete(_cover);
    expect(await pending, isNull);
    expect(await cache.read('one', _videoId, isCurrent: () => true), isNull);
    expect(cache.savedCover.value, isNull);
  });

  test('an unreadable local cover can be replaced by the next lookup',
      () async {
    var calls = 0;
    final cache = MusicCommunityCoverCache(
        supportDirectory: () async => directory,
        loader: (_, __, {required isCurrent}) async {
          calls++;
          return _cover;
        });
    final file = (await cache.load('one', _videoId, _track, 180,
        isCurrent: () => true))!;
    expect(await cache.read('one', _videoId, isCurrent: () => true), isNotNull);

    await file.writeAsBytes(_cover.sublist(0, 20), flush: true);
    expect(await cache.read('one', _videoId, isCurrent: () => true), isNull);
    expect(calls, 1);
    final repaired =
        await cache.load('one', _videoId, _track, 180, isCurrent: () => true);
    expect(await repaired!.readAsBytes(), _cover);
    expect(await cache.read('one', _videoId, isCurrent: () => true), isNotNull);
    expect(calls, 2);
  });

  test('missing covers are cached for the specific query and profile',
      () async {
    var calls = 0;
    final cache = MusicCommunityCoverCache(
        supportDirectory: () async => directory,
        loader: (_, __, {required isCurrent}) async {
          calls++;
          return null;
        });
    await cache.load('one', _videoId, _track, 180, isCurrent: () => true);
    await cache.load('one', _videoId, _track, 180, isCurrent: () => true);
    expect(calls, 1);
    await cache.load('one', _videoId, _track, 200, isCurrent: () => true);
    await cache.load('two', _videoId, _track, 180, isCurrent: () => true);
    expect(calls, 3);
  });
}
