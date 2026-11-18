import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Batched, local recommendation calculations. The caller owns durable state.
class VidereRecommendations {
  static const MethodChannel _channel = MethodChannel('videre/recommendations');
  static bool _licensesRegistered = false;

  static void registerLicenses() {
    if (_licensesRegistered) return;
    _licensesRegistered = true;
    LicenseRegistry.addLicense(() async* {
      final notice = await rootBundle.loadString(
        'packages/videre_recommendations/assets/NOTICE.txt',
      );
      yield LicenseEntryWithLineBreaks(
        ['Flow Android Client and recommendation data contributors'],
        notice,
      );
    });
  }

  static Future<Map<String, dynamic>> evaluate(
    Map<String, Object?> request,
  ) async {
    registerLicenses();
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'evaluate',
      request,
    );
    if (result == null) {
      throw StateError('The recommendation engine returned no result.');
    }
    return result;
  }
}
