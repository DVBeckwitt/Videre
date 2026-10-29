import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../settings/models/errors/invidious_service_error.dart';

/// A memory view of Android's private, origin-scoped verification sessions.
/// Sessions never enter the server database, backups, logs or exported headers.
class OnionVerification {
  OnionVerification._({
    bool? supported,
    MethodChannel? channel,
    DateTime Function()? now,
  })  : _supported = supported ?? Platform.isAndroid,
        _channel = channel ?? const MethodChannel('videre/proxy'),
        _now = now ?? DateTime.now;

  @visibleForTesting
  OnionVerification.forTesting({
    bool supported = true,
    MethodChannel? channel,
    DateTime Function()? now,
  }) : this._(supported: supported, channel: channel, now: now);

  static final instance = OnionVerification._();
  static const requestTimeout = Duration(seconds: 165);
  static const _fingerprintHeaders = {
    'user-agent',
    'accept',
    'accept-language',
    'accept-encoding',
    'cookie',
  };
  final bool _supported;
  final MethodChannel _channel;
  final DateTime Function() _now;
  final _sessions = <String, _OnionSession>{};
  final _pending = <String, Future<bool>>{};
  bool _enabled = false;
  int _epoch = 0;

  static String? origin(Uri uri) {
    if (uri.scheme != 'http' ||
        uri.port != 80 ||
        uri.userInfo.isNotEmpty ||
        !RegExp(r'^[a-z2-7]{56}\.onion$').hasMatch(uri.host)) {
      return null;
    }
    return uri.origin;
  }

  bool eligible(Uri uri) => _supported && _enabled && origin(uri) != null;
  int get policyEpoch => _epoch;
  Object? sessionToken(Uri uri) => _sessions[origin(uri)];

  /// Policy changes invalidate even an in-flight verification's result.
  void reset() {
    _epoch++;
    _enabled = false;
    _sessions.clear();
    _pending.clear();
  }

  Future<void> initialize({required bool proxyEnabled}) async {
    reset();
    _enabled = proxyEnabled;
    if (!_supported || !_enabled) return;
    final epoch = _epoch;
    try {
      final saved = await _channel.invokeMethod<Object?>('getOnionSessions');
      if (_epoch != epoch || saved is! Map) return;
      for (final entry in saved.entries) {
        if (entry.key is! String) continue;
        final uri = Uri.tryParse(entry.key as String);
        if (uri == null || origin(uri) != entry.key) continue;
        final session = _parseSession(entry.value);
        if (session != null) _sessions[entry.key as String] = session;
      }
    } on PlatformException {
      // Missing/corrupt verification data must not change network routing.
    } on MissingPluginException {
      // Non-Android hosts and older test fixtures have no verifier.
    }
  }

  _OnionSession? _parseSession(Object? value) {
    if (value is! Map ||
        value['headers'] is! Map ||
        value['expiresAt'] is! int) {
      return null;
    }
    final expires = value['expiresAt'] as int;
    if (expires <= _now().millisecondsSinceEpoch) return null;
    final headers = <String, String>{};
    for (final entry in (value['headers'] as Map).entries) {
      if (entry.key is! String || entry.value is! String) return null;
      final name = (entry.key as String).toLowerCase();
      final header = entry.value as String;
      if (!_fingerprintHeaders.contains(name) ||
          header.length > 16384 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(header)) {
        return null;
      }
      headers[name] = header;
    }
    if (!headers.keys.toSet().containsAll(_fingerprintHeaders) ||
        (headers['cookie'] ?? '').isEmpty ||
        (headers['user-agent'] ?? '').isEmpty) {
      return null;
    }
    return _OnionSession(Map.unmodifiable(headers), expires);
  }

