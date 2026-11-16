import 'dart:io';

import '../../network/direct_http_client.dart';
import '../../network/network_proxy.dart';
import '../../network/reloadable_http_client.dart';
import 'podcast_url.dart';

export 'podcast_url.dart';

/// Publisher traffic follows the selected network proxy, without instance
/// headers, login cookies, gateway recovery, or relaxed certificate validation.
HttpClient createPodcastHttpClient() => ReloadableHttpClient(() {
      final client = createDirectHttpClient()
        ..connectionTimeout = const Duration(seconds: 20)
        ..userAgent = 'Videre-Podcasts'
        ..badCertificateCallback = ((_, __, ___) => false);
      // Routing validates before every request, redirect and connection reuse.
      NetworkProxy.instance.configureClient(client,
          requireValidCertificate: true,
          validateDestination: PodcastUrlPolicy.validate);
      return client;
    });
