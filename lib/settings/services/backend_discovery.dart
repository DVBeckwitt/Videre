import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import '../models/backend_selector.dart';
import '../models/db/server.dart';

class BackendDiscoveryUnsupported implements Exception {
  const BackendDiscoveryUnsupported();

  @override
  String toString() =>
      'This server does not advertise compatible backend options.';
}

class BackendDiscoveryException implements Exception {
  final String message;

  const BackendDiscoveryException(
      [this.message = 'Could not check this server’s backend options.']);

  @override
  String toString() => message;
}

/// Reads advertised choices without executing scripts or changing account
/// preferences. Only the two verified Invidious selector protocols are supported.
class BackendDiscovery {
  final http.Client client;
  final Duration timeout;

  static const _maximumBytes = 2 * 1024 * 1024;
  static const _maximumOptions = 64;
  static final _integer = RegExp(r'^(0|[1-9][0-9]*)$');
  static final _cookieName = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
  static final _cookieSeparator =
      RegExp(r",(?=\s*[!#$%&'*+\-.^_`|~0-9A-Za-z]+\s*=)");
  static final _challenge = RegExp(
      r'captcha|challenge|maintenance|temporarily unavailable|access denied|checking.{0,30}connection|verify.{0,30}human',
      caseSensitive: false);

  BackendDiscovery(this.client, {this.timeout = const Duration(seconds: 15)});

  Future<BackendSelector> discover(Server server) async {
    final elapsed = Stopwatch()..start();
    try {
      final origin = Uri.tryParse(server.url);
      if (origin == null ||
          !const {'http', 'https'}.contains(origin.scheme) ||
          origin.host.isEmpty ||
          origin.userInfo.isNotEmpty ||
          origin.hasQuery ||
          origin.hasFragment ||
          _isSwitcher(origin)) {
        throw const BackendDiscoveryException('The server address is invalid.');
      }
      var pageUri = origin.path.isEmpty ? origin.replace(path: '/') : origin;
      late _DiscoveryResponse page;
      final headers = Map<String, String>.from(server.customHeaders)
        ..removeWhere((key, _) => key.toLowerCase() == 'accept')
        ..['Accept'] = 'text/html';
      for (var redirects = 0;; redirects++) {
        page = await _read(pageUri, headers, _remaining(elapsed));
        if (!_isRedirect(page.status)) break;
        final next = _redirectTarget(page, pageUri, origin);
        if (next == null || redirects >= 3 || _isSwitcher(next)) {
          throw const BackendDiscoveryException();
        }
        pageUri = next;
      }
      if (page.status != 200) throw const BackendDiscoveryException();
      return await _parsePage(server, origin, pageUri,
          utf8.decode(page.body, allowMalformed: true), elapsed);
    } on BackendDiscoveryUnsupported {
      rethrow;
    } on BackendDiscoveryException {
      rethrow;
    } catch (_) {
      // HTTP/parser exceptions may contain headers or cookie contents.
      throw const BackendDiscoveryException();
    }
  }

  /// Imports public selector markup from the visible Android browser. Browser
  /// sessions and credentials are deliberately outside this API.
  Future<BackendSelector> discoverBrowserPage(Server server,
      {required Uri pageUri, required String source}) async {
    final origin = Uri.tryParse(server.url);
    if (origin == null ||
        origin.scheme != 'https' ||
        !const {'invidious.nerdvpn.de', 'www.invidious.nerdvpn.de'}
            .contains(origin.host) ||
        origin.port != 443 ||
        (origin.path.isNotEmpty && origin.path != '/') ||
        origin.userInfo.isNotEmpty ||
        origin.hasQuery ||
        origin.hasFragment ||
        !_sameOrigin(origin, pageUri) ||
        pageUri.userInfo.isNotEmpty ||
        pageUri.hasFragment ||
        _isSwitcher(pageUri) ||
        source.length > _maximumBytes ||
        utf8.encode(source).length > _maximumBytes) {
      throw const BackendDiscoveryException();
    }
    try {
      return await _parsePage(
          server, origin, pageUri, source, Stopwatch()..start(),
          browserPage: true);
    } on BackendDiscoveryUnsupported {
      rethrow;
    } on BackendDiscoveryException {
      rethrow;
    } catch (_) {
      throw const BackendDiscoveryException();
    }
  }

