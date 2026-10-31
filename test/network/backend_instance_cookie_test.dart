import 'dart:convert';

import 'package:clipious/globals.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/services/backend_discovery.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Minimal public selector excerpts, not a list of currently healthy backends.
// Each fixture deliberately retains four choices so exhausting two alternatives
// cannot pass merely because there are no remaining advertised choices.
// NerdVPN source: 64d0cd413c3abd608fadc49cc3eaeada198293e3,
// patches/invidious/0002-companion-backend-selector.patch at git.nerdvpn.de.
// PREFS protocol: Fijxu/invidious 022021b39ac4fbe7470fe50867abb60e48ccd363
// and MiningTcup/invidious 5dd6c49a33bbbdf24d768420a922ab640221bf25,
// src/invidious/routes/backend_switcher.cr and src/invidious/user/cookies.cr.
// Nadeko, ChocolateMoo and MiningTcup excerpts: fresh anonymous 2026-10-30
// snapshots sanitized at build/backend-cookie-audit/<host>-selector.html.
// The first four choices are retained so tests do not depend on untracked build
// output. NerdVPN was unreachable during this audit; its fixture is explicitly
// derived from the prior verified source above, not a fresh live snapshot.
// These tests prove client requests, not which backend a live server executes.
class _InstanceFixture {
  final String name;
  final String origin;
  final String html;
  final List<BackendOption> options;
  final bool usesPreferences;

  const _InstanceFixture(this.name, this.origin, this.html, this.options,
      {this.usesPreferences = true});
}

const _instances = [
  _InstanceFixture(
    'NerdVPN',
    'https://invidious.nerdvpn.de',
    '''<title>Invidious</title><div class="backend-selector">
      <a href="/switchbackend?backend_id=0&amp;referer=%2F">1 - Prôtos 1 <span class="backend-status">❚</span></a>
      <a href="/switchbackend?backend_id=1&amp;referer=%2F">2 - Prôtos 2 <span class="backend-status">❚</span></a>
      <a href="/switchbackend?backend_id=2&amp;referer=%2F">3 - Prôtos 3 <span class="backend-status">❚</span></a>
      <a href="/switchbackend?backend_id=3&amp;referer=%2F">4 - Deúteros 1 <span class="backend-status">❚</span></a>
    </div>''',
    [
      BackendOption('0', '1 - Prôtos 1'),
      BackendOption('1', '2 - Prôtos 2'),
      BackendOption('2', '3 - Prôtos 3'),
      BackendOption('3', '4 - Deúteros 1'),
    ],
    usesPreferences: false,
  ),
  _InstanceFixture(
    'Nadeko',
    'https://inv.nadeko.net',
    '''<title>Invidious</title>
      <a href="/switchbackend?companion_id=0&amp;referer=%2Ffeed%2Fpopular">B1 (CL) ❚</a>
      <a href="/switchbackend?companion_id=1&amp;referer=%2Ffeed%2Fpopular">B2 (US) ❚</a>
      <a href="/switchbackend?companion_id=2&amp;referer=%2Ffeed%2Fpopular">B3 (US) ❚</a>
      <a href="/switchbackend?companion_id=3&amp;referer=%2Ffeed%2Fpopular">B4 (US) ❚</a>''',
    [
      BackendOption('0', 'B1 (CL)'),
      BackendOption('1', 'B2 (US)'),
      BackendOption('2', 'B3 (US)'),
      BackendOption('3', 'B4 (US)'),
    ],
  ),
  _InstanceFixture(
    'ChocolateMoo',
    'https://yt.chocolatemoo53.com',
    '''<title>Invidious</title>
      <a href="/switchbackend?companion_id=0&amp;referer=%2F" style="text-decoration-line: underline; display: inline-block;">Backend1 ❚</a>
      <a href="/switchbackend?companion_id=1&amp;referer=%2F" style=" display: inline-block;">Backend2 ❚</a>
      <a href="/switchbackend?companion_id=2&amp;referer=%2F" style=" display: inline-block;">Backend3 ❚</a>
      <a href="/switchbackend?companion_id=3&amp;referer=%2F" style=" display: inline-block;">Backend4 ❚</a>''',
    [
      BackendOption('0', 'Backend1'),
      BackendOption('1', 'Backend2'),
      BackendOption('2', 'Backend3'),
      BackendOption('3', 'Backend4'),
    ],
  ),
  _InstanceFixture(
    'MiningTcup',
    'https://inv.miningtcup.me',
    '''<title>Invidious</title>
      <a href="/switchbackend?companion_id=0&amp;referer=%2F" style="text-decoration-line: underline; display: inline-block;">B1 US/Cal-VPN1 ❚</a>
      <a href="/switchbackend?companion_id=1&amp;referer=%2F" style=" display: inline-block;">B2 US/Cal-VPN1 ❚</a>
      <a href="/switchbackend?companion_id=2&amp;referer=%2F" style=" display: inline-block;">B3 US/Cal-VPN2 ❚</a>
      <a href="/switchbackend?companion_id=3&amp;referer=%2F" style=" display: inline-block;">B4 US/Cal-VPN2 ❚</a>''',
    [
      BackendOption('0', 'B1 US/Cal-VPN1'),
      BackendOption('1', 'B2 US/Cal-VPN1'),
      BackendOption('2', 'B3 US/Cal-VPN2'),
      BackendOption('3', 'B4 US/Cal-VPN2'),
    ],
  ),
];

