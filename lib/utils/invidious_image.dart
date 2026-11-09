import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../settings/models/db/server.dart';

/// Private instance images must not reuse another person's cached response.
String invidiousImageCacheKey(String url, Server server) {
  final target = Uri.tryParse(url);
  final origin = Uri.tryParse(server.url);
  if (target == null ||
      origin == null ||
      !const {'http', 'https'}.contains(target.scheme) ||
      !const {'http', 'https'}.contains(origin.scheme) ||
      target.origin != origin.origin) {
    return url;
  }
  return 'videre-account-image:${const Uuid().v5(Namespace.url.value, jsonEncode([
            server.profileId,
            server.accountId,
            url
          ]))}';
}

/// Routes YouTube artwork through Invidious, independently of the video-stream
/// and SOCKS proxy settings. Resolve at request time so saved metadata benefits
/// too, without storing an instance-specific replacement in the library.
String invidiousImageUrl(String url, Server server) {
  if (url.isEmpty) return url;
  final image = Uri.tryParse(url);
  if (image == null) return url;
  final base = server.url.replaceFirst(RegExp(r'/+$'), '');

  if (!image.hasScheme && !image.hasAuthority) {
    return '$base/${url.startsWith('/') ? url.substring(1) : url}';
  }
  if (image.hasScheme && image.scheme != 'http' && image.scheme != 'https') {
    return url;
  }

  String? path;
  if (image.host == 'yt3.ggpht.com' ||
      image.host == 'yt3.googleusercontent.com' ||
      image.host == 'lh3.googleusercontent.com') {
    // Music artist portraits use the same image IDs on lh3. Invidious's
    // /ggpht route serves these too, without a direct Google fallback.
    path = '/ggpht${image.path}';
  } else if (RegExp(r'^i[0-9]?\.ytimg\.com$').hasMatch(image.host)) {
    // Only routes supported by Invidious's image controller. In particular,
    // /vi_webp is not a proxy endpoint; request its JPEG equivalent instead.
    if (image.path.startsWith('/sb/')) {
      path = '/sb/${image.host.split('.').first}/${image.path.substring(4)}';
    } else if (RegExp(r'^/vi/[^/]+/[^/]+$').hasMatch(image.path) ||
        RegExp(r'^/(s_p|pl_c|tvfilm_banner)/[^/]+/[^/]+$')
            .hasMatch(image.path)) {
      path = image.path;
    } else if (RegExp(r'^/vi_webp/[^/]+/[^/]+\.webp$').hasMatch(image.path)) {
      path = image.path.replaceFirst('/vi_webp/', '/vi/');
      path = '${path.substring(0, path.length - 5)}.jpg';
    }
  }

  if (path != null) {
    // Use the parsed, still-escaped path/query, without decoding image IDs or
    // adding a direct Google fallback if this instance cannot serve the image.
    return '$base$path${image.hasQuery ? '?${image.query}' : ''}';
  }
  // DeArrow and other independent image providers retain their own origins.
  return image.hasScheme
      ? url
      : image.replace(scheme: Uri.parse(server.url).scheme).toString();
}
