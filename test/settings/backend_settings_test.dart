import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/services/backend_discovery.dart';
import 'package:clipious/settings/views/components/backend_picker.dart';
import 'package:clipious/settings/views/screens/manage_single_server.dart';
import 'package:clipious/settings/views/tv/screens/manage_single_server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';

void main() {
  late TestAppCubit app;
  final selector = BackendSelector('COMPANION_ID', [
    for (var i = 0; i < 8; i++) BackendOption('$i', 'Backend ${i + 1}'),
  ]);
  final server =
      Server(url: 'https://invidious.example', backendSelector: selector);
  final setting = find.byKey(const ValueKey('backend-setting'));
  final save = find.byKey(const ValueKey('backend-save'));
  final cancel = find.byKey(const ValueKey('backend-cancel'));
  final automatic = find.byKey(const ValueKey('backend-automatic'));
  final refresh = find.byKey(const ValueKey('backend-refresh'));
  final retry = find.byKey(const ValueKey('backend-retry'));
  Finder choice(String? value) =>
      find.byKey(ValueKey('backend-${value ?? 'default'}'));

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    await app.initState();
    await db
        .upsertServer(const Server(url: 'https://other.example', inUse: true));
  });

  tearDown(() async {
    await app.close();
    await db.close();
  });

  Widget testApp(Widget home) => BlocProvider<AppCubit>.value(
        value: app,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: home,
        ),
      );

  Future<void> pumpPicker(WidgetTester tester,
      {Server? initial,
      Future<Server> Function()? discover,
      bool settle = true,
      required Future<void> Function(String?, bool) onSave}) async {
    await tester.pumpWidget(testApp(Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showBackendPicker(context,
              server: initial ?? server,
              onDiscover: discover ?? () async => server,
              onSave: onSave),
          child: const Text('Open picker'),
        ),
      ),
    )));
    await tester.tap(find.text('Open picker'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> selectChoice(WidgetTester tester, String? value) async {
    await tester.ensureVisible(choice(value));
    await tester.pumpAndSettle();
    await tester.tap(choice(value));
    await tester.pumpAndSettle();
  }

  Future<void> toggleAutomatic(WidgetTester tester) async {
    await tester.ensureVisible(automatic);
    await tester.pumpAndSettle();
    await tester.tap(automatic);
    await tester.pumpAndSettle();
  }

  for (final tv in [false, true]) {
    testWidgets(
        '${tv ? 'TV' : 'phone'} backend setting saves and reopens selection',
        (tester) async {
      final initial = server.copyWith(customHeaders: {
        'Cookie': 'session=keep; COMPANION_ID=0',
        'Authorization': 'Basic unchanged',
      });
      await tester.runAsync(() => db.upsertServer(initial));
      await tester.pumpWidget(testApp(tv
          ? TvManageSingleServerScreen(server: initial)
          : ManageSingleServerScreen(server: initial)));
      await tester.pumpAndSettle();
      expect(setting, findsOneWidget);
      expect(find.text(selector.options.first.label), findsOneWidget);

      Future<void> openSetting() async {
        await tester.ensureVisible(setting);
        await tester.pumpAndSettle();
        if (tv) {
          Focus.of(tester.element(find
                  .descendant(of: setting, matching: find.byType(ListTile))
                  .first))
              .requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
        } else {
          await tester.tap(setting);
        }
        await tester.pumpAndSettle();
      }

      await openSetting();
      expect(find.byType(BackendPicker), findsOneWidget);
      await selectChoice(tester, '4');
      await toggleAutomatic(tester);
      expect(selector.selectedValue(db.getServer(server.url)!), '0');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.byType(BackendPicker), findsNothing);
      final saved = db.getServer(server.url)!;
      expect(selector.selectedValue(saved), '4');
      expect(saved.backendSelector!.automaticFallback, isTrue);
      expect(saved.customHeaders['Cookie'], contains('session=keep'));
      expect(saved.customHeaders['Authorization'], 'Basic unchanged');
      expect((await tester.runAsync(db.getCurrentlySelectedServer))!.url,
          'https://other.example');

      await openSetting();
      expect(tester.widget<ListTile>(choice('4')).selected, isTrue);
      expect(tester.widget<SwitchListTile>(automatic).value, isTrue);
      await selectChoice(tester, '1');
      await toggleAutomatic(tester);
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(selector.selectedValue(db.getServer(server.url)!), '4');
      expect(
          db.getServer(server.url)!.backendSelector!.automaticFallback, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '${tv ? 'TV' : 'phone'} offers backend discovery without saved configuration',
        (tester) async {
      const other = Server(url: 'https://invidious.example');
      await tester.pumpWidget(testApp(tv
          ? const TvManageSingleServerScreen(server: other)
          : const ManageSingleServerScreen(server: other)));
      await tester.pumpAndSettle();
      expect(setting, findsOneWidget);
      expect(find.text('Backend'), findsOneWidget);
      expect(find.text('Check available backends'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('D-pad arrows only move focus and Select chooses before Save',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final saved = <String?>[];
    await pumpPicker(tester,
        onSave: (value, automatic) async => saved.add(value));
    expect(tester.widget<ListTile>(choice(null)).selected, isTrue);
    expect(tester.getSemantics(choice(null)).flagsCollection.isChecked, isTrue);
    expect(
        tester
            .getSemantics(choice(null))
            .flagsCollection
            .isInMutuallyExclusiveGroup,
        isTrue);
    semantics.dispose();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(choice(null)).selected, isTrue);
    expect(tester.widget<ListTile>(choice('0')).selected, isFalse);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(choice('0')).selected, isTrue);
    expect(saved, isEmpty);
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saved, ['0']);
    expect(find.byType(BackendPicker), findsNothing);
  });

  testWidgets('pending save disables controls and a failure can be retried',
      (tester) async {
    final pending = Completer<void>();
    var calls = 0;
    await pumpPicker(tester, onSave: (_, automatic) {
      calls++;
      return calls == 1 ? pending.future : Future.value();
    });
    await selectChoice(tester, '0');
    await tester.tap(save);
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(tester.widget<TextButton>(cancel).onPressed, isNull);
    expect(tester.widget<ListTile>(choice('1')).enabled, isFalse);
    expect(tester.widget<SwitchListTile>(automatic).onChanged, isNull);
    expect(tester.widget<OutlinedButton>(refresh).onPressed, isNull);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(BackendPicker), findsOneWidget);
    pending.completeError(StateError('private implementation details'));
    await tester.pumpAndSettle();
    expect(
        find
            .text('Could not save the backend. Please try again.')
            .hitTestable(),
        findsOneWidget);
    expect(find.textContaining('private implementation'), findsNothing);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(BackendPicker), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown manual selection stays custom until explicitly replaced',
      (tester) async {
    final saved = <String?>[];
    await pumpPicker(tester,
        initial:
            server.copyWith(customHeaders: {'Cookie': 'COMPANION_ID=future'}),
        onSave: (value, automatic) async => saved.add(value));
    expect(find.text('Custom selection'), findsOneWidget);
    expect(find.textContaining('future'), findsNothing);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await selectChoice(tester, null);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saved, [null]);
  });

  testWidgets(
      '320px with large text scrolls all choices and keeps actions usable',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final saved = <String?>[];
    await pumpPicker(tester,
        onSave: (value, automatic) async => saved.add(value));
    expect(tester.takeException(), isNull);
    await selectChoice(tester, '7');
    expect(tester.takeException(), isNull);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saved, ['7']);
    expect(find.byType(BackendPicker), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saved last backend opens focused and visible with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpPicker(tester,
        initial: server.copyWith(customHeaders: {'Cookie': 'COMPANION_ID=7'}),
        onSave: (_, automatic) async {});
    expect(choice('7').hitTestable(), findsOneWidget);
    expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<ListTile>()
            ?.key,
        const ValueKey('backend-7'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('discovery shows loading then choices without saving a selection',
      (tester) async {
    final pending = Completer<Server>();
    var saves = 0;
    await pumpPicker(tester,
        initial: const Server(url: 'https://custom.example'),
        settle: false,
        discover: () => pending.future,
        onSave: (_, automatic) async => saves++);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Checking available backends…'), findsOneWidget);
    expect(save, findsNothing);
    pending.complete(server);
    await tester.pumpAndSettle();
    expect(choice('0'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(automatic).value, isFalse);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(saves, 0);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(saves, 0);
  });

  for (final unsupported in [true, false]) {
    testWidgets(
        'discovery ${unsupported ? 'unsupported' : 'network failure'} has a usable Retry',
        (tester) async {
      var calls = 0;
      await pumpPicker(tester,
          initial: const Server(url: 'https://custom.example'),
          discover: () async {
        if (++calls == 1) {
          if (unsupported) throw BackendDiscoveryUnsupported();
          throw StateError('private network details');
        }
        return server;
      }, onSave: (_, automatic) async {});
      expect(
          find.text(unsupported
              ? 'This instance does not expose a compatible backend selector.'
              : 'Could not check available backends. Check your connection and try again.'),
          findsOneWidget);
      expect(find.textContaining('private network'), findsNothing);
      expect(retry.hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(choice('0'), findsOneWidget);
      expect(retry, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'refresh replaces metadata while preserving unsaved choice and fallback',
      (tester) async {
    final saved = <(String?, bool)>[];
    var calls = 0;
    await pumpPicker(tester,
        discover: () async {
          calls++;
          return server.copyWith(
              backendSelector: BackendSelector('COMPANION_ID', [
            ...selector.options,
            const BackendOption('8', 'New backend'),
          ]));
        },
        onSave: (value, automatic) async => saved.add((value, automatic)));
    expect(calls, 0);
    await selectChoice(tester, '4');
    await toggleAutomatic(tester);
    await tester.ensureVisible(refresh);
    await tester.pumpAndSettle();
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(choice('8'), findsOneWidget);
    expect(tester.widget<ListTile>(choice('4')).selected, isTrue);
    expect(tester.widget<SwitchListTile>(automatic).value, isTrue);
    expect(saved, isEmpty);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saved, [('4', true)]);
  });

  testWidgets('closing discovery ignores a late response', (tester) async {
    final pending = Completer<Server>();
    var saves = 0;
    await pumpPicker(tester,
        initial: const Server(url: 'https://custom.example'),
        settle: false,
        discover: () => pending.future,
        onSave: (_, automatic) async => saves++);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    pending.complete(server);
    await tester.pumpAndSettle();
    expect(find.byType(BackendPicker), findsNothing);
    expect(saves, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed refresh retains the saved list and unsaved choices',
      (tester) async {
    final saved = <(String?, bool)>[];
    await pumpPicker(tester,
        discover: () async => throw StateError('offline'),
        onSave: (value, automatic) async => saved.add((value, automatic)));
    await selectChoice(tester, '4');
    await toggleAutomatic(tester);
    await tester.ensureVisible(refresh);
    await tester.pumpAndSettle();
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(retry.hitTestable(), findsOneWidget);
    expect(tester.widget<ListTile>(choice('4')).selected, isTrue);
    expect(tester.widget<SwitchListTile>(automatic).value, isTrue);
    expect(saved, isEmpty);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saved, [('4', true)]);
  });

  testWidgets('automatic fallback alone requires Save and can be cancelled',
      (tester) async {
    final saved = <(String?, bool)>[];
    await pumpPicker(tester,
        onSave: (value, automatic) async => saved.add((value, automatic)));
    await toggleAutomatic(tester);
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    expect(saved, isEmpty);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
    await pumpPicker(tester,
        onSave: (value, automatic) async => saved.add((value, automatic)));
    await toggleAutomatic(tester);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saved, [(null, true)]);
  });
}
