import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../network/youtube_privacy.dart';
import '../../settings/models/db/server.dart';
import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';
import 'playback_reliability.dart';

/// A single alternate instance, selected explicitly for this profile.
abstract final class PlaybackInstanceFallback {
  static const _setting = 'playbackInstanceFallbackAccount';
  static const _backendRetriesSetting = 'playbackBackendRetries';
  static const _sharingSetting = 'sharePlaybackInstanceFallback';
  static const _routePrefix = '@profile:';
  static const bestSaved = '@best';
  static const defaultBackendRetries = 2;
  static const maxBackendRetries = 4;
  static final _revision = ValueNotifier(0);
  static ValueListenable<int> get revision => _revision;

  static String? preference(IDbClient owner) {
    final value = owner.getSettings(_setting)?.value;
    return value == null || value.isEmpty ? null : value;
  }

  static int backendRetries(IDbClient owner) {
    final saved = owner.getSettings(_backendRetriesSetting)?.value;
    final count = int.tryParse(saved ?? '') ?? defaultBackendRetries;
    return count.clamp(0, maxBackendRetries);
  }

  static Future<void> saveBackendRetries(IDbClient owner, int count) async {
    RangeError.checkValueInInterval(count, 0, maxBackendRetries, 'count');
    await owner
        .forProfile(owner.profileId)
        .saveSetting(SettingsValue(_backendRetriesSetting, count.toString()));
    _revision.value++;
  }

  static bool sharingEnabled(IDbClient owner) =>
      owner.getSettings(_sharingSetting)?.value == 'true';

  static Future<void> saveSharing(IDbClient owner, bool enabled) async {
    await owner
        .forProfile(owner.profileId)
        .saveSetting(SettingsValue(_sharingSetting, enabled.toString()));
    _revision.value++;
  }

  /// Existing local preferences retain their IDs. Encoded IDs identify both
  /// the destination profile and exact account, including reserved local IDs.
  static String choiceId(IDbClient source, Server candidate) {
    final accountId = candidate.accountId;
    return candidate.profileId == source.profileId &&
            accountId != bestSaved &&
            !accountId.startsWith(_routePrefix)
        ? accountId
        : _encodeChoice(candidate.profileId, accountId);
  }

  /// Automatically ranked fallback never leaves the active profile.
  static Future<List<Server>> choices(IDbClient owner) =>
      _choices(owner, shared: false);

  /// Explicit backups may include accounts offered by another person profile.
  static Future<List<Server>> backupChoices(IDbClient source) =>
      _choices(source, shared: true);

  static Future<List<Server>> _choices(IDbClient source,
      {required bool shared}) async {
    final profile = source.profileId;
    final owner = source.forProfile(profile);
    final accounts = await owner.getServers();
    final selected = accounts
        .where((account) => account.profileId == profile && account.inUse)
        .firstOrNull;
    if (selected == null || source.profileId != profile) return const [];

    final available = accounts
        .where((account) =>
            account.profileId == profile && _eligible(selected, account))
        .toList();
    if (shared) {
      for (final person in await owner.getProfiles()) {
        if (person.id == profile) continue;
        final destination = _sharedOwner(owner, person.id);
        if (destination == null) continue;
        try {
          final accounts = await destination.getServers();
          if (!sharingEnabled(destination)) continue;
          available.addAll(accounts.where((account) =>
              account.profileId == person.id && _eligible(selected, account)));
        } on StateError {
          // The profile may have been removed during the lookup.
        }
      }
    }
    return source.profileId == profile ? available : const [];
  }

  static Future<void> save(IDbClient owner, String? accountId) async {
    final profile = owner.profileId;
    final source = owner.forProfile(profile);
    if (accountId != null) {
      final accounts = await source.getServers();
      final selected = accounts
          .where((account) => account.profileId == profile && account.inUse)
          .firstOrNull;
      final available = selected != null &&
          (accountId == bestSaved
              ? accounts.any((candidate) =>
                  candidate.profileId == profile &&
                  _eligible(selected, candidate))
              : _resolve(source, selected, accountId) != null);
      if (!available) {
        throw StateError('The selected backup instance is unavailable.');
      }
    }
    if (owner.profileId != profile) {
      throw StateError('The active profile changed.');
    }
    await source.saveSetting(SettingsValue(_setting, accountId ?? ''));
    _revision.value++;
  }

