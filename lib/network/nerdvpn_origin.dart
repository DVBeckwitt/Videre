/// Public NerdVPN origins. Each origin keeps its own account credentials.
const nerdVpnOnionHost =
    'nerdvpneaggggfdiurknszkbmhvjndks5z5k3g5yp4nhphflh3n3boad.onion';

bool isNerdVpnOnionUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.host == nerdVpnOnionHost &&
      uri.userInfo.isEmpty &&
      ((uri.scheme == 'http' && uri.port == 80) ||
          (uri.scheme == 'https' && uri.port == 443));
}

bool isNerdVpnUrl(String value) {
  final uri = Uri.tryParse(value);
  return isNerdVpnOnionUrl(value) ||
      (uri != null &&
          uri.scheme == 'https' &&
          uri.host == 'invidious.nerdvpn.de' &&
          uri.port == 443 &&
          uri.userInfo.isEmpty);
}
