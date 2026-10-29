import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'network_proxy.dart';
import 'onion_verification.dart';
import 'socks_proxy.dart';

/// Bounded JSON/API transport for background engines. Android owns its routing
/// policy, so a stale worker cannot reset or bypass the foreground proxy.
class NativeProxyHttpClient extends http.BaseClient {
  static const maxBodyBytes = 4 * 1024 * 1024;
  final MethodChannel _channel;
  final SocksProxyConfig Function() _onionProxyConfig;
  bool _closed = false;

  NativeProxyHttpClient(
      {MethodChannel channel = const MethodChannel('videre/proxy'),
      SocksProxyConfig Function()? onionProxyConfig})
      : _channel = channel,
        _onionProxyConfig =
            onionProxyConfig ?? (() => NetworkProxy.instance.config);

  void _checkOpen(Uri url) {
    if (_closed) throw http.ClientException('HTTP client is closed.', url);
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url;
    _checkOpen(url);
    if ((url.scheme != 'http' && url.scheme != 'https') ||
        !url.hasAuthority ||
        url.host.isEmpty) {
      throw http.ClientException(
          'Only HTTP and HTTPS URLs are supported.', url);
    }
    // Workers retain the route used to load their private onion sessions.
    // Native transport compares this snapshot atomically with its current
    // policy; a foreground proxy change must reject stale session headers.
    final expectedOnionProxy = OnionVerification.origin(url) == null
        ? null
        : _onionProxyConfig().toJson();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request.finalize()) {
      if (chunk.length > maxBodyBytes - builder.length) {
        throw http.ClientException('Native proxy request exceeds 4 MiB.', url);
      }
      builder.add(chunk);
    }
    _checkOpen(url);

    Object? value;
    try {
      value = await _channel.invokeMethod<Object?>('request', {
        'method': request.method,
        'url': url.toString(),
        'headers': Map<String, String>.from(request.headers),
        'body': builder.takeBytes(),
        'followRedirects': request.followRedirects,
        'maxRedirects': request.maxRedirects,
        if (expectedOnionProxy != null)
          'expectedOnionProxy': expectedOnionProxy,
      });
    } on PlatformException {
      // Platform messages may include URLs or request headers. Keep them out of
      // exceptions logged by service callers and never retry through Dart IO.
      throw http.ClientException('Native proxy request failed.', url);
    } on MissingPluginException {
      throw http.ClientException('Native proxy transport is unavailable.', url);
    }
    _checkOpen(url);

    if (value is! Map ||
        value['statusCode'] is! int ||
        value['statusCode'] < 100 ||
        value['statusCode'] > 599 ||
        value['headers'] is! Map ||
        value['body'] is! Uint8List) {
      throw http.ClientException('Invalid native proxy response.', url);
    }
    final body = value['body'] as Uint8List;
    if (body.length > maxBodyBytes) {
      throw http.ClientException('Native proxy response exceeds 4 MiB.', url);
    }
    final headers = <String, String>{};
    for (final entry in (value['headers'] as Map).entries) {
      if (entry.key is! String || entry.value is! String) {
        throw http.ClientException(
            'Invalid native proxy response headers.', url);
      }
      final name = (entry.key as String).toLowerCase();
      final header = entry.value as String;
      headers.update(name, (previous) => '$previous,$header',
          ifAbsent: () => header);
    }
    final status = value['statusCode'] as int;
    return http.StreamedResponse(Stream<List<int>>.value(body), status,
        contentLength: body.length,
        request: request,
        headers: headers,
        isRedirect: const [301, 302, 303, 307, 308].contains(status));
  }

  @override
  void close() {
    _closed = true;
  }
}
