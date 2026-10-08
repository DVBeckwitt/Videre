import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Only playback intent crosses the network; each device uses its own instance.
class RemoteCommand {
  final String action;
  final String? videoId;
  final int position;
  final bool playing;

  const RemoteCommand(this.action,
      {this.videoId, this.position = 0, this.playing = true});

  factory RemoteCommand.fromJson(Map<String, dynamic> json) {
    final action = json['action'];
    if (action == 'play' || action == 'pause' || action == 'disconnect') {
      return RemoteCommand(action);
    }
    if (action != 'load' ||
        json['videoId'] is! String ||
        json['videoId'].length != 11 ||
        !RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(json['videoId']) ||
        json['position'] is! int ||
        json['position'] < 0 ||
        json['position'] > 604800 ||
        json['playing'] is! bool) {
      throw const FormatException('Invalid playback command');
    }
    return RemoteCommand('load',
        videoId: json['videoId'],
        position: json['position'],
        playing: json['playing']);
  }

  Map<String, dynamic> toJson() => {
        'action': action,
        if (action == 'load') ...{
          'videoId': videoId,
          'position': position,
          'playing': playing,
        },
      };
}

bool _localAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  return address.isLoopback ||
      (bytes.length == 4 &&
          (bytes[0] == 10 ||
              (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
              (bytes[0] == 192 && bytes[1] == 168) ||
              (bytes[0] == 169 && bytes[1] == 254)));
}

Future<Map<String, dynamic>> _readJson(Stream<List<int>> stream) async {
  final bytes = <int>[];
  await for (final chunk in stream) {
    bytes.addAll(chunk);
    if (bytes.length > 1024) {
      throw const FormatException('Message too large');
    }
  }
  final value = jsonDecode(utf8.decode(bytes));
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected a JSON object');
  }
  return value;
}

class RemoteReceiver {
  final HttpServer _server;
  final FutureOr<void> Function(RemoteCommand command) onCommand;
  final void Function()? onChanged;
  final DateTime Function() _now;
  final DateTime expiresAt;
  final String code;
  String? _token;
  bool _usedCode = false;
  bool _closed = false;
  int _activeRequests = 0;
  final List<DateTime> _pairAttempts = [];
  DateTime? _lastCommand;
  bool _commandBusy = false;

  RemoteReceiver._(this._server, this.onCommand, this.onChanged, this._now,
      this.expiresAt, this.code) {
    _server.listen(_handle);
  }

  int get port => _server.port;
  bool get paired => _token != null;
  bool get codeExpired => !_now().isBefore(expiresAt);
  bool get pairingAvailable => !_usedCode && !codeExpired;

  Future<List<String>> localAddresses() async =>
      (await NetworkInterface.list(type: InternetAddressType.IPv4))
          .expand((interface) => interface.addresses)
          .where((address) => !address.isLoopback && _localAddress(address))
          .map((address) => '${address.address}:$port')
          .toList();

  static Future<RemoteReceiver> start({
    required FutureOr<void> Function(RemoteCommand command) onCommand,
    void Function()? onChanged,
    InternetAddress? address,
    DateTime Function()? now,
  }) async {
    final clock = now ?? DateTime.now;
    final server = await HttpServer.bind(address ?? InternetAddress.anyIPv4, 0);
    return RemoteReceiver._(
        server,
        onCommand,
        onChanged,
        clock,
        clock().add(const Duration(minutes: 5)),
        Random.secure().nextInt(1000000).toString().padLeft(6, '0'));
  }

