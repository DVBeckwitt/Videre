import 'package:flutter/foundation.dart';

import 'music_provider_consent.dart';

final _consent = MusicProviderConsent('music-lrclib-enabled');

ValueListenable<int> get lrclibPreferenceRevision => _consent.revision;

bool isLrclibEnabled() => _consent.enabled;

Future<void> setLrclibEnabled(bool enabled, {String? expectedProfileId}) =>
    _consent.setEnabled(enabled, expectedProfileId: expectedProfileId);
