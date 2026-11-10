import 'dart:convert';
import 'dart:io';

import 'package:clipious/globals.dart';
import 'package:clipious/http_overrides.dart';
import 'package:clipious/music/services/invidious_music_catalog_service.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _LiveNetworkBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

Uri _instanceUri(String value) {
  final uri = Uri.tryParse(value.trim());
  final host = uri?.host.toLowerCase().replaceFirst(RegExp(r'\.+$'), '') ?? '';
  final officialHost = const [
        'youtube.com',
        'youtu.be',
        'youtube-nocookie.com',
        'google.com',
        'g.co',
        'googleapis.com',
        'googlevideo.com',
        'googleusercontent.com',
        'gstatic.com',
        'ytimg.com',
        'ggpht.com',
      ].any((domain) => host == domain || host.endsWith('.$domain')) ||
      RegExp(r'(^|\.)(google|youtube)\.[a-z.]+$').hasMatch(host);
  if (uri == null ||
      !const {'http', 'https'}.contains(uri.scheme) ||
      host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      officialHost) {
    throw const FormatException(
        'VIDERE_LIVE_MUSIC_INSTANCE must be an HTTP(S) Invidious address '
        'without credentials, query parameters, or a fragment.');
  }
  return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''));
}

/// Service's redirect wrapper sends each hop through this guard. A server
/// redirect cannot silently turn this live check into a Google catalog request.
class _OriginOnlyClient extends http.BaseClient {
  final Uri instance;
  final http.Client _inner;
  int requests = 0;

  _OriginOnlyClient(this.instance, this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.origin != instance.origin ||
        request.url.userInfo.isNotEmpty) {
      throw StateError('Music request escaped the selected Invidious origin.');
    }
    requests++;
    return _inner.send(request).timeout(const Duration(seconds: 60));
  }

  @override
  void close() => _inner.close();
}

