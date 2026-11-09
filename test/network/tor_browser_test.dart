import 'package:clipious/network/nerdvpn_origin.dart';
import 'package:clipious/network/tor_browser.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('videre/tor_browser');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final browser = TorBrowser(channel: channel);
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('opens only the separate app without sending a URL or credentials',
      () async {
    expect(await browser.openApp(), isTrue);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'openApp');
    expect(calls.single.arguments, isNull);
  });

  test('reports a missing app without falling back to another browser',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return false;
    });
    expect(await browser.openApp(), isFalse);
    expect(calls, hasLength(1));
  });

  for (final origin in [
    'http://$nerdVpnOnionHost',
    'http://$nerdVpnOnionHost:80/',
    'https://$nerdVpnOnionHost',
    'https://$nerdVpnOnionHost:443/',
  ]) {
    test('opens preferences using only the validated origin: $origin',
        () async {
      expect(await browser.openNerdVpnPreferences(origin), isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'openNerdVpnPreferences');
      expect(calls.single.arguments, {'serverUrl': Uri.parse(origin).origin});
    });
  }

  test('rejects other origins and URLs carrying paths or credentials',
      () async {
    for (final url in [
      '',
      'not a URL',
      'https://invidious.nerdvpn.de',
      'http://other.onion',
      'https://$nerdVpnOnionHost.example',
      'http://$nerdVpnOnionHost:443',
      'https://$nerdVpnOnionHost:80',
      'http://user:password@$nerdVpnOnionHost',
      'http://@$nerdVpnOnionHost',
      'http://$nerdVpnOnionHost/preferences',
      'http://$nerdVpnOnionHost/?key=secret',
      'http://$nerdVpnOnionHost/#secret',
      'http://$nerdVpnOnionHost/?',
      'http://$nerdVpnOnionHost/#',
    ]) {
      expect(await browser.openNerdVpnPreferences(url), isFalse, reason: url);
    }
    expect(calls, isEmpty);
  });

  test('reports unavailable without another browser attempt', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return false;
    });
    expect(await browser.openNerdVpnPreferences('http://$nerdVpnOnionHost'),
        isFalse);
    expect(calls, hasLength(1));
  });

  test('reports missing native support as unavailable', () async {
    messenger.setMockMethodCallHandler(channel, null);
    expect(await browser.openNerdVpnPreferences('http://$nerdVpnOnionHost'),
        isFalse);
  });

  test('reports a failed native handoff as unavailable', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'UNAVAILABLE');
    });
    expect(await browser.openNerdVpnPreferences('http://$nerdVpnOnionHost'),
        isFalse);
  });

  test('an empty native result is not a successful launch', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await browser.openNerdVpnPreferences('http://$nerdVpnOnionHost'),
        isFalse);
  });
}
