import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/services/backend_discovery.dart';
import 'package:clipious/settings/services/backend_browser.dart';
import 'package:clipious/settings/views/components/backend_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const server = Server(url: 'https://invidious.nerdvpn.de');
  final discovered = server.copyWith(
    backendSelector: BackendSelector('COMPANION_ID', const [
      BackendOption('0', 'Prôtos 1'),
      BackendOption('5', 'Deúteros 3'),
    ]),
  );
  final browser = find.byKey(const ValueKey('backend-browser'));
  final retry = find.byKey(const ValueKey('backend-retry'));
  final save = find.byKey(const ValueKey('backend-save'));
  final automatic = find.byKey(const ValueKey('backend-automatic'));
  Finder choice(String value) => find.byKey(ValueKey('backend-$value'));

  setUp(() async {
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
  });

  tearDown(() async {
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
  });

  Future<void> pumpPicker(
    WidgetTester tester, {
    Server? initial,
    Future<Server> Function()? discover,
    Future<Server?> Function()? browserDiscover,
    Future<void> Function(String?, bool)? onSave,
  }) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => BackendPicker(
                server: initial ?? server,
                onDiscover: discover ??
                    () async => throw const BackendDiscoveryException(),
                onBrowserDiscover: browserDiscover,
                onSave: onSave ?? (_, __) async {},
              ),
            ),
            child: const Text('Open picker'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets('failed direct discovery offers visible browser and retry',
      (tester) async {
    var browserCalls = 0;
    await pumpPicker(tester, browserDiscover: () async {
      browserCalls++;
      return null;
    });

    expect(browser, findsOneWidget);
    expect(find.text('Open backend page'), findsOneWidget);
    expect(retry, findsOneWidget);
    expect(browserCalls, 0);
    expect(tester.widget<OutlinedButton>(browser).onPressed, isNotNull);
    expect(save, findsNothing);
  });

  testWidgets('browser cancellation retains direct retry and no configuration',
      (tester) async {
    var directCalls = 0;
    var saves = 0;
    await pumpPicker(tester,
        discover: () async {
          directCalls++;
          throw const BackendDiscoveryException();
        },
        browserDiscover: () async => null,
        onSave: (_, __) async => saves++);

    await tapVisible(tester, browser);
    expect(browser, findsOneWidget);
    expect(retry, findsOneWidget);
    expect(save, findsNothing);
    expect(saves, 0);
    await tapVisible(tester, retry);
    expect(directCalls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('browser result enables manual selection and fallback saving',
      (tester) async {
    String? selected;
    bool? fallback;
    await pumpPicker(tester,
        browserDiscover: () async => discovered,
        onSave: (value, enabled) async {
          selected = value;
          fallback = enabled;
        });

    await tapVisible(tester, browser);
    expect(find.text('Prôtos 1'), findsOneWidget);
    expect(find.text('Deúteros 3'), findsOneWidget);
    expect(browser, findsNothing);
    expect(tester.widget<SwitchListTile>(automatic).value, isTrue);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tapVisible(tester, choice('5'));
    await tapVisible(tester, automatic);
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tapVisible(tester, save);
    expect(selected, '5');
    expect(fallback, isFalse);
    expect(find.byType(BackendPicker), findsNothing);
  });

  testWidgets('cancelled browser refresh preserves unsaved choice and fallback',
      (tester) async {
    await pumpPicker(tester,
        initial: discovered, browserDiscover: () async => null);
    await tapVisible(tester, choice('5'));
    await tapVisible(tester, automatic);
    await tapVisible(tester, find.byKey(const ValueKey('backend-refresh')));
    expect(browser, findsOneWidget);

    await tapVisible(tester, browser);
    expect(tester.widget<ListTile>(choice('5')).selected, isTrue);
    expect(tester.widget<SwitchListTile>(automatic).value, isFalse);
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    expect(retry, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('browser errors use generic message without native secrets',
      (tester) async {
    await pumpPicker(tester, browserDiscover: () async {
      throw StateError('private-session-cookie-do-not-show');
    });
    await tapVisible(tester, browser);

    expect(find.textContaining('private-session-cookie'), findsNothing);
    expect(find.textContaining('Could not check available backends'),
        findsOneWidget);
    expect(retry, findsOneWidget);
    expect(browser, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saved proxy leaves browser discovery enabled', (tester) async {
    var browserCalls = 0;
    await NetworkProxy.instance
        .initialize(saved: '{"enabled":true}', configureNative: false);
    await pumpPicker(tester, browserDiscover: () async {
      browserCalls++;
      return discovered;
    });

    expect(browser, findsOneWidget);
    expect(tester.widget<OutlinedButton>(browser).onPressed, isNotNull);
    expect(find.text('This page uses your saved SOCKS5 proxy connection.'),
        findsOneWidget);
    expect(browserCalls, 0);
    await tapVisible(tester, browser);
    expect(browserCalls, 1);
    expect(choice('5'), findsOneWidget);
  });

  testWidgets('unsupported WebView proxy support explains how to repair it',
      (tester) async {
    await NetworkProxy.instance
        .initialize(saved: '{"enabled":true}', configureNative: false);
    await pumpPicker(tester, browserDiscover: () async {
      throw const BackendBrowserProxyUnsupported();
    });
    await tapVisible(tester, browser);
    expect(
        find.textContaining('Update Android System WebView'), findsOneWidget);
    expect(retry, findsOneWidget);
    expect(browser, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