// Live requests require both VIDERE_LIVE_MUSIC_TEST=true and an explicit
// VIDERE_LIVE_MUSIC_INSTANCE=https://your-invidious-instance (no default host).
// The instance must already allow this test client API access. No credentials
// are accepted in defines. This checks metadata routes, not native playback.
// Optional VIDERE_LIVE_MUSIC_SOCKS_PORT=9050 and VIDERE_LIVE_MUSIC_SOCKS_HOST
// exercise the configured transport; VIDERE_LIVE_MUSIC_VERIFY_TOR=true adds
// one explicit check.torproject.org probe through that SOCKS connection.
void main() {
  _LiveNetworkBinding();
  const enabled = bool.fromEnvironment('VIDERE_LIVE_MUSIC_TEST');
  const instanceAddress = String.fromEnvironment('VIDERE_LIVE_MUSIC_INSTANCE');
  const port = int.fromEnvironment('VIDERE_LIVE_MUSIC_SOCKS_PORT');
  const verifyTor = bool.fromEnvironment('VIDERE_LIVE_MUSIC_VERIFY_TOR');
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const sessions = MethodChannel('videre/gateway_sessions');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final previousOverrides = HttpOverrides.current;
  final previousService = service;
  SembastSqfDb? database;
  Directory? documents;
  _OriginOnlyClient? transport;
  late InvidiousMusicCatalogService catalog;

  setUpAll(() async {
    if (!enabled) return;
    // Validate before creating a client or making even an optional Tor probe.
    final instance = _instanceUri(instanceAddress);
    documents = await Directory.systemTemp.createTemp('videre-live-music-');
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documents!.path);
    messenger.setMockMethodCallHandler(
        sessions,
        (call) async => call.method == 'resolve'
            ? {'enabled': false, 'needsSignIn': false}
            : false);
    db = database = await SembastSqfDb.createInMemory();
    await db.upsertServer(Server(url: instance.toString()));
    await db.saveSetting(SettingsValue(dearrowSettingName, 'false'));
    HttpOverrides.global = MyHttpOverrides();
    final config = SocksProxyConfig(
        enabled: port != 0,
        host: const String.fromEnvironment('VIDERE_LIVE_MUSIC_SOCKS_HOST',
            defaultValue: '127.0.0.1'),
        port: port == 0 ? 9050 : port);
    await NetworkProxy.instance
        .initialize(saved: jsonEncode(config.toJson()), configureNative: false);
    transport = _OriginOnlyClient(instance, http.Client());
    service = Service(httpClient: transport);
    catalog = InvidiousMusicCatalogService(api: service);
    if (verifyTor) {
      expect(config.enabled, isTrue,
          reason: 'Tor verification requires an explicit SOCKS endpoint.');
      final probe = _OriginOnlyClient(
          Uri.parse('https://check.torproject.org'), http.Client());
      try {
        final request = http.Request(
            'GET', Uri.parse('https://check.torproject.org/api/ip'))
          ..followRedirects = false;
        final response =
            await http.Response.fromStream(await probe.send(request))
                .timeout(const Duration(seconds: 60));
        expect(response.statusCode, 200);
        expect(jsonDecode(response.body)['IsTor'], isTrue);
      } finally {
        probe.close();
      }
    }
  });

  tearDownAll(() async {
    if (!enabled) return;
    transport?.close();
    service = previousService;
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
    HttpOverrides.global = previousOverrides;
    messenger.setMockMethodCallHandler(pathProvider, null);
    messenger.setMockMethodCallHandler(sessions, null);
    await database?.close();
    if (documents != null) await documents!.delete(recursive: true);
  });

  test('live instance configuration requires an explicit non-Google origin',
      () {
    for (final invalid in [
      '',
      'file:///tmp/catalog',
      'https://fixture:password@invidious.example',
      'https://invidious.example?key=fixture',
      'https://invidious.example#fragment',
      'https://music.youtube.com',
      'https://music.youtube.com.',
      'https://youtubei.googleapis.com',
      'https://www.google.de',
      'https://www.youtube.co.uk',
      'https://lh3.googleusercontent.com',
    ]) {
      expect(() => _instanceUri(invalid), throwsFormatException);
    }
    expect(_instanceUri('https://invidious.example/').toString(),
        'https://invidious.example');
    expect(_instanceUri('http://127.0.0.1:3000').port, 3000);
  });

  test('live request guard blocks off-instance redirects before transport',
      () async {
    var sent = 0;
    final guarded = _OriginOnlyClient(Uri.parse('https://invidious.example'),
        MockClient((request) async {
      sent++;
      return http.Response('', 302,
          headers: {'location': 'https://music.youtube.com/'},
          request: request);
    }));
    final client = Service(httpClient: guarded).httpClient;
    addTearDown(client.close);
    await expectLater(
        client
            .get(Uri.parse('https://invidious.example/api/v1/search?q=music')),
        throwsStateError);
    expect(sent, 1);
  });

  for (final useMediaProxy in [false, true]) {
    group('Invidious music with legacy proxy preference=$useMediaProxy', () {
      setUp(() async {
        if (!enabled) return;
        await db.saveSetting(
            SettingsValue(useProxySettingName, useMediaProxy.toString()));
        // Each scenario observes fresh requests rather than a prior cache hit.
        service = Service(httpClient: transport);
        catalog = InvidiousMusicCatalogService(api: service);
      });

      test('trending music uses the selected instance', () async {
        final before = transport!.requests;
        final songs = await catalog.getTrendingSongs();
        expect(songs, isNotEmpty);
        expect(songs.every((song) => song.title.isNotEmpty), isTrue);
        expect(transport!.requests, greaterThan(before));
      }, skip: !enabled, timeout: const Timeout(Duration(minutes: 2)));

      test('search, recording, artist channel and playlist use the instance',
          () async {
        final before = transport!.requests;
        final songs = await catalog.searchSongs('Daft Punk Get Lucky');
        expect(songs, isNotEmpty);
        final song = await catalog.getSong(songs.first.videoId);
        expect(song.videoId, songs.first.videoId);
        final artists = await catalog.searchArtists('Daft Punk');
        expect(artists, isNotEmpty);
        final artist = await catalog.getArtist(artists.first.id);
        expect(artist.artist.id, artists.first.id);
        expect(artist.songs, isNotEmpty);
        final playlists = await catalog.searchPlaylists('Daft Punk');
        expect(playlists, isNotEmpty);
        final collection = await catalog
            .getPlaylist('OLAK5uy_kNhM2yaBTOVwrcZJepB1C9P3-n5_Sfy5c');
        expect(collection.tracks, isNotEmpty);
        expect(transport!.requests, greaterThan(before));
        // Artwork routing has offline coverage; no original artwork URL is
        // fetched here, and no media stream request is made by this smoke test.
      }, skip: !enabled, timeout: const Timeout(Duration(minutes: 5)));
    });
  }
}
