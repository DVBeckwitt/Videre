import 'package:http/http.dart' as http;

import 'onion_verification.dart';

/// Keeps thumbnail session headers on their original onion service, including
/// when a redirect changes only the port or adds a subdomain.
class OnionImageClient extends http.BaseClient {
  final http.Client _delegate;

  OnionImageClient({http.Client? client}) : _delegate = client ?? http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final origin = OnionVerification.origin(request.url);
    if (origin == null) return _delegate.send(request);
    final follow = request.followRedirects && request.method == 'GET';
    request.followRedirects = false;
    var next = request;
    for (var redirects = 0;; redirects++) {
      final response = await _delegate.send(next);
      final location = response.headers['location'];
      if (!follow ||
          !const [301, 302, 303, 307, 308].contains(response.statusCode) ||
          location == null ||
          redirects >= 3 ||
          redirects >= request.maxRedirects) {
        return response;
      }
      final redirect = Uri.tryParse(location);
      if (redirect == null) return response;
      final target = next.url.resolveUri(redirect);
      if (OnionVerification.origin(target) != origin) return response;
      await response.stream.listen(null).cancel();
      next = http.Request('GET', target)
        ..followRedirects = false
        ..headers.addAll(request.headers);
    }
  }

  @override
  void close() => _delegate.close();
}
