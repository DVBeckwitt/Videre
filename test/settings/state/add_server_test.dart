import 'dart:async';

import 'package:clipious/globals.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/server_already_exists.dart';
import 'package:clipious/settings/states/add_server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

    test('checks the normalized address with only its configured headers',
        () async {
      service = Service(httpClient: MockClient((request) async {
        expect(request.url.toString(), 'https://inv.example/api/v1/stats');
        expect(request.headers['Authorization'], 'Basic own-server');
        return http.Response('{"software":{"name":"invidious"}}', 200);
      }));
      cubit.urlController.text = 'inv.example/';
      cubit.addHeader('Authorization', 'Basic own-server');

      final server = await cubit.validateServer();
      expect(server?.url, 'https://inv.example');
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
  });
}
