import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/feedback/models/feedback_report.dart';
import 'package:clipious/feedback/services/feedback_submission_client.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/http_overrides.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

FeedbackDraft report() => FeedbackDraft.empty().copyWith(
    title: 'Playback stopped',
    description: 'The player stops after a backend change.');
http.Response created({int status = 201, String? url}) => http.Response(
    jsonEncode({
      'status': 'created',
      'issueNumber': 123,
      'issueUrl': url ?? 'https://github.com/DVBeckwitt/Videre/issues/123',
    }),
    status);
Matcher fails(String code) => throwsA(
    isA<FeedbackFailure>().having((failure) => failure.code, 'code', code));

void main() {
  test('default build uses the public relay only after explicit submission',
      () async {
    var requests = 0;
    final client = FeedbackSubmissionClient(client: MockClient((request) async {
      requests++;
      expect(request.method, 'POST');
      expect(request.url.toString(),
          'https://feedback.dvbeckwitt.duckdns.org/v1/reports');
      return created();
    }));

    expect(client.configured, isTrue);
    expect(requests, 0);
    expect((await client.submit(report())).issueNumber, 123);
    expect(requests, 1);
  }, skip: const bool.hasEnvironment('VIDERE_FEEDBACK_URL'));

  test(
      'minimal report omits all optional data and sends no instance credentials',
      () async {
    final draft = report();
    final client = FeedbackSubmissionClient(
        endpoint: Uri.parse('https://feedback.example'),
        client: MockClient((request) async {
          expect(request.url.toString(), 'https://feedback.example/v1/reports');
          expect(request.followRedirects, isFalse);
          expect(request.headers.keys.map((key) => key.toLowerCase()),
              isNot(contains('cookie')));
          expect(request.headers.keys.map((key) => key.toLowerCase()),
              isNot(contains('authorization')));
          expect(jsonDecode(request.body), {
            'schemaVersion': 1,
            'submissionId': draft.submissionId,
            'kind': 'bug',
            'title': draft.title,
            'description': draft.description
          });
          return created();
        }));
    final receipt = await client.submit(draft);
    expect(receipt.issueNumber, 123);
    expect(receipt.submissionId, draft.submissionId);
  });

  test('caller and preview mutations cannot change a saved screenshot snapshot',
      () {
    final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nWQAAAAASUVORK5CYII=');
    final original = base64Encode(bytes);
    final draft = report().copyWith(screenshot: bytes);
    bytes[0] = 0;
    draft.screenshot![1] = 0;
    expect(base64Encode(draft.screenshot!), original);
    expect((draft.toRequest()['screenshot'] as Map)['base64'], original);
    expect(draft.isValid, isTrue);
  });
  test('explicit optional fields are attached without unknown diagnostics',
      () async {
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nWQAAAAASUVORK5CYII=');
    final draft = report().copyWith(
        kind: FeedbackKind.suggestion,
        diagnostics: {'appVersion': '1.22.30', 'cookie': 'SID=private'},
        screenshot: png);
    final client = FeedbackSubmissionClient(
        endpoint: Uri.parse('https://feedback.example'),
        client: MockClient((request) async {
          final value = jsonDecode(request.body) as Map<String, dynamic>;
          expect(value['kind'], 'suggestion');
          expect(value['diagnostics'], {'appVersion': '1.22.30'});
          expect(value['screenshot'],
              {'mimeType': 'image/png', 'base64': base64Encode(png)});
          return created(status: 200);
        }));
    expect((await client.submit(draft)).issueNumber, 123);
  });

  test('missing or unsafe service URLs are disabled before network access',
      () async {
    for (final uri in [
      '',
      'http://feedback.example',
      'https://user:password@feedback.example',
      'https://feedback.example/?key=secret',
      'file:///tmp/reports'
    ]) {
      final client = FeedbackSubmissionClient(
          endpoint: Uri.parse(uri),
          client: MockClient((_) async => fail('Network must not run')));
      expect(client.configured, isFalse, reason: uri);
      await expectLater(client.submit(report()), fails('unconfigured'));
    }
    expect(
        FeedbackSubmissionClient(
                endpoint: Uri.parse('http://127.0.0.1:18767'), allowHttp: true)
            .configured,
        isTrue);
    expect(
        FeedbackSubmissionClient(
                endpoint: Uri.parse('http://10.0.2.2:18767'), allowHttp: true)
            .configured,
        isTrue);
    expect(
        FeedbackSubmissionClient(
                endpoint: Uri.parse('http://192.168.1.2'), allowHttp: true)
            .configured,
        isFalse);
  });

  test('a pending receipt cannot be reported as success', () async {
    final client = FeedbackSubmissionClient(
        endpoint: Uri.parse('https://feedback.example'),
        client: MockClient((_) async => http.Response(
            '{"status":"pending"}', 202,
            headers: {'retry-after': '15'})));
    await expectLater(
        client.submit(report()),
        throwsA(isA<FeedbackFailure>()
            .having((e) => e.code, 'code', 'pending')
            .having((e) => e.retryAfterSeconds, 'retry', 15)));
  });

  test('service errors expose fixed error codes and never response text',
      () async {
    for (final entry in {
      400: 'validation',
      409: 'conflict',
      413: 'too_large',
      429: 'rate_limited',
      503: 'unavailable',
      502: 'github_failed',
      302: 'invalid_response'
    }.entries) {
      final client = FeedbackSubmissionClient(
          endpoint: Uri.parse('https://feedback.example'),
          client: MockClient(
              (_) async => http.Response('private SID=secret', entry.key)));
      await expectLater(client.submit(report()), fails(entry.value));
    }
  });

  test('success validates repository, issue identity and URL origin', () async {
    for (final url in [
      'https://github.com/attacker/Videre/issues/123',
      'https://github.com/DVBeckwitt/Videre/issues/124',
      'http://github.com/DVBeckwitt/Videre/issues/123',
      'https://github.com.evil.test/DVBeckwitt/Videre/issues/123',
      'https://github.com/DVBeckwitt/Videre/issues/123?token=secret'
    ]) {
      final client = FeedbackSubmissionClient(
          endpoint: Uri.parse('https://feedback.example'),
          client: MockClient((_) async => created(url: url)));
      await expectLater(client.submit(report()), fails('invalid_response'));
    }
  });

  test('missing and oversized success bodies are not confirmations', () async {
    for (final body in [
      '{}',
      'not json',
      jsonEncode({
        'status': 'created',
        'issueNumber': '123',
        'issueUrl': 'https://github.com/DVBeckwitt/Videre/issues/123'
      }),
      'x' * (64 * 1024 + 1)
    ]) {
      final client = FeedbackSubmissionClient(
          endpoint: Uri.parse('https://feedback.example'),
          client: MockClient((_) async => http.Response(body, 201)));
      await expectLater(client.submit(report()), fails('invalid_response'));
    }
  });

  test('timeout is uncertain and does not automatically repeat the POST',
      () async {
    var requests = 0;
    final completion = Completer<http.Response>();
    final client = FeedbackSubmissionClient(
        endpoint: Uri.parse('https://feedback.example'),
        timeout: const Duration(milliseconds: 20),
        client: MockClient((_) {
          requests++;
          return completion.future;
        }));
    await expectLater(client.submit(report()), fails('network'));
    expect(requests, 1);
    completion.complete(created());
  });

  test('transport follows no service redirect with submitted private data',
      () async {
    await NetworkProxy.instance
        .initialize(saved: '{"enabled":false}', configureNative: false);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var redirected = false;
    server.listen((request) async {
      if (request.uri.path == '/v1/reports') {
        expect(request.headers.value(HttpHeaders.userAgentHeader),
            'Videre-Feedback');
        await request.drain<void>();
        request.response.statusCode = 307;
        request.response.headers.set('Location', '/leak');
      } else {
        redirected = true;
      }
      await request.response.close();
    });
    final client = FeedbackSubmissionClient(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        allowHttp: true);
    await expectLater(client.submit(report()), fails('invalid_response'));
    expect(redirected, isFalse);
  });

  test('invalid saved proxy blocks feedback rather than connecting directly',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) {
      requests++;
      request.response.close();
    });
    await NetworkProxy.instance.initialize(
        saved: '{"enabled":true,"host":""}', configureNative: false);
    final client = FeedbackSubmissionClient(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        allowHttp: true);
    await expectLater(client.submit(report()), fails('network'));
    expect(requests, 0);
    await NetworkProxy.instance
        .initialize(saved: '{"enabled":false}', configureNative: false);
  });

  test(
      'strict feedback TLS rejects an instance certificate exception directly and via SOCKS policy',
      () async {
    db = await SembastSqfDb.createInMemory();
    addTearDown(() => db.close());
    await db.saveSetting(SettingsValue(skipSslVerificationSettingName, 'true'));
    const fixture =
        'submodules/flutter/packages/flutter_tools/test/data/asset_test/tls_cert';
    final context = SecurityContext()
      ..useCertificateChain('$fixture/dummy-cert.pem')
      ..usePrivateKey('$fixture/dummy-key.pem');
    final server =
        await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response.write('ok');
      request.response.close();
    }, onError: (Object _) {});
    final uri = Uri.parse('https://127.0.0.1:${server.port}/');
    for (final proxyEnabled in [false, true]) {
      await NetworkProxy.instance.initialize(
          saved: jsonEncode(
              {'enabled': proxyEnabled, 'host': '127.0.0.1', 'port': 9050}),
          configureNative: false);
      final ordinary = MyHttpOverrides().createHttpClient(null);
      try {
        expect(
            await (await (await ordinary.getUrl(uri)).close())
                .transform(utf8.decoder)
                .join(),
            'ok');
      } finally {
        ordinary.close(force: true);
      }
      final feedback = createFeedbackHttpClient();
      try {
        await expectLater(() async => (await feedback.getUrl(uri)).close(),
            throwsA(isA<HandshakeException>()));
      } finally {
        feedback.close(force: true);
      }
    }
    await NetworkProxy.instance
        .initialize(saved: '{"enabled":false}', configureNative: false);
  });
}
