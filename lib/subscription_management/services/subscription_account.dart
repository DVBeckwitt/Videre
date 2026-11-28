import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../globals.dart' show fileDb;
import '../../recommendations/subscription_revision.dart';
import '../../settings/models/db/server.dart';
import '../../settings/models/db/settings.dart';
import '../../settings/models/errors/no_server_selected.dart';
import '../../utils/interfaces/db.dart';
import '../../videos/services/watch_history.dart';

/// The account used for subscriptions, scoped to one Videre profile.
abstract final class SubscriptionAccount {
  static final revision = ValueNotifier<int>(0);

  /// Null follows the playback account. A saved ID remains explicit even if
  /// the account was removed or signed out.
  static Future<String?> preference(IDbClient owner) async =>
      owner.getSettings(subscriptionAccountSetting)?.value;

  static Future<List<Server>> choices(IDbClient owner) async => (await owner
          .getServers())
      .where((account) =>
          account.profileId == owner.profileId && hasHistoryAccount(account))
      .toList();

  static Future<Server?> resolve(IDbClient owner) async {
    final id = await preference(owner);
    final Server? account;
    try {
      account = id == null
          ? await owner.getCurrentlySelectedServer()
          : owner.getAccount(id);
    } on NoServerSelected {
      return null;
    }
    return account != null &&
            account.profileId == owner.profileId &&
            hasHistoryAccount(account)
        ? account
        : null;
  }

  static Future<void> save(IDbClient owner, String? accountId) async {
    final database = owner.forProfile(owner.profileId);
    if (accountId != null) {
      final account = database.getAccount(accountId);
      if (account == null || !hasHistoryAccount(account)) {
        throw StateError('The subscription account is no longer signed in.');
      }
    }
    if (accountId == await preference(database)) return;
    Future<void> persist() => accountId == null
        ? database.deleteSetting(subscriptionAccountSetting)
        : database
            .saveSetting(SettingsValue(subscriptionAccountSetting, accountId));
    // The background worker only has a playback-account mirror. Keep its
    // conservative source check synchronized with the foreground setting.
    if (Platform.isAndroid) {
      await fileDb
          .forProfile(database.profileId)
          .setSubscriptionNotificationAccountId(accountId, commit: persist);
    } else {
      await persist();
    }
    revision.value++;
    await invalidateStoredSubscriptionRecommendations(database);
  }
}
