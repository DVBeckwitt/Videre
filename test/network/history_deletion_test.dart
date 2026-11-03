import 'dart:async';
import 'dart:convert';

import 'package:clipious/globals.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/services/watch_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const account = Server(
      url: 'https://instance.example', id: 'first', authToken: 'first-token');
  const other = Server(
      url: 'https://instance.example', id: 'second', authToken: 'second-token');
  late SembastSqfDb database;
  late WatchRepository repository;

  setUp(() async {
    db = database = await SembastSqfDb.createInMemory();
    await database.upsertServer(account);
    await database.upsertServer(other);
    await database.useServer(account);
    repository = WatchRepository(database);
  });

  tearDown(() async => database.close());

  for (final clearAll in [false, true]) {
    test('server ${clearAll ? "clear" : "delete"} retires old queued intent',
        () async {
      final remote = <String>{'video'};
      final requests = <String>[];
      final client = MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer first-token');
        requests.add('${request.method} ${request.url.path}');
        if (request.method == 'DELETE') remote.clear();
        if (request.method == 'POST') remote.add('video');
        return http.Response(
            request.method == 'GET' ? jsonEncode(remote.toList()) : '{}', 200);
      });
      addTearDown(client.close);
      final api = Service(httpClient: client);
      await database.saveProgress(Progress(0.4, 'video'));
      await repository.mark('video', true, account: account);
      await repository.mark('video', true, account: other);
      await repository.mergeRemote(account.accountId, {'video'},
          complete: true);

      if (clearAll) {
        await api.clearUserHistory();
      } else {
        await api.deleteFromUserHistory('video');
      }
      await api.syncAccountHistory(account,
          database: database, force: true, pull: false);

      expect(remote, isEmpty, reason: requests.join(', '));
      expect(requests, [
        'DELETE /api/v1/auth/history${clearAll ? "" : "/video"}',
      ]);
      expect(repository.pending(account.accountId), isEmpty);
      expect(repository.pending(other.accountId), hasLength(1));
      // A server-only delete is not the manual "mark unwatched" action.
      expect(repository.isWatched('video'), isTrue);
      expect(database.getVideoProgress('video'), 0.4);
    });

    test('failed server ${clearAll ? "clear" : "delete"} keeps pending intent',
        () async {
      final client = MockClient((request) async => http.Response('{}', 503));
      addTearDown(client.close);
      final api = Service(httpClient: client);
      await repository.mark('video', true, account: account);
      final revision = repository.pending(account.accountId).single.revision;

      await expectLater(
          clearAll
              ? api.clearUserHistory()
              : api.deleteFromUserHistory('video'),
          throwsA(anything));

      expect(repository.pending(account.accountId).single.revision, revision);
      expect(repository.pending(account.accountId).single.present, isTrue);
    });

    test(
        '${clearAll ? "clear" : "delete"} follows in-flight POST and keeps a later mark',
        () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final events = <String>[];
      final remote = <String>{};
      var writes = 0;
      final coordinator = WatchHistorySync(
          repository: repository,
          accountIsCurrent: (_) async => true,
          readPage: (_, __, ___) async => [],
          changeHistory: (_, id, present) async {
            writes++;
            if (writes == 1) {
              entered.complete();
              await release.future;
            }
            events.add('POST');
            remote.add(id);
          });
      await repository.mark('video', true, account: account);
      final syncing = coordinator.run(account, pull: false);
      await entered.future;
      final deleting = coordinator.deleteHistory(account,
          videoId: clearAll ? null : 'video', deleteRemote: () async {
        events.add('DELETE');
        remote.clear();
      });
      // The edit's revision transaction precedes this snapshot and later mark.
      await repository.historyEditRevision();
      await repository.mark('video', true, account: account);
      final newerSync = coordinator.run(account, pull: false);
      expect(events, isEmpty);
      release.complete();
      await Future.wait([syncing, deleting, newerSync]);

      expect(events, ['POST', 'DELETE', 'POST']);
      expect(remote, {'video'});
      expect(repository.pending(account.accountId), isEmpty);
    });
  }

  test('a failed DELETE after a successful POST preserves newer unsent intent',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final coordinator = WatchHistorySync(
        repository: repository,
        accountIsCurrent: (_) async => true,
        readPage: (_, __, ___) async => [],
        changeHistory: (_, __, ___) async {
          entered.complete();
          await release.future;
        });
    await repository.mark('video', true, account: account);
    final syncing = coordinator.run(account, pull: false);
    await entered.future;
    final deleting = coordinator.deleteHistory(account,
        deleteRemote: () async => throw StateError('fixture delete failure'));
    final failed = expectLater(deleting, throwsStateError);
    await repository.historyEditRevision();
    await repository.mark('video', false, account: account);
    final latest = repository.pending(account.accountId).single.revision;
    release.complete();
    await Future.wait([syncing, failed]);

    expect(repository.pending(account.accountId).single.revision, latest);
    expect(repository.pending(account.accountId).single.present, isFalse);
  });

  test('changed account credentials prevent queued deletion', () async {
    var valid = true;
    final entered = Completer<void>();
    final release = Completer<void>();
    var deletes = 0;
    final coordinator = WatchHistorySync(
        repository: repository,
        accountIsCurrent: (_) async => valid,
        readPage: (_, __, ___) async => [],
        changeHistory: (_, __, ___) async {
          entered.complete();
          await release.future;
        });
    await repository.mark('video', true, account: account);
    final syncing = coordinator.run(account, pull: false);
    await entered.future;
    final deleting =
        coordinator.deleteHistory(account, deleteRemote: () async => deletes++);
    final failed = expectLater(deleting, throwsStateError);
    valid = false;
    release.complete();
    await Future.wait([syncing, failed]);
    expect(deletes, 0);
    expect(repository.pending(account.accountId), hasLength(1));
  });

  test('an unsettled timed-out POST blocks DELETE with a bounded error',
      () async {
    final response = Completer<void>();
    var deletes = 0;
    final coordinator = WatchHistorySync(
        repository: repository,
        requestTimeout: const Duration(milliseconds: 20),
        accountIsCurrent: (_) async => true,
        readPage: (_, __, ___) async => [],
        changeHistory: (_, __, ___) => response.future);
    await repository.mark('video', true, account: account);
    await coordinator.run(account, pull: false);
    final deleting =
        coordinator.deleteHistory(account, deleteRemote: () async => deletes++);
    await expectLater(deleting, throwsA(isA<TimeoutException>()));
    expect(deletes, 0);
    expect(repository.pending(account.accountId), hasLength(1));

    response.complete();
    await coordinator.deleteHistory(account,
        deleteRemote: () async => deletes++);
    expect(deletes, 1);
    expect(repository.pending(account.accountId), isEmpty);
  });
}
