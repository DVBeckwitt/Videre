import 'package:clipious/network/gateway_context.dart';
import 'package:clipious/network/nerdvpn_access.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const onion = 'http://$nerdVpnOnionHost';

  test('onion context round trips and attaches only to its exact origin', () {
    final context =
        GatewayRequestContext.forAccount('person', 'account', onion)!;
    expect(GatewayRequestContext.tryParse(context.encoded)!.origin,
        Uri.parse(onion));
    for (final path in ['/api/v1/videos/song', '/api/v1/auth/api_key']) {
      final headers = gatewayContextHeaders(
          profileId: 'person',
          accountId: 'account',
          serverUrl: onion,
          targetUrl: '$onion$path');
      expect(headers[gatewayContextHeader], context.encoded);
    }
    for (final target in [
      'https://$nerdVpnOnionHost/api/v1/videos/song',
      'https://invidious.nerdvpn.de/api/v1/videos/song',
      'http://$nerdVpnOnionHost:81/api/v1/videos/song',
      'http://other.onion/api/v1/videos/song',
      'http://$nerdVpnOnionHost.attacker.example/api/v1/videos/song',
      'http://user@$nerdVpnOnionHost/api/v1/videos/song',
    ]) {
      expect(context.allows(Uri.parse(target)), isFalse, reason: target);
      expect(
          gatewayContextHeaders(
              profileId: 'person',
              accountId: 'account',
              serverUrl: onion,
              targetUrl: target,
              headers: {gatewayContextHeader: context.encoded}),
          isNot(contains(gatewayContextHeader)),
          reason: target);
    }
  });

  test('onion credentials are isolated by origin, profile and account', () {
    final keys = {
      for (final identity in [
        ('person', 'account', onion),
        ('person', 'account', 'https://$nerdVpnOnionHost'),
        ('person', 'account', 'https://invidious.nerdvpn.de'),
        ('other-person', 'account', onion),
        ('person', 'other-account', onion),
      ])
        GatewayRequestContext.forAccount(identity.$1, identity.$2, identity.$3)!
            .key,
    };
    expect(keys, hasLength(5));
  });

  test('HTTP gateway exception does not extend to other hosts or ports', () {
    for (final origin in [
      'http://invidious.nerdvpn.de',
      'http://other.onion',
      'http://$nerdVpnOnionHost:8080',
      'http://sub.$nerdVpnOnionHost',
      'http://user@$nerdVpnOnionHost',
      'http://$nerdVpnOnionHost.attacker.example',
    ]) {
      expect(
          GatewayRequestContext.forAccount('person', 'account', origin), isNull,
          reason: origin);
    }
    expect(
        GatewayRequestContext.forAccount(
            'person', 'account', 'https://other.example'),
        isNotNull);
  });
}
