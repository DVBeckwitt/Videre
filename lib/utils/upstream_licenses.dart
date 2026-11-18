import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool _registered = false;

/// Licenses for the source-derived Flow and Muzza UI ports. Recommendation
/// algorithm/data notices are registered separately by videre_recommendations.
void registerUpstreamUiLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    final notice =
        await rootBundle.loadString('assets/licenses/upstream-ui.txt');
    final license = await rootBundle.loadString('assets/licenses/GPL-3.0.txt');
    yield LicenseEntryWithLineBreaks(
      ['Flow and Muzza UI source ports'],
      '$notice\n\n$license',
    );
  });
}
