import '../network/nerdvpn_origin.dart';
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
  // Validation must not reserialize a signed media query.
  return url;
}

String? validatedMediaUrl(String? value, Server server) {
  final url = parseMediaUrl(value);
  final uri = url == null ? null : Uri.parse(url);
  final serverUri = Uri.tryParse(server.url);
  if (uri == null || serverUri == null) return null;
  if (sameMediaOrigin(uri, serverUri)) return url;
  return null;
}

Map<String, String>? mediaHeaders(Server server, String url) {
  final headers = server.headersForUrl(url);
  return headers == null || headers.isEmpty ? null : headers;
}

String proxyMediaUrl(String url, Server server, {bool adaptive = false}) {
  final source = Uri.parse(url);
  final target = Uri.tryParse(server.url);
  // NerdVPN sometimes advertises its public media origin from its onion API.
  // Keep already-proxied media on the chosen endpoint and its own credentials.
  if (target != null &&
      isNerdVpnUrl(url) &&
      isNerdVpnUrl(server.url) &&
      (target.path.isEmpty || target.path == '/') &&
      !target.hasQuery &&
      !target.hasFragment &&
      !sameMediaOrigin(source, target) &&
      !source.pathSegments.any((part) => part == '.' || part == '..') &&
      (source.path == '/videoplayback' ||
          source.path.startsWith('/videoplayback/') ||
          source.path.startsWith('/api/manifest/dash/id/') ||
          source.path.startsWith('/api/manifest/hls_playlist/') ||
          source.path.startsWith('/api/manifest/hls_variant/'))) {
    final pathStart = url.indexOf('/', url.indexOf('://') + 3);
    url = '${target.origin}${url.substring(pathStart)}';
  }
  if (adaptive) {
    return _withMediaParameter(url, 'local', 'true');
  }
  final host = source.host.toLowerCase();
  if (host != 'googlevideo.com' && !host.endsWith('.googlevideo.com')) {
    return url;
  }
  if ((source.scheme != 'https' || source.port != 443) &&
      (source.scheme != 'http' || source.port != 80)) {
    return url;
  }
  if (target == null ||
      (target.scheme != 'http' && target.scheme != 'https') ||
      target.host.isEmpty) {
    return url;
  }
  if (sameMediaOrigin(source, target)) return url;
  final prefix = target.path.endsWith('/')
      ? target.path.substring(0, target.path.length - 1)
      : target.path;
  // Invidious's media proxy needs the original Googlevideo host. Preserve the
  // signed query's spelling, ordering and repeated fields instead of decoding
  // and re-encoding the complete query through queryParametersAll.
  final fragmentStart = url.indexOf('#');
  final query = source.hasQuery
      ? url.substring(
          url.indexOf('?') + 1, fragmentStart < 0 ? url.length : fragmentStart)
      : '';
  final proxied = Uri(
    scheme: target.scheme,
    userInfo: target.userInfo,
    host: target.host,
    port: target.hasPort ? target.port : null,
    path: '$prefix${source.path}',
  ).toString();
  return _withMediaParameter(
      '$proxied${source.hasQuery ? '?$query' : ''}'
          '${fragmentStart < 0 ? '' : url.substring(fragmentStart)}',
      'host',
      host);
}

String _withMediaParameter(String url, String name, String value) {
  final fragmentStart = url.indexOf('#');
  final fragment = fragmentStart < 0 ? '' : url.substring(fragmentStart);
  final base = fragmentStart < 0 ? url : url.substring(0, fragmentStart);
  final queryStart = base.indexOf('?');
  final query = queryStart < 0 ? '' : base.substring(queryStart + 1);
  final fields = query.isEmpty ? <String>[] : query.split('&');
  fields.removeWhere((field) {
    try {
      return Uri.decodeQueryComponent(field.split('=').first) == name;
    } on FormatException {
      return false;
    }
  });
  fields.add('$name=${Uri.encodeQueryComponent(value)}');
  return '${queryStart < 0 ? base : base.substring(0, queryStart)}'
      '?${fields.join('&')}$fragment';
}
