import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../network/network_proxy.dart';
import '../../settings/models/db/server.dart';
import '../../settings/models/errors/invidious_service_error.dart';

/// A classified transport failure, without URLs, cookies or native messages.
class BackendPlaybackFailure implements Exception {
  const BackendPlaybackFailure();
}

bool _isUnavailableBackend(InvidiousServiceError error) {
  if (error.statusCode != 500 || error.responseWasHtml) return false;
  final code =
      error.errorCode?.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  // An explicit Companion message can identify a backend condition even with
  // HTTP 500, which would otherwise be an unclassified server error.
  // Match complete structured messages. Arbitrary 500s keep their error path,
  // and BackendPlayback still requires automatic fallback.
  return const {
    'this backend is still starting and not yet available. '
        'please wait for a short time or use another backend.',
    'this backend is blocked by youtube. please wait '
        'until it has refreshed itself or switch to another backend.',
  }.contains(code);
}

bool isBackendRetryable(Object error) =>
    error is BackendPlaybackFailure ||
    error is TimeoutException ||
    (error is SocketException && error.osError != null) ||
    (error is InvidiousServiceError &&
        !error.isGatewayAccessFailure &&
        // A cooldown belongs to the instance, including its other backends.
        // Invalid values must not become permission to dispatch immediately.
        !error.retryAfterIsInvalid &&
        (error.retryAfter ?? Duration.zero) <= Duration.zero &&
        (const [502, 503, 504].contains(error.statusCode) ||
            _isUnavailableBackend(error)));

class _BackendRetryBudget {
  final attempted = <String>{};
  int retries = 0;
  bool busy = false;
}

/// Ephemeral per-video routing. Returned videos retain an immutable server
/// snapshot; only the bounded attempt budget is shared across their retries.
/// Never serialize this object: it contains the instance's request credentials.
class BackendPlayback {
  final Server preferredServer;
  final Server server;
  final _BackendRetryBudget _budget;
  final Object _proxyConfiguration;

  /// True for a player-side choice, including its bounded fallback attempts.
  final bool manualSelection;

  /// The attempt represented by this snapshot, independent of later retries.
  final int retryIndex;

  factory BackendPlayback(Server server) {
    final budget = _BackendRetryBudget();
    final selected = server.backendSelector?.selectedValue(server);
    if (selected != null) budget.attempted.add(selected);
    return BackendPlayback._(
        server, server, budget, NetworkProxy.instance.config);
  }

  factory BackendPlayback.manual(Server preferredServer, String? value) {
    final selector = preferredServer.backendSelector;
    if (selector == null) throw StateError('No backend selector is available');
    final selected = selector.withSelection(preferredServer, value);
    final budget = _BackendRetryBudget();
    if (value != null) budget.attempted.add(value);
    return BackendPlayback._(
        preferredServer, selected, budget, NetworkProxy.instance.config,
        manualSelection: true);
  }

  BackendPlayback._(
      this.preferredServer, this.server, this._budget, this._proxyConfiguration,
      {this.manualSelection = false})
      : retryIndex = _budget.retries;

  int get retries => _budget.retries;

  bool get canRetry =>
      identical(NetworkProxy.instance.config, _proxyConfiguration) &&
      server.backendSelector?.automaticFallback == true &&
      _budget.retries < 2 &&
      server.backendSelector!.options
          .any((option) => !_budget.attempted.contains(option.value));

  bool acquireRecovery() {
    if (_budget.busy || !canRetry) return false;
    _budget.busy = true;
    return true;
  }

  void releaseRecovery() => _budget.busy = false;

  bool matches(Server current) =>
      identical(NetworkProxy.instance.config, _proxyConfiguration) &&
      preferredServer.url == current.url &&
      preferredServer.profileId == current.profileId &&
      preferredServer.accountId == current.accountId &&
      preferredServer.authToken == current.authToken &&
      preferredServer.sidCookie == current.sidCookie &&
      preferredServer.backendSelector == current.backendSelector &&
      mapEquals(preferredServer.customHeaders, current.customHeaders);

  BackendPlayback? next() {
    if (!canRetry) return null;
    final selector = server.backendSelector!;
    final option = selector.options
        .firstWhere((option) => !_budget.attempted.contains(option.value));
    // Reserve before awaiting anything, including a metadata request. Failed
    // attempts and repeated native error notifications cannot reset the limit.
    _budget.attempted.add(option.value);
    _budget.retries++;
    final nextServer = selector.withSelection(server, option.value);
    return BackendPlayback._(
        preferredServer, nextServer, _budget, _proxyConfiguration,
        manualSelection: manualSelection);
  }

  String get label {
    final selector = server.backendSelector!;
    return selector.labelFor(selector.selectedValue(server)) ?? '';
  }
}
