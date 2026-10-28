import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// An application proxy, independent of Invidious's media proxy setting.
class SocksProxyConfig {
  final bool enabled;
  final String host;
  final int port;

  SocksProxyConfig({
    this.enabled = false,
    this.host = '127.0.0.1',
    this.port = 9050,
  }) {
    if (host.isEmpty ||
        host.trim() != host ||
        RegExp(r'[\s/@?#]').hasMatch(host) ||
        host.contains('://') ||
        (host.contains(':') && InternetAddress.tryParse(host) == null)) {
      throw const FormatException('Enter a proxy host without a URL or port.');
    }
    if (port < 1 || port > 65535) {
      throw const FormatException('Proxy port must be between 1 and 65535.');
    }
  }

  factory SocksProxyConfig.fromJson(Map<String, dynamic> json) {
    if (json['enabled'] != null && json['enabled'] is! bool) {
      throw const FormatException('Invalid proxy enabled setting.');
    }
    if (json['host'] != null && json['host'] is! String ||
        json['port'] != null && json['port'] is! int) {
      throw const FormatException('Invalid proxy address setting.');
    }
    return SocksProxyConfig(
      enabled: json['enabled'] as bool? ?? false,
      host: json['host'] as String? ?? '127.0.0.1',
      port: json['port'] as int? ?? 9050,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'host': host,
        'port': port,
      };
}

bool isProxyLoopback(String host) =>
    host.toLowerCase() == 'localhost' ||
    InternetAddress.tryParse(host)?.isLoopback == true;

/// Routes new HTTP connections through SOCKS5, with destination DNS at the
/// proxy. Local player forwarding sockets are the only automatic exception.
///
/// The connection factory owns TLS, so callers must pass their existing TLS
/// policy explicitly. Ordinary certificate verification remains the default.
void configureSocksHttpClient(
  HttpClient client,
  SocksProxyConfig config, {
  SecurityContext? context,
  bool Function(X509Certificate certificate, String host, int port)?
      badCertificateCallback,
  Duration timeout = const Duration(seconds: 15),
}) {
  if (!config.enabled) return;
  // Environment HTTP_PROXY/NO_PROXY settings must not add a direct fallback or
  // an HTTP CONNECT exchange inside the SOCKS tunnel.
  client.findProxy = (_) => 'DIRECT';
  client.connectionFactory = (uri, _, __) async => _startConnection(
        uri,
        config,
        context: context,
        badCertificateCallback: badCertificateCallback,
        timeout: timeout,
      );
}

ConnectionTask<Socket> _startConnection(
  Uri uri,
  SocksProxyConfig config, {
  SecurityContext? context,
  bool Function(X509Certificate certificate, String host, int port)?
      badCertificateCallback,
  required Duration timeout,
}) {
  final result = Completer<Socket>();
  ConnectionTask<RawSocket>? connecting;
  RawSocket? raw;

  void fail(Object error, [StackTrace? stack]) {
    if (result.isCompleted) return;
    connecting?.cancel();
    raw?.close();
    result.completeError(error, stack);
  }

  final timer = Timer(timeout, () {
    fail(const SocketException('SOCKS5 connection timed out.'));
  });

  Future<void> connect() async {
    try {
      final loopback = isProxyLoopback(uri.host);
      connecting = await RawSocket.startConnect(
          loopback ? uri.host : config.host, loopback ? uri.port : config.port);
      if (result.isCompleted) {
        connecting!.cancel();
        await connecting!.socket;
        return;
      }
      raw = await connecting!.socket;
      if (result.isCompleted) {
        raw!.close();
        return;
      }
      final handshake = _RawHandshake(raw!);
      if (!loopback) {
        await handshake.write([5, 1, 0]); // SOCKS5, NO AUTH only.
        final method = await handshake.read(2);
        if (method[0] != 5 || method[1] != 0) {
          throw const SocketException(
              'SOCKS5 proxy does not accept unauthenticated connections.');
        }
        await handshake.write(_connectRequest(uri.host, uri.port));
        final reply = await handshake.read(4);
        if (reply[0] != 5 || reply[2] != 0) {
          throw const SocketException('Invalid SOCKS5 connection reply.');
        }
        if (reply[1] != 0) {
          throw SocketException('SOCKS5 connection rejected (${reply[1]}).');
        }
        final addressLength = switch (reply[3]) {
          1 => 4,
          4 => 16,
          3 => (await handshake.read(1)).single,
          _ => throw const SocketException('Invalid SOCKS5 address type.'),
        };
        await handshake.read(addressLength + 2);
      }
      if (result.isCompleted) return;
      final Socket socket;
      if (uri.scheme == 'https') {
        // Retain the underlying raw socket while TLS negotiates. Unlike
        // SecureSocket.secure, this lets timeout/cancel close a stalled TLS
        // handshake using public APIs.
        final secure = await RawSecureSocket.secure(
          raw!,
          subscription: handshake.subscription,
          host: uri.host,
          context: context,
          onBadCertificate: badCertificateCallback == null
              ? null
              : (certificate) =>
                  badCertificateCallback(certificate, uri.host, uri.port),
        );
        raw = secure;
        socket = _SecureStreamSocket(secure);
      } else {
        socket = _RawStreamSocket(raw!, subscription: handshake.subscription);
      }
      if (result.isCompleted) {
        socket.destroy();
        return;
      }
      timer.cancel();
      result.complete(socket);
    } catch (error, stack) {
      timer.cancel();
      fail(error, stack);
    }
  }

  unawaited(connect());
  return ConnectionTask.fromSocket(result.future, () {
    timer.cancel();
    fail(const SocketException('SOCKS5 connection cancelled.'));
  });
}

List<int> _connectRequest(String host, int port) {
  final ip = InternetAddress.tryParse(host);
  final List<int> address;
  if (ip != null) {
    address = [ip.type == InternetAddressType.IPv4 ? 1 : 4, ...ip.rawAddress];
  } else {
    final bytes = ascii.encode(host);
    if (bytes.isEmpty || bytes.length > 255) {
      throw const SocketException('SOCKS5 destination host is too long.');
    }
    address = [3, bytes.length, ...bytes];
  }
  return [5, 1, 0, ...address, port >> 8, port & 255];
}

/// Reads exactly the requested handshake bytes. Any coalesced tunneled payload
/// stays in the OS socket buffer, ready for HTTP or TLS to take over.
class _RawHandshake {
  final RawSocket raw;
  late final StreamSubscription<RawSocketEvent> subscription;
  final List<int> _buffer = [];
  Completer<List<int>>? _pending;
  Completer<void>? _writable;
  int _needed = 0;
  Object? _error;

