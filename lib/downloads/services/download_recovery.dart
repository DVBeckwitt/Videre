import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../globals.dart';
import '../../network/network_proxy.dart';
import '../../player/models/backend_playback.dart';
import '../../service.dart';
import '../../settings/models/db/server.dart';
import '../../settings/models/db/settings.dart';
import '../../settings/models/errors/invidious_service_error.dart';
import '../../utils/interfaces/db.dart';

/// A different extractor may return the missing compatible rendition.
class DownloadFormatsUnavailable implements Exception {
  const DownloadFormatsUnavailable();
}

/// Release the queue and leave this job paused for an explicit resume.
class DownloadCooldown implements Exception {
  final DateTime retryAt;
  const DownloadCooldown(this.retryAt);
}

class DownloadRecovery {
  static const _maximumWait = Duration(seconds: 10);
  static final _cooldowns = Expando<Map<String, DateTime>>();

  final Service _client;
  final IDbClient _database;
  final IDbClient _owner;
  final CancelToken _token;
  BackendPlayback _route;

  DownloadRecovery._(
      this._client, this._database, this._owner, this._token, this._route);

  static String _cooldownKey(Server server) =>
      'download-cooldown-${sha256.convert(utf8.encode(Uri.parse(server.url).origin))}';

  static DateTime? retryAtFor(Service client, IDbClient owner, Server server) {
    final key = _cooldownKey(server);
    final memory = _cooldowns[client]?[key];
    final saved = DateTime.tryParse(owner.getSettings(key)?.value ?? '');
    final deadline = memory != null && (saved == null || memory.isAfter(saved))
        ? memory
        : saved;
    return deadline != null && deadline.isAfter(DateTime.now())
        ? deadline
        : null;
  }

  static Future<DownloadRecovery> start(Service client, IDbClient owner,
      Server account, CancelToken token) async {
    final database = db;
    final prepared =
        await client.preparePlaybackServer(serverOverride: account);
    final recovery = DownloadRecovery._(client, database, owner, token,
        BackendPlayback(prepared, health: client.backendHealth));
    recovery.checkCurrent();
    return recovery;
  }

  void checkCurrent() {
    if (_token.isCancelled) throw _token.cancelError!;
    final saved = _owner.getAccount(_route.preferredServer.accountId);
    if (!identical(db, _database) ||
        db.profileId != _owner.profileId ||
        NetworkProxy.instance.isChanging ||
        saved == null ||
        !_route.matches(saved)) {
      throw StateError('The download connection changed.');
    }
  }

