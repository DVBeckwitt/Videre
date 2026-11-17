import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../network/direct_http_client.dart';
import '../network/network_proxy.dart';
import '../network/reloadable_http_client.dart';
import 'community_models.dart';

const _host = 'ailist.flow-tube.org';
const _manifestLimit = 64 * 1024;
const _snapshotLimit = 8 * 1024 * 1024;
const _cacheLimit = ((_manifestLimit + _snapshotLimit) * 4 ~/ 3) + 4096;
final _sha256Hex = RegExp(r'^[a-f0-9]{64}$');
final _etagFormat = RegExp(r'^(W/)?"[\x21\x23-\x7e]{0,126}"$');

// Flow's published Ed25519 public key, encoded as raw bytes without the
// SubjectPublicKeyInfo wrapper. Rotate by adding keys here before publication.
// https://github.com/Flow-Tube/AIlist/blob/main/keys/2026-11.pub.pem
const _trustedSigningKeys = {
  '2026-11': 'xak9y4JaDG+UjKfl7cDwiaJs+7FjrOM+urMW1YfSuc0=',
};

/// Downloads Flow's signed v1 lists over Videre's network route. The cache is
/// shared across profiles and stored outside Android and Videre backups.
class FlowListRepository implements CommunityListStore {
  final Future<Directory> Function() _directory;
  final http.Client Function() _createClient;
  final Map<String, String> _signingKeys;
  final Duration _timeout;
  final _pending = <CommunityList, Future<void>>{};

  FlowListRepository({
    Future<Directory> Function()? directory,
    http.Client Function()? createClient,
    Map<String, String> signingKeys = _trustedSigningKeys,
    Duration timeout = const Duration(seconds: 30),
  })  : _directory = directory ?? getApplicationCacheDirectory,
        _createClient = createClient ?? _createListHttpClient,
        _signingKeys = Map.unmodifiable(signingKeys),
        _timeout = timeout;

  Future<File> _file(CommunityList list) async => File(p.join(
      (await _directory()).path, 'community-lists', '${list.name}.json'));

  @override
  Future<CommunitySnapshot?> load(CommunityList list) async =>
      (await _load(list))?.snapshot;

