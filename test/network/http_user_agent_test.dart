import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/globals.dart';
import 'package:clipious/http_overrides.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/reloadable_http_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  const configuredIdentity = String.fromEnvironment('VIDERE_USER_AGENT');
  const packageIdentity =
      'Videre/1.22.30-backend-test.3 (com.github.dvbeckwitt.videre.backendtest)';
  late PackageInfo? previousPackageInfo;

  setUp(() async {
    previousPackageInfo = packageInfo;
    packageInfo = PackageInfo(
      appName: 'Videre Backend Test',
      packageName: 'com.github.dvbeckwitt.videre.backendtest',
      version: '1.22.30-backend-test.3',
      buildNumber: '60879',
    );
    await NetworkProxy.instance.initialize(
      saved: '{"enabled":false,"host":"127.0.0.1","port":9050}',
      configureNative: false,
    );
  });

  tearDown(() {
    packageInfo = previousPackageInfo;
  });

  Future<HttpServer> echoUserAgent() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
          .write(request.headers.value(HttpHeaders.userAgentHeader) ?? '');
      unawaited(request.response.close());
    });
    return server;
  }

  HttpClient appClient() {
    final client = MyHttpOverrides().createHttpClient(null);
    addTearDown(() => client.close(force: true));
    return client;
  }

  Future<String> readIdentity(HttpClient client, HttpServer server) async {
    final request = await client
        .getUrl(Uri.parse('http://127.0.0.1:${server.port}/api/v1/stats'));
    final response = await request.close();
    return response.transform(utf8.decoder).join();
  }

  test('app requests send the build identity or the actual package identity',
      () async {
    final server = await echoUserAgent();
    final expected =
        configuredIdentity.isEmpty ? packageIdentity : configuredIdentity;
    expect(await readIdentity(appClient(), server), expected);
  });

  test('request identity survives rebuilding the transport after a proxy reset',
      () async {
    final server = await echoUserAgent();
    final client = appClient();
    final expected =
        configuredIdentity.isEmpty ? packageIdentity : configuredIdentity;
    expect(await readIdentity(client, server), expected);
    ReloadableHttpClient.resetAll();
    expect(await readIdentity(client, server), expected);
  });

  test(
      'startup before package information is available retains a valid identity',
      () async {
    packageInfo = null;
    final server = await echoUserAgent();
    final expected =
        configuredIdentity.isEmpty ? 'Videre/0.0.0 ()' : configuredIdentity;
    expect(await readIdentity(appClient(), server), expected);
  });
}
