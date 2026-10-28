import 'dart:async';

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/settings/views/screens/network_proxy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpSettings(
    WidgetTester tester, {
    SocksProxyConfig? config,
    Future<void> Function(SocksProxyConfig)? onApply,
    Future<void> Function(SocksProxyConfig)? onTest,
  }) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: NetworkProxySettingsScreen(
        initialConfig: config ?? SocksProxyConfig(),
        onApply: onApply ?? (_) async {},
        onTest: onTest ?? (_) async {},
      ),
    ));
    await tester.pumpAndSettle();
  }

  final listScrollable = find.byWidgetPredicate((widget) =>
      widget is Scrollable && widget.axisDirection == AxisDirection.down);

  Future<void> reveal(WidgetTester tester, Finder target,
      {double delta = 200}) async {
    await tester.scrollUntilVisible(target, delta,
        scrollable: listScrollable, maxScrolls: 15);
    await tester.pumpAndSettle();
    expect(target.hitTestable(), findsOneWidget);
  }

  Future<void> tap(WidgetTester tester, String label) async {
    final target = find.text(label);
    await reveal(tester, target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets('Orbot preset can be tested without saving', (tester) async {
    SocksProxyConfig? tested;
    var saves = 0;
    await pumpSettings(tester,
        config: SocksProxyConfig(host: 'other.proxy', port: 1080),
        onTest: (config) async => tested = config,
        onApply: (_) async => saves++);

    await tap(tester, 'Use Orbot preset');
    await tap(tester, 'Test connection');
    expect(tested!.enabled, isTrue);
    expect(tested!.host, '127.0.0.1');
    expect(tested!.port, 9050);
    expect(saves, 0);
    expect(find.textContaining('Settings have not been saved'), findsOneWidget);

    await tap(tester, 'Save');
    expect(saves, 1);
    expect(find.text('Network proxy settings saved.'), findsOneWidget);
  });

  testWidgets('invalid endpoint stays unsaved and can still be disabled',
      (tester) async {
    SocksProxyConfig? saved;
    await pumpSettings(tester,
        config: SocksProxyConfig(enabled: true),
        onApply: (config) async => saved = config);
    await tester.enterText(find.byType(TextFormField).first, 'https://proxy');
    await tester.enterText(find.byType(TextFormField).last, '70000');
    await tap(tester, 'Save');
    expect(saved, isNull);
    expect(find.textContaining('without a URL'), findsOneWidget);
    expect(find.text('Enter a port between 1 and 65535.'), findsOneWidget);

    final toggle = find.byType(SwitchListTile);
    await reveal(tester, toggle, delta: -200);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tap(tester, 'Save');
    expect(saved!.enabled, isFalse);
    expect(saved!.host, '127.0.0.1');
  });

  testWidgets('first-run test explains how to configure proxy before a server',
      (tester) async {
    var saves = 0;
    await pumpSettings(tester,
        config: SocksProxyConfig(enabled: true),
        onTest: (_) async => throw ProxyTestNeedsServer(),
        onApply: (_) async => saves++);
    await tap(tester, 'Test connection');
    expect(
        find.text(
            'Save proxy settings, then add a server before testing the connection.'),
        findsOneWidget);
    expect(saves, 0);
    expect(find.textContaining('Could not reach the selected instance'),
        findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
  });

  testWidgets('test failure clears pending state without exposing raw errors',
      (tester) async {
    final pending = Completer<void>();
    await pumpSettings(tester,
        config: SocksProxyConfig(enabled: true), onTest: (_) => pending.future);
    await reveal(tester, find.text('Test connection'));
    await tester.tap(find.text('Test connection'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);

    pending.completeError(Exception('secret response body'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not reach the selected instance'),
        findsOneWidget);
    expect(find.textContaining('secret response body'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
  });
}
