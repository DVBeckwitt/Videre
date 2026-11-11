import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../network/nerdvpn_origin.dart';
import '../network/youtube_privacy.dart';
import '../settings/models/db/server.dart';

/// Older saved Music songs sometimes put an instance's video fallback into
/// their catalog artwork. Recognize only actual Invidious image routes; public
/// YouTube image URLs are still valid original catalog artwork.
bool isInvidiousThumbnailUrl(String url) {
  final image = Uri.tryParse(url);
  if (image == null ||
      image.userInfo.isNotEmpty ||
      (image.hasScheme && !const {'http', 'https'}.contains(image.scheme))) {
    return false;
  }
  if (isOfficialYoutubeHost(image.host)) {
    return false;
  }
  return RegExp(r'(^|/)(vi|vi_webp|s_p|pl_c|tvfilm_banner)/[^/]+/[^/]+$')
          .hasMatch(image.path) ||
      RegExp(r'(^|/)ggpht/.+$').hasMatch(image.path) ||
      RegExp(r'(^|/)sb/i[0-9]?/[^/]+/.+$').hasMatch(image.path);
}

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

/// Routes YouTube artwork through Invidious. Resolve at request time so saved
/// metadata benefits too, without storing an instance-specific replacement in
/// the library.
/// A null result means no supported private route exists; callers must omit the
/// image instead of fetching its original Google URL.
String? invidiousImageUrl(String url, Server server) {
  if (url.isEmpty) return url;
  final image = Uri.tryParse(url);
  if (image == null) return url;
  final base = server.url.replaceFirst(RegExp(r'/+$'), '');
  final host = image.host.toLowerCase().replaceFirst(RegExp(r'\.+$'), '');

  if (!image.hasScheme && !image.hasAuthority) {
    return '$base/${url.startsWith('/') ? url.substring(1) : url}';
  }
  if (image.hasScheme && image.scheme != 'http' && image.scheme != 'https') {
    return isOfficialYoutubeUrl(image) ? null : url;
  }

  final target = Uri.tryParse(server.url);
  if (target != null &&
      isNerdVpnOnionUrl(server.url) &&
      isNerdVpnUrl(url) &&
      (target.path.isEmpty || target.path == '/') &&
      !target.hasQuery &&
      !target.hasFragment &&
      image.origin != target.origin &&
      image.path.startsWith('/vi/')) {
    // NerdVPN's onion API can advertise canonical public thumbnails. Keep
    // those requests on the selected onion account without copying credentials
    // across origins. Match the raw path so normalized traversal is rejected.
    final match = RegExp(
      r'^[^:]+://[^/?#\\@]+(/vi/[a-zA-Z0-9_-]{11}/[a-zA-Z0-9_-]+\.jpg(?:[?#].*)?)$',
    ).firstMatch(url);
    if (match != null) {
      return '${target.origin}${match[1]}';
    }
  }

  String? path;
  if (host == 'yt3.ggpht.com' ||
      host == 'yt3.googleusercontent.com' ||
      host == 'lh3.googleusercontent.com') {
    // Music artist portraits use the same image IDs on lh3. Invidious's
    // /ggpht route serves these too, without a direct Google fallback.
    path = '/ggpht${image.path}';
  } else if (RegExp(r'^i[0-9]?\.ytimg\.com$').hasMatch(host)) {
    // Only routes supported by Invidious's image controller. In particular,
    // /vi_webp is not a proxy endpoint; request its JPEG equivalent instead.
    if (image.path.startsWith('/sb/')) {
      path = '/sb/${host.split('.').first}/${image.path.substring(4)}';
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
  if (isOfficialYoutubeUrl(image)) return null;
  // DeArrow and other independent image providers retain their own origins.
  return image.hasScheme
      ? url
      : image.replace(scheme: Uri.parse(server.url).scheme).toString();
}