  _RawHandshake(this.raw) {
    raw.readEventsEnabled = false;
    raw.writeEventsEnabled = false;
    subscription = raw.listen((event) {
      if (event == RawSocketEvent.read) _drain();
      if (event == RawSocketEvent.write) {
        _writable?.complete();
        _writable = null;
      }
      if (event == RawSocketEvent.closed ||
          event == RawSocketEvent.readClosed) {
        _fail(const SocketException('SOCKS5 proxy closed during negotiation.'));
      }
    }, onError: (Object error) {
      _fail(error);
    }, onDone: () {
      _fail(const SocketException('SOCKS5 proxy closed during negotiation.'));
    });
  }

  void _fail(Object error) {
    _error = error;
    _pending?.completeError(error);
    _pending = null;
    _writable?.completeError(error);
    _writable = null;
  }

  Future<void> write(List<int> bytes) async {
    var offset = 0;
    while (offset < bytes.length) {
      if (_error != null) throw _error!;
      final count = raw.write(bytes, offset);
      offset += count;
      if (offset < bytes.length) {
        final writable = _writable = Completer<void>();
        raw.writeEventsEnabled = true;
        await writable.future;
      }
    }
  }

  Future<List<int>> read(int count) {
    assert(_pending == null);
    if (_error != null) return Future.error(_error!);
    final pending = _pending = Completer<List<int>>();
    _needed = count;
    raw.readEventsEnabled = true;
    _drain();
    return pending.future;
  }

  void _drain() {
    final pending = _pending;
    if (pending == null) return;
    while (_buffer.length < _needed) {
      final bytes = raw.read(_needed - _buffer.length);
      if (bytes == null) return;
      _buffer.addAll(bytes);
    }
    raw.readEventsEnabled = false;
    _pending = null;
    final result = List<int>.of(_buffer);
    _buffer.clear();
    pending.complete(result);
  }
}

/// Adapts the public raw socket API to HttpClient's stream/sink contract. The
/// IOSink supplies write ordering and buffering; _write handles partial writes.
class _RawStreamSocket extends Stream<Uint8List> implements Socket {
  final RawSocket raw;
  late final StreamController<Uint8List> _input;
  late final StreamSubscription<RawSocketEvent> _subscription;
  late final IOSink _sink;
  Completer<void>? _writable;
  bool _destroyed = false;
  Object? _writeError;

