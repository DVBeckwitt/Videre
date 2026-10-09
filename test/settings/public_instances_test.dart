import 'dart:async';

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/states/add_server.dart';
import 'package:clipious/settings/views/components/public_instances.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AddServerCubit cubit;
  setUp(() => cubit = AddServerCubit(const AddServerState()));
  tearDown(() => cubit.close());

  Future<void> pumpPicker(
      WidgetTester tester, Future<List<PublicInstance>> Function() loader,
      {Future<void> Function(BuildContext)? openDirectory}) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BlocProvider.value(
        value: cubit,
        child: Scaffold(
          body: PublicInstancesButton(
              openDirectory: openDirectory ?? (_) async {},
              loadInstances: loader),
        ),
      ),
    ));
  }

  testWidgets('loads on opening, retries a failure and preserves custom entry',
      (tester) async {
    cubit.urlController.text = 'https://custom.example';
    cubit.addHeader('Authorization', 'Basic private');
    var calls = 0;
    var directoryOpened = false;
    final failed = Completer<List<PublicInstance>>();
    await pumpPicker(tester, () {
      calls++;
      return calls == 1
          ? failed.future
          : Future.value([(url: 'https://public.example', api: false)]);
    }, openDirectory: (_) async => directoryOpened = true);

    expect(calls, 0);
    await tester.tap(find.text('Public instances'));
    await tester.pump();
    expect(calls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    failed.completeError(StateError('Offline'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Could not load public instances'), findsOneWidget);
    await tester.tap(find.text('Official list'));
    expect(directoryOpened, isTrue);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('public.example'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(cubit.urlController.text, 'https://custom.example');
    expect(cubit.state.headers, {'Authorization': 'Basic private'});
  });

  testWidgets('a TV select key fills the form and clears private headers',
      (tester) async {
    cubit.addHeader('Authorization', 'Basic private');
    await pumpPicker(
        tester, () async => [(url: 'https://public.example', api: true)]);
    await tester.tap(find.text('Public instances'));
    await tester.pumpAndSettle();
    expect(find.text('public.example'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(cubit.urlController.text, 'https://public.example');
    expect(cubit.state.publicInstance, 'https://public.example');
    expect(cubit.state.headers, isEmpty);
    expect(cubit.state.advancedTest, isTrue);
  });

  testWidgets('empty directory keeps retry and custom entry available',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpPicker(tester, () async => []);
    await tester.tap(find.text('Public instances'));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Official list'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('closing during a directory request ignores its later completion',
      (tester) async {
    final pending = Completer<List<PublicInstance>>();
    await pumpPicker(tester, () => pending.future);
    await tester.tap(find.text('Public instances'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    pending.complete([(url: 'https://public.example', api: true)]);
    await tester.pumpAndSettle();
    expect(cubit.urlController.text, 'https://');
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape with large text can scroll an error and retry',
      (tester) async {
    tester.view.physicalSize = const Size(640, 320);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    var calls = 0;
    await pumpPicker(tester, () async {
      if (++calls == 1) throw StateError('Offline');
      return [];
    });
    await tester.tap(find.text('Public instances'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Retry'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });
}
