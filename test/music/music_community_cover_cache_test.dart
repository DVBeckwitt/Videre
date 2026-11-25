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

  test(
      'clearing one profile cancels its outstanding lookup and permits a new cover',
      () async {
    final firstStarted = Completer<void>();
    final otherStarted = Completer<void>();
    final firstResponse = Completer<Uint8List?>();
    final otherResponse = Completer<Uint8List?>();
    final cache = MusicCommunityCoverCache(
      supportDirectory: () async => directory,
      loader: (track, _, {required isCurrent}) async {
        if (track.title == 'Old') {
          firstStarted.complete();
          return firstResponse.future;
        }
        if (track.title == 'Other profile') {
          otherStarted.complete();
          return otherResponse.future;
        }
        return _cover;
      },
    );
    final commits = <(String, String)>[];
    cache.savedCover.addListener(() {
      if (cache.savedCover.value case final commit?) commits.add(commit);
    });
    final first = cache.load('one', _videoId,
        const MusicMetadata(title: 'Old', artist: 'Artist'), 180,
        isCurrent: () => true);
    final other = cache.load('two', _videoId,
        const MusicMetadata(title: 'Other profile', artist: 'Artist'), 180,
        isCurrent: () => true);
    await Future.wait([firstStarted.future, otherStarted.future]);
    await cache.clear('one');
    expect(cache.invalidated.value, ('one', null));
    expect(await cache.entries('one'), isEmpty);

    firstResponse.complete(_cover);
    expect(await first, isNull);
    expect(await cache.entries('one'), isEmpty);
    final replacement =
        await cache.load('one', _videoId, _track, 180, isCurrent: () => true);
    expect(await replacement!.readAsBytes(), _cover);
    otherResponse.complete(_cover);
    expect(await (await other)!.readAsBytes(), _cover);
    expect(commits, [('one', _videoId), ('two', _videoId)]);
    expect((await cache.entries('one')).single.bytes, _cover.length);
    expect((await cache.entries('two')).single.bytes, _cover.length);
  });

  test(
      'reads refresh recency and protect a cover from stale eviction snapshots',
      () async {
    final cache = MusicCommunityCoverCache(
        supportDirectory: () async => directory,
        loader: (_, __, {required isCurrent}) async => _cover);
    final first =
        await cache.load('one', _videoId, _track, 180, isCurrent: () => true);
    final other =
        await cache.load('two', _videoId, _track, 180, isCurrent: () => true);
    final yesterday = DateTime.now().toUtc().subtract(const Duration(days: 1));
    await first!.setLastModified(yesterday);
    await first.setLastAccessed(yesterday);
    // Reopen the same folder to exercise persisted recency, independent of the
    // writer's in-memory timestamps and the filesystem's timestamp resolution.
    final reopened =
        MusicCommunityCoverCache(supportDirectory: () async => directory);
    final before = (await reopened.entries('one')).single;
    expect(
        await reopened.read('one', _videoId, isCurrent: () => true), isNotNull);
    final refreshed = (await reopened.entries('one')).single;
    expect(refreshed.touched.isAfter(before.touched), isTrue);
    expect(refreshed.bytes, _cover.length);
    await before.remove();
    expect(await first.exists(), isTrue);
    expect(reopened.invalidated.value, isNull);
    await refreshed.remove();
    expect(await first.exists(), isFalse);
    expect(await reopened.entries('one'), isEmpty);
    expect(reopened.invalidated.value, ('one', _videoId));
    expect(reopened.savedCover.value, isNull);
    expect(await other!.exists(), isTrue);
  });

  test('a descriptor captured before clear cannot remove replacement bytes',
      () async {
    final cache = MusicCommunityCoverCache(
        supportDirectory: () async => directory,
        loader: (_, __, {required isCurrent}) async => _cover);
    await cache.load('one', _videoId, _track, 180, isCurrent: () => true);
    final stale = (await cache.entries('one')).single;
    await cache.clear('one');
    final replacement =
        await cache.load('one', _videoId, _track, 180, isCurrent: () => true);
    await stale.remove();
    expect(await replacement!.readAsBytes(), _cover);
    expect((await cache.entries('one')).single.bytes, stale.bytes);
  });

  test('inventory reclaims interrupted staging after the active publish',
      () async {
    final publishing = Completer<void>();
    final resume = Completer<void>();
    addTearDown(() {
      if (!resume.isCompleted) resume.complete();
    });
    var holdDisk = false;
    var lookups = 0;
    final cache = MusicCommunityCoverCache(supportDirectory: () async {
      if (holdDisk) {
        holdDisk = false;
        publishing.complete();
        await resume.future;
      }
      return directory;
    }, loader: (_, __, {required isCurrent}) async {
      if (++lookups == 2) holdDisk = true;
      return _cover;
    });
    final first = (await cache.load('one', _videoId, _track, 180,
        isCurrent: () => true))!;
    final folder = first.parent;
    Future<File> file(Directory dir, String name) =>
        File.fromUri(dir.uri.resolve(name)).writeAsBytes([1, 2, 3]);
    final orphan = await folder.createTemp('.pending-');
    await file(orphan, 'cover.png');
    final mixed = await folder.createTemp('.pending-');
    final mixedPartial = await file(mixed, 'cover.png');
    final unrelated = await file(mixed, 'keep.txt');
    final elsewhere = await folder.createTemp('other-');
    final otherCover = await file(elsewhere, 'cover.png');

    // The cache test also runs on case-insensitive volumes.
    final second =
        cache.load('one', 'LMNOPQRSTUV', _track, 180, isCurrent: () => true);
    await Future.any([
      publishing.future,
      second.then<void>((_) => throw StateError(
          'Second cover completed before entering publication')),
    ]).timeout(const Duration(seconds: 5));
    final inventory = cache.entries('one');
    resume.complete();
    expect(await (await second)!.readAsBytes(), _cover);
    expect((await inventory).map((record) => record.bytes),
        [_cover.length, _cover.length]);
    expect(await first.exists(), isTrue);
    expect(await orphan.exists(), isFalse);
    expect(await mixedPartial.exists(), isFalse);
    expect(await unrelated.readAsBytes(), [1, 2, 3]);
    expect(await otherCover.readAsBytes(), [1, 2, 3]);
    expect(lookups, 2);
  });
}
