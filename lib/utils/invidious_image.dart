import 'dart:convert';

import 'package:uuid/uuid.dart';

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
  final target = Uri.tryParse(server.url);
  if (image == null ||
      image.userInfo.isNotEmpty ||
      target == null ||
      !const {'http', 'https'}.contains(target.scheme) ||
      target.host.isEmpty ||
      target.userInfo.isNotEmpty ||
      target.hasQuery ||
      target.hasFragment ||
      isOfficialYoutubeUrl(target)) {
    return null;
  }
  final base = server.url.replaceFirst(RegExp(r'/+$'), '');
  final queryStart = url.indexOf('?');
  final fragmentStart = url.indexOf('#');
  final rawQuery =
      queryStart >= 0 && (fragmentStart < 0 || queryStart < fragmentStart)
          ? url.substring(
              queryStart, fragmentStart < 0 ? url.length : fragmentStart)
          : '';
  final host = image.host.toLowerCase().replaceFirst(RegExp(r'\.+$'), '');

  if (!image.hasScheme && !image.hasAuthority) {
    return '$base/${url.startsWith('/') ? url.substring(1) : url}';
  }
  if (image.hasScheme && image.scheme != 'http' && image.scheme != 'https') {
    return null;
  }
  final resolved =
      image.hasScheme ? image : image.replace(scheme: target.scheme);
  if (resolved.origin == target.origin) {
    return image.hasScheme ? url : '${target.scheme}:$url';
  }
  // DeArrow is an explicitly enabled independent image provider. It does not
  // make arbitrary origins advertised in instance metadata trustworthy.
  if (resolved.origin == 'https://dearrow-thumb.ajay.app' &&
      resolved.path == '/api/v1/getThumbnail') {
    return image.hasScheme ? url : '${target.scheme}:$url';
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
    return '$base$path$rawQuery';
  }
  if (isOfficialYoutubeUrl(image)) return null;
  // Saved metadata and alternate Invidious hosts may advertise their own
  // image origin. Only recognized root image routes can move to this instance.
  final rawPath =
      RegExp(r'^(?:https?:)?//[^/?#\\@]+(/[^?#]*)', caseSensitive: false)
          .firstMatch(url)
          ?.group(1);
  if (rawPath != image.path) return null;
  if (RegExp(r'^/(vi|s_p|pl_c|tvfilm_banner)/[^/]+/[^/]+$')
          .hasMatch(image.path) ||
      RegExp(r'^/ggpht/.+$').hasMatch(image.path) ||
      RegExp(r'^/sb/i[0-9]?/[^/]+/.+$').hasMatch(image.path)) {
    return '$base${image.path}$rawQuery';
  }
  if (RegExp(r'^/vi_webp/[^/]+/[^/]+\.webp$').hasMatch(image.path)) {
    path = image.path.replaceFirst('/vi_webp/', '/vi/');
    return '$base${path.substring(0, path.length - 5)}.jpg$rawQuery';
  }
  return null;
}
