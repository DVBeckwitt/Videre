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
  String? clipboardText;
  Completer<void>? clipboard;

  setUp(() {
    controller = TextEditingController();
    calls.clear();
    clipboardText = null;
    clipboard = null;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return true;
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
      'address dialog preserves typed key and prevents duplicate opening',
      (tester) async {
    controller.text = _key;
    await showSetup(tester);
    await tester.tap(find.text('Tor preferences address'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<OutlinedButton>(
                find.byWidgetPredicate((widget) => widget is OutlinedButton))
            .onPressed,
        isNull);
    expect(calls, isEmpty);
    expect(controller.text, _key);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('OK'));
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
        '${television ? 'TV' : 'phone'} onion guidance preserves address and copies only on request',
        (tester) async {
      await showSetup(tester, television: television);
      await tester.tap(find.text('Tor preferences address'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
          find.textContaining('Copy this address and open it'), findsOneWidget);
      expect(find.textContaining('Videre does not include Tor Browser.'),
          findsOneWidget);
      expect(find.text('$_onionOrigin/preferences#api-access'), findsOneWidget);
      expect(find.textContaining('https://invidious.nerdvpn.de'), findsNothing);
      expect(calls, isEmpty);
      expect(clipboardText, isNull);
      await tester.tap(find.text('Copy to clipboard'));
      await tester.pumpAndSettle();
      expect(find.text('Address copied.'), findsOneWidget);
      expect(clipboardText, '$_onionOrigin/preferences#api-access');
      expect(calls, isEmpty);
      expect(find.text('$_onionOrigin/preferences#api-access'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '${television ? 'TV' : 'phone'} setup disables edits and address dialog during validation',
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

  testWidgets('copying the preferences address does not copy the API key',
      (tester) async {
    controller.text = _key;
    await showSetup(tester);
    await tester.tap(find.text('Tor preferences address'));
    await tester.pumpAndSettle();
    expect(clipboardText, isNull);
    expect(calls, isEmpty);
    await tester.tap(find.text('Copy to clipboard'));
    await tester.pumpAndSettle();
    expect(clipboardText, '$_onionOrigin/preferences#api-access');
    expect(clipboardText, isNot(contains(_key)));
    expect(calls, isEmpty);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(controller.text, _key);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV remote select shows a copyable address and masks the key',
      (tester) async {
    controller.text = _key;
    await showSetup(tester, television: true);
    final field = tester.widget<TvTextField>(find.byType(TvTextField));
    expect(field.obscureText, isTrue);
    expect(field.autocorrect, isFalse);
    expect(find.text(_key), findsNothing);
    Focus.of(tester.element(find.text('Tor preferences address')))
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(find.text('$_onionOrigin/preferences#api-access'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final barrier in [false, true]) {
    for (final succeeds in [false, true]) {
      testWidgets(
          '${barrier ? 'barrier' : 'OK'} dismissal during clipboard ${succeeds ? 'success' : 'failure'} does not update or pop setup',
          (tester) async {
        clipboard = Completer<void>();
        await showSetup(tester, pushed: true);
        final setupRoute =
            ModalRoute.of(tester.element(find.byType(NerdVpnOnionSetup)))!;
        await tester.tap(find.text('Tor preferences address'));
        await tester.pumpAndSettle();
        final dialogContext = tester.element(find.byType(AlertDialog));
        final dialogRoute = ModalRoute.of(dialogContext)!;
        await tester.tap(find.text('Copy to clipboard'));
        await tester.pump();
        if (barrier) {
          await tester.tapAt(const Offset(1, 1));
        } else {
          await tester.tap(find.text('OK'));
        }
        expect(dialogContext.mounted, isTrue);
        expect(dialogRoute.isCurrent, isFalse);
        if (succeeds) {
          clipboard!.complete();
        } else {
          clipboard!.completeError(PlatformException(code: 'unavailable'));
        }
        await tester.pump();
        expect(calls, isEmpty);
        expect(setupRoute.isCurrent, isTrue);
        await tester.pumpAndSettle();
        expect(find.byType(NerdVpnOnionSetup), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
      'copy failure keeps the selectable address and allows another attempt',
      (tester) async {
    clipboard = Completer<void>();
    await showSetup(tester);
    await tester.tap(find.text('Tor preferences address'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy to clipboard'));
    await tester.pump();
    clipboard!.completeError(PlatformException(code: 'unavailable'));
    await tester.pumpAndSettle();
    expect(
        find.text('The address could not be copied. Select and copy it below.'),
        findsOneWidget);
    expect(find.text('$_onionOrigin/preferences#api-access'), findsOneWidget);
    expect(calls, isEmpty);
    clipboard = null;
    await tester.tap(find.text('Copy to clipboard'));
    await tester.pumpAndSettle();
    expect(clipboardText, '$_onionOrigin/preferences#api-access');
    expect(find.text('Address copied.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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
