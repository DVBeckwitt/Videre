import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/services/backend_discovery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

const _server = Server(url: 'https://invidious.nerdvpn.de');
const _labels = [
  '1 - Prôtos 1',
  '2 - Prôtos 2',
  '3 - Prôtos 3',
  '4 - Deúteros 1',
  '5 - Deúteros 2',
  '6 - Deúteros 3',
  '7 - Trítos 1',
  '8 - Trítos 2',
];

// Public selector structure captured from NerdVPN on Android, 2026-10-30.
String _selector() => '<div id="backend-selector">'
    '${List.generate(_labels.length, (index) => '''
      <a class="backend backend-healthy backend_number_$index"
         href="/switchbackend?backend_id=$index&amp;referer=%2F">
        ${_labels[index]} <span class="backend-status">❚</span>
      </a>''').join()}'
    '<span class="backend backend-unhealthy">Unavailable backend</span>'
    '</div>';

void main() {
  late BackendDiscovery discovery;

  setUp(() {
    final client = MockClient((_) async {
      fail('Browser markup import must never make HTTP requests');
    });
    addTearDown(client.close);
    discovery = BackendDiscovery(client);
  });

  Future<BackendSelector> read({
    Server server = _server,
    String page = 'https://invidious.nerdvpn.de/',
    String? source,
  }) =>
      discovery.discoverBrowserPage(server,
          pageUri: Uri.parse(page), source: source ?? _selector());

  test('imports all current advertised choices with known routing cookie',
      () async {
    final result = await read();
    expect(result.cookieName, 'COMPANION_ID');
    expect(result.preferenceField, isNull);
    expect(result.options.map((option) => option.value).toList(),
        ['0', '1', '2', '3', '4', '5', '6', '7']);
    expect(result.options.map((option) => option.label).toList(), _labels);
    expect(result.automaticFallback, isTrue);
  });

  test('preserves automatic setting and never imports browser selection',
      () async {
    final previous = BackendSelector(
        'old-routing-cookie',
        const [
          BackendOption('0', 'Old first'),
          BackendOption('5', 'Old sixth'),
        ],
        automaticFallback: true);
    final server = _server.copyWith(
      backendSelector: previous,
      sidCookie: 'SID=saved-login',
      authToken: 'saved-api-token',
      customHeaders: {
        'Cookie': 'COMPANION_ID=5; PREFS=kept',
        'X-Custom': 'kept'
      },
    );
    final result = await read(
      server: server,
      source: _selector()
          .replaceFirst('backend-healthy', 'backend-healthy backend-selected'),
    );
    expect(result.cookieName, 'COMPANION_ID');
    expect(result.automaticFallback, isTrue);
    expect(result.selectedValue(server), '5');
    expect(server.sidCookie, 'SID=saved-login');
    expect(server.authToken, 'saved-api-token');
    expect(server.customHeaders,
        {'Cookie': 'COMPANION_ID=5; PREFS=kept', 'X-Custom': 'kept'});
  });

  test('allows public pages only on the exact configured HTTPS origin',
      () async {
    expect(
        (await read(page: 'https://invidious.nerdvpn.de/feed/popular')).options,
        hasLength(8));
    const alias = Server(url: 'https://www.invidious.nerdvpn.de/');
    expect(
        (await read(server: alias, page: 'https://www.invidious.nerdvpn.de/'))
            .options,
        hasLength(8));
  });

  for (final address in [
    'http://invidious.nerdvpn.de/',
    'https://invidious.nerdvpn.de:8443/',
    'https://elsewhere.example/',
    'https://invidious.nerdvpn.de.attacker.example/',
    'https://user@invidious.nerdvpn.de/',
    'https://invidious.nerdvpn.de/#fragment',
    'https://invidious.nerdvpn.de/?query=yes',
    'https://invidious.nerdvpn.de/not-the-root',
  ]) {
    test('rejects unsupported configured origin $address', () async {
      await expectLater(read(server: Server(url: address), page: address),
          throwsA(isA<BackendDiscoveryException>()));
    });
  }

  for (final page in [
    'http://invidious.nerdvpn.de/',
    'https://invidious.nerdvpn.de:8443/',
    'https://www.invidious.nerdvpn.de/',
    'https://elsewhere.example/',
    'https://user@invidious.nerdvpn.de/',
    'https://invidious.nerdvpn.de/#fragment',
    'https://invidious.nerdvpn.de/switchbackend?backend_id=0',
  ]) {
    test('rejects off-origin or unsafe returned page $page', () async {
      await expectLater(
          read(page: page), throwsA(isA<BackendDiscoveryException>()));
    });
  }

  test('requires the verified NerdVPN selector protocol', () async {
    await expectLater(
        read(source: _selector().replaceAll('backend_id=', 'companion_id=')),
        throwsA(isA<BackendDiscoveryException>()));
  });

  test('rejects a browser check or a page without choices', () async {
    await expectLater(
        read(
            source:
                '<title>Browser check</title><div>Verify you are human</div>'),
        throwsA(isA<BackendDiscoveryException>()));
    await expectLater(read(source: '<title>Invidious</title>'),
        throwsA(isA<BackendDiscoveryUnsupported>()));
  });

  test('enforces byte limit including multibyte text', () async {
    final oversized = List.filled(1024 * 1024, 'é').join() + _selector();
    await expectLater(
        read(source: oversized), throwsA(isA<BackendDiscoveryException>()));
  });

  test('foreign and disabled entries never become fallback candidates',
      () async {
    final source = '${_selector()}'
        '<a href="https://elsewhere.example/switchbackend?backend_id=88">Foreign</a>'
        '<span data-href="/switchbackend?backend_id=89">Disabled</span>';
    final result = await read(source: source);
    expect(result.options, hasLength(8));
    expect(result.labelFor('88'), isNull);
    expect(result.labelFor('89'), isNull);
  });
}
