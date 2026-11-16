import '../../network/youtube_privacy.dart';

/// Podcast requests are independent of Google, YouTube and instance accounts.
class PodcastUrlPolicy {
  static Uri validate(Uri uri) {
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.+$'), '');
    if (!const {'http', 'https'}.contains(uri.scheme) ||
        !uri.hasAuthority ||
        host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.toString().length > 4096 ||
        host.contains('%') ||
        host.codeUnits.any((unit) => unit > 0x7f || unit <= 0x20)) {
      throw const FormatException('Enter an HTTP or HTTPS podcast feed link.');
    }
    if (isOfficialYoutubeHost(host) ||
        host == 'feedburner.com' ||
        host.endsWith('.feedburner.com')) {
      throw const FormatException(
          'Google and YouTube connections are disabled. Use the publisher’s RSS feed.');
    }
    return uri.replace(host: host, path: uri.path.isEmpty ? '/' : uri.path);
  }

  static Uri parse(String value) {
    late Uri uri;
    try {
      uri = Uri.parse(value.trim());
    } catch (_) {
      throw const FormatException('Enter an HTTP or HTTPS podcast feed link.');
    }
    return validate(uri);
  }
}