Map<String, Object> _preferences(_InstanceFixture fixture) => {
      'locale': 'es',
      'captions': ['two words + é'],
      'dark_mode': 'dark',
      'fixture': fixture.name,
    };

String _expectedCookie(_InstanceFixture fixture, String? choice,
    {bool authenticated = false}) {
  final preferences = {
    ..._preferences(fixture),
    if (fixture.usesPreferences && choice != null)
      'current_companion': int.parse(choice),
  };
  return 'SID=${authenticated ? 'account' : 'custom'}-${fixture.name}; '
      'PREFS=${Uri.encodeQueryComponent(jsonEncode(preferences))}; '
      'unrelated=keep-${fixture.name}'
      '${!fixture.usesPreferences && choice != null ? '; COMPANION_ID=$choice' : ''}';
}

Map<String, String> _expectedHeaders(_InstanceFixture fixture, String? choice,
        {bool authenticated = false, bool token = false}) =>
    {
      'cookie': _expectedCookie(fixture, choice,
          authenticated: authenticated && !token),
      'x-instance': 'custom-${fixture.name}',
      'accept': 'application/json',
      if (token) 'authorization': 'Bearer token-${fixture.name}',
    };

Map<String, String> _normalizedHeaders(Map<String, String> headers) => {
      for (final header in headers.entries)
        header.key.toLowerCase(): header.value,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async => db = await SembastSqfDb.createInMemory());
  tearDown(() => db.close());

  for (var index = 0; index < _instances.length; index++) {
    final fixture = _instances[index];
    final foreign = _instances[(index + 1) % _instances.length];
    test('${fixture.name} discovery, saved cookie and bounded retry contract',
        () async {
      final requests = <http.Request>[];
      var metadataCalls = 0;
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url == Uri.parse('${fixture.origin}/')) {
          return http.Response(fixture.html, 200,
              headers: {'content-type': 'text/html; charset=utf-8'});
        }
        if (request.url.path == '/api/v1/videos/contract-video') {
          metadataCalls++;
          if (metadataCalls == 1) {
            return http.Response('{"error":"temporary failure"}', 503,
                headers: {'content-type': 'application/json'});
          }
          return http.Response(
              '{"videoId":"contract-video","title":"Test",'
              '"formatStreams":[],"adaptiveFormats":[],"captions":[]}',
              200,
              headers: {'content-type': 'application/json'});
        }
        if (request.url.path == urlGetSubscriptions) {
          return http.Response('[]', 200,
              headers: {'content-type': 'application/json'});
        }
        if (request.url.path == '/companion/fixture-media') {
          return http.Response('media fixture', 200);
        }
        throw StateError('Unexpected fixture request');
      });
      addTearDown(client.close);
      final api = Service(httpClient: client);
      final original = Server(
        url: fixture.origin,
        sidCookie: 'SID=account-${fixture.name}',
        customHeaders: {
          'cOoKiE': _expectedCookie(fixture, null),
          'X-Instance': 'custom-${fixture.name}',
        },
      );

      final discovered = await BackendDiscovery(client).discover(original);
      expect(discovered.options, fixture.options);
      expect(discovered.cookieName,
          fixture.usesPreferences ? 'PREFS' : 'COMPANION_ID');
      expect(discovered.preferenceField,
          fixture.usesPreferences ? 'current_companion' : null);
      expect(discovered.automaticFallback, isTrue);
      expect(requests, hasLength(1));
      expect(_normalizedHeaders(requests.single.headers), {
        'cookie': _expectedCookie(fixture, null),
        'x-instance': 'custom-${fixture.name}',
        'accept': 'text/html',
      });
      expect(requests.single.followRedirects, isFalse);

      final selector = discovered;
      await db.upsertServer(selector.withSelection(original, '2'));
      final saved = await db.getCurrentlySelectedServer();
      expect(saved.backendSelector, selector);
      expect(selector.selectedValue(saved), '2');
      expect(saved.customHeaders['Cookie'], _expectedCookie(fixture, '2'));

      final attempts = <String>[];
      final video = await api.getVideo('contract-video',
          onBackendRequest: (attempt) => attempts.add(attempt.label));
      final firstSession = video.backendPlayback!;
      expect(firstSession.retryIndex, 1);
      expect(selector.selectedValue(firstSession.server), '0');
      final retryNotices = <String>[];
      final recovered = await api.retryVideoBackend(video,
          isCurrent: () => true,
          onRetry: (attempt) => retryNotices.add(attempt.label));
      final recoveredSession = recovered!.backendPlayback!;
      expect(recoveredSession.retryIndex, 2);
      expect(selector.selectedValue(recoveredSession.server), '1');
      expect(attempts, [fixture.options[2].label, fixture.options[0].label]);
      expect(retryNotices, [fixture.options[1].label]);
      expect(await api.retryVideoBackend(recovered, isCurrent: () => true),
          isNull);
      expect(metadataCalls, 3);
      expect(recoveredSession.canRetry, isFalse);
      final metadataRequests = requests
          .where(
              (request) => request.url.path == '/api/v1/videos/contract-video')
          .toList();
      expect(metadataRequests.map((request) => request.url.origin),
          everyElement(fixture.origin));
      expect(
          metadataRequests
              .map((request) => _normalizedHeaders(request.headers)),
          ['2', '0', '1'].map((choice) => _expectedHeaders(fixture, choice)));

      // Authenticated requests on the temporary route must merge only the SID;
      // a bearer token must coexist with routing and custom cookies as well.
      for (final token in [false, true]) {
        final authenticatedServer = recoveredSession.server
            .copyWith(authToken: token ? 'token-${fixture.name}' : null);
        final request = await api.buildRequest(urlGetSubscriptions,
            authenticated: true, serverOverride: authenticatedServer);
        await client.get(request.uri, headers: request.headers);
        expect(_normalizedHeaders(requests.last.headers),
            _expectedHeaders(fixture, '1', authenticated: true, token: token));
      }

      // The normal account endpoint still uses the preferred saved route.
      await api.getSubscriptions();
      expect(_normalizedHeaders(requests.last.headers),
          _expectedHeaders(fixture, '2', authenticated: true));
      expect(await db.getCurrentlySelectedServer(), saved);
      expect(db.getServer(fixture.origin), saved);

      final sameOriginMedia = '${fixture.origin}/companion/fixture-media';
      await client.get(Uri.parse(sameOriginMedia),
          headers: recoveredSession.server.headersForUrl(sameOriginMedia));
      expect(_normalizedHeaders(requests.last.headers), {
        'cookie': _expectedCookie(fixture, '1'),
        'x-instance': 'custom-${fixture.name}',
      });
      final offOriginMedia = '${foreign.origin}/companion/fixture-media';
      expect(recoveredSession.server.headersForUrl(offOriginMedia), isNull);
      await client.get(Uri.parse(offOriginMedia),
          headers: recoveredSession.server.headersForUrl(offOriginMedia));
      expect(requests.last.headers, isEmpty);
      for (final otherOrigin in [
        fixture.origin.replaceFirst('https:', 'http:'),
        '${fixture.origin}:8443',
        '${fixture.origin}.unrelated.example',
      ]) {
        expect(recoveredSession.server.headersForUrl('$otherOrigin/media'),
            isNull);
      }
      final serialized = jsonEncode(recovered.toJson());
      expect(serialized, isNot(contains('backendPlayback')));
      expect(serialized, isNot(contains('account-${fixture.name}')));
      expect(serialized, isNot(contains('custom-${fixture.name}')));
    });
  }
}