  Future<BackendSelector> _parsePage(
      Server server, Uri origin, Uri pageUri, String source, Stopwatch elapsed,
      {bool browserPage = false}) async {
    final document = html.parse(source);
    final groups = <String, Map<String, _AdvertisedOption>>{};
    for (final anchor in document.querySelectorAll('a[href]')) {
      final target = Uri.tryParse(anchor.attributes['href'] ?? '');
      if (target == null) continue;
      final resolved = pageUri.resolveUri(target);
      if (!_sameOrigin(origin, resolved) ||
          resolved.userInfo.isNotEmpty ||
          resolved.hasFragment ||
          !_isSwitcher(resolved)) {
        continue;
      }
      final query = resolved.queryParametersAll;
      final protocols = const ['backend_id', 'companion_id']
          .where(query.containsKey)
          .toList();
      if (protocols.length != 1) continue;
      final protocol = protocols.single;
      final values = query[protocol]!;
      if (values.length != 1 || !_integer.hasMatch(values.single)) continue;
      final value = int.tryParse(values.single);
      if (value == null || value > 2147483647) continue;
      final label = _label(anchor);
      if (label.isEmpty || label.length > 256) continue;
      final options = groups.putIfAbsent(protocol, () => {});
      options.putIfAbsent(
          values.single,
          () =>
              _AdvertisedOption(BackendOption(values.single, label), resolved));
      if (options.length > _maximumOptions) {
        throw const BackendDiscoveryException(
            'Too many backend options were advertised.');
      }
    }
    if (groups.length > 1) {
      throw const BackendDiscoveryException(
          'The backend selector format is ambiguous.');
    }
    if (groups.isEmpty || groups.values.single.length < 2) {
      final text = document.body?.text ?? '';
      final title = document.querySelector('title')?.text ?? '';
      if (_challenge.hasMatch(text) ||
          _challenge.hasMatch(title) ||
          document.querySelector('cap-widget, [data-sitekey]') != null) {
        throw const BackendDiscoveryException(
            'The server is temporarily unavailable or requires a browser check.');
      }
      final recognizable = groups.isNotEmpty ||
          title.toLowerCase().contains('invidious') ||
          document.querySelectorAll('a[href]').any((anchor) =>
              (anchor.attributes['href'] ?? '')
                  .startsWith('https://github.com/iv-org/invidious'));
      if (!recognizable) throw const BackendDiscoveryException();
      throw const BackendDiscoveryUnsupported();
    }
    final protocol = groups.keys.single;
    final advertised = groups.values.single.values.toList();
    final options = advertised.map((entry) => entry.option).toList();
    final automaticFallback = server.backendSelector?.automaticFallback ?? true;
    if (browserPage && protocol != 'backend_id') {
      throw const BackendDiscoveryException();
    }
    if (protocol == 'companion_id') {
      // Fijxu-derived instances store this nullable integer in form-encoded
      // PREFS JSON. Probing with SID would update account preferences.
      // https://git.nadeko.net/Fijxu/invidious/src/commit/022021b39ac4fbe7470fe50867abb60e48ccd363/src/invidious/routes/backend_switcher.cr
      // MiningTcup uses the same contract at 5dd6c49a33bbbdf24d768420a922ab640221bf25:
      // https://git.miningtcup.me/MiningTcup/invidious/src/commit/5dd6c49a33bbbdf24d768420a922ab640221bf25/src/invidious/routes/backend_switcher.cr
      // Their public video metadata API/cache may ignore this preference.
      return BackendSelector('PREFS', options,
          preferenceField: 'current_companion',
          automaticFallback: automaticFallback);
    }
    final existing = server.backendSelector;
    String? name;
    if (browserPage) {
      name = 'COMPANION_ID';
    } else if (existing != null &&
        existing.preferenceField == null &&
        _isRoutingCookieName(existing.cookieName)) {
      name = existing.cookieName;
    } else if (_hasLegacyNerdVpnCookie(origin)) {
      // Retain the established official NerdVPN contract when its switch
      // endpoint requires a browser challenge.
      // https://git.nerdvpn.de/NerdVPN.de/invidious/src/commit/64d0cd413c3abd608fadc49cc3eaeada198293e3/patches/invidious/0002-companion-backend-selector.patch
      // Its public video metadata API/cache may also ignore this preference.
      name = 'COMPANION_ID';
    }
    name ??= await _discoverCookie(
        origin, advertised.take(2).toList(), server, elapsed);
    return BackendSelector(name, options, automaticFallback: automaticFallback);
  }

