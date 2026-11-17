import 'dart:convert';
import 'dart:io';

import 'package:clipious/content_filter/community_models.dart';
import 'package:clipious/content_filter/flow_list_repository.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

const _blockId = 'UC--f0eYRq7CAf25PP4PiQ0g';
const _warnId = 'UC1qwIUkiTytsFoOsnC5zyqg';
const _musicId = 'UC--ppxarUtjMpI6lZfApKzg';
const _etag = '"manifest-2026-11"';

void main() {
  final signer = Ed25519();
  late KeyPair keyPair;
  late Map<String, String> signingKeys;
  late Directory directory;

  setUpAll(() async {
    keyPair = await signer.newKeyPair();
    final publicKey = await keyPair.extractPublicKey() as SimplePublicKey;
    signingKeys = {'fixture': base64Encode(publicKey.bytes)};
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('videre-flow-lists-');
    addTearDown(() => directory.delete(recursive: true));
  });

  FlowListRepository repository(MockClientHandler handler) =>
      FlowListRepository(
        directory: () async => directory,
        createClient: () => MockClient(handler),
        signingKeys: signingKeys,
      );

  Future<({String manifest, String snapshot})> fixture({
    CommunityList list = CommunityList.aislist,
    int version = 6,
    bool tamperedSignature = false,
    bool invalidIdentity = false,
    String? path,
  }) async {
    final music = list == CommunityList.aimusic;
    final body = jsonEncode({
      'schema': 1,
      'list': list.name,
      'version': version,
      'block': {
        'ids': [
          if (invalidIdentity)
            'a display name'
          else if (music)
            _musicId
          else
            _blockId
        ],
        'handles': [if (!music) 'música'],
      },
      'warn': {
        'ids': [if (!music) _warnId],
        'handles': [if (!music) 'another_creator'],
      },
    });
    final bytes = utf8.encode(body);
    final payload = utf8.encode(jsonEncode({
      'schema': 1,
      'list': list.name,
      'version': version,
      'generated_at': '2026-11-16T03:17:00Z',
      'snapshot': {
        'path': path ?? 'snapshot/$version.json',
        'sha256': sha256.convert(bytes).toString(),
        'bytes': bytes.length,
      },
      'counts': {
        'block_handles': music ? 0 : 1,
        'block_ids': 1,
        'warn_handles': music ? 0 : 1,
        'warn_ids': music ? 0 : 1,
      },
    }));
    final signature = await signer.sign(payload, keyPair: keyPair);
    final signatureBytes = [...signature.bytes];
    if (tamperedSignature) signatureBytes[0] ^= 1;
    return (
      manifest: jsonEncode({
        'key_id': 'fixture',
        'payload': base64Encode(payload),
        'sig': base64Encode(signatureBytes),
      }),
      snapshot: body,
    );
  }

  http.Response manifestResponse(String body) =>
      http.Response(body, 200, headers: {'etag': _etag});

  http.Response snapshotResponse(String body) =>
      http.Response.bytes(utf8.encode(body), 200);

  test('validates the two list feeds independently and reloads signed tiers',
      () async {
    final aislist = await fixture();
    final music = await fixture(list: CommunityList.aimusic, version: 2);
    final paths = <String>[];
    final feed = repository((request) async {
      expect(request.url.origin, 'https://ailist.flow-tube.org');
      expect(request.method, 'GET');
      expect(request.followRedirects, isFalse);
      expect(request.url.hasQuery, isFalse);
      expect(request.headers.keys, {'accept'});
      paths.add(request.url.path);
      final list = paths.last.contains('/aislist/') ? aislist : music;
      return paths.last.endsWith('/manifest.json')
          ? manifestResponse(list.manifest)
          : snapshotResponse(list.snapshot);
    });

    expect(await feed.load(CommunityList.aislist), isNull);
    final first =
        await feed.refresh(CommunityList.aislist, isCurrent: () => true);
    final second =
        await feed.refresh(CommunityList.aimusic, isCurrent: () => true);
    expect(first.blockHandles, {'música'});
    expect(first.blockIds, {_blockId});
    expect(first.warnIds, {_warnId});
    expect(first.warnHandles, {'another_creator'});
    expect(second.blockIds, {_musicId});
    expect(second.blockHandles, isEmpty);
    expect(second.warnIds, isEmpty);
    expect(paths, [
      '/v1/aislist/manifest.json',
      '/v1/aislist/snapshot/6.json',
      '/v1/aimusic/manifest.json',
      '/v1/aimusic/snapshot/2.json',
    ]);

    final restarted =
        repository((_) async => fail('Cache load made a request'));
    final cached = await restarted.load(CommunityList.aislist);
    expect(cached?.checkedAt, isNotNull);
    expect(cached?.warnHandles, first.warnHandles);
    expect((await restarted.load(CommunityList.aimusic))?.blockIds, {_musicId});
  });

  test('conditional 304 persists the successful check time across reloads',
      () async {
    final source = await fixture();
    final original = repository((request) async =>
        request.url.path.endsWith('/manifest.json')
            ? manifestResponse(source.manifest)
            : snapshotResponse(source.snapshot));
    await original.refresh(CommunityList.aislist, isCurrent: () => true);
    final file =
        File(p.join(directory.path, 'community-lists', 'aislist.json'));
    final saved = await file.readAsBytes();
    final stale = DateTime.now().toUtc().subtract(const Duration(days: 2));
    await file.setLastModified(stale);
    var checks = 0;
    final feed = repository((request) async {
      checks++;
      expect(request.url.path, '/v1/aislist/manifest.json');
      expect(request.headers['if-none-match'], _etag);
      return http.Response('', 304);
    });
    final checked =
        await feed.refresh(CommunityList.aislist, isCurrent: () => true);
    expect(checks, 1);
    expect(checked.version, 6);
    expect(checked.checkedAt!.isAfter(stale), isTrue);
    expect(
        (await original.load(CommunityList.aislist))!.checkedAt!.isAfter(stale),
        isTrue);
    expect(await file.readAsBytes(), saved);
  });

  test('failed replacements preserve the last valid cached snapshot', () async {
    final source = await fixture();
    var next = source;
    int? manifestStatus;
    var snapshots = 0;
    final feed = repository((request) async {
      if (request.url.path.endsWith('/manifest.json')) {
        if (manifestStatus case final status?) {
          return http.Response('', status,
              headers: {'location': 'https://other.invalid'});
        }
        return manifestResponse(next.manifest);
      }
      snapshots++;
      return snapshotResponse(next.snapshot);
    });
    await feed.refresh(CommunityList.aislist, isCurrent: () => true);

    Future<void> rejects(({String manifest, String snapshot}) response) async {
      next = response;
      await expectLater(
          feed.refresh(CommunityList.aislist, isCurrent: () => true),
          throwsFormatException);
      expect((await feed.load(CommunityList.aislist))?.version, 6);
    }

    await rejects(await fixture(version: 7, tamperedSignature: true));
    await rejects(await fixture(version: 5));
    await rejects(await fixture(list: CommunityList.aimusic, version: 7));
    await rejects(
        await fixture(version: 7, path: 'https://other.invalid/a.json'));
    expect(snapshots, 1,
        reason: 'invalid manifests cannot authorize a snapshot');

    final newer = await fixture(version: 7);
    await rejects((manifest: newer.manifest, snapshot: source.snapshot));
    await rejects(await fixture(version: 7, invalidIdentity: true));
    manifestStatus = 302;
    await rejects(newer);
    manifestStatus = null;
    expect(
        (await feed.refresh(CommunityList.aislist, isCurrent: () => true))
            .version,
        7);
  });

  test('off and cancelled requests never advance to a snapshot', () async {
    final source = await fixture();
    var current = false;
    var requests = 0;
    final feed = repository((request) async {
      requests++;
      expect(request.url.path, '/v1/aislist/manifest.json');
      current = false;
      return manifestResponse(source.manifest);
    });
    await expectLater(
        feed.refresh(CommunityList.aislist, isCurrent: () => current),
        throwsStateError);
    expect(requests, 0);
    current = true;
    await expectLater(
        feed.refresh(CommunityList.aislist, isCurrent: () => current),
        throwsStateError);
    expect(requests, 1);
    expect(await feed.load(CommunityList.aislist), isNull);
  });
}