  static Server? target(
      IDbClient owner, Server selected, Iterable<Server> accounts,
      {bool Function(Server)? recentlyFailed}) {
    final id = preference(owner);
    if (id == null || selected.profileId != owner.profileId) return null;
    if (id != bestSaved) return admittedTarget(owner, selected, id);

    final ranked = [
      for (final account in accounts)
        if (account.profileId == owner.profileId &&
            _eligible(selected, account) &&
            recentlyFailed?.call(account) != true)
          (
            account: account,
            score: PlaybackReliability.account(owner, account).score
          )
    ]..sort((left, right) {
        final comparison = right.score.compareTo(left.score);
        return comparison != 0
            ? comparison
            : left.account.accountId.compareTo(right.account.accountId);
      });
    return ranked.firstOrNull?.account;
  }

  /// Revalidate the route that was actually chosen, even if scores have moved.
  /// A shared route stops being eligible as soon as sharing is revoked.
  static Server? admittedTarget(
      IDbClient owner, Server selected, String targetId) {
    final preferenceId = preference(owner);
    if (preferenceId == bestSaved) {
      final choice = _decodeChoice(owner.profileId, targetId);
      if (choice == null || choice.profileId != owner.profileId) return null;
    } else if (preferenceId != targetId) {
      return null;
    }
    return _resolve(owner, selected, targetId);
  }

  static Server? _resolve(IDbClient owner, Server selected, String choiceId) {
    final sourceProfile = owner.profileId;
    if (selected.profileId != sourceProfile) return null;
    final choice = _decodeChoice(sourceProfile, choiceId);
    if (choice == null) return null;
    final destination = choice.profileId == sourceProfile
        ? owner
        : _sharedOwner(owner, choice.profileId);
    if (destination == null) return null;
    final account = destination.getAccount(choice.accountId);
    return account != null &&
            account.profileId == choice.profileId &&
            account.accountId == choice.accountId &&
            _eligible(selected, account)
        ? account
        : null;
  }

  static IDbClient? _sharedOwner(IDbClient source, String profileId) {
    try {
      final destination = source.forProfile(profileId);
      return destination.profileId == profileId && sharingEnabled(destination)
          ? destination
          : null;
    } on StateError {
      return null;
    } on UnsupportedError {
      return null;
    }
  }

  static String _encodeChoice(String profileId, String accountId) =>
      '$_routePrefix${base64Url.encode(utf8.encode(jsonEncode([
            profileId,
            accountId
          ])))}';

  static ({String profileId, String accountId})? _decodeChoice(
      String sourceProfile, String value) {
    if (!value.startsWith(_routePrefix)) {
      return (profileId: sourceProfile, accountId: value);
    }
    if (value.length > 16384) return null;
    try {
      final json = jsonDecode(
          utf8.decode(base64Url.decode(value.substring(_routePrefix.length))));
      if (json case [final String profileId, final String accountId]
          when profileId.isNotEmpty &&
              accountId.isNotEmpty &&
              _encodeChoice(profileId, accountId) == value) {
        return (profileId: profileId, accountId: accountId);
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  static bool _eligible(Server selected, Server candidate) {
    final current = _origin(selected);
    final alternate = _origin(candidate);
    return (candidate.profileId != selected.profileId ||
            candidate.accountId != selected.accountId) &&
        current != null &&
        alternate != null &&
        current != alternate;
  }

  static String? _origin(Server server) {
    final uri = Uri.tryParse(server.url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        isOfficialYoutubeUrl(uri)) {
      return null;
    }
    return uri.origin;
  }
}