  /// Three attempts total across metadata, track discovery and transfer.
  /// A server cooldown applies to every download backend on the same origin.
  Future<T> run<T>(Future<T> Function(BackendPlayback route) operation,
      {void Function(DateTime? retryAt)? onWaiting}) async {
    final cooldowns = _cooldowns[_client] ??= {};
    cooldowns.removeWhere((_, deadline) => !deadline.isAfter(DateTime.now()));
    var renewedExpiredUrl = false;
    for (var attempt = 1;; attempt++) {
      checkCurrent();
      while (true) {
        final deadline = retryAtFor(_client, _owner, _route.server);
        if (deadline == null) break;
        final remaining = deadline.difference(DateTime.now());
        if (remaining > _maximumWait) throw DownloadCooldown(deadline);
        await _wait(remaining, onWaiting);
      }
      try {
        return await operation(_route);
      } catch (error) {
        checkCurrent();
        final response = _responseError(error);
        if (response?.isGatewayAccessFailure == true) rethrow;
        if (response != null &&
            (response.isRateLimited ||
                response.retryAfterIsInvalid ||
                (response.retryAfter ?? Duration.zero) > Duration.zero)) {
          // Missing/invalid rate-limit guidance pauses the job. Give other
          // queued jobs a local quiet period as well.
          final delay = response.retryAfter ?? const Duration(seconds: 30);
          final now = DateTime.now().toUtc();
          final prior = retryAtFor(_client, _owner, _route.server);
          // Keep very large valid delays representable by Dart's DateTime.
          final latest = DateTime.utc(9999, 12, 31);
          final proposed =
              delay >= latest.difference(now) ? latest : now.add(delay);
          final deadline =
              prior != null && prior.isAfter(proposed) ? prior : proposed;
          if (deadline != prior) {
            final key = _cooldownKey(_route.server);
            cooldowns[key] = deadline;
            await _owner.saveSetting(
                SettingsValue(key, deadline.toUtc().toIso8601String()));
          }
          if (response.retryAfter == null ||
              delay > _maximumWait ||
              attempt >= 3 ||
              const {401, 403, 404, 410, 451}.contains(response.statusCode)) {
            throw DownloadCooldown(deadline);
          }
          if (delay <= Duration.zero) {
            await _wait(Duration(seconds: attempt), onWaiting);
          }
          continue; // Keep the same route after an instance-wide limit.
        }
        final failure = response ?? error;
        _route.recordFailure(failure);
        if (attempt >= 3) rethrow;
        if (!renewedExpiredUrl && _expiredMediaUrl(error)) {
          renewedExpiredUrl = true;
          await _wait(Duration(seconds: attempt), onWaiting);
          continue;
        }
        final alternateAllowed = isBackendRetryable(failure) ||
            error is DownloadFormatsUnavailable ||
            _transportFailure(error);
        final alternate = alternateAllowed ? _route.next() : null;
        if (alternate != null) {
          _route = alternate;
          if (attempt == 2) await _wait(const Duration(seconds: 2), onWaiting);
          continue;
        }
        // Explicit Companion startup/block reports already identify this
        // extractor as unavailable. Leave Retry to the user if no eligible
        // alternative remains.
        if (failure is InvidiousServiceError && isUnavailableBackend(failure)) {
          rethrow;
        }
        final refreshSameRoute =
            (alternateAllowed && error is! DownloadFormatsUnavailable) ||
                error is SocketException;
        if (!refreshSameRoute || _route.retryIndex > 0) rethrow;
        await _wait(Duration(seconds: attempt), onWaiting);
      }
    }
  }

  Future<void> _wait(
      Duration duration, void Function(DateTime?)? onWaiting) async {
    if (duration <= Duration.zero) return;
    onWaiting?.call(DateTime.now().add(duration));
    final elapsed = Completer<void>();
    final timer = Timer(duration, elapsed.complete);
    try {
      await Future.any([elapsed.future, _token.whenCancel]);
    } finally {
      timer.cancel();
      onWaiting?.call(null);
    }
    checkCurrent();
  }

  // A signed URL can expire during a long transfer. Renew metadata once on
  // the same route when the URL itself confirms expiry. Access denials for
  // current URLs never authorize another backend.
  static bool _expiredMediaUrl(Object error) {
    if (error is! DioException ||
        !const {403, 410}.contains(error.response?.statusCode)) {
      return false;
    }
    final expires =
        int.tryParse(error.requestOptions.uri.queryParameters['expire'] ?? '');
    return expires != null &&
        expires > 0 &&
        expires <= DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }

  InvidiousServiceError? _responseError(Object error) {
    if (error is InvidiousServiceError) return error;
    if (error is! DioException) return null;
    if (error.error case final InvidiousServiceError cause) return cause;
    final response = error.response;
    if (response == null) return null;
    final values = response.headers[HttpHeaders.retryAfterHeader];
    final delay =
        values?.length == 1 ? _client.retryAfterDelay(values!.first) : null;
    return InvidiousServiceError('Download request failed.',
        statusCode: response.statusCode,
        retryAfter: delay,
        retryAfterIsInvalid: values != null && delay == null);
  }

  static bool _transportFailure(Object error) {
    if (error is HttpException) return true;
    if (error is! DioException) return false;
    return const {
          DioExceptionType.connectionTimeout,
          DioExceptionType.receiveTimeout,
          DioExceptionType.sendTimeout
        }.contains(error.type) ||
        isBackendRetryable(error.error ?? error) ||
        error.error is HttpException;
  }
}