  Duration _remaining(Stopwatch elapsed) {
    final remaining = timeout - elapsed.elapsed;
    if (remaining <= Duration.zero) throw const BackendDiscoveryException();
    return remaining;
  }

  Future<String> _discoverCookie(Uri origin, List<_AdvertisedOption> choices,
      Server server, Stopwatch elapsed) async {
    final headers = <String, String>{'Accept': 'text/html'};
    for (final header in server.customHeaders.entries) {
      if (header.key.toLowerCase() == 'authorization' &&
          RegExp(r'^Basic\s+\S+$', caseSensitive: false)
              .hasMatch(header.value.trim())) {
        headers['Authorization'] = header.value;
      }
    }
    Set<String>? names;
    for (final choice in choices) {
      final target = choice.uri.replace(queryParameters: {
        'backend_id': choice.option.value,
        'referer': '/',
      });
      final response = await _read(target, headers, _remaining(elapsed));
      if (response.status < 200 || response.status >= 400) {
        throw const BackendDiscoveryException(
            'The server could not verify its backend cookie.');
      }
      if (response.headers['location'] != null &&
          _redirectTarget(response, target, origin) == null) {
        throw const BackendDiscoveryException();
      }
      final candidates =
          _cookieCandidates(response, choice.option.value, origin);
      names = names == null ? candidates : names.intersection(candidates);
      if (names.isEmpty) {
        throw const BackendDiscoveryException(
            'The server could not verify its backend cookie.');
      }
    }
    if (names == null || names.length != 1) {
      throw const BackendDiscoveryException(
          'The backend cookie could not be identified safely.');
    }
    return names.single;
  }

  Set<String> _cookieCandidates(
      _DiscoveryResponse response, String value, Uri origin) {
    final cookies = <String, String?>{};
    for (final line
        in (response.headers['set-cookie'] ?? '').split(_cookieSeparator)) {
      final parts = line.split(';');
      final separator = parts.first.indexOf('=');
      if (separator < 1) continue;
      final name = parts.first.substring(0, separator).trim();
      if (!_isRoutingCookieName(name)) continue;
      var candidate = parts.first.substring(separator + 1).trim();
      if (candidate.startsWith('"') &&
          candidate.endsWith('"') &&
          candidate.length > 1) {
        candidate = candidate.substring(1, candidate.length - 1);
      }
      var validScope = true;
      for (final attribute in parts.skip(1)) {
        final split = attribute.indexOf('=');
        if (split < 0) continue;
        final key = attribute.substring(0, split).trim().toLowerCase();
        final setting = attribute.substring(split + 1).trim().toLowerCase();
        if (key == 'domain') {
          final domain =
              setting.startsWith('.') ? setting.substring(1) : setting;
          if (domain.isEmpty ||
              (domain != origin.host && !origin.host.endsWith('.$domain'))) {
            validScope = false;
          }
        } else if (key == 'path' && setting != '/') {
          validScope = false;
        } else if (key == 'max-age' && (int.tryParse(setting) ?? 0) <= 0) {
          validScope = false;
        }
      }
      if (!validScope || cookies.containsKey(name)) {
        cookies[name] = null;
      } else {
        cookies[name] = candidate;
      }
    }
    return cookies.entries
        .where((entry) => entry.value == value)
        .map((entry) => entry.key)
        .toSet();
  }

