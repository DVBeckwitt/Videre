import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../settings/models/db/server.dart';
import 'gateway_context.dart';
import 'youtube_privacy.dart';

const maxMediaCompanionOrigins = 8;
final _originPattern = RegExp(r'^https://([a-z0-9.-]+)(?::([0-9]{1,5}))?/?$',
    caseSensitive: false);
final _dnsLabel = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');

/// Parses an operator's exact HTTPS origin as entered in account settings.
String? parseMediaCompanionOrigin(String input) {
  final match = _originPattern.firstMatch(input.trim());
  if (match == null) return null;
  final host = match[1]!.toLowerCase();
  final labels = host.split('.');
  if (host.length > 253 ||
      labels.length < 2 ||
      !labels.every(_dnsLabel.hasMatch) ||
      !RegExp(r'^[a-z]').hasMatch(labels.last) ||
      isOfficialYoutubeHost(host) ||
      const [
        'onion',
        'local',
        'localhost',
        'localdomain',
        'lan',
        'internal',
        'home',
        'home.arpa'
      ].any((zone) => host == zone || host.endsWith('.$zone'))) {
    return null;
  }
  final port = match[2] == null ? 443 : int.parse(match[2]!);
  if (port == 0 || port > 65535) return null;
  return port == 443 ? 'https://$host' : 'https://$host:$port';
}

String? _serverOrigin(Server server) {
  if (server.accountId.isEmpty || server.profileId.isEmpty) return null;
  final uri = Uri.tryParse(server.url);
  if (uri == null ||
      uri.scheme != 'https' ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return parseMediaCompanionOrigin(uri.origin);
}

bool isMediaCompanionEligibleServer(Server server) =>
    _serverOrigin(server) != null;

bool isMediaCompanionAccountRoute(Uri uri) =>
    uri.pathSegments.any((segment) => const {
          'login',
          'signin',
          'sign-in',
          'logout',
          'signout',
          'sign-out',
          'register',
          'token_manager',
          'switchbackend',
          'auth',
          'authorize',
          'oauth',
          'oauth2',
          'outpost.goauthentik.io',
          'openid-connect',
          '.well-known',
          'saml',
        }.contains(segment.toLowerCase())) ||
    uri.path.startsWith('/if/flow/');

bool isMediaCompanionPlaybackRoute(Uri uri) {
  if (isMediaCompanionAccountRoute(uri)) return false;
  final path = uri.path.toLowerCase();
  return uri.pathSegments.contains('videoplayback') ||
      path.contains('/api/manifest/') ||
      path.endsWith('.mpd') ||
      path.endsWith('.m3u8');
}

/// A reverse proxy can serve distinct instances at different base paths.
String? mediaCompanionInstanceAddress(Server server) {
  final origin = _serverOrigin(server);
  if (origin == null) return null;
  final path = Uri.parse(server.url).path.replaceFirst(RegExp(r'/+$'), '');
  return '$origin$path';
}

Set<String> trustedMediaCompanionOrigins(Server server) {
  if (server.mediaCompanionOrigins.isEmpty ||
      server.mediaCompanionOrigins.length > maxMediaCompanionOrigins) {
    return const {};
  }
  final instance = _serverOrigin(server);
  if (instance == null) return const {};
  return {
    for (final value in server.mediaCompanionOrigins)
      if (parseMediaCompanionOrigin(value) case final String origin
          when origin != instance)
        origin,
  };
}

bool allowsMediaCompanion(Server server, Uri target) =>
    target.scheme == 'https' &&
    target.host.isNotEmpty &&
    target.userInfo.isEmpty &&
    trustedMediaCompanionOrigins(server).contains(target.origin);

/// Only media players consume this local context. No part is an HTTP header.
Map<String, Object?>? mediaCompanionContext(Server server) {
  final origins = trustedMediaCompanionOrigins(server);
  if (origins.isEmpty) return null;
  return _contextWithOrigins(server, origins);
}

Map<String, Object?>? _contextWithOrigins(Server server, Set<String> origins) {
  final context = GatewayRequestContext.forAccount(
      server.profileId, server.accountId, server.url);
  if (context == null) return null;
  return {
    'origin': _serverOrigin(server)!,
    'instanceBase': mediaCompanionInstanceAddress(server)!,
    'origins': origins.toList()..sort(),
    'gatewayContext': context.encoded
  };
}

/// Awaited inside the account transaction. Native players can retain a
/// previously prepared source, including one queued on another Flutter engine.
Future<void> setNativeMediaCompanionOrigins(
        Server account, Set<String> origins) =>
    setNativeMediaCompanionAccounts({account: origins});

Future<void> setNativeMediaCompanionAccounts(
    Map<Server, Set<String>> accounts) async {
  if (accounts.isEmpty) return;
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  final values = accounts.entries
      .map((entry) =>
          _contextWithOrigins(entry.key, entry.value) ??
          (throw StateError('Missing media companion account')))
      .toList();
  await const MethodChannel('videre/proxy').invokeMethod<void>(
      'setMediaCompanionOrigins',
      values.length == 1 ? values.single : {'accounts': values});
}
