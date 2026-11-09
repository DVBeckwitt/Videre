import '../settings/models/db/server.dart';

bool sameMediaOrigin(Uri left, Uri right) =>
    left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
    left.host.toLowerCase() == right.host.toLowerCase() &&
    left.port == right.port;

String? parseMediaUrl(String? value) {
  final url = value?.trim();
  final uri = url == null ? null : Uri.tryParse(url);
  if (uri == null ||
      uri.userInfo.isNotEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri.toString();
}

String? validatedMediaUrl(String? value, Server server) {
  final url = parseMediaUrl(value);
  final uri = url == null ? null : Uri.parse(url);
  final serverUri = Uri.tryParse(server.url);
  if (uri == null || serverUri == null) return null;
  if (sameMediaOrigin(uri, serverUri)) return uri.toString();

  final host = uri.host.toLowerCase();
  final trustedVideoHost = host == 'googlevideo.com' ||
      host.endsWith('.googlevideo.com') ||
      host == 'youtube.com' ||
      host.endsWith('.youtube.com');
  return uri.scheme == 'https' && uri.port == 443 && trustedVideoHost
      ? uri.toString()
      : null;
}

Map<String, String>? mediaHeaders(Server server, String url) {
  final headers = server.headersForUrl(url);
  return headers == null || headers.isEmpty ? null : headers;
}

String proxyMediaUrl(String url, Server server, bool useProxy,
    {bool adaptive = false}) {
  if (!useProxy) return url;
  if (adaptive) {
    final uri = Uri.parse(url);
    return uri.replace(queryParameters: {
      ...uri.queryParametersAll,
      'local': ['true']
    }).toString();
  }
  final source = Uri.parse(url);
  final host = source.host.toLowerCase();
  if (host != 'googlevideo.com' && !host.endsWith('.googlevideo.com')) {
    return url;
  }
  final target = Uri.tryParse(server.url);
  if (target == null ||
      (target.scheme != 'http' && target.scheme != 'https') ||
      target.host.isEmpty) {
    return url;
  }
  final prefix = target.path.endsWith('/')
      ? target.path.substring(0, target.path.length - 1)
      : target.path;
  return Uri(
    scheme: target.scheme,
    userInfo: target.userInfo,
    host: target.host,
    port: target.hasPort ? target.port : null,
    path: '$prefix${source.path}',
    query: source.hasQuery ? source.query : null,
    fragment: source.hasFragment ? source.fragment : null,
  ).toString();
}
