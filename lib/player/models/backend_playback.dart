import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../network/media_companion.dart';
import '../../network/network_proxy.dart';
import '../../settings/models/db/server.dart';
import '../../settings/models/errors/invidious_service_error.dart';
import '../../utils/interfaces/db.dart';
import 'playback_instance_fallback.dart';
import 'playback_reliability.dart';

/// A classified transport failure, without URLs, cookies or native messages.
class BackendPlaybackFailure implements Exception {
  const BackendPlaybackFailure();
}

bool isUnavailableBackend(InvidiousServiceError error) {
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
            isUnavailableBackend(error)));

enum _BackendResult {
  success(Duration(minutes: 5)),
  upstreamError(Duration(seconds: 30)),
  unavailable(Duration(minutes: 2));

  final Duration lifetime;
  const _BackendResult(this.lifetime);
}

typedef _BackendObservation = ({
  _BackendResult result,
  DateTime time,
  int attempt
});

/// Passive observations from this service session. A route with no recent
/// evidence keeps its advertised order. Only explicit Companion outages
/// quarantine a backend; an item, account or network failure says nothing
/// about whether that backend can serve the next video.
class BackendHealth {
  static const _maximumEntries = 256;

  final DateTime Function() _now;
  Expando<Map<(String, int), _BackendObservation>>? _byProxy = Expando();
  int _attempt = 0;

