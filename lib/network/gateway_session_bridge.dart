import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'gateway_context.dart';

class GatewayAuthenticationRequired implements Exception {
  const GatewayAuthenticationRequired();

  @override
  String toString() => 'Sign in again to the protected server.';
}

class GatewayTransportUnavailable implements Exception {
  const GatewayTransportUnavailable();

  @override
  String toString() => 'The protected server session is unavailable.';
}

class GatewayResolvedSession {
  final bool enabled;
  final bool needsSignIn;
  final String? cookies;
  final int? revision;

  const GatewayResolvedSession(
      {required this.enabled,
      required this.needsSignIn,
      this.cookies,
      this.revision});
}

/// Cookies are request-scoped copies. The native profile store is authoritative.
class GatewaySessionBridge {
  static final instance = GatewaySessionBridge();
  final MethodChannel channel;

  GatewaySessionBridge(
      {this.channel = const MethodChannel('videre/gateway_sessions')});

  Future<GatewayResolvedSession> resolve(String encodedContext, Uri url) async {
    final context = GatewayRequestContext.tryParse(encodedContext);
    if (context == null) throw const GatewayTransportUnavailable();
    if (!context.allows(url) ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return const GatewayResolvedSession(enabled: false, needsSignIn: false);
    }
    try {
      final value = await channel.invokeMapMethod<String, dynamic>('resolve', {
        'context': encodedContext,
        'url': url.toString(),
      });
      if (value == null ||
          value['enabled'] is! bool ||
          value['needsSignIn'] is! bool ||
          (value['cookies'] != null && value['cookies'] is! String) ||
          (value['revision'] != null && value['revision'] is! int)) {
        throw const GatewayTransportUnavailable();
      }
      return GatewayResolvedSession(
          enabled: value['enabled'],
          needsSignIn: value['needsSignIn'],
          cookies: value['cookies'],
          revision: value['revision'] as int?);
    } on PlatformException {
      throw const GatewayTransportUnavailable();
    } on MissingPluginException {
      throw const GatewayTransportUnavailable();
    }
  }

  Future<void> ingest(String encodedContext, Uri url, List<String> setCookies,
      {required int statusCode,
      String? contentType,
      String? location,
      int? revision}) async {
    final context = GatewayRequestContext.tryParse(encodedContext);
    if (context == null) throw const GatewayTransportUnavailable();
    if (!context.allows(url) ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      final required = await channel.invokeMethod<bool>('ingest', {
        'context': encodedContext,
        'url': url.toString(),
        'setCookies': setCookies,
        'statusCode': statusCode,
        'contentType': contentType,
        'location': location,
        'revision': revision,
      });
      if (required == true) throw const GatewayAuthenticationRequired();
    } on PlatformException catch (error) {
      if (error.code == 'GATEWAY_AUTH_REQUIRED') {
        throw const GatewayAuthenticationRequired();
      }
      throw const GatewayTransportUnavailable();
    } on MissingPluginException {
      throw const GatewayTransportUnavailable();
    }
  }
}
