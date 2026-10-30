import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../network/network_proxy.dart';
import '../../network/reloadable_http_client.dart';
import '../models/feedback_report.dart';

/// Separate from Invidious Service: feedback never inherits instance credentials.
class FeedbackSubmissionClient {
  static const configuredUrl = String.fromEnvironment('VIDERE_FEEDBACK_URL');
  static const allowDevelopmentHttp =
      bool.fromEnvironment('VIDERE_FEEDBACK_ALLOW_HTTP');
  final Uri? endpoint;
  final http.Client? _injectedClient;
  final bool _allowHttp;
  final Duration timeout;

  FeedbackSubmissionClient(
      {Uri? endpoint,
      http.Client? client,
      bool allowHttp = allowDevelopmentHttp,
      this.timeout = const Duration(seconds: 40)})
      : endpoint = endpoint ??
            (configuredUrl.isEmpty ? null : Uri.tryParse(configuredUrl)),
        _injectedClient = client,
        _allowHttp = allowHttp;

  bool get configured {
    final uri = endpoint;
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return false;
    }
    if (uri.scheme == 'https') return true;
    return _allowHttp &&
        uri.scheme == 'http' &&
        (uri.host == 'localhost' ||
            uri.host == '127.0.0.1' ||
            uri.host == '::1' ||
            uri.host == '10.0.2.2');
  }

  Uri get reportsEndpoint {
    if (!configured) throw const FeedbackFailure('unconfigured');
    final base = endpoint!;
    final path = base.path.replaceAll(RegExp(r'/+$'), '');
    return base.replace(path: '$path/v1/reports');
  }

  Future<FeedbackReceipt> submit(FeedbackDraft draft) async {
    if (!configured) throw const FeedbackFailure('unconfigured');
    if (!draft.isValid) throw const FeedbackFailure('validation');
    final bytes = utf8.encode(jsonEncode(draft.toRequest()));
    if (bytes.length > 3 * 1024 * 1024) {
      throw const FeedbackFailure('too_large');
    }
    final owned = _injectedClient == null;
    final client = _injectedClient ?? IOClient(createFeedbackHttpClient());
    try {
      return await _send(client, draft, bytes).timeout(timeout);
    } on FeedbackFailure {
      rethrow;
    } catch (_) {
      // The issue may already exist after a timeout. The controller retains its
      // exact submitted snapshot and nonce for the next explicit retry.
      throw const FeedbackFailure('network');
    } finally {
      if (owned) client.close();
    }
  }

  Future<FeedbackReceipt> _send(
      http.Client client, FeedbackDraft draft, List<int> bytes) async {
    final request = http.Request('POST', reportsEndpoint)
      ..followRedirects = false
      ..headers.addAll({
        'Content-Type': 'application/json; charset=utf-8',
        'Accept': 'application/json'
      })
      ..bodyBytes = bytes;
    final response = await client.send(request);
    final body = <int>[];
    await for (final chunk in response.stream) {
      if (body.length + chunk.length > 64 * 1024) {
        throw const FeedbackFailure('invalid_response');
      }
      body.addAll(chunk);
    }
    int? retryAfter;
    final parsedRetry = int.tryParse(response.headers['retry-after'] ?? '');
    if (parsedRetry != null && parsedRetry > 0 && parsedRetry <= 86400) {
      retryAfter = parsedRetry;
    }
    if (response.statusCode == 202) {
      throw FeedbackFailure('pending', retryAfterSeconds: retryAfter);
    }
    if (response.statusCode != 200 && response.statusCode != 201) {
      final code = switch (response.statusCode) {
        400 => 'validation',
        409 => 'conflict',
        413 => 'too_large',
        429 => 'rate_limited',
        503 => 'unavailable',
        502 => 'github_failed',
        _ => 'invalid_response',
      };
      throw FeedbackFailure(code, retryAfterSeconds: retryAfter);
    }
    Object? json;
    try {
      json = jsonDecode(utf8.decode(body));
    } catch (_) {
      throw const FeedbackFailure('invalid_response');
    }
    if (json is! Map<String, dynamic> ||
        json['status'] != 'created' ||
        json['issueNumber'] is! int ||
        json['issueUrl'] is! String) {
      throw const FeedbackFailure('invalid_response');
    }
    final number = json['issueNumber'] as int;
    final uri = Uri.tryParse(json['issueUrl'] as String);
    if (uri == null || !FeedbackReceipt.validIssueUrl(uri, number)) {
      throw const FeedbackFailure('invalid_response');
    }
    return FeedbackReceipt(
        submissionId: draft.submissionId,
        issueNumber: number,
        issueUrl: uri,
        createdAt: DateTime.now().toUtc(),
        title: draft.title,
        kind: draft.kind);
  }
}

/// Applies the same fail-closed routing/reset policy as playback, while requiring
/// valid TLS even if the user allowed an invalid certificate on an instance.
HttpClient createFeedbackHttpClient() =>
    _FeedbackHttpOverrides().createHttpClient(null);

class _FeedbackHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      ReloadableHttpClient(() {
        final client = super.createHttpClient(context)
          ..badCertificateCallback = ((_, __, ___) => false)
          // Version/build details belong only in the user's optional diagnostics.
          ..userAgent = 'Videre-Feedback';
        NetworkProxy.instance.configureClient(client,
            context: context, requireValidCertificate: true);
        return client;
      });
}
