import 'package:flutter/foundation.dart';

import '../../globals.dart';
import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';

/// A profile's opt-in authorizes requests only after the enabling write commits.
/// An opt-out also blocks any queued request while its write is pending.
class MusicProviderConsent {
  final String setting;
  final _revision = ValueNotifier(0);
  final _revoking = <(IDbClient, String), int>{};

  MusicProviderConsent(this.setting);

  ValueListenable<int> get revision => _revision;

  bool get enabled {
    final database = db;
    return !_revoking.containsKey((database, database.profileId)) &&
        database.getSettings(setting)?.value == 'true';
  }

  Future<void> setEnabled(bool value, {String? expectedProfileId}) async {
    final database = db;
    final profile = database.profileId;
    if (expectedProfileId != null && expectedProfileId != profile) return;
    final owner = database.forProfile(profile);
    final scope = (database, profile);
    bool isActive() => identical(db, database) && database.profileId == profile;
    if (!value) {
      _revoking.update(scope, (count) => count + 1, ifAbsent: () => 1);
      _revision.value++;
    }
    try {
      await owner.saveSetting(SettingsValue(setting, value.toString()));
      if (value && isActive()) _revision.value++;
    } finally {
      if (!value) {
        final remaining = _revoking[scope]! - 1;
        if (remaining == 0) {
          _revoking.remove(scope);
        } else {
          _revoking[scope] = remaining;
        }
        // If saving failed, restore the effective state of the persisted choice.
        if (isActive() && enabled) _revision.value++;
      }
    }
  }
}
