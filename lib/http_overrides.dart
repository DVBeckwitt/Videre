import 'dart:io';

import 'package:clipious/globals.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'network/gateway_http_client.dart';
import 'network/nerdvpn_origin.dart';
import 'network/network_proxy.dart';
import 'network/reloadable_http_client.dart';

class MyHttpOverrides extends HttpOverrides {
  // A separately installed test build can use the normal app request identity.
  // Release builds omit this define and keep their package-derived identity.
  static const _buildUserAgent = String.fromEnvironment('VIDERE_USER_AGENT');

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return ReloadableHttpClient(() {
      final client = super.createHttpClient(context)
        ..userAgent = _buildUserAgent.isNotEmpty
            ? _buildUserAgent
            : 'Videre/${packageInfo?.version ?? '0.0.0'} (${packageInfo?.packageName ?? ''})'
        ..badCertificateCallback =
            (X509Certificate cert, String host, int port) {
          // Managed credentials require a valid certificate on both public
          // and onion HTTPS origins, regardless of other servers' overrides.
          if (isNerdVpnUrl(
              Uri(scheme: 'https', host: host, port: port).toString())) {
            return false;
          }
          // if true, it will allow all certs, if false it will throw error on a bad cert
          return db.getSettings(skipSslVerificationSettingName)?.value ==
              'true';
        };
      NetworkProxy.instance.configureClient(client, context: context);
      return GatewayHttpClient(client);
    });
  }
}
