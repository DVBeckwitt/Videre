import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../settings/models/db/server.dart';
import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';

final class PlaybackReliabilityCount {
  final int successes;
  final int failures;

  const PlaybackReliabilityCount({this.successes = 0, this.failures = 0});

  int get attempts => successes + failures;

  /// A balanced prior limits the influence of a single attempt.
  double get score => (successes + 4) / (attempts + 8);

  PlaybackReliabilityCount _after(bool success) {
    final reduce = attempts >= PlaybackReliability._maximumAttempts;
    return PlaybackReliabilityCount(
      successes: (reduce ? successes ~/ 2 : successes) + (success ? 1 : 0),
      failures: (reduce ? failures ~/ 2 : failures) + (success ? 0 : 1),
    );
  }

  List<int> _encode() => [successes, failures];
}

/// Profile-local outcomes used only to rank already eligible playback routes.
abstract final class PlaybackReliability {
  static const _setting = 'playback-reliability-v1';
  static const _maximumEntries = 128;
  static const _maximumAttempts = 100000;
  static const _empty = PlaybackReliabilityCount();
  static final _fingerprint = RegExp(r'^[0-9a-f]{64}$');
  static final _log = Logger('PlaybackReliability');
  static final _revision = ValueNotifier<int>(0);
  static final _writes = <String, Future<void>>{};
  static ({String raw, Map<String, PlaybackReliabilityCount> rows})? _decoded;

  static ValueListenable<int> get revision => _revision;

  static PlaybackReliabilityCount account(IDbClient owner, Server account) =>
      _count(owner, _accountKey(account, owner.profileId));

  /// The index refers to the selector's advertised options. The stored key
  /// follows the backend if the instance reorders its options.
  static PlaybackReliabilityCount backend(
      IDbClient owner, Server account, int index) {
    final accountKey = _accountKey(account, owner.profileId);
    return _count(owner,
        accountKey == null ? null : _backendKey(account, accountKey, index));
  }

  /// Queues an observation without delaying playback. An identified backend
  /// also contributes to its instance's aggregate in the same settings write.
  static void record(IDbClient capturedOwner, Server account,
      {int? backendIndex, required bool success, IDbClient? accountOwner}) {
    final accountId = account.accountId;
    final String profileId;
    final IDbClient owner;
    final IDbClient routeOwner;
    try {
      profileId = capturedOwner.profileId;
      owner = capturedOwner.forProfile(profileId);
      routeOwner = accountOwner ?? owner;
      if (routeOwner.profileId != account.profileId) return;
    } on Object {
      return;
    }
    final accountKey = _accountKey(account, profileId);
    if (accountKey == null) return;
    final backendKey = backendIndex == null
        ? null
        : _backendKey(account, accountKey, backendIndex);

    final previous = _writes[profileId] ?? Future<void>.value();
    final pending = previous.then((_) async {
      try {
        final current = routeOwner.getAccount(accountId);
        if (current == null || _accountKey(current, profileId) != accountKey) {
          return;
        }
        final rows = Map.of(_read(owner));
        if (backendKey != null) _increment(rows, backendKey, success);
        _increment(rows, accountKey, success);
        while (rows.length > _maximumEntries) {
          rows.remove(rows.keys.first);
        }
        await owner.saveSetting(SettingsValue(
            _setting,
            jsonEncode(
                rows.map((key, count) => MapEntry(key, count._encode())))));
        _revision.value++;
      } on Object catch (error) {
        // Profile removal or an unavailable settings store cannot disrupt play.
        _log.fine('Could not save playback reliability (${error.runtimeType})');
      }
    });
    _writes[profileId] = pending;
    unawaited(pending.whenComplete(() {
      if (identical(_writes[profileId], pending)) _writes.remove(profileId);
    }));
  }

  static PlaybackReliabilityCount _count(IDbClient owner, String? key) {
    if (key == null) return _empty;
    try {
      return _read(owner)[key] ?? _empty;
    } on Object {
      return _empty;
    }
  }

  static void _increment(
      Map<String, PlaybackReliabilityCount> rows, String key, bool success) {
    final previous = rows.remove(key) ?? _empty;
    rows[key] = previous._after(success);
  }

  static Map<String, PlaybackReliabilityCount> _read(IDbClient owner) {
    final raw = owner.getSettings(_setting)?.value;
    if (raw == null || raw.length > _maximumEntries * 112) return const {};
    final snapshot = _decoded;
    if (snapshot != null && snapshot.raw == raw) return snapshot.rows;

    final rows = <String, PlaybackReliabilityCount>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        for (final MapEntry(:key, :value)
            in decoded.entries.take(_maximumEntries)) {
          if (_fingerprint.stringMatch(key) == key &&
              value is List &&
              value.length == 2 &&
              value[0] is int &&
              value[1] is int) {
            final successes = value[0] as int;
            final failures = value[1] as int;
            if (successes >= 0 &&
                failures >= 0 &&
                successes <= _maximumAttempts &&
                failures <= _maximumAttempts &&
                successes + failures <= _maximumAttempts) {
              rows[key] = PlaybackReliabilityCount(
                  successes: successes, failures: failures);
            }
          }
        }
      }
    } on FormatException {
      // An incomplete or invalid settings value has no usable evidence.
    }
    _decoded = (raw: raw, rows: rows);
    return rows;
  }

  static String? _accountKey(Server server, String ownerProfileId) {
    final uri = Uri.tryParse(server.url);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      return null;
    }
    return _digest([
      'account',
      if (server.profileId != ownerProfileId) server.profileId,
      server.accountId,
      uri.origin,
      if (uri.path.isNotEmpty && uri.path != '/') uri.path,
    ]);
  }

  static String? _backendKey(Server server, String accountKey, int index) {
    final selector = server.backendSelector;
    if (selector == null || index < 0 || index >= selector.options.length) {
      return null;
    }
    return _digest([
      'backend',
      accountKey,
      selector.cookieName,
      selector.preferenceField,
      selector.options[index].value,
    ]);
  }

  static String _digest(List<Object?> values) =>
      sha256.convert(utf8.encode(jsonEncode(values))).toString();
}
