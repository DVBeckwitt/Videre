import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../settings/models/db/server.dart';
import 'gateway_context.dart';
import 'nerdvpn_origin.dart';

export 'nerdvpn_origin.dart';

const nerdVpnKeyHeader = 'X-Invidious-Token';

class NerdVpnPkce {
  final String verifier;
  final String challenge;

  NerdVpnPkce._(this.verifier)
      : challenge = base64Url
            .encode(sha256.convert(ascii.encode(verifier)).bytes)
            .replaceAll('=', '');

  factory NerdVpnPkce.create() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return NerdVpnPkce._(base64Url.encode(bytes).replaceAll('=', ''));
  }
}

class NerdVpnAccessStatus {
  final String state;
  final DateTime? availableAt;
  final DateTime? retryAt;
  final bool retryAllowed;
  final int? revision;
  final int? apiKeyIntent;

  const NerdVpnAccessStatus(this.state,
      {this.availableAt,
      this.retryAt,
      this.retryAllowed = false,
      this.revision,
      this.apiKeyIntent});

  bool get ready => state == 'ready';

  factory NerdVpnAccessStatus.fromMap(Map<dynamic, dynamic> value) {
    final state = value['state'];
    if (!const {
      'ready',
      'waiting',
      'disabled',
      'denied',
      'signInRequired',
      'unavailable',
      'missing',
      'proxyRequired',
    }.contains(state)) {
      throw const NerdVpnAccessRequired('unavailable');
    }
    DateTime? date(String key) => value[key] is String
        ? DateTime.tryParse(value[key] as String)?.toUtc()
        : null;
    return NerdVpnAccessStatus(state as String,
        availableAt: date('availableAt'),
        retryAt: date('retryAt'),
        retryAllowed: value['retryAllowed'] == true,
        revision: value['revision'] is int ? value['revision'] as int : null,
        apiKeyIntent:
            value['apiKeyIntent'] is int ? value['apiKeyIntent'] as int : null);
  }
}

class NerdVpnAccessRequired implements Exception {
  final String state;
  const NerdVpnAccessRequired(this.state);

  @override
  String toString() => switch (state) {
        'waiting' => 'This account is waiting for NerdVPN API access.',
        'disabled' => 'API access is disabled in your NerdVPN preferences.',
        'denied' => 'NerdVPN has restricted access from this connection.',
        'signInRequired' => 'Sign in to NerdVPN again to enable API access.',
        'missing' =>
          'Sign in to NerdVPN or enter an API key in server settings.',
        'proxyRequired' =>
          'Enable SOCKS5/Orbot in Network proxy to use this onion server.',
        _ => 'NerdVPN API access is temporarily unavailable. Try again later.',
      };
}

/// Keys and recovery credentials are held by the Android Keystore-backed store.
/// Only the native transport obtains a request-scoped copy of an API key.
class NerdVpnAccess {
  static final instance = NerdVpnAccess();
  static final _keyPattern = RegExp(r'^nvpn_[A-Za-z0-9]{32}$');
  final MethodChannel channel;

  NerdVpnAccess({this.channel = const MethodChannel('videre/nerdvpn_access')});

  static bool supports(Server server) => supportsUrl(server.url);

  static bool supportsUrl(String value) {
    final uri = Uri.tryParse(value);
    return isNerdVpnUrl(value) &&
        uri != null &&
        (uri.path.isEmpty || uri.path == '/') &&
        !uri.hasQuery &&
        !uri.hasFragment;
  }

  static bool isKeyHeader(String name) =>
      name.toLowerCase() == nerdVpnKeyHeader.toLowerCase();

  static bool isValidKey(String value) => _keyPattern.hasMatch(value.trim());

  String _context(Server server) {
    if (!supports(server)) {
      throw ArgumentError('This server does not support NerdVPN API access.');
    }
    return GatewayRequestContext.forAccount(
            server.profileId, server.accountId, server.url)!
        .encoded;
  }

  Future<NerdVpnAccessStatus> _call(
      String method, Map<String, dynamic> arguments) async {
    try {
      final value =
          await channel.invokeMapMethod<String, dynamic>(method, arguments);
      if (value == null) throw const NerdVpnAccessRequired('unavailable');
      if (value['superseded'] == true) {
        throw const NerdVpnAccessRequired('superseded');
      }
      return NerdVpnAccessStatus.fromMap(value);
    } on MissingPluginException {
      throw const NerdVpnAccessRequired('unavailable');
    } on PlatformException catch (error) {
      final details = error.details;
      if (error.code == 'NERDVPN_ACCESS' && details is Map) {
        throw NerdVpnAccessRequired(NerdVpnAccessStatus.fromMap(details).state);
      }
      throw const NerdVpnAccessRequired('unavailable');
    }
  }

  Future<NerdVpnAccessStatus> status(Server server) =>
      _call('status', {'context': _context(server)});

  Future<int> beginAuth(Server server) async {
    try {
      final value = await channel.invokeMapMethod<String, dynamic>(
          'beginAuth', {'context': _context(server)});
      final intent = value?['intent'];
      if (intent is! int) throw const NerdVpnAccessRequired('unavailable');
      return intent;
    } on MissingPluginException {
      throw const NerdVpnAccessRequired('unavailable');
    } on PlatformException {
      throw const NerdVpnAccessRequired('unavailable');
    }
  }

  Future<NerdVpnAccessStatus> authorize(Server server, String token,
          {required int intent}) =>
      _call('authorize',
          {'context': _context(server), 'token': token, 'intent': intent});

  Future<NerdVpnAccessStatus> check(Server server) =>
      _call('check', {'context': _context(server)});

  Future<NerdVpnAccessStatus> setKey(Server server, String key,
          {int? expectedRevision}) =>
      _call('setKey', {
        'context': _context(server),
        'key': key.trim(),
        if (expectedRevision != null) 'expectedRevision': expectedRevision,
      });

  Future<void> clear(Server server) async {
    if (supports(server)) await _call('clear', {'context': _context(server)});
  }

  Future<NerdVpnAccessStatus> recover(String encodedContext,
          {required String error,
          required int statusCode,
          String? retryAfter,
          String? failedKey,
          int? failedIntent,
          int? revision,
          bool retry = true}) =>
      _call('recover', {
        'context': encodedContext,
        'error': error,
        'statusCode': statusCode,
        'retryAfter': retryAfter,
        'failedKey': failedKey,
        'failedIntent': failedIntent,
        'revision': revision,
        'retry': retry,
      });
}
