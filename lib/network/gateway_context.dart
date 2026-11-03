import 'dart:convert';

import 'package:uuid/uuid.dart';

/// Internal transport metadata. Every transport must remove this before sending.
const gatewayContextHeader = 'X-Videre-Gateway-Context';

class GatewayRequestContext {
  final String key;
  final Uri origin;

  const GatewayRequestContext._(this.key, this.origin);

  static final _keyPattern = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

  static GatewayRequestContext? forAccount(
      String profileId, String accountId, String serverUrl) {
    final server = Uri.tryParse(serverUrl);
    if (profileId.isEmpty || accountId.isEmpty || !_validOrigin(server)) {
      return null;
    }
    final origin = Uri.parse(server!.origin);
    final key = const Uuid().v5(
        Namespace.url.value,
        jsonEncode(
            ['videre-gateway-v1', profileId, accountId, origin.toString()]));
    return GatewayRequestContext._(key, origin);
  }

  static bool _validOrigin(Uri? uri) =>
      uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;

  static GatewayRequestContext? tryParse(String value) {
    if (value.length > 2048) return null;
    try {
      final parts = value.split('.');
      if (parts.length != 3 ||
          parts[0] != 'v1' ||
          !_keyPattern.hasMatch(parts[1])) {
        return null;
      }
      final origin = Uri.parse(utf8.decode(base64Url.decode(parts[2])));
      if (!_validOrigin(origin) ||
          origin.hasQuery ||
          origin.hasFragment ||
          (origin.path.isNotEmpty && origin.path != '/')) {
        return null;
      }
      return GatewayRequestContext._(parts[1], Uri.parse(origin.origin));
    } catch (_) {
      return null;
    }
  }

  String get encoded =>
      'v1.$key.${base64Url.encode(utf8.encode(origin.toString()))}';

  bool allows(Uri target) =>
      _validOrigin(target) && target.origin == origin.origin;
}

Map<String, String> gatewayContextHeaders({
  required String profileId,
  required String accountId,
  required String serverUrl,
  required String targetUrl,
  Map<String, String> headers = const {},
}) {
  final result = Map<String, String>.from(headers)
    ..removeWhere(
        (name, _) => name.toLowerCase() == gatewayContextHeader.toLowerCase());
  final context =
      GatewayRequestContext.forAccount(profileId, accountId, serverUrl);
  final target = Uri.tryParse(targetUrl);
  if (context != null && target != null && context.allows(target)) {
    result[gatewayContextHeader] = context.encoded;
  }
  return result;
}
