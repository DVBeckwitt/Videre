import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../network/gateway_context.dart';
import '../../network/network_proxy.dart';
import '../../network/gateway_session_bridge.dart';
import '../../network/nerdvpn_access.dart';
import '../models/db/server.dart';

class GatewayAuthStatus {
  final bool supported;
  final bool enabled;
  final bool needsSignIn;
  final int? revision;
  const GatewayAuthStatus(
      {required this.supported,
      required this.enabled,
      required this.needsSignIn,
      this.revision});
}

class GatewayAuth {
  static const _sessions = MethodChannel('videre/gateway_sessions');
  static const _browser = MethodChannel('videre/gateway_auth');
  static final _intents = <String, int>{};
  static final _revocations = <String, Future<void>>{};

  static int _beginIntent(String key) =>
      _intents.update(key, (previous) => previous + 1, ifAbsent: () => 1);

  static GatewayRequestContext _context(Server server) =>
      GatewayRequestContext.forAccount(
          server.profileId, server.accountId, server.url) ??
      (throw const GatewayTransportUnavailable());

  static Future<GatewayAuthStatus> status(Server server) async {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        GatewayRequestContext.forAccount(
                server.profileId, server.accountId, server.url) ==
            null) {
      return const GatewayAuthStatus(
          supported: false, enabled: false, needsSignIn: false);
    }
    try {
      final value = await _sessions.invokeMapMethod<String, dynamic>('status', {
        'context': _context(server).encoded,
      });
      return GatewayAuthStatus(
          supported: value?['supported'] == true,
          enabled: value?['enabled'] == true,
          needsSignIn: value?['needsSignIn'] == true,
          revision: value?['revision'] as int?);
    } on PlatformException {
      throw const GatewayTransportUnavailable();
    } on MissingPluginException {
      if (server.gatewayEnabled) throw const GatewayTransportUnavailable();
      return const GatewayAuthStatus(
          supported: false, enabled: false, needsSignIn: false);
    }
  }

  /// A null token means the user cancelled. Only the requested account is used.
  static Future<String?> signIn(Server server,
      {String title = 'Sign in to protected server',
      String cancel = 'Cancel',
      String help =
          'Sign in to your gateway, then authorize this Invidious account.'}) async {
    final context = _context(server);
    final intent = _beginIntent(context.key);
    final proxy = NetworkProxy.instance;
    var proxyChanged = false;
    bool isCurrent() =>
        _intents[context.key] == intent && !proxyChanged && !proxy.isChanging;
    NerdVpnAccessStatus? access;
    await _revocations[context.key];
    if (!isCurrent()) return null;
    Future<void> close() {
      proxyChanged = true;
      return _browser.invokeMethod<void>('close', {'context': context.encoded});
    }

    proxy.addBeforeApply(close);
    try {
      if (NerdVpnAccess.supports(server)) {
        access = await NerdVpnAccess.instance.status(server);
        if (!isCurrent()) return null;
        if (access.retryAt?.isAfter(DateTime.now()) ?? false) {
          throw const GatewaySignInFailed(
              'NerdVPN has asked Videre to wait. Try signing in again later.');
        }
      }
      await _browser.invokeMethod<void>('close', {'context': context.encoded});
      if (!isCurrent()) return null;
      final token = await _browser.invokeMethod<String>('signIn', {
        'context': context.encoded,
        'serverUrl': server.url,
        'title': title,
        'cancel': cancel,
        'help': help,
      });
      return isCurrent() ? token : null;
    } on PlatformException catch (error) {
      if (!isCurrent()) return null;
      if (error.code == 'GATEWAY_UNSUPPORTED') {
        throw const GatewayUnsupported();
      }
      if (error.code == 'GATEWAY_ONION_PROXY_REQUIRED') {
        throw const GatewaySignInFailed(
            'Enable SOCKS5/Orbot in Network proxy to use this onion server.');
      }
      if (error.code == 'GATEWAY_TOKEN_EXPIRED') {
        throw const GatewaySignInFailed(
            'The sign-in code expired or was already used. Sign in again.');
      }
      if (error.code == 'GATEWAY_TOKEN_UNAVAILABLE') {
        final details = error.details;
        if (NerdVpnAccess.supports(server) &&
            details is Map &&
            (details['statusCode'] == 429 || details['statusCode'] == 503)) {
          final code = details['statusCode'] as int;
          await NerdVpnAccess.instance.recover(context.encoded,
              error: code == 429 ? 'rate_limited' : 'unavailable',
              statusCode: code,
              retryAfter: details['retryAfter'] as String?,
              failedIntent: access?.apiKeyIntent,
              revision: access?.revision,
              retry: false);
        }
        throw const GatewaySignInFailed(
            'The server could not complete sign-in. Try again later.');
      }
      if (error.code == 'GATEWAY_TOKEN_EXCHANGE_FAILED') {
        throw const GatewaySignInFailed(
            'The server could not verify this sign-in. Sign in again.');
      }
      throw const GatewayTransportUnavailable();
    } on MissingPluginException {
      throw const GatewayUnsupported();
    } finally {
      proxy.removeBeforeApply(close);
    }
  }

  static Future<void> signOut(Server server) async {
    final context = GatewayRequestContext.forAccount(
        server.profileId, server.accountId, server.url);
    if (context == null) return;
    final intent = _beginIntent(context.key);
    Future<void> revoke() async {
      final current = await status(server);
      if (_intents[context.key] != intent || !current.enabled) return;
      try {
        try {
          await _browser.invokeMethod<void>('close', {
            'context': context.encoded,
            'revision': current.revision,
          });
        } on MissingPluginException {
          // A worker may revoke a session without an Activity/login browser.
        }
        await _sessions.invokeMethod<void>('signOut', {
          'context': context.encoded,
          'revision': current.revision,
        });
      } on PlatformException {
        throw const GatewayTransportUnavailable();
      } on MissingPluginException {
        throw const GatewayTransportUnavailable();
      }
    }

    final previous = _revocations[context.key];
    final pending = () async {
      await previous;
      await revoke();
    }();
    _revocations[context.key] = pending;
    try {
      await pending;
    } finally {
      if (identical(_revocations[context.key], pending)) {
        _revocations.remove(context.key);
      }
    }
  }
}

class GatewaySignInFailed implements Exception {
  final String message;

  const GatewaySignInFailed(this.message);

  @override
  String toString() => message;
}

class GatewayUnsupported implements Exception {
  const GatewayUnsupported();
  @override
  String toString() =>
      'This Android WebView does not support isolated sign-in profiles. Update Android System WebView to use protected servers.';
}
