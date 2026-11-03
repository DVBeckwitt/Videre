import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:flutter_test/flutter_test.dart';

class _InitializingApp extends AppCubit {
  _InitializingApp() : super(AppState(0, null, HomeLayout()));

  @override
  void onReady() {}

  @override
  Future<void> initState() async {}

  Future<void> initialize() async => super.initState();
}

class _PendingServerDb extends IDbClient {
  final selectedServer = Completer<Server>();

  @override
  Future<Server> getCurrentlySelectedServer() => selectedServer.future;

  @override
  HomeLayout getHomeLayout() => HomeLayout();

  @override
  SettingsValue? getSettings(String name) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup finishing after close does not emit into the closed app',
      () async {
    final database = _PendingServerDb();
    db = database;
    final app = _InitializingApp();
    app.intentDataStreamSubscription = const Stream.empty().listen((_) {});
    final initialization = app.initialize();

    await app.close();
    database.selectedServer.complete(const Server(url: 'https://example.test'));

    await expectLater(initialization, completes);
    expect(app.state.server, isNull);
  });

  test('close waits for sharing stream cancellation', () async {
    final cancelled = Completer<void>();
    final stream = StreamController<void>(onCancel: () => cancelled.future);
    final app = _InitializingApp();
    app.intentDataStreamSubscription = stream.stream.listen((_) {});
    var finished = false;

    final close = app.close().then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    expect(app.isClosed, isTrue);
    expect(finished, isFalse);

    cancelled.complete();
    await close;
    await stream.close();
    expect(finished, isTrue);
  });
}
