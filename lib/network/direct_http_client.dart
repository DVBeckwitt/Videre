import 'dart:io';

/// A raw client for proxy tests, the validated redirect-free LAN remote, or a
/// credential-free publisher client that explicitly reapplies NetworkProxy.
/// Ordinary application clients must use the global routing policy.
HttpClient createDirectHttpClient() =>
    _DirectOverrides().createHttpClient(null);

class _DirectOverrides extends HttpOverrides {}
