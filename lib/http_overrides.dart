import 'dart:io';

import 'package:clipious/globals.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'network/network_proxy.dart';
import 'network/reloadable_http_client.dart';

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return ReloadableHttpClient(() {
      final client = super.createHttpClient(context)
        ..userAgent =
            'Videre/${packageInfo?.version ?? '0.0.0'} (${packageInfo?.packageName ?? ''})'
        ..badCertificateCallback =
            (X509Certificate cert, String host, int port) {
          // if true, it will allow all certs, if false it will throw error on a bad cert
          return db.getSettings(skipSslVerificationSettingName)?.value ==
              'true';
        };
      NetworkProxy.instance.configureClient(client, context: context);
      return client;
    });
  }
}
