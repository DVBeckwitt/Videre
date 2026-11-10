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

  test('an installed Tor Browser cannot be launched outside the privacy guard',
      () async {
    expect(await browser.openApp(), isFalse);
    expect(calls, isEmpty);
  });

  for (final address in [
    'http://other.onion/watch?v=video123456&local=true#chapter',
    'https://other.onion:8443/invidious/preferences?theme=dark',
    'http://OTHER.ONION./channel/UCexample?next=a%2Bb%20c',
    'https://instance.example/watch?v=video123456',
    'http://other.onion.example/watch',
    'http://onion/watch',
    'ftp://other.onion/watch',
    'javascript:alert(1)',
    '//other.onion/watch',
    '/watch?v=video123456',
    'http://user:password@other.onion/watch',
    'https://user@other.onion/preferences',
  ]) {
    test('cannot delegate a URL to an unguarded browser: $address', () async {
      expect(await browser.openOnionUrl(Uri.parse(address)), isFalse);
      expect(calls, isEmpty);
    });
  }

  for (final origin in [
    'http://$nerdVpnOnionHost',
    'http://$nerdVpnOnionHost:80/',
    'https://$nerdVpnOnionHost',
    'https://$nerdVpnOnionHost:443/',
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
    test('preferences remain copy-only without a platform call: $origin',
        () async {
      expect(await browser.openNerdVpnPreferences(origin), isFalse);
      expect(calls, isEmpty);
    });
  }

  test('onion address recognition retains host boundaries and trailing dots',
      () {
    for (final url in [
      'http://instance.onion/watch',
      'https://INSTANCE.ONION./watch',
    ]) {
      expect(TorBrowser.isOnionAddress(Uri.parse(url)), isTrue);
    }
    for (final url in [
      'https://onion/watch',
      'https://instance.onion.example/watch',
      'https://instance.example/onion',
    ]) {
      expect(TorBrowser.isOnionAddress(Uri.parse(url)), isFalse);
    }
  });
}