  static bool _isRoutingCookieName(String name) {
    final lower = name.toLowerCase();
    final unprefixed = lower.replaceFirst(RegExp(r'^__(?:host|secure)-'), '');
    return name.length <= 256 &&
        _cookieName.hasMatch(name) &&
        !const {'sid', 'prefs', 'jwt', 'access', 'refresh'}
            .contains(unprefixed) &&
        !RegExp(r'session|sessid|auth|token|csrf|xsrf|login|password|captcha|challenge|clearance|gandalf|goaway|anubis')
            .hasMatch(lower);
  }

  static String _label(dom.Element anchor) {
    final buffer = StringBuffer();
    void append(dom.Node node) {
      if (node is dom.Text) {
        buffer.write(node.data);
      } else if (node is dom.Element &&
          !const {'script', 'style', 'template'}.contains(node.localName) &&
          !node.classes.contains('backend-status')) {
        for (final child in node.nodes) {
          append(child);
        }
      }
    }

    append(anchor);
    return buffer
        .toString()
        .replaceAll(RegExp(r'[❚|]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static bool _isSwitcher(Uri uri) => uri.path == '/switchbackend';

  static bool _hasLegacyNerdVpnCookie(Uri uri) =>
      const {'http', 'https'}.contains(uri.scheme) &&
      const {
        'invidious.nerdvpn.de',
        'nerdvpneaggggfdiurknszkbmhvjndks5z5k3g5yp4nhphflh3n3boad.onion',
        'invidious-nerdvpn.i2p',
      }.contains(uri.host) &&
      uri.port == (uri.scheme == 'https' ? 443 : 80) &&
      (uri.path.isEmpty || uri.path == '/') &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment;
  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;
  static bool _isRedirect(int status) =>
      const {301, 302, 303, 307, 308}.contains(status);

  static Uri? _redirectTarget(
      _DiscoveryResponse response, Uri current, Uri origin) {
    final location = response.headers['location'];
    if (location == null) return null;
    final parsed = Uri.tryParse(location);
    if (parsed == null) return null;
    final target = current.resolveUri(parsed);
    return _sameOrigin(origin, target) && target.userInfo.isEmpty
        ? target
        : null;
  }

  Future<_DiscoveryResponse> _read(
      Uri uri, Map<String, String> headers, Duration remaining) {
    final completed = Completer<_DiscoveryResponse>();
    StreamSubscription<List<int>>? subscription;
    final body = BytesBuilder(copy: false);
    late Timer deadline;
    void fail() {
      if (completed.isCompleted) return;
      deadline.cancel();
      unawaited(subscription?.cancel());
      completed.completeError(const BackendDiscoveryException());
    }

    deadline = Timer(remaining, fail);
    try {
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers.addAll(headers);
      unawaited(client.send(request).then<void>((response) {
        if (completed.isCompleted) {
          unawaited(response.stream.listen(null).cancel());
          return;
        }
        if ((response.contentLength ?? 0) > _maximumBytes) {
          unawaited(response.stream.listen(null).cancel());
          fail();
          return;
        }
        subscription = response.stream.listen((chunk) {
          if (completed.isCompleted) return;
          if (body.length + chunk.length > _maximumBytes) {
            fail();
          } else {
            body.add(chunk);
          }
        }, onError: (Object _, StackTrace __) {
          fail();
        }, onDone: () {
          if (completed.isCompleted) return;
          deadline.cancel();
          completed.complete(_DiscoveryResponse(
              response.statusCode,
              {
                for (final header in response.headers.entries)
                  header.key.toLowerCase(): header.value
              },
              body.takeBytes()));
        }, cancelOnError: true);
      }).catchError((Object _) {
        fail();
      }));
    } catch (_) {
      fail();
    }
    return completed.future;
  }
}

class _AdvertisedOption {
  final BackendOption option;
  final Uri uri;
  const _AdvertisedOption(this.option, this.uri);
}

class _DiscoveryResponse {
  final int status;
  final Map<String, String> headers;
  final List<int> body;
  const _DiscoveryResponse(this.status, this.headers, this.body);
}