  Future<void> _handle(HttpRequest request) async {
    _activeRequests++;
    var status = HttpStatus.badRequest;
    Map<String, dynamic> response = {};
    try {
      final peer = request.connectionInfo?.remoteAddress;
      if (_closed ||
          peer == null ||
          !_localAddress(peer) ||
          request.headers.value('origin') != null) {
        status = HttpStatus.forbidden;
      } else if (_activeRequests > 4) {
        status = HttpStatus.tooManyRequests;
      } else if (request.method != 'POST') {
        status = HttpStatus.methodNotAllowed;
      } else if (request.uri.path == '/pair') {
        final now = _now();
        _pairAttempts.removeWhere(
            (attempt) => now.difference(attempt) >= const Duration(minutes: 1));
        if (_pairAttempts.length >= 6) {
          status = HttpStatus.tooManyRequests;
        } else {
          _pairAttempts.add(now);
          final body =
              await _readJson(request).timeout(const Duration(seconds: 3));
          if (_closed || _usedCode || codeExpired || body['code'] != code) {
            status = HttpStatus.unauthorized;
          } else {
            _usedCode = true;
            _token = base64UrlEncode(
                List.generate(32, (_) => Random.secure().nextInt(256)));
            response = {'token': _token};
            status = HttpStatus.ok;
            onChanged?.call();
          }
        }
      } else if (request.uri.path == '/command') {
        if (_token == null ||
            request.headers.value(HttpHeaders.authorizationHeader) !=
                'Bearer $_token') {
          status = HttpStatus.unauthorized;
        } else {
          final bearer = _token;
          final body =
              await _readJson(request).timeout(const Duration(seconds: 3));
          final command = RemoteCommand.fromJson(body);
          final now = _now();
          if (_closed || _token != bearer) {
            status = HttpStatus.unauthorized;
          } else if (command.action == 'disconnect') {
            _token = null;
            onChanged?.call();
            status = HttpStatus.ok;
          } else if (_commandBusy ||
              (_lastCommand != null &&
                  now.difference(_lastCommand!) <
                      const Duration(milliseconds: 150))) {
            status = HttpStatus.tooManyRequests;
          } else {
            _lastCommand = now;
            _commandBusy = true;
            try {
              await onCommand(command);
            } finally {
              _commandBusy = false;
            }
            status = HttpStatus.ok;
          }
        }
      } else {
        status = HttpStatus.notFound;
      }
    } on FormatException {
      status = HttpStatus.badRequest;
    } on TimeoutException {
      status = HttpStatus.requestTimeout;
    } catch (_) {
      status = HttpStatus.internalServerError;
    } finally {
      _activeRequests--;
      try {
        request.response
          ..statusCode = status
          ..headers.contentType = ContentType.json
          ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
          ..write(jsonEncode(response));
        await request.response.close();
      } catch (_) {
        // A phone can leave Wi-Fi while a request is still in flight.
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    _token = null;
    await _server.close(force: true);
  }
}

class RemoteClient {
  final Uri address;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);
  String? _token;

  RemoteClient(String input) : address = parseAddress(input);

  static Uri parseAddress(String input) {
    final text = input.trim();
    final uri = Uri.tryParse(text.contains('://') ? text : 'http://$text');
    final ip = uri == null ? null : InternetAddress.tryParse(uri.host);
    if (uri == null ||
        uri.scheme != 'http' ||
        ip == null ||
        !_localAddress(ip) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw const FormatException('remoteInvalidAddress');
    }
    return uri;
  }

  Future<Map<String, dynamic>> _post(
      String path, Map<String, dynamic> body) async {
    final request = await _http.postUrl(address.replace(path: path));
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    if (_token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    }
    request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 15));
    final result =
        await _readJson(response).timeout(const Duration(seconds: 3));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(switch (response.statusCode) {
        HttpStatus.unauthorized => 'remoteExpired',
        HttpStatus.tooManyRequests => 'remoteBusy',
        _ => 'remoteCommandFailed',
      });
    }
    return result;
  }

  Future<void> pair(String code) async {
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      throw const FormatException('remoteInvalidCode');
    }
    final result = await _post('/pair', {'code': code});
    final token = result['token'];
    if (token is! String || token.length < 32 || token.length > 128) {
      throw const FormatException('Invalid pairing response');
    }
    _token = token;
  }

  Future<void> send(RemoteCommand command) async {
    RemoteCommand.fromJson(command.toJson());
    await _post('/command', command.toJson());
  }

  void close() {
    _token = null;
    _http.close(force: true);
  }
}
