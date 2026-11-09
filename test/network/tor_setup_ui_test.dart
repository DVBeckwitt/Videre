import 'dart:async';

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/views/components/nerdvpn_onion_setup.dart';
import 'package:clipious/settings/states/add_server.dart';
import 'package:clipious/settings/views/screens/add_server.dart';
import 'package:clipious/utils/views/tv/components/tv_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _onionOrigin =
    'http://nerdvpneaggggfdiurknszkbmhvjndks5z5k3g5yp4nhphflh3n3boad.onion';
const _channel = MethodChannel('videre/tor_browser');
const _key = 'nvpn_0123456789abcdefghijklmnopqrstuv';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late TextEditingController controller;
  final calls = <MethodCall>[];
  var available = true;
  var appAvailable = true;
  String? clipboardText;
  Completer<bool>? launch;
  Completer<void>? clipboard;
  Completer<bool>? appLaunch;

  setUp(() {
    controller = TextEditingController();
    calls.clear();
    available = true;
    appAvailable = true;
    clipboardText = null;
    launch = null;
    clipboard = null;
    appLaunch = null;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      if (call.method == 'openApp') {
        return appLaunch == null ? appAvailable : await appLaunch!.future;
      }
      return launch == null ? available : await launch!.future;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        if (clipboard != null) await clipboard!.future;
        clipboardText = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
  });

  tearDown(() {
    controller.dispose();
    messenger.setMockMethodCallHandler(_channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> showSetup(WidgetTester tester,
      {bool television = false,
      bool loading = false,
      bool pushed = false}) async {
    final navigator = GlobalKey<NavigatorState>();
    final setup = Scaffold(
      body: SingleChildScrollView(
        child: NerdVpnOnionSetup(
          serverUrl: _onionOrigin,
          apiKeyController: controller,
          loading: loading,
          television: television,
        ),
      ),
    );
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: pushed ? const Scaffold(body: Text('Underlying page')) : setup,
    ));
    if (pushed) {
      navigator.currentState!
          .push(MaterialPageRoute<void>(builder: (_) => setup));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('phone API key input disables suggestions and learning',
      (tester) async {
    await showSetup(tester);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue);
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
    expect(field.enableIMEPersonalizedLearning, isFalse);
    await tester.enterText(find.byType(TextField), _key);
    expect(controller.text, _key);
    expect(calls, isEmpty);
  });

  testWidgets('key validation feedback explains the key instead of the address',
      (tester) async {
    await showSetup(tester);
    final context = tester.element(find.byType(NerdVpnOnionSetup));
    const error =
        NerdVpnApiKeyException('Enter an API key from NerdVPN preferences.');
    AddServerScreen.handleError(context, error);
    await tester.pumpAndSettle();
    expect(find.text(error.message), findsOneWidget);
    expect(find.text(AppLocalizations.of(context)!.instanceAddressInvalid),
        findsNothing);
    expect(find.textContaining('FormatException'), findsNothing);
  });

  testWidgets(
      'external handoff preserves typed key and prevents duplicate open',
      (tester) async {
    controller.text = _key;
    launch = Completer<bool>();
    await showSetup(tester);
    await tester.tap(find.text('Open Tor Browser'));
    await tester.pump();
    expect(
        tester
            .widget<OutlinedButton>(
                find.byWidgetPredicate((widget) => widget is OutlinedButton))
            .onPressed,
        isNull);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'openNerdVpnPreferences');
    expect(calls.single.arguments, {'serverUrl': _onionOrigin});
    expect(controller.text, _key);
    launch!.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.text, _key);
    expect(
        tester
            .widget<OutlinedButton>(
                find.byWidgetPredicate((widget) => widget is OutlinedButton))
            .onPressed,
        isNotNull);
    expect(tester.takeException(), isNull);
  });

  for (final television in [false, true]) {
    testWidgets(
        '${television ? 'TV' : 'phone'} missing Tor Browser explains separate install and preserves onion',
        (tester) async {
      available = false;
      appAvailable = false;
      await showSetup(tester, television: television);
      await tester.tap(find.text('Open Tor Browser'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('Tor Browser cannot open this link directly'),
          findsOneWidget);
      expect(find.textContaining('Videre does not include Tor Browser.'),
          findsOneWidget);
      expect(find.text('$_onionOrigin/preferences#api-access'), findsOneWidget);
      expect(find.textContaining('https://invidious.nerdvpn.de'), findsNothing);
      expect(calls, hasLength(1));
      expect(clipboardText, isNull);
      await tester.tap(find.text('Copy address and open Tor Browser'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Install Tor Browser separately'),
          findsOneWidget);
      expect(clipboardText, '$_onionOrigin/preferences#api-access');
      expect(calls.last.method, 'openApp');
      expect(find.text('$_onionOrigin/preferences#api-access'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '${television ? 'TV' : 'phone'} setup disables edits and handoff during validation',
        (tester) async {
      await showSetup(tester, television: television, loading: true);
      expect(
          tester
              .widget<OutlinedButton>(
                  find.byWidgetPredicate((widget) => widget is OutlinedButton))
              .onPressed,
          isNull);
      if (television) {
        final excluded = tester.widget<ExcludeFocus>(find.ancestor(
            of: find.byType(TvTextField), matching: find.byType(ExcludeFocus)));
        expect(excluded.excluding, isTrue);
      } else {
        expect(
            tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
      }
    });
  }

  testWidgets(
      'Tor Browser without link support gets an explicit public-address handoff',
      (tester) async {
    available = false;
    controller.text = _key;
    await showSetup(tester);
    await tester.tap(find.text('Open Tor Browser'));
    await tester.pumpAndSettle();
    expect(clipboardText, isNull);
    expect(calls, hasLength(1));
    await tester.tap(find.text('Copy address and open Tor Browser'));
    await tester.pumpAndSettle();
    expect(clipboardText, '$_onionOrigin/preferences#api-access');
    expect(clipboardText, isNot(contains(_key)));
    expect(calls.map((call) => call.method),
        ['openNerdVpnPreferences', 'openApp']);
    expect(calls.last.arguments, isNull);
    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.text, _key);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV remote select opens the separate browser and masks the key',
      (tester) async {
    controller.text = _key;
    await showSetup(tester, television: true);
    final field = tester.widget<TvTextField>(find.byType(TvTextField));
    expect(field.obscureText, isTrue);
    expect(field.autocorrect, isFalse);
    expect(find.text(_key), findsNothing);
    Focus.of(tester.element(find.text('Open Tor Browser'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));
    expect(calls.single.arguments, {'serverUrl': _onionOrigin});
    expect(tester.takeException(), isNull);
  });

  for (final barrier in [false, true]) {
    testWidgets(
        '${barrier ? 'barrier' : 'OK'} dismissal during clipboard wait cancels browser launch',
        (tester) async {
      available = false;
      clipboard = Completer<void>();
      await showSetup(tester, pushed: true);
      final setupRoute =
          ModalRoute.of(tester.element(find.byType(NerdVpnOnionSetup)))!;
      await tester.tap(find.text('Open Tor Browser'));
      await tester.pumpAndSettle();
      final dialogContext = tester.element(find.byType(AlertDialog));
      final dialogRoute = ModalRoute.of(dialogContext)!;
      await tester.tap(find.text('Copy address and open Tor Browser'));
      await tester.pump();
      if (barrier) {
        await tester.tapAt(const Offset(1, 1));
      } else {
        await tester.tap(find.text('OK'));
      }
      expect(dialogContext.mounted, isTrue);
      expect(dialogRoute.isCurrent, isFalse);
      clipboard!.complete();
      await tester.pump();
      expect(calls.map((call) => call.method), ['openNerdVpnPreferences']);
      expect(setupRoute.isCurrent, isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(NerdVpnOnionSetup), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '${barrier ? 'barrier' : 'OK'} dismissal during app launch cannot pop the setup route',
        (tester) async {
      available = false;
      appLaunch = Completer<bool>();
      await showSetup(tester, pushed: true);
      final setupRoute =
          ModalRoute.of(tester.element(find.byType(NerdVpnOnionSetup)))!;
      await tester.tap(find.text('Open Tor Browser'));
      await tester.pumpAndSettle();
      final dialogContext = tester.element(find.byType(AlertDialog));
      final dialogRoute = ModalRoute.of(dialogContext)!;
      await tester.tap(find.text('Copy address and open Tor Browser'));
      await tester.pump();
      expect(calls.last.method, 'openApp');
      if (barrier) {
        await tester.tapAt(const Offset(1, 1));
      } else {
        await tester.tap(find.text('OK'));
      }
      expect(dialogContext.mounted, isTrue);
      expect(dialogRoute.isCurrent, isFalse);
      appLaunch!.complete(true);
      await tester.pump();
      expect(setupRoute.isCurrent, isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(NerdVpnOnionSetup), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'TV secure keyboard disables suggestions and personalized learning',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: TvTextFieldScreen(
        controller: controller,
        obscureText: true,
        autocorrect: false,
      ),
    ));
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue);
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
    expect(field.enableIMEPersonalizedLearning, isFalse);
  });
}
