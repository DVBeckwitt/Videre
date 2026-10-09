import 'dart:async';
import 'dart:convert';

import 'package:clipious/globals.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/server_already_exists.dart';
import 'package:clipious/settings/states/add_server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _ValidationService extends Service {
  final checked = <Server>[];
  final response = Completer<void>();

  @override
  Future<void> validateServer(String url, Map<String, String>? headers) {
    checked.add(Server(url: url, customHeaders: headers ?? {}));
    return response.future;
  }

  @override
  Future<Video> getVideo(String videoId, {Server? serverOverride}) async {
    checked.add(serverOverride!);
    return Video(videoId: videoId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('normalizes copied instance addresses and preserves self-hosted paths',
      () {
    expect(
        AddServerCubit.normalizeUrl(' INV.example/// '), 'https://inv.example');
    expect(AddServerCubit.normalizeUrl('http://localhost:3000/invidious/'),
        'http://localhost:3000/invidious');
    expect(
        AddServerCubit.normalizeUrl('http://[::1]:3000/'), 'http://[::1]:3000');
    for (final address in [
      '',
      'https://',
      'not a host',
      'ftp://inv.example',
      'https://inv.example:65536',
      'https://user:password@inv.example',
      'https://inv.example/watch?v=video',
      'https://inv.example/#fragment',
    ]) {
      expect(AddServerCubit.normalizeUrl(address), isNull, reason: address);
    }
  });

  group('public instance directory', () {
    dynamic entry(String url, {dynamic api = false, String type = 'https'}) => [
          Uri.parse(url).host,
          {'uri': url, 'api': api, 'type': type, 'monitor': {}}
        ];

    test('keeps HTTPS roots, deduplicates and puts reported APIs first', () {
      final parsed = AddServerCubit.parsePublicInstances([
        entry('https://z.example'),
        entry('https://a.example', api: null),
        entry('https://b.example/', api: true),
        entry('https://b.example', api: false),
        entry('http://plain.example'),
        entry('noscheme.example'),
        entry('https://path.example/api'),
        entry('https://login:secret@private.example'),
        entry('https://query.example/?query=1'),
        entry('https://fragment.example/#fragment'),
        entry('https://hidden.onion', type: 'onion'),
        [
          'special.example',
          {'uri': 'https://special.example', 'type': 'https'}
        ],
        ['broken'],
        [
          'broken',
          {'uri': 1}
        ],
        'unexpected',
        null,
      ]);
      expect(parsed, [
        (url: 'https://b.example', api: true),
        (url: 'https://a.example', api: false),
        (url: 'https://z.example', api: false),
      ]);
      expect(
          () => AddServerCubit.parsePublicInstances({}), throwsFormatException);
    });

    test('requests the official directory without server headers', () async {
      final client = MockClient((request) async {
        expect(request.url.toString(), AddServerCubit.directoryUrl);
        expect(request.headers, isEmpty);
        return http.Response('[]', 200);
      });
      expect(await AddServerCubit.getPublicInstances(client: client), isEmpty);
    });

    test('the fetched directory suggests only the two checked hosts', () async {
      final requests = <Uri>[];
      final client = MockClient((request) async {
        requests.add(request.url);
        return http.Response(
            jsonEncode([
              entry('https://invidious.f5.si'),
              entry('https://inv.nadeko.net'),
              entry('https://invidious.nerdvpn.de', api: true),
              entry('https://yt.chocolatemoo53.com', api: true),
              entry('https://invidious.tiekoetter.com', api: true),
              entry('https://new.example', api: true),
            ]),
            200);
      });

      final instances = await AddServerCubit.getPublicInstances(client: client);
      expect(
          instances.map((instance) => instance.url),
          unorderedEquals([
            'https://invidious.f5.si',
            'https://inv.nadeko.net',
          ]));
      expect(requests, [Uri.parse(AddServerCubit.directoryUrl)]);
    });

    test('rejects HTTP failures and malformed directory data', () async {
      for (final response in [
        http.Response('Unavailable', 503),
        http.Response('<html>Challenge</html>', 200),
        http.Response('{}', 200),
      ]) {
        await expectLater(
            AddServerCubit.getPublicInstances(
                client: MockClient((_) async => response)),
            throwsFormatException);
      }
    });
  });

  group('adding an instance', () {
    late AddServerCubit cubit;
    setUp(() async {
      db = await SembastSqfDb.createInMemory();
      cubit = AddServerCubit(const AddServerState(advancedTest: false));
    });
    tearDown(() async {
      if (!cubit.isClosed) await cubit.close();
      await db.close();
      service = Service();
    });

    test('a copied duplicate never replaces a saved account or makes a request',
        () async {
      const saved =
          Server(url: 'https://inv.example', authToken: 'saved-account');
      await db.upsertServer(saved);
      final before = db.getServer(saved.url);
      service = Service(
          httpClient:
              MockClient((_) async => throw StateError('Unexpected request')));
      cubit.urlController.text = 'inv.example/';

      await expectLater(
          cubit.validateServer(), throwsA(isA<ServerAlreadyExists>()));
      expect(db.getServer(saved.url), before);
      expect(cubit.state.loading, isFalse);
    });

    test('manual addresses omitted from suggestions can still use credentials',
        () async {
      service = Service(httpClient: MockClient((request) async {
        expect(request.url.toString(),
            'https://invidious.nerdvpn.de/api/v1/stats');
        expect(request.headers['Authorization'], 'Basic own-server');
        return http.Response('{"software":{"name":"invidious"}}', 200);
      }));
      cubit.urlController.text = 'invidious.nerdvpn.de/';
      cubit.addHeader('Authorization', 'Basic own-server');

      final server = await cubit.validateServer();
      expect(server?.url, 'https://invidious.nerdvpn.de');
      expect(server?.authToken, isNull);
      expect(server?.customHeaders['Authorization'], 'Basic own-server');
      expect(cubit.state.loading, isFalse);
      expect(await db.getServers(), isEmpty);
    });

    test('a failed connection leaves no saved server and clears loading',
        () async {
      service = Service(
          httpClient:
              MockClient((_) async => http.Response('Unavailable', 503)));
      cubit.urlController.text = 'inv.example';

      await expectLater(cubit.validateServer(), throwsA(anything));
      expect(cubit.state.loading, isFalse);
      expect(await db.getServers(), isEmpty);
    });

    test('leaving during a connection test does not emit to a closed cubit',
        () async {
      final response = Completer<http.Response>();
      service = Service(httpClient: MockClient((_) => response.future));
      cubit.urlController.text = 'inv.example';
      final pending = cubit.validateServer();
      await cubit.close();
      response
          .complete(http.Response('{"software":{"name":"invidious"}}', 200));
      expect((await pending)?.url, 'https://inv.example');
    });

    test('public selection clears private headers without contacting or saving',
        () async {
      service = Service(httpClient: MockClient((_) async {
        fail('Selecting an instance must not contact it');
      }));
      cubit.addHeader('Authorization', 'Basic private');
      cubit.addHeader('X-Private', 'secret');
      cubit.selectPublicInstance('https://public.example');
      expect(cubit.urlController.text, 'https://public.example');
      expect(cubit.state.headers, isEmpty);
      expect(cubit.state.advancedTest, isTrue);
      cubit.setAdvancedTest(false);
      expect(cubit.state.advancedTest, isTrue);
      expect(await db.getServers(), isEmpty);

      cubit.urlController.text = 'https://custom.example';
      expect(cubit.state.publicInstance, isNull);
      cubit.setAdvancedTest(false);
      expect(cubit.state.advancedTest, isFalse);
    });

    test('public choice cannot overwrite an already saved account', () async {
      const saved =
          Server(url: 'https://public.example', authToken: 'saved-account');
      await db.upsertServer(saved);
      final before = db.getServer(saved.url);
      service = Service(httpClient: MockClient((_) async {
        fail('A duplicate must not make a request');
      }));
      cubit.selectPublicInstance(saved.url);
      await expectLater(
          cubit.validateServer(), throwsA(isA<ServerAlreadyExists>()));
      expect(db.getServer(saved.url), before);
    });

    test('validation uses one snapshot and public choices check the video API',
        () async {
      final validator = _ValidationService();
      service = validator;
      cubit.selectPublicInstance('https://public.example');
      final pending = cubit.validateServer();
      expect(await cubit.validateServer(), isNull);
      cubit.selectPublicInstance('https://different.example');
      cubit.addHeader('Authorization', 'Basic private');
      cubit.setAdvancedTest(false);
      // Even a controller edit outside the UI cannot retarget an active check.
      cubit.urlController.text = 'https://custom.example';
      validator.response.complete();

      final server = await pending;
      expect(server, const Server(url: 'https://public.example'));
      expect(validator.checked, [server, server]);
      expect(await db.getServers(), isEmpty);
    });
  });
}