  Future<_CachedList?> _load(CommunityList list) async {
    try {
      final file = await _file(list);
      if (!await file.exists() || await file.length() > _cacheLimit) {
        return null;
      }
      final checkedAt = (await file.lastModified()).toUtc();
      final record = _jsonObject(await file.readAsBytes());
      final envelope = _base64Field(record, 'manifest');
      final bytes = _base64Field(record, 'snapshot');
      final manifest = await _verifyManifest(envelope, list);
      final snapshot = await _parseSnapshot(bytes, list, manifest, checkedAt);
      return _CachedList(manifest, snapshot, _validEtag(record['etag']));
    } on FormatException {
      // A corrupt or unverifiable local cache can be replaced by a fresh list.
      return null;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<CommunitySnapshot> refresh(CommunityList list,
      {required bool Function() isCurrent}) {
    // A later profile can retry after an earlier refresh is cancelled. Keep
    // updates ordered so a stale response cannot overwrite a newer version.
    final previous = _pending[list] ?? Future<void>.value();
    final result = previous.then((_) => _refresh(list, isCurrent));
    final completion = result.then<void>((_) {}, onError: (Object _) {});
    _pending[list] = completion;
    return result;
  }

  Future<CommunitySnapshot> _refresh(
      CommunityList list, bool Function() isCurrent) async {
    _checkCurrent(isCurrent);
    final cache = await _load(list);
    _checkCurrent(isCurrent);
    final proxy = NetworkProxy.instance.config;
    bool current() =>
        isCurrent() &&
        !NetworkProxy.instance.isChanging &&
        identical(proxy, NetworkProxy.instance.config);
    _checkCurrent(current);
    final client = _createClient();
    final basePath = '/v1/${list.name}';
    try {
      final envelope = await _get(
        client,
        Uri.https(_host, '$basePath/manifest.json'),
        _manifestLimit,
        current,
        etag: cache?.etag,
      ).timeout(_timeout);
      _checkCurrent(current);
      if (envelope == null && cache != null) {
        return await _recordCheck(list, cache.snapshot, current);
      }
      if (envelope == null) throw const FormatException('Missing manifest.');
      final manifest = await _verifyManifest(envelope.bytes, list);
      if (cache != null) {
        if (manifest.version < cache.manifest.version ||
            (manifest.version == cache.manifest.version &&
                manifest.hash != cache.manifest.hash)) {
          throw const FormatException('Unexpected list version.');
        }
        if (manifest.version == cache.manifest.version) {
          return await _recordCheck(list, cache.snapshot, current);
        }
      }
      final content = await _get(
        client,
        Uri.https(_host, '$basePath/snapshot/${manifest.version}.json'),
        manifest.size,
        current,
      ).timeout(_timeout);
      if (content == null) throw const FormatException('Missing snapshot.');
      final snapshot = await _parseSnapshot(
          content.bytes, list, manifest, DateTime.now().toUtc());
      _checkCurrent(current);
      final file = await _file(list);
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.${const Uuid().v4()}.tmp');
      try {
        _checkCurrent(current);
        await temporary.writeAsString(
          jsonEncode({
            'manifest': base64Encode(envelope.bytes),
            'snapshot': base64Encode(content.bytes),
            'etag': envelope.etag,
          }),
          flush: true,
        );
        _checkCurrent(current);
        await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
      return snapshot;
    } finally {
      client.close();
    }
  }

  Future<CommunitySnapshot> _recordCheck(CommunityList list,
      CommunitySnapshot snapshot, bool Function() isCurrent) async {
    final file = await _file(list);
    _checkCurrent(isCurrent);
    final checkedAt = DateTime.now().toUtc();
    // A successful conditional check advances the refresh interval without
    // rewriting the signed manifest, snapshot or cached validators.
    await file.setLastModified(checkedAt);
    return CommunitySnapshot(
      version: snapshot.version,
      generatedAt: snapshot.generatedAt,
      blockIds: snapshot.blockIds,
      blockHandles: snapshot.blockHandles,
      warnIds: snapshot.warnIds,
      warnHandles: snapshot.warnHandles,
      checkedAt: checkedAt,
    );
  }

  Future<_Manifest> _verifyManifest(Uint8List body, CommunityList list) async {
    if (body.length > _manifestLimit) {
      throw const FormatException('List manifest is too large.');
    }
    final envelope = _jsonObject(body);
    final key = _signingKeys[envelope['key_id']];
    final payload = _base64Field(envelope, 'payload');
    final signed = _base64Field(envelope, 'sig');
    if (key == null ||
        signed.length != 64 ||
        !await Ed25519().verify(
          payload,
          signature: Signature(signed,
              publicKey: SimplePublicKey(base64Decode(key),
                  type: KeyPairType.ed25519)),
        )) {
      throw const FormatException('Invalid list signature.');
    }
    final manifest = _jsonObject(payload);
    final version = manifest['version'];
    final timestamp = manifest['generated_at'];
    final generatedAt =
        timestamp is String ? DateTime.tryParse(timestamp) : null;
    final snapshot = _asObject(manifest['snapshot']);
    final size = snapshot['bytes'];
    final hash = snapshot['sha256'];
    if (manifest['schema'] != 1 ||
        manifest['list'] != list.name ||
        version is! int ||
        version < 1 ||
        generatedAt == null ||
        !generatedAt.isUtc ||
        snapshot['path'] != 'snapshot/$version.json' ||
        size is! int ||
        size < 1 ||
        size > _snapshotLimit ||
        hash is! String ||
        !_sha256Hex.hasMatch(hash)) {
      throw const FormatException('Invalid list manifest.');
    }
    final counts = _asObject(manifest['counts']);
    int count(String name) {
      final size = counts[name];
      if (size is! int || size < 0 || size > 250000) {
        throw const FormatException('Invalid list count.');
      }
      return size;
    }

    return _Manifest(version, generatedAt, size, hash, count('block_ids'),
        count('block_handles'), count('warn_ids'), count('warn_handles'));
  }
}

http.Client _createListHttpClient() => IOClient(ReloadableHttpClient(() {
      final client = createDirectHttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..userAgent = 'Videre';
      NetworkProxy.instance.configureClient(client,
          requireValidCertificate: true,
          validateDestination: _validateDestination);
      return client;
    }));

void _validateDestination(Uri uri) {
  if (uri.origin != 'https://$_host' ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException('Invalid list origin.');
  }
}

void _checkCurrent(bool Function() isCurrent) {
  if (!isCurrent()) throw StateError('List refresh was cancelled.');
}

String? _validEtag(Object? value) =>
    value is String && _etagFormat.hasMatch(value) ? value : null;

Future<({Uint8List bytes, String? etag})?> _get(
    http.Client client, Uri uri, int limit, bool Function() isCurrent,
    {String? etag}) async {
  _checkCurrent(isCurrent);
  _validateDestination(uri);
  final request = http.Request('GET', uri)
    ..followRedirects = false
    ..headers['accept'] = 'application/json';
  if (etag != null) request.headers['if-none-match'] = etag;
  final response = await client.send(request);
  if (response.statusCode != HttpStatus.ok ||
      (response.contentLength ?? 0) > limit ||
      !isCurrent()) {
    await response.stream.listen(null).cancel();
    _checkCurrent(isCurrent);
    if (response.statusCode == HttpStatus.notModified && etag != null) {
      return null;
    }
    throw const FormatException('List response was unavailable or too large.');
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response.stream) {
    _checkCurrent(isCurrent);
    if (bytes.length + chunk.length > limit) {
      throw const FormatException('List response is too large.');
    }
    bytes.add(chunk);
  }
  return (bytes: bytes.takeBytes(), etag: _validEtag(response.headers['etag']));
}

Map<String, dynamic> _jsonObject(List<int> bytes) =>
    _asObject(jsonDecode(utf8.decode(bytes)));

Map<String, dynamic> _asObject(Object? value) {
  if (value is Map<String, dynamic>) return value;
  throw const FormatException('Expected a JSON object.');
}

Uint8List _base64Field(Map<String, dynamic> json, String name) {
  final value = json[name];
  if (value is! String) throw const FormatException('Invalid list encoding.');
  return base64Decode(value);
}

class _Manifest {
  final int version;
  final DateTime generatedAt;
  final int size;
  final String hash;
  final int blockIds, blockHandles, warnIds, warnHandles;

  const _Manifest(this.version, this.generatedAt, this.size, this.hash,
      this.blockIds, this.blockHandles, this.warnIds, this.warnHandles);
}

class _CachedList {
  final _Manifest manifest;
  final CommunitySnapshot snapshot;
  final String? etag;

  const _CachedList(this.manifest, this.snapshot, this.etag);
}

Future<CommunitySnapshot> _parseSnapshot(Uint8List bytes, CommunityList list,
        _Manifest manifest, DateTime checkedAt) =>
    compute(_decodeSnapshot, (bytes, list, manifest, checkedAt));

CommunitySnapshot _decodeSnapshot(
    (Uint8List, CommunityList, _Manifest, DateTime) input) {
  final (bytes, list, manifest, checkedAt) = input;
  if (bytes.length != manifest.size ||
      sha256.convert(bytes).toString() != manifest.hash) {
    throw const FormatException('List snapshot does not match its manifest.');
  }
  final data = _jsonObject(bytes);
  if (data['schema'] != 1 ||
      data['list'] != list.name ||
      data['version'] != manifest.version) {
    throw const FormatException('Invalid list snapshot.');
  }
  final block = _asObject(data['block']);
  final warn = _asObject(data['warn']);
  final blockIds =
      _entries(block['ids'], manifest.blockIds, normalizeChannelId);
  final warnIds = _entries(warn['ids'], manifest.warnIds, normalizeChannelId);
  final blockHandles =
      _entries(block['handles'], manifest.blockHandles, normalizeChannelHandle);
  final warnHandles =
      _entries(warn['handles'], manifest.warnHandles, normalizeChannelHandle);
  if ((list == CommunityList.aimusic &&
          (blockHandles.isNotEmpty ||
              warnHandles.isNotEmpty ||
              warnIds.isNotEmpty)) ||
      warnIds.any(blockIds.contains) ||
      warnHandles.any(blockHandles.contains)) {
    throw const FormatException('Invalid list tiers.');
  }
  return CommunitySnapshot(
    version: manifest.version,
    generatedAt: manifest.generatedAt,
    blockIds: blockIds,
    blockHandles: blockHandles,
    warnIds: warnIds,
    warnHandles: warnHandles,
    checkedAt: checkedAt,
  );
}

Set<String> _entries(
    Object? value, int count, String? Function(String?) normalize) {
  if (value is! List || value.length != count) {
    throw const FormatException('List count does not match its manifest.');
  }
  final entries = <String>{};
  for (final entry in value) {
    if (entry is! String || normalize(entry) != entry || !entries.add(entry)) {
      throw const FormatException('Invalid or duplicate list entry.');
    }
  }
  return entries;
}