  BackendHealth({DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// Retained player snapshots may outlive the service session that admitted
  /// them. Those snapshots can no longer read or publish health observations.
  void retire() => _byProxy = null;

  // Store a fingerprint and an advertised option index. The table never
  // retains credentials, raw headers, URLs, content IDs or proxy settings.
  String _scope(Server server) {
    final headers = server.customHeaders.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return sha256
        .convert(utf8.encode(jsonEncode([
          server.profileId,
          server.accountId,
          server.url,
          server.gatewayEnabled,
          server.authToken,
          server.sidCookie,
          for (final entry in headers) [entry.key, entry.value],
          server.backendSelector?.toJson(),
        ])))
        .toString();
  }

  Map<(String, int), _BackendObservation>? _recent(Object proxy) {
    final tables = _byProxy;
    if (tables == null) return null;
    final entries = tables[proxy] ??= {};
    final now = _now();
    entries.removeWhere((_, value) {
      final age = now.difference(value.time);
      return age.isNegative || age >= value.result.lifetime;
    });
    return entries;
  }

  void recordInstanceStartupFailure(Server server) {
    if (NetworkProxy.instance.isChanging) return;
    _record(NetworkProxy.instance.config, _scope(server), -1, ++_attempt,
        _BackendResult.upstreamError);
  }

  bool hasRecentInstanceStartupFailure(Server server) =>
      _recent(NetworkProxy.instance.config)?[(_scope(server), -1)]?.result ==
      _BackendResult.upstreamError;

  void _record(Object proxy, String scope, int option, int attempt,
      _BackendResult result) {
    final entries = _recent(proxy);
    if (entries == null) return;
    final key = (scope, option);
    final previous = entries[key];
    // A slow, older request must not erase an outage reported by a newer
    // one. An outage after metadata success on the same attempt wins too.
    if (previous != null &&
        (attempt < previous.attempt ||
            (attempt == previous.attempt &&
                previous.result.index >= result.index) ||
            (previous.result == _BackendResult.unavailable &&
                result == _BackendResult.upstreamError))) {
      return;
    }
    entries.remove(key);
    entries[key] = (result: result, time: _now(), attempt: attempt);
    if (entries.length > _maximumEntries) entries.remove(entries.keys.first);
  }
}

class _BackendRetryBudget {
  final BackendHealth? health;
  final String? healthScope;
  final int limit;
  final IDbClient? reliabilityOwner;
  final attempted = <String>{};
  int retries = 0;
  bool busy = false;
  bool initialPlaybackHandoff = false;

  _BackendRetryBudget(Server server, this.health,
      {int retries = PlaybackInstanceFallback.defaultBackendRetries,
      this.reliabilityOwner})
      : limit = retries.clamp(0, PlaybackInstanceFallback.maxBackendRetries),
        healthScope =
            server.backendSelector == null ? null : health?._scope(server);
}

/// Ephemeral per-video routing. Returned videos retain an immutable server
/// snapshot; only the bounded attempt budget is shared across their retries.
/// Never serialize this object: it contains the instance's request credentials.
class BackendPlayback {
  final Server preferredServer;
  final Server server;
  final _BackendRetryBudget _budget;
  final Object _proxyConfiguration;
  final int _healthAttempt;

  /// True for a player-side choice, including its bounded fallback attempts.
  final bool manualSelection;
  final bool isInstanceFallback;

  /// The attempt represented by this snapshot, independent of later retries.
  final int retryIndex;

  factory BackendPlayback(Server server,
      {BackendHealth? health,
      int backendRetries = PlaybackInstanceFallback.defaultBackendRetries,
      IDbClient? reliabilityOwner}) {
    final budget = _BackendRetryBudget(server, health,
        retries: backendRetries, reliabilityOwner: reliabilityOwner);
    final selected = server.backendSelector?.selectedValue(server);
    if (selected != null) budget.attempted.add(selected);
    return BackendPlayback._(
        server, server, budget, NetworkProxy.instance.config);
  }

  factory BackendPlayback.manual(Server preferredServer, String? value,
      {BackendHealth? health,
      int backendRetries = PlaybackInstanceFallback.defaultBackendRetries,
      IDbClient? reliabilityOwner}) {
    final selector = preferredServer.backendSelector;
    if (selector == null) throw StateError('No backend selector is available');
    final selected = selector.withSelection(preferredServer, value);
    final budget = _BackendRetryBudget(preferredServer, health,
        retries: backendRetries, reliabilityOwner: reliabilityOwner);
    if (value != null) budget.attempted.add(value);
    return BackendPlayback._(
        preferredServer, selected, budget, NetworkProxy.instance.config,
        manualSelection: true);
  }

  factory BackendPlayback.instanceFallback(Server selected, Server target) =>
      BackendPlayback._(selected, target, _BackendRetryBudget(target, null),
          NetworkProxy.instance.config,
          isInstanceFallback: true);

  BackendPlayback._(
      this.preferredServer, this.server, this._budget, this._proxyConfiguration,
      {this.manualSelection = false, this.isInstanceFallback = false})
      : retryIndex = _budget.retries,
        _healthAttempt =
            _budget.health == null ? 0 : ++_budget.health!._attempt;

  int get retries => _budget.retries;
  int get backendRetryLimit => _budget.limit;

  /// A Watch details route can forward its fresh alternate once when playback
  /// begins. Queue entries and saved state cannot renew this admission.
  void allowInitialPlaybackHandoff() {
    if (isInstanceFallback) _budget.initialPlaybackHandoff = true;
  }

  bool takeInitialPlaybackHandoff() {
    final permitted = _budget.initialPlaybackHandoff;
    _budget.initialPlaybackHandoff = false;
    return permitted;
  }

  String? get _nextValue {
    final selector = server.backendSelector;
    if (isInstanceFallback ||
        selector == null ||
        !selector.automaticFallback ||
        _budget.retries >= _budget.limit ||
        NetworkProxy.instance.isChanging ||
        !identical(NetworkProxy.instance.config, _proxyConfiguration)) {
      return null;
    }
    final recent = _budget.health?._recent(_proxyConfiguration);
    final owner = _budget.reliabilityOwner;
    String? best;
    var bestScore = -1.0;
    var bestHealth = -1;
    for (final (index, option) in selector.options.indexed) {
      if (_budget.attempted.contains(option.value)) continue;
      final health = switch (recent?[(_budget.healthScope!, index)]?.result) {
        _BackendResult.success => 2,
        null => 1,
        _BackendResult.upstreamError => 0,
        _BackendResult.unavailable => -1,
      };
      if (health < 0) continue;
      final score = owner == null
          ? 0.5
          : PlaybackReliability.backend(owner, preferredServer, index).score;
      if (score > bestScore || score == bestScore && health > bestHealth) {
        best = option.value;
        bestScore = score;
        bestHealth = health;
      }
    }
    return best;
  }

  bool get canRetry => _nextValue != null;

  void recordSuccess() => _record(_BackendResult.success);

  /// Decoder evidence is separate from metadata health, which remains advisory.
  void recordDecoderOutcome(IDbClient owner, {required bool success}) {
    try {
      if (owner.profileId != preferredServer.profileId ||
          NetworkProxy.instance.isChanging) {
        return;
      }
      final selected = owner.getAccount(preferredServer.accountId);
      if (selected == null ||
          !selected.inUse ||
          !matchesPlaybackConnection(owner, selected)) {
        return;
      }
      final account = isInstanceFallback
          ? PlaybackInstanceFallback.admittedTarget(
              owner, selected, PlaybackInstanceFallback.choiceId(owner, server))
          : selected;
      if (account == null) return;
      final selector = server.backendSelector;
      final value = selector?.selectedValue(server);
      final index =
          selector?.options.indexWhere((option) => option.value == value);
      PlaybackReliability.record(owner, account,
          backendIndex: index,
          success: success,
          accountOwner: account.profileId == owner.profileId
              ? null
              : owner.forProfile(account.profileId));
    } on Object {
      // Losing the settings store cannot interrupt a decoder.
    }
  }

  void recordFailure(Object error) {
    if (error is! InvidiousServiceError ||
        error.isGatewayAccessFailure ||
        error.retryAfter != null ||
        error.retryAfterIsInvalid) {
      return;
    }
    if (isUnavailableBackend(error)) {
      _record(_BackendResult.unavailable);
    } else if (const [502, 503, 504].contains(error.statusCode)) {
      // An upstream error may affect the entire instance. Prefer an untested
      // route on the next item, but keep this one eligible if none remain.
      _record(_BackendResult.upstreamError);
    }
  }

  void _record(_BackendResult result) {
    final health = _budget.health;
    final scope = _budget.healthScope;
    if (health == null ||
        scope == null ||
        NetworkProxy.instance.isChanging ||
        !identical(NetworkProxy.instance.config, _proxyConfiguration)) {
      return;
    }
    final selector = server.backendSelector!;
    final value = selector.selectedValue(server);
    final index =
        selector.options.indexWhere((option) => option.value == value);
    // The instance can automatically choose a backend without identifying it.
    if (index >= 0) {
      health._record(_proxyConfiguration, scope, index, _healthAttempt, result);
    }
  }

  bool acquireRecovery() {
    if (_budget.busy || !canRetry) return false;
    _budget.busy = true;
    return true;
  }

  void releaseRecovery() => _budget.busy = false;

  bool matches(Server current) =>
      matchesConnection(current) &&
      setEquals(trustedMediaCompanionOrigins(preferredServer),
          trustedMediaCompanionOrigins(current));

  /// Frontend-only requests never use the player's media companion grants.
  bool matchesConnection(Server current) =>
      !isInstanceFallback && _matchesPreferred(current);

  bool _matchesPreferred(Server current) =>
      identical(NetworkProxy.instance.config, _proxyConfiguration) &&
      _sameConnection(preferredServer, current);

  /// Backup playback must still own the selected account and the
  /// separately authorized transport account on each admission.
  bool matchesPlaybackConnection(IDbClient owner, Server selected) {
    if (!isInstanceFallback) return matches(selected);
    if (!_matchesPreferred(selected) || NetworkProxy.instance.isChanging) {
      return false;
    }
    final target = PlaybackInstanceFallback.admittedTarget(
        owner, selected, PlaybackInstanceFallback.choiceId(owner, server));
    return selected.inUse &&
        selected.gatewayEnabled == preferredServer.gatewayEnabled &&
        target != null &&
        target.gatewayEnabled == server.gatewayEnabled &&
        _sameConnection(server, target) &&
        setEquals(trustedMediaCompanionOrigins(server),
            trustedMediaCompanionOrigins(target));
  }

  static bool _sameConnection(Server expected, Server current) =>
      expected.url == current.url &&
      expected.profileId == current.profileId &&
      expected.accountId == current.accountId &&
      expected.authToken == current.authToken &&
      expected.sidCookie == current.sidCookie &&
      expected.backendSelector == current.backendSelector &&
      mapEquals(expected.customHeaders, current.customHeaders);

  BackendPlayback? next() {
    final value = _nextValue;
    if (value == null) return null;
    // Reserve before awaiting anything, including a metadata request. Failed
    // attempts and repeated native error notifications cannot reset the limit.
    _budget.attempted.add(value);
    _budget.retries++;
    final nextServer = server.backendSelector!.withSelection(server, value);
    return BackendPlayback._(
        preferredServer, nextServer, _budget, _proxyConfiguration,
        manualSelection: manualSelection);
  }

  String get label {
    final selector = server.backendSelector!;
    return selector.labelFor(selector.selectedValue(server)) ?? '';
  }
}
