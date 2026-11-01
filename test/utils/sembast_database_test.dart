import 'package:clipious/settings/models/db/app_logs.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast.dart';

void main() {
  late SembastSqfDb database;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
  });

  tearDown(() => database.close());

  test('concurrent server selections leave exactly one selected server',
      () async {
    const first = Server(url: 'https://first.example');
    const second = Server(url: 'https://second.example');
    await database.upsertServer(first);
    await database.upsertServer(second);

    await Future.wait([
      database.useServer(first),
      database.useServer(second),
    ]);

    final servers = await database.getServers();
    expect(servers.where((server) => server.inUse).map((server) => server.url),
        [second.url]);
  });

  test('log cleanup keeps the newest entries independent of record order',
      () async {
    await database.db.transaction((txn) async {
      for (var index = maxLogs + 1; index >= 0; index--) {
        await database.appLogsStore.record('log-$index').put(
            txn,
            AppLog(
                    level: 'INFO',
                    logger: 'test',
                    time: DateTime.utc(2026).add(Duration(seconds: index)),
                    message: '$index')
                .toJson());
      }
    });

    await database.cleanOldLogs();

    expect(database.getAppLogs(), hasLength(maxLogs));
    expect(database.getAppLogs().map((log) => log.message),
        isNot(anyOf(contains('0'), contains('1'))));
    await database.cleanOldLogs();
    expect(database.getAppLogs(), hasLength(maxLogs));
  });
}
