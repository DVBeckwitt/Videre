import 'package:flutter_test/flutter_test.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/settings/models/db/app_logs.dart';
import 'package:clipious/settings/states/app_logs.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    db = await SembastSqfDb.createInMemory();
  });

  tearDown(() => db.close());
  test('test logs', () async {
    for (int i = 0; i < 11; i++) {
      await db.insertLogs(AppLog(
          message: i.toString(),
          level: "info",
          logger: 'test_log',
          time: DateTime.now()));
    }

    var cubit = AppLogsCubit(AppLogsState.init());
    expect(cubit.state.logs.isEmpty, false);

    cubit.selectLog(cubit.state.logs[10].uuid, true);
    expect(cubit.state.selected.length, 1);
    cubit.selectLog(cubit.state.logs[10].uuid, false);
    expect(cubit.state.selected.length, 0);

    cubit.selectAll();
    expect(cubit.state.selected.length, cubit.state.logs.length);
  });
}
