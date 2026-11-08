import 'package:clipious/network/gateway_context.dart';
import 'package:clipious/network/gateway_session_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/gateway_sessions');
  final bridge = GatewaySessionBridge(channel: channel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final context = GatewayRequestContext.forAccount(
      'profile', 'account', 'https://invidious.nerdvpn.de')!;
  final url = Uri.parse('https://invidious.nerdvpn.de/api/v1/videos/example');
  const requiredFields = {'enabled': true, 'needsSignIn': false};
  Object? payload;

  Future<GatewayResolvedSession> resolve() =>
      bridge.resolve(context.encoded, url);

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    messenger.setMockMethodCallHandler(channel, (_) async => payload);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('resolves native credentials and revisions while ignoring extra fields',
      () async {
    payload = {
      ...requiredFields,
      'cookies': 'session=test',
      'revision': 4,
      'apiKey': 'test-api-key',
      'accessError': 'waiting',
      'apiKeyRevision': 5,
      'apiKeyIntent': 6,
      'futureField': <Object?>[1, null],
    };

    final result = await resolve();

    expect(result.enabled, isTrue);
    expect(result.needsSignIn, isFalse);
    expect(result.cookies, 'session=test');
    expect(result.revision, 4);
    expect(result.apiKey, 'test-api-key');
    expect(result.accessError, 'waiting');
    expect(result.apiKeyRevision, 5);
    expect(result.apiKeyIntent, 6);
  });

  test('accepts missing and explicitly null optional native fields', () async {
    for (final fields in [
      requiredFields,
      {
        ...requiredFields,
        'cookies': null,
        'revision': null,
        'apiKey': null,
        'accessError': null,
        'apiKeyRevision': null,
        'apiKeyIntent': null,
      },
    ]) {
      payload = fields;

      final result = await resolve();

      expect(result.enabled, isTrue);
      expect(result.needsSignIn, isFalse);
      expect(result.cookies, isNull);
      expect(result.revision, isNull);
      expect(result.apiKey, isNull);
      expect(result.accessError, isNull);
      expect(result.apiKeyRevision, isNull);
      expect(result.apiKeyIntent, isNull);
    }
  });

  test('rejects absent or malformed native session fields safely', () async {
    final malformed = <Object?>[
      null,
      <String, Object?>{},
      {'enabled': true},
      {'needsSignIn': false},
      {...requiredFields, 'enabled': 'true'},
      {...requiredFields, 'enabled': null},
      {...requiredFields, 'needsSignIn': 0},
      {...requiredFields, 'needsSignIn': null},
      for (final field in ['cookies', 'apiKey', 'accessError'])
        {...requiredFields, field: 1},
      for (final field in ['revision', 'apiKeyRevision', 'apiKeyIntent'])
        {...requiredFields, field: '1'},
    ];
    for (final value in malformed) {
      payload = value;
      await expectLater(resolve(), throwsA(isA<GatewayTransportUnavailable>()));
    }
  });

  test('rejects platform failures without exposing native error details',
      () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'FAILED', message: 'private native detail');
    });

    await expectLater(
        resolve(),
        throwsA(isA<GatewayTransportUnavailable>().having(
            (error) => error.toString(),
            'safe message',
            isNot(contains('private native detail')))));
  });
}
