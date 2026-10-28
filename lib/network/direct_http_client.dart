import 'dart:io';

/// Used only for an unsaved proxy test or the validated, redirect-free LAN
/// remote. Ordinary application clients must use the global routing policy.
HttpClient createDirectHttpClient() =>
    _DirectOverrides().createHttpClient(null);

class _DirectOverrides extends HttpOverrides {}
