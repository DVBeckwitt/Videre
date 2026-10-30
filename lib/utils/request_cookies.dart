typedef _RequestCookie = ({String name, String value});

List<_RequestCookie> _parseRequestCookies(String value) {
  final cookies = <_RequestCookie>[];
  for (final part in value.split(';')) {
    final separator = part.indexOf('=');
    if (separator < 1) continue;
    final name = part.substring(0, separator).trim();
    if (name.isEmpty) continue;
    cookies.add((name: name, value: part.substring(separator + 1).trim()));
  }
  return cookies;
}

List<_RequestCookie> _cookiesFromHeaders(Map<String, String> headers) {
  final cookies = <_RequestCookie>[];
  for (final header in headers.entries) {
    if (header.key.toLowerCase() == 'cookie') {
      cookies.addAll(_parseRequestCookies(header.value));
    }
  }
  return cookies;
}

Map<String, String> _headersWithCookies(
    Map<String, String> headers, List<_RequestCookie> cookies) {
  final result = Map<String, String>.from(headers)
    ..removeWhere((name, _) => name.toLowerCase() == 'cookie');
  if (cookies.isNotEmpty) {
    result['Cookie'] =
        cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
  }
  return result;
}

/// HTTP header names are case-insensitive; cookie names are case-sensitive.
String? requestCookieValue(Map<String, String> headers, String name) {
  String? value;
  for (final cookie in _cookiesFromHeaders(headers)) {
    if (cookie.name == name) value = cookie.value;
  }
  return value;
}

void _replaceCookie(List<_RequestCookie> cookies, String name, String? value) {
  final index = cookies.indexWhere((cookie) => cookie.name == name);
  cookies.removeWhere((cookie) => cookie.name == name);
  if (value != null) {
    cookies
        .insert(index < 0 ? cookies.length : index, (name: name, value: value));
  }
}

/// Changes one request cookie while preserving other cookies and headers.
/// A null value removes the cookie; an empty string remains an empty value.
Map<String, String> withRequestCookie(
    Map<String, String> headers, String name, String? value) {
  final cookies = _cookiesFromHeaders(headers);
  _replaceCookie(cookies, name, value);
  return _headersWithCookies(headers, cookies);
}

/// Adds request cookies, replacing existing values with the same cookie name.
Map<String, String> mergeRequestCookies(
    Map<String, String> headers, String cookies) {
  final merged = _cookiesFromHeaders(headers);
  for (final cookie in _parseRequestCookies(cookies)) {
    _replaceCookie(merged, cookie.name, cookie.value);
  }
  return _headersWithCookies(headers, merged);
}
