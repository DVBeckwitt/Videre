import 'dart:async';

import 'package:flutter/foundation.dart';

import '../settings/models/db/settings.dart';
import '../utils/interfaces/db.dart';

/// Invalidates a recommendation shelf after a follow change is committed.
final recommendationSubscriptionRevision = ValueNotifier<int>(0);

const subscriptionRecommendationCacheSetting =
    'recommendation-subscription-cache-v1';

final _pendingWrites = <String, Set<Future<void>>>{};

Future<void> writeSubscriptionRecommendationCache(
    IDbClient database, String value) async {
  final profile = database.profileId;
  final writes = _pendingWrites.putIfAbsent(profile, () => {});
  final complete = Completer<void>();
  writes.add(complete.future);
  try {
    await database.saveSetting(
        SettingsValue(subscriptionRecommendationCacheSetting, value));
  } finally {
    writes.remove(complete.future);
    if (writes.isEmpty) _pendingWrites.remove(profile);
    complete.complete();
  }
}

Future<void> invalidateStoredSubscriptionRecommendations(
    IDbClient database) async {
  final profile = database.profileId;
  // Revoke older reads before yielding. Drain writes that were admitted before
  // revocation so a slow settings store cannot resurrect their snapshots.
  final pending = _pendingWrites[profile]?.toList() ?? const <Future<void>>[];
  recommendationSubscriptionRevision.value++;
  try {
    await Future.wait(pending);
    await database.deleteSetting(subscriptionRecommendationCacheSetting);
  } on Object {
    // A completed follow or account operation remains authoritative.
  }
}
