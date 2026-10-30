import 'dart:async';

import 'package:clipious/l10n/generated/app_localizations_en.dart';
import 'package:clipious/globals.dart' as globals;
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/services/backend_browser.dart';
import 'package:clipious/settings/services/backend_discovery.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('videre/backend_discovery');
  const server = Server(url: 'https://invidious.nerdvpn.de');
  final locals = AppLocalizationsEn();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
  });

  test('browser is restricted to exact official HTTPS Android origins', () {
    expect(BackendBrowser.supports(server), isTrue);
    expect(
        BackendBrowser.supports(
            const Server(url: 'https://www.invidious.nerdvpn.de/')),
        isTrue);
    for (final url in [
      'http://invidious.nerdvpn.de',
      'https://invidious.nerdvpn.de:8443',
      'https://invidious.nerdvpn.de.attacker.example',
      'https://invidious.nerdvpn.de@attacker.example',
      'https://user@invidious.nerdvpn.de',
      'https://invidious.nerdvpn.de/path',
      'https://invidious.nerdvpn.de/?query=true',
      'https://invidious.nerdvpn.de/#fragment',
      'not a server',
    ]) {
      expect(BackendBrowser.supports(Server(url: url)), isFalse, reason: url);
    }
    for (final platform in TargetPlatform.values
        .where((platform) => platform != TargetPlatform.android)) {
      debugDefaultTargetPlatformOverride = platform;
      expect(BackendBrowser.supports(server), isFalse, reason: '$platform');
    }
  });

  test('unsupported servers never open a native browser', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return null;
    });
    await expectLater(
        BackendBrowser.open(const Server(url: 'https://other.example'), locals),
        throwsA(isA<BackendDiscoveryException>()));
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await expectLater(BackendBrowser.open(server, locals),
        throwsA(isA<BackendDiscoveryException>()));
    expect(calls, 0);
  });

  test('proxy mode opens the native browser using its saved connection',
      () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return {
        'url': 'https://invidious.nerdvpn.de/',
        'html': '<div id="backend-selector">public choices</div>',
      };
    });
    await NetworkProxy.instance.initialize(
        saved: '{"enabled":true,"host":"127.0.0.1","port":9050}',
        configureNative: false);
    final result = await BackendBrowser.open(server, locals);
    expect(result!.source, contains('public choices'));
    expect(received!.method, 'open');
    final arguments = received!.arguments as Map;
    expect(arguments.containsKey('host'), isFalse);
    expect(arguments.containsKey('port'), isFalse);
    expect(arguments.containsKey('proxy'), isFalse);
  });

  test('unsupported native proxy capability has a dedicated error', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
          code: 'BROWSER_PROXY_UNSUPPORTED', message: 'private-native-details');
    });
    await NetworkProxy.instance
        .initialize(saved: '{"enabled":true}', configureNative: false);
    await expectLater(BackendBrowser.open(server, locals),
        throwsA(isA<BackendBrowserProxyUnsupported>()));
  });

  test('proxy changes wait for native browser teardown', () async {
    final store = await SembastSqfDb.createInMemory();
    globals.db = store;
    addTearDown(store.close);
    final pending = Completer<Map<String, dynamic>?>();
    final closing = Completer<void>();
    final release = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'open') return pending.future;
      expect(call.method, 'close');
      closing.complete();
      await release.future;
      pending.complete(null);
      return null;
    });
    final browser = BackendBrowser.open(server, locals);
    await Future<void>.delayed(Duration.zero);
    final applying =
        NetworkProxy.instance.apply(SocksProxyConfig(enabled: true));
    await closing.future;
    expect(NetworkProxy.instance.config.enabled, isFalse);
    release.complete();
    await applying;
    expect(await browser, isNull);
    expect(NetworkProxy.instance.config.enabled, isTrue);
  });

  test('a changed connection cannot accept a stale browser result', () async {
    final pending = Completer<Map<String, dynamic>>();
    messenger.setMockMethodCallHandler(channel, (call) => pending.future);
    final browser = BackendBrowser.open(server, locals);
    await Future<void>.delayed(Duration.zero);
    await NetworkProxy.instance
        .initialize(saved: '{"enabled":true}', configureNative: false);
    final expectation =
        expectLater(browser, throwsA(isA<BackendDiscoveryException>()));
    pending.complete({
      'url': 'https://invidious.nerdvpn.de/',
      'html': '<div id="backend-selector">public choices</div>',
    });
    await expectation;
  });

  test('native cancellation returns null and sends no credentials', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    final configured = server.copyWith(
        authToken: 'private-token',
        sidCookie: 'SID=private-session',
        customHeaders: {
          'Cookie': 'custom-session',
          'X-Api-Key': 'private-key'
        });

    expect(await BackendBrowser.open(configured, locals), isNull);
    expect(received!.method, 'open');
    final arguments = received!.arguments as Map;
    expect(
        arguments.keys,
        unorderedEquals(
            ['url', 'title', 'usePage', 'cancel', 'help', 'noOptions']));
    expect(arguments['url'], 'https://invidious.nerdvpn.de/');
    expect(arguments.values.join(' '), isNot(contains('private-')));
    expect(arguments.values.join(' '), isNot(contains('custom-session')));
  });

  test('native result returns public page data without session fields',
      () async {
    messenger.setMockMethodCallHandler(
        channel,
        (call) async => {
              'url': 'https://invidious.nerdvpn.de/',
              'html': '<div id="backend-selector">public choices</div>',
              'cookies': 'private-native-data-must-not-be-returned',
            });

    final result = await BackendBrowser.open(server, locals);
    expect(result!.uri, Uri.parse('https://invidious.nerdvpn.de/'));
    expect(result.source, '<div id="backend-selector">public choices</div>');
    expect(result.source, isNot(contains('private-native-data')));
  });

  test('native errors become generic discovery errors', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
          code: 'private-code', message: 'private-native-session');
    });
    await expectLater(
        BackendBrowser.open(server, locals),
        throwsA(isA<BackendDiscoveryException>().having(
            (error) => error.toString(),
            'sanitized message',
            isNot(contains('private-')))));
  });

  test('malformed native results cannot become a browser page', () async {
    for (final data in [
      {'url': 123, 'html': '<div>choices</div>'},
      {'url': 'https://invidious.nerdvpn.de/', 'html': 123},
      {'url': 'https://invidious.nerdvpn.de/'},
    ]) {
      messenger.setMockMethodCallHandler(channel, (call) async => data);
      await expectLater(BackendBrowser.open(server, locals),
          throwsA(isA<BackendDiscoveryException>()));
    }
  });
}
