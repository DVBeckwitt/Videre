import 'dart:async';
import 'dart:convert';

import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/services/backend_discovery.dart';
import 'package:clipious/utils/request_cookies.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _server = Server(url: 'https://instance.example');
const _bodyLimit = 2 * 1024 * 1024;

String _page(String body) =>
    '<!doctype html><html><head><title>Invidious</title></head>'
    '<body><a href="/">Invidious</a>$body</body></html>';

String _choices(String parameter, [List<String> values = const ['0', '5']]) =>
    _page(values
        .map((value) => '<a href="/switchbackend?$parameter=$value'
            '&amp;referer=%2Ffeed%2Fpopular">Backend $value</a>')
        .join());

http.Response _html(String body) => http.Response(body, 200,
    headers: {'content-type': 'text/html; charset=utf-8'});

String? _header(http.BaseRequest request, String name) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
  }
  return null;
}

class _StreamClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;

  _StreamClient(this.respond);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request);
}

void main() {
  group('companion selector discovery', () {
    test('reads current Nadeko markup without probing or importing credentials',
        () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return _html(_page('''
          <div>Switch backend:
            <a href="/switchbackend?companion_id=0&amp;referer=%2Ffeed%2Fpopular"
               style="display: inline-block;"> B1 (CL)
              <span style="color: #ddc338;">❚</span></a> |
            <a href="/switchbackend?companion_id=5&amp;referer=%2Ffeed%2Fpopular"
               style="text-decoration-line: underline; display: inline-block;">
              B6   (US) <span style="color: #42ae3c;">❚</span></a>
          </div>'''));
      });
      addTearDown(client.close);
      final original = _server.copyWith(
        authToken: 'saved-token-must-not-be-added',
        sidCookie: 'SID=saved-session-must-not-be-added',
        customHeaders: {'X-Instance': 'configured'},
      );

      final selector = await BackendDiscovery(client).discover(original);

      expect(selector.cookieName, 'PREFS');
      expect(selector.preferenceField, 'current_companion');
      expect(selector.options, const [
        BackendOption('0', 'B1 (CL)'),
        BackendOption('5', 'B6 (US)'),
      ]);
      expect(selector.automaticFallback, isFalse);
      expect(requests, hasLength(1));
      expect(requests.single.url, Uri.parse('${_server.url}/'));
      expect(_header(requests.single, 'X-Instance'), 'configured');
      expect(_header(requests.single, 'Authorization'), isNull);
      expect(_header(requests.single, 'Cookie'), isNull);
      expect(requests.single.followRedirects, isFalse);
    });

    test('discovered preferences selection preserves unrelated data', () async {
      final client = MockClient((_) async => _html(_choices('companion_id')));
      addTearDown(client.close);
      final existing = {
        'dark_mode': 'dark',
        'captions': ['two words + é'],
        'current_companion': 0,
      };
      final original = _server.copyWith(customHeaders: {
        'Cookie': 'PREFS=${Uri.encodeQueryComponent(jsonEncode(existing))}; '
            'SID=manual-session; unrelated=kept',
        'X-Instance': 'kept',
      });
      final selector = await BackendDiscovery(client).discover(original);
      final selected = selector.withSelection(original, '5');
      final prefs = requestCookieValue(selected.customHeaders, 'PREFS')!;

      expect(jsonDecode(Uri.decodeQueryComponent(prefs)), {
        ...existing,
        'current_companion': 5,
      });
      expect(
          requestCookieValue(selected.customHeaders, 'SID'), 'manual-session');
      expect(requestCookieValue(selected.customHeaders, 'unrelated'), 'kept');
      expect(selected.customHeaders['X-Instance'], 'kept');
      expect(selector.selectedValue(original), '0');
      final automatic = selector.withSelection(selected, null);
      final reset = requestCookieValue(automatic.customHeaders, 'PREFS')!;
      expect(jsonDecode(Uri.decodeQueryComponent(reset)), {
        'dark_mode': 'dark',
        'captions': ['two words + é'],
      });
    });

    test('ignores duplicate and malformed IDs and unsafe candidate URLs',
        () async {
      final requested = <Uri>[];
      final client = MockClient((request) async {
        requested.add(request.url);
        return _html(_page('''
          <a href="/switchbackend?companion_id=0">First | ❚</a>
          <a href="/switchbackend?companion_id=0">Duplicate</a>
          <a href="/switchbackend?companion_id=5">Second</a>
          <a href="/switchbackend?companion_id=-1">Negative</a>
          <a href="/switchbackend?companion_id=01">Leading zero</a>
          <a href="/switchbackend?companion_id=1.0">Decimal</a>
          <a href="/switchbackend?companion_id=2147483648">Overflow</a>
          <a href="/switchbackend?companion_id=">Empty</a>
          <a href="/switchbackend?companion_id=words">Not numeric</a>
          <a href="https://external.example/switchbackend?companion_id=6">External</a>
          <a href="//external.example/switchbackend?companion_id=7">External</a>
          <a href="javascript:alert('companion_id=8')">Script</a>
        '''));
      });
      addTearDown(client.close);

      final selector = await BackendDiscovery(client).discover(_server);

      expect(selector.options, const [
        BackendOption('0', 'First'),
        BackendOption('5', 'Second'),
      ]);
      expect(requested, [Uri.parse('${_server.url}/')]);
    });

    test('accepts the 64-option limit including the largest canonical ID',
        () async {
      final ids = [for (var i = 0; i < 63; i++) '$i', '2147483647'];
      final client =
          MockClient((_) async => _html(_choices('companion_id', ids)));
      addTearDown(client.close);
      final selector = await BackendDiscovery(client).discover(_server);
      expect(selector.options, hasLength(64));
      expect(selector.options.last.value, '2147483647');
    });

    test('labels omit executable, hidden template and backend status contents',
        () async {
      final client = MockClient((_) async => _html(_page('''
        <a href="/switchbackend?companion_id=0">First
          <script>window.alert('not a label')</script>
          <style>.backend { color: red }</style>
          <template>Hidden template text</template>
          <span class="backend-status">Blocked</span> ❚</a>
        <a href="/switchbackend?companion_id=5">Second</a>
      ''')));
      addTearDown(client.close);

      final selector = await BackendDiscovery(client).discover(_server);

      expect(selector.options, const [
        BackendOption('0', 'First'),
        BackendOption('5', 'Second'),
      ]);
    });

    test('mixed selector protocols are rejected without probing either one',
        () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return _html(_page('''
          <a href="/switchbackend?companion_id=0">Companion one</a>
          <a href="/switchbackend?companion_id=5">Companion two</a>
          <a href="/switchbackend?backend_id=0">Backend one</a>
          <a href="/switchbackend?backend_id=5">Backend two</a>
        '''));
      });
      addTearDown(client.close);

      await expectLater(BackendDiscovery(client).discover(_server),
          throwsA(isA<BackendDiscoveryException>()));
      expect(requests, 1);
    });

    test('rejects more than 64 options instead of silently truncating',
        () async {
      final client = MockClient((_) async =>
          _html(_choices('companion_id', [for (var i = 0; i < 65; i++) '$i'])));
      addTearDown(client.close);
      await expectLater(BackendDiscovery(client).discover(_server),
          throwsA(isA<BackendDiscoveryException>()));
    });

    for (final body in [
      '<p>No selector is configured.</p>',
      '<a href="/switchbackend?companion_id=0">Only one</a>',
      '<a href="/switchbackend?companion_id=0">First</a>'
          '<a href="/switchbackend?companion_id=0">Duplicate</a>',
      '<a href="https://external.example/switchbackend?backend_id=0">External</a>',
    ]) {
      test(
          'valid Invidious page with fewer than two choices is unsupported: '
          '$body', () async {
        var requests = 0;
        final client = MockClient((_) async {
          requests++;
          return _html(_page(body));
        });
        addTearDown(client.close);
        await expectLater(BackendDiscovery(client).discover(_server),
            throwsA(isA<BackendDiscoveryUnsupported>()));
        expect(requests, 1);
      });
    }
  });

  group('plain backend cookie verification', () {
    test('uses two anonymous probes and preserves homepage custom headers',
        () async {
      final requests = <http.Request>[];
      final original = _server.copyWith(
        authToken: 'saved-token',
        sidCookie: 'SID=saved-session',
        customHeaders: {
          'Cookie': 'SID=manual-session; PREFS=manual-preferences',
          'Authorization': 'Bearer manual-token',
          'X-Api-Key': 'custom-key',
          'X-Custom-Token': 'custom-token',
        },
      );
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/') return _html(_choices('backend_id'));
        final id = request.url.queryParameters['backend_id']!;
        return http.Response('', 302, headers: {
          'location': '/',
          'set-cookie': 'routingcookie=$id; Path=/; HttpOnly; SameSite=Lax',
        });
      });
      addTearDown(client.close);

      final selector = await BackendDiscovery(client).discover(original);

      expect(selector.cookieName, 'routingcookie');
      expect(selector.preferenceField, isNull);
      expect(selector.options.map((option) => option.value), ['0', '5']);
      expect(requests, hasLength(3));
      for (final entry in original.customHeaders.entries) {
        expect(_header(requests.first, entry.key), entry.value);
      }
      expect(requests.first.headers.values, isNot(contains('saved-token')));
      expect(
          requests.first.headers.values, isNot(contains('SID=saved-session')));
      for (final request in requests.skip(1)) {
        expect(request.method, 'GET');
        expect(request.url.origin, _server.url);
        expect(request.url.path, '/switchbackend');
        expect(request.followRedirects, isFalse);
        expect(
            request.headers.keys.map((name) => name.toLowerCase()), ['accept']);
        expect(_header(request, 'Accept'), 'text/html');
      }
      expect(original.customHeaders['Cookie'], contains('SID=manual-session'));
    });

    test('retains Basic instance access but excludes all other custom headers',
        () async {
      final probes = <http.Request>[];
      final client = MockClient((request) async {
        if (request.url.path == '/') return _html(_choices('backend_id'));
        probes.add(request);
        return http.Response('', 302, headers: {
          'set-cookie':
              'ROUTE=${request.url.queryParameters['backend_id']}; Path=/',
        });
      });
      addTearDown(client.close);
      final server = _server.copyWith(customHeaders: {
        'authorization': 'Basic aW5zdGFuY2U6YWNjZXNz',
        'cookie': 'SID=do-not-send',
        'X-Secret': 'do-not-send',
        'Accept': 'application/json',
      });

      expect((await BackendDiscovery(client).discover(server)).cookieName,
          'ROUTE');
      expect(probes, hasLength(2));
      for (final request in probes) {
        expect(_header(request, 'Authorization'), 'Basic aW5zdGFuY2U6YWNjZXNz');
        expect(_header(request, 'Accept'), 'text/html');
        expect(request.headers, hasLength(2));
      }
    });

    test('a previously verified plain cookie name is reused without probing',
        () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return _html(_choices('backend_id'));
      });
      addTearDown(client.close);
      final server = _server.copyWith(
        backendSelector: BackendSelector('verified_route', const [
          BackendOption('0', 'Old label'),
          BackendOption('1', 'Removed backend'),
        ]),
      );

      final selector = await BackendDiscovery(client).discover(server);

      expect(selector.cookieName, 'verified_route');
      expect(selector.options.map((option) => option.value), ['0', '5']);
      expect(requests, 1);
    });

    test('official legacy NerdVPN host uses its known cookie without probing',
        () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return _html(_choices('backend_id'));
      });
      addTearDown(client.close);
      final selector = await BackendDiscovery(client)
          .discover(const Server(url: 'https://invidious.nerdvpn.de'));
      expect(selector.cookieName, 'COMPANION_ID');
      expect(requests, 1);
    });

    for (final url in [
      'http://nerdvpneaggggfdiurknszkbmhvjndks5z5k3g5yp4nhphflh3n3boad.onion',
      'http://invidious-nerdvpn.i2p/',
    ]) {
      test('official legacy alias retains its verified cookie: $url', () async {
        var requests = 0;
        final client = MockClient((_) async {
          requests++;
          return _html(_choices('backend_id'));
        });
        addTearDown(client.close);
        final selector =
            await BackendDiscovery(client).discover(Server(url: url));
        expect(selector.cookieName, 'COMPANION_ID');
        expect(requests, 1);
      });
    }

    for (final url in [
      'https://invidious.nerdvpn.de:8443',
      'https://invidious.nerdvpn.de/other-instance',
      'https://invidious.nerdvpn.de.other.example',
    ]) {
      test('different deployments require cookie verification: $url', () async {
        var requests = 0;
        final client = MockClient((request) async {
          requests++;
          if (request.url.path != '/switchbackend') {
            return _html(_choices('backend_id'));
          }
          return http.Response('', 302, headers: {
            'set-cookie':
                'custom_route=${request.url.queryParameters['backend_id']}; Path=/',
          });
        });
        addTearDown(client.close);
        final selector =
            await BackendDiscovery(client).discover(Server(url: url));
        expect(selector.cookieName, 'custom_route');
        expect(requests, 3);
      });
    }

    test('folded cookies and expiry commas do not import authentication data',
        () async {
      final client = MockClient((request) async {
        if (request.url.path == '/') return _html(_choices('backend_id'));
        final id = request.url.queryParameters['backend_id'];
        return http.Response('', 302, headers: {
          'set-cookie': 'SID=$id; Path=/, route=$id; Path=/; '
              'Expires=Wed, 21 Oct 2037 07:28:00 GMT, unrelated=keep; Path=/',
        });
      });
      addTearDown(client.close);
      final selector = await BackendDiscovery(client).discover(_server);
      expect(selector.cookieName, 'route');
      expect(selector.withSelection(_server, '5').customHeaders,
          {'Cookie': 'route=5'});
    });

    for (final failure in [
      'mismatch',
      'different name',
      'ambiguous',
      'SID',
      'PREFS',
      '__Host-SID',
      'PHPSESSID',
      'csrf_token',
      'jwt',
    ]) {
      test('rejects unproven routing cookies: $failure', () async {
        var probes = 0;
        final client = MockClient((request) async {
          if (request.url.path == '/') return _html(_choices('backend_id'));
          probes++;
          final id = request.url.queryParameters['backend_id']!;
          final cookie = switch (failure) {
            'mismatch' => 'route=99; Path=/',
            'different name' =>
              '${probes == 1 ? 'first' : 'second'}=$id; Path=/',
            'ambiguous' => 'first=$id; Path=/, second=$id; Path=/',
            _ => '$failure=$id; Path=/',
          };
          return http.Response('', 302, headers: {'set-cookie': cookie});
        });
        addTearDown(client.close);
        await expectLater(BackendDiscovery(client).discover(_server),
            throwsA(isA<BackendDiscoveryException>()));
      });
    }

    test('does not follow an external probe redirect even with matching cookie',
        () async {
      final requested = <Uri>[];
      final client = MockClient((request) async {
        requested.add(request.url);
        if (request.url.path == '/') return _html(_choices('backend_id'));
        return http.Response('', 302, headers: {
          'set-cookie':
              'route=${request.url.queryParameters['backend_id']}; Path=/',
          'location': 'https://external.example/receive',
        });
      });
      addTearDown(client.close);
      await expectLater(BackendDiscovery(client).discover(_server),
          throwsA(isA<BackendDiscoveryException>()));
      expect(requested.every((url) => url.origin == _server.url), isTrue);
    });
  });

  group('bounded homepage discovery', () {
    test(
        'follows up to three same-origin redirects with automatic redirects off',
        () async {
      final requested = <Uri>[];
      final client = MockClient((request) async {
        requested.add(request.url);
        expect(request.followRedirects, isFalse);
        if (requested.length <= 3) {
          return http.Response('', 302,
              headers: {'location': '/step${requested.length}'});
        }
        return _html(_choices('companion_id'));
      });
      addTearDown(client.close);
      expect((await BackendDiscovery(client).discover(_server)).options,
          hasLength(2));
      expect(requested.map((url) => url.path),
          ['/', '/step1', '/step2', '/step3']);
    });

    test('a fourth redirect is rejected without requesting its target',
        () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return http.Response('', 302, headers: {'location': '/step$requests'});
      });
      addTearDown(client.close);
      await expectLater(BackendDiscovery(client).discover(_server),
          throwsA(isA<BackendDiscoveryException>()));
      expect(requests, 4);
    });

    for (final target in [
      'https://external.example/',
      'http://instance.example/',
      'https://instance.example:8443/',
      '/switchbackend?companion_id=5',
    ]) {
      test('does not follow unsafe homepage redirect $target', () async {
        var requests = 0;
        final client = MockClient((_) async {
          requests++;
          return http.Response('', 302, headers: {'location': target});
        });
        addTearDown(client.close);
        await expectLater(
            BackendDiscovery(client).discover(_server.copyWith(customHeaders: {
              'Cookie': 'SID=manual-session',
            })),
            throwsA(isA<BackendDiscoveryException>()));
        expect(requests, 1);
      });
    }

    for (final body in [
      '',
      '   ',
      '<html><title>Checking you are not a bot</title><p>Challenge</p></html>',
      '<html><title>Log in</title><form>Authentication required</form></html>',
    ]) {
      test('empty or challenge page is a failure, not unsupported: $body',
          () async {
        final client = MockClient((_) async => _html(body));
        addTearDown(client.close);
        await expectLater(BackendDiscovery(client).discover(_server),
            throwsA(isA<BackendDiscoveryException>()));
      });
    }

    test('transport errors and responses never expose sensitive diagnostics',
        () async {
      const secret = 'private-token-DO-NOT-REPORT';
      for (final response in [false, true]) {
        final client = MockClient((_) async {
          if (response) return http.Response('Forbidden: $secret', 403);
          throw http.ClientException('Request included $secret');
        });
        addTearDown(client.close);
        await expectLater(
            BackendDiscovery(client).discover(_server),
            throwsA(isA<BackendDiscoveryException>().having(
                (error) => error.toString(),
                'safe message',
                isNot(contains(secret)))));
      }
    });

    test('declared oversized responses cancel without consuming body chunks',
        () async {
      var cancelled = false;
      var consumed = 0;
      late final StreamController<List<int>> body;
      body = StreamController<List<int>>(
        onListen: () => body.add([32]),
        onCancel: () => cancelled = true,
      );
      addTearDown(body.close);
      final client = _StreamClient((_) async => http.StreamedResponse(
            body.stream.map((chunk) {
              consumed++;
              return chunk;
            }),
            200,
            contentLength: _bodyLimit + 1,
            headers: {'content-type': 'text/html'},
          ));
      addTearDown(client.close);
      await expectLater(BackendDiscovery(client).discover(_server),
          throwsA(isA<BackendDiscoveryException>()));
      expect(cancelled, isTrue);
      expect(consumed, 0);
    });

    test('actual streamed size is capped when no length is declared', () async {
      var cancelled = false;
      final body = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      addTearDown(body.close);
      final client = _StreamClient((_) async {
        body.add(List.filled(_bodyLimit, 32));
        body.add([32]);
        return http.StreamedResponse(body.stream, 200,
            headers: {'content-type': 'text/html'});
      });
      addTearDown(client.close);
      await expectLater(BackendDiscovery(client).discover(_server),
          throwsA(isA<BackendDiscoveryException>()));
      expect(cancelled, isTrue);
    });

    test('exactly 2 MiB remains a valid discovery response', () async {
      final markup = _choices('companion_id');
      final bytes = utf8.encode(markup);
      final client = _StreamClient((_) async => http.StreamedResponse(
            Stream.fromIterable(
                [bytes, List.filled(_bodyLimit - bytes.length, 32)]),
            200,
            contentLength: _bodyLimit,
            headers: {'content-type': 'text/html'},
          ));
      addTearDown(client.close);
      expect((await BackendDiscovery(client).discover(_server)).options,
          hasLength(2));
    });

    test('absolute deadline stops a body that keeps producing bytes', () async {
      var cancelled = false;
      Timer? timer;
      late final StreamController<List<int>> body;
      body = StreamController<List<int>>(
        onListen: () => timer = Timer.periodic(
            const Duration(milliseconds: 5), (_) => body.add([32])),
        onCancel: () {
          cancelled = true;
          timer?.cancel();
        },
      );
      addTearDown(() async {
        timer?.cancel();
        await body.close();
      });
      final client =
          _StreamClient((_) async => http.StreamedResponse(body.stream, 200));
      addTearDown(client.close);

      await expectLater(
          BackendDiscovery(client, timeout: const Duration(milliseconds: 40))
              .discover(_server)
              .timeout(const Duration(seconds: 2)),
          throwsA(isA<BackendDiscoveryException>()));
      expect(cancelled, isTrue);
    });

    test('one deadline covers the homepage and both routing probes', () async {
      final client = MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        if (request.url.path == '/') return _html(_choices('backend_id'));
        return http.Response('', 302, headers: {
          'set-cookie':
              'route=${request.url.queryParameters['backend_id']}; Path=/',
        });
      });
      addTearDown(client.close);

      // Every request is individually faster than the timeout. Together, the
      // homepage and two required probes exceed the discovery deadline.
      await expectLater(
          BackendDiscovery(client, timeout: const Duration(milliseconds: 70))
              .discover(_server)
              .timeout(const Duration(seconds: 2)),
          throwsA(isA<BackendDiscoveryException>()));
    });
  });
}
