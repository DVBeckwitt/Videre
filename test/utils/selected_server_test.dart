import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/app_logs.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/views/components/selected_server.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingDb extends SembastSqfDb {
  _CountingDb(super.database);

  int selectedReads = 0;
  int logWrites = 0;

  @override
  Future<void> upsertServer(Server server) async => super.upsertServer(server);

  @override
  Future<void> insertLogs(AppLog log) async {
    logWrites++;
    await super.insertLogs(log);
  }

  @override
  Future<Server> getCurrentlySelectedServer() {
    selectedReads++;
    return super.getCurrentlySelectedServer();
  }
}

class _App extends AppCubit {
  _App(Server server) : super(AppState(0, server, HomeLayout()));

  @override
  void initState() {}

  @override
  void onReady() {
    intentDataStreamSubscription = const Stream<void>.empty().listen((_) {});
  }
}

void main() {
  late _CountingDb database;
  const first = Server(url: 'https://first.example');
  const second = Server(url: 'https://second.example');

  setUp(() async {
    final opened = await SembastSqfDb.createInMemory();
    database = _CountingDb(opened.db);
    db = database;
    await database.upsertServer(first);
    await database.upsertServer(second);
    await database.useServer(first);
    database.selectedReads = 0;
  });

  tearDown(() async {
    await database.close();
  });

  Widget serverLabel() => SelectedServerBuilder(builder: (context, server) {
        return Text('${server?.url}|${server?.customHeaders['X-Test']}');
      });

  testWidgets('standalone rebuilds reuse the initial selected-server lookup',
      (tester) async {
    late StateSetter rebuild;
    await tester.pumpWidget(
        MaterialApp(home: StatefulBuilder(builder: (context, setState) {
      rebuild = setState;
      return serverLabel();
    })));
    await tester.pumpAndSettle();
    expect(find.text('${first.url}|null'), findsOneWidget);
    expect(database.selectedReads, 1);
    expect(database.logWrites, 0);
    for (var index = 0; index < 5; index++) {
      rebuild(() {});
      await tester.pump();
    }
    expect(database.selectedReads, 1);
  });

  testWidgets('app server switches update without asynchronous record scans',
      (tester) async {
    final app = _App(first);
    addTearDown(app.close);
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
        value: app, child: MaterialApp(home: serverLabel())));
    expect(find.text('${first.url}|null'), findsOneWidget);
    expect(database.selectedReads, 0);

    await tester.runAsync(() => database.useServer(second));
    app.setServer(second);
    await tester.pumpAndSettle();
    expect(find.text('${second.url}|null'), findsOneWidget);
    expect(database.selectedReads, 0);
  });

  testWidgets('rebuild reads changed credentials from the saved server record',
      (tester) async {
    final app = _App(first);
    addTearDown(app.close);
    late StateSetter rebuild;
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
        value: app,
        child: MaterialApp(home: StatefulBuilder(builder: (context, setState) {
          rebuild = setState;
          return serverLabel();
        }))));
    await tester.runAsync(() => database.upsertServer(
        first.copyWith(customHeaders: {'X-Test': 'updated'}, inUse: true)));
    rebuild(() {});
    await tester.pump();
    expect(find.text('${first.url}|updated'), findsOneWidget);
    expect(database.selectedReads, 0);
  });

  testWidgets('deleted legacy selection never exposes replacement headers',
      (tester) async {
    final app = _App(first);
    addTearDown(app.close);
    late StateSetter rebuild;
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
        value: app,
        child: MaterialApp(home: StatefulBuilder(builder: (context, setState) {
          rebuild = setState;
          return serverLabel();
        }))));
    await tester.runAsync(() async {
      await database.upsertServer(first
          .copyWith(id: 'replacement', customHeaders: {'X-Test': 'private'}));
      await database.deleteServerById(first);
    });

    rebuild(() {});
    await tester.pump();
    expect(find.text('null|null'), findsOneWidget);
    expect(find.text('${first.url}|private'), findsNothing);
    expect(database.selectedReads, 0);
  });
}