  Map<String, String> headersFor(Uri uri, Map<String, String> base) {
    if (!eligible(uri)) return Map.of(base);
    final session = _sessions[origin(uri)];
    if (session == null || session.expiresAt <= _now().millisecondsSinceEpoch) {
      return Map.of(base);
    }
    final merged = mergeHeaders(base, session.headers);
    // An Invidious account SID belongs to the user, never to the anonymous
    // verification browser. Preserve it if both cookie jars contain that name.
    final accountCookies = base.entries
        .where((entry) => entry.key.toLowerCase() == 'cookie')
        .expand((entry) => entry.value.split(';'))
        .map((cookie) => cookie.trim())
        .where((cookie) => cookie.startsWith('SID='))
        .join('; ');
    return accountCookies.isEmpty
        ? merged
        : mergeHeaders(merged, {'cookie': accountCookies});
  }

  /// Case-insensitive HTTP fields, but case-sensitive cookie names. Existing
  /// login cookies coexist with the verifier's cookies instead of replacing it.
  static Map<String, String> mergeHeaders(
    Map<String, String> base,
    Map<String, String> additions,
  ) {
    final headers = <String, String>{
      for (final entry in base.entries) entry.key.toLowerCase(): entry.value,
    };
    for (final entry in additions.entries) {
      final name = entry.key.toLowerCase();
      if (name == 'cookie' && headers[name] != null) {
        final cookies = <String, String>{};
        for (final header in [headers[name]!, entry.value]) {
          for (final part in header.split(';')) {
            final value = part.trim();
            final equal = value.indexOf('=');
            if (equal > 0) cookies[value.substring(0, equal)] = value;
          }
        }
        headers[name] = cookies.values.join('; ');
      } else {
        headers[name] = entry.value;
      }
    }
    return headers;
  }

  bool needsVerification(Uri uri, http.Response response) {
    if (!eligible(uri)) return false;
    final location = response.headers['location'];
    if (response.statusCode >= 300 &&
        response.statusCode < 400 &&
        location != null) {
      try {
        final next = uri.resolve(location);
        if (origin(next) == origin(uri) && next.path.startsWith('/.gandalf/')) {
          return true;
        }
      } on FormatException {
        return false;
      }
    }
    if (response.statusCode != 200 && response.statusCode != 403) return false;
    final body = utf8
        .decode(response.bodyBytes.take(65536).toList(), allowMalformed: true)
        .toLowerCase();
    final isHtml =
        (response.headers['content-type'] ?? '').toLowerCase().contains(
                  'html',
                ) ||
            body.trimLeft().startsWith('<');
    return isHtml && body.contains('gandalf');
  }

  Future<bool> verify(
    Uri uri, {
    required Object? previousSession,
    required int policyEpoch,
  }) {
    if (!eligible(uri) || _epoch != policyEpoch) return Future.value(false);
    final key = origin(uri)!;
    final current = _sessions[key];
    if (current != null &&
        !identical(current, previousSession) &&
        current.expiresAt > _now().millisecondsSinceEpoch) {
      // Another request already renewed the session after this read began.
      return Future.value(true);
    }
    return _pending.putIfAbsent(key, () {
      final epoch = _epoch;
      return _verify(key, epoch).whenComplete(() {
        if (_epoch == epoch) _pending.remove(key);
      });
    });
  }

  Future<bool> _verify(String key, int epoch) async {
    try {
      final value = await _channel.invokeMethod<Object?>('verifyOnionSession', {
        'url': key,
      });
      if (_epoch != epoch || !_enabled) return false;
      final session = _parseSession(value);
      if (session == null) return false;
      _sessions[key] = session;
      return true;
    } on PlatformException catch (error) {
      if (_epoch != epoch || !_enabled) return false;
      if (error.code == 'ONION_VERIFICATION_UNSUPPORTED_WEBVIEW') {
        throw InvidiousServiceError(
          'The system Android WebView needs an update to verify this onion '
          'instance securely.',
        );
      }
      // Cancellation, background work and other failures retain the
      // original response. Never log platform messages containing site data.
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

class _OnionSession {
  final Map<String, String> headers;
  final int expiresAt;
  const _OnionSession(this.headers, this.expiresAt);
}
