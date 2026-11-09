import 'package:clipious/network/nerdvpn_access.dart';
import 'package:clipious/player/dash_manifest_resolver.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const instance = Server(url: 'https://invidious.nerdvpn.de');

  for (final code in [
    'credentials_required',
    'invalid_credentials',
    'not_yet_eligible',
    'access_disabled',
    'access_denied',
  ]) {
    test('$code preserves the account session', () {
      final failure = InvidiousServiceError(code,
          statusCode: 403, errorCode: code, isGatewayResponse: true);
      expect(failure.isAuthenticationFailure, isFalse);
      expect(isBackendRetryable(failure), isFalse);
    });
  }

  test('missing scope requires authorization without rejecting the token', () {
    final failure = InvidiousServiceError('Invalid scope',
        statusCode: 403, errorCode: 'Invalid scope', isGatewayResponse: true);
    expect(failure.isAuthenticationFailure, isFalse);
  });

  for (final (origin, retryable) in [
    (instance.url, false),
    ('http://$nerdVpnOnionHost', false),
    ('https://$nerdVpnOnionHost', false),
    ('https://instance.example', true),
  ]) {
    test('$origin preserves its unavailable response classification', () {
      final api = Service();
      addTearDown(api.httpClient.close);
      final response = http.Response('{"error":"unavailable"}', 503,
          request: http.Request('GET', Uri.parse('$origin/api/v1/videos/id')),
          headers: {'content-type': 'application/json'});
      expect(
          () => api.handleResponse(response),
          throwsA(isA<InvidiousServiceError>().having(
              (error) => isBackendRetryable(error),
              'backend retry',
              retryable)));
    });
  }

  for (final (status, code) in [(429, 'rate_limited'), (503, 'unavailable')]) {
    test('DASH $code stops both backend and progressive retries', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('{"error":"$code"}', status,
            headers: {'content-type': 'application/json'});
      });
      addTearDown(client.close);
      final resolver = DashManifestResolver(client);
      await expectLater(
          resolver.resolve(
              '${instance.url}/api/manifest/dash/id/video', 'video', instance,
              throwRetryable: true),
          throwsA(isA<InvidiousServiceError>().having(
              (error) => isBackendRetryable(error), 'backend retry', isFalse)));
      expect(requests, 1);
    });
  }

  test('DASH retains the native access state rather than swallowing it',
      () async {
    final client = MockClient((_) async {
      throw const NerdVpnAccessRequired('disabled');
    });
    addTearDown(client.close);
    await expectLater(
        DashManifestResolver(client).resolve(
            '${instance.url}/api/manifest/dash/id/video', 'video', instance),
        throwsA(isA<NerdVpnAccessRequired>()
            .having((error) => error.state, 'state', 'disabled')));
  });
}
