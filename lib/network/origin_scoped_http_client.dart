import 'package:http/http.dart' as http;

/// Instance access controls may use arbitrary header names. Keep all supplied
/// headers on their original origin instead of relying on the transport's list
/// of standard credentials to strip during redirects.
class OriginScopedHttpClient extends http.BaseClient {
  final http.Client _inner;

  OriginScopedHttpClient(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final followRedirects = request.followRedirects;
    final maxRedirects = request.maxRedirects;
    var current = request;
    for (var redirects = 0;; redirects++) {
      current.followRedirects = false;
      final response = await _inner.send(current);
      final location = response.headers['location'];
      final status = response.statusCode;
      final canRedirect = current.method == 'GET' ||
          current.method == 'HEAD' ||
          (current.method == 'POST' && status == 303);
      if (!followRedirects ||
          !canRedirect ||
          !const {301, 302, 303, 307, 308}.contains(status) ||
          location == null) {
        return response;
      }
      // Finish each response before reusing the connection. Never replay the
      // original request body, including credentials posted to a login form.
      await response.stream.drain<void>();
      if (redirects >= maxRedirects) {
        throw http.ClientException('Maximum HTTP redirects exceeded.');
      }
      final target = current.url.resolve(location);
      if (!const {'http', 'https'}.contains(target.scheme) ||
          target.host.isEmpty ||
          target.userInfo.isNotEmpty) {
        throw http.ClientException('Invalid HTTP redirect.');
      }
      final next = http.Request(
          current.method == 'POST' ? 'GET' : current.method, target)
        ..persistentConnection = current.persistentConnection;
      if (target.origin == current.url.origin) {
        next.headers.addAll(current.headers);
        next.headers.removeWhere((name, _) => const {
              'content-length',
              'transfer-encoding',
              'host',
            }.contains(name.toLowerCase()));
      }
      current = next;
    }
  }

  @override
  void close() => _inner.close();
}
