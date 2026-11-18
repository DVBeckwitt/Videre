import 'package:flutter/foundation.dart';

import '../../settings/models/db/settings.dart';
import 'music_provider_consent.dart';

final _consent = MusicProviderConsent(musicCommunityCoverSettingName);

ValueListenable<int> get communityCoverArtPreferenceRevision =>
    _consent.revision;

bool isCommunityCoverArtEnabled() => _consent.enabled;

Future<void> setCommunityCoverArtEnabled(bool enabled,
        {String? expectedProfileId}) =>
    _consent.setEnabled(enabled, expectedProfileId: expectedProfileId);