  _RawStreamSocket(this.raw,
      {StreamSubscription<RawSocketEvent>? subscription}) {
    raw.readEventsEnabled = false;
    raw.writeEventsEnabled = false;
    _input = StreamController<Uint8List>(
      onListen: () => raw.readEventsEnabled = true,
      onPause: () => raw.readEventsEnabled = false,
      onResume: () => raw.readEventsEnabled = true,
      onCancel: destroy,
    );
    _subscription = subscription ?? raw.listen(null);
    _subscription
      ..onData(_event)
      ..onError(_error)
      ..onDone(_closed);
    _sink = IOSink(_RawConsumer(this));
    // Socket users may only observe stream errors or destroy the socket.
    // Consume the sink's error independently without changing caller futures.
    _sink.done.ignore();
  }

  void _event(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      final bytes = raw.read();
      if (bytes != null) _input.add(bytes);
    } else if (event == RawSocketEvent.write) {
      _writable?.complete();
      _writable = null;
    } else if (event == RawSocketEvent.readClosed) {
      raw.readEventsEnabled = false;
      _input.close();
    } else if (event == RawSocketEvent.closed) {
      _closed();
    }
  }

  void _error(Object error, [StackTrace? stack]) {
    _writeError = error;
    _writable?.completeError(error, stack);
    _writable = null;
    if (!_input.isClosed) {
      _input.addError(error, stack);
      _input.close();
    }
  }

  void _closed() {
    _writeError ??= const SocketException('Socket closed.');
    _writable?.completeError(_writeError!);
    _writable = null;
    if (!_input.isClosed) _input.close();
  }

  Future<void> _write(List<int> bytes) async {
    var offset = 0;
    while (offset < bytes.length) {
      if (_writeError != null) throw _writeError!;
      final count = raw.write(bytes, offset);
      offset += count;
      if (offset < bytes.length) {
        final writable = _writable = Completer<void>();
        raw.writeEventsEnabled = true;
        await writable.future;
      }
    }
  }

  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      _input.stream.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  InternetAddress get address => raw.address;
  @override
  int get port => raw.port;
  @override
  InternetAddress get remoteAddress => raw.remoteAddress;
  @override
  int get remotePort => raw.remotePort;
  @override
  Encoding get encoding => _sink.encoding;
  @override
  set encoding(Encoding value) => _sink.encoding = value;
  @override
  Future get done => _sink.done;
  @override
  void add(List<int> data) => _sink.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      throw UnsupportedError('Cannot send errors on sockets');
  @override
  Future addStream(Stream<List<int>> stream) => _sink.addStream(stream);
  @override
  Future flush() => _sink.flush();
  @override
  Future close() => _sink.close();
  @override
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _closed();
    raw.close();
    _sink.close().ignore();
  }

  @override
  bool setOption(SocketOption option, bool enabled) =>
      raw.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => raw.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => raw.setRawOption(option);
  @override
  void write(Object? object) => _sink.write(object);
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _sink.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _sink.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _sink.writeln(object);

  // HttpClient only requires this private TLS-detach member when upgrading an
  // HTTP CONNECT proxy. findProxy=DIRECT and pre-negotiated TLS avoid that path.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RawConsumer implements StreamConsumer<List<int>> {
  final _RawStreamSocket socket;
  _RawConsumer(this.socket);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final bytes in stream) {
      await socket._write(bytes);
    }
  }

  @override
  Future<void> close() async {
    if (!socket._destroyed) socket.raw.shutdown(SocketDirection.send);
  }
}

class _SecureStreamSocket extends _RawStreamSocket implements SecureSocket {
  final RawSecureSocket _secure;
  _SecureStreamSocket(this._secure) : super(_secure);

  @override
  X509Certificate? get peerCertificate => _secure.peerCertificate;
  @override
  String? get selectedProtocol => _secure.selectedProtocol;
  @override
  void renegotiate({
    bool useSessionCache = true,
    bool requestClientCertificate = false,
    bool requireClientCertificate = false,
  }) {
    // dart:io documents renegotiation as an unimplemented no-op.
  }
}
