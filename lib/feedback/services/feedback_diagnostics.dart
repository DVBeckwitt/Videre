import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import '../../globals.dart' as globals;
import '../../network/network_proxy.dart';
import '../../player/states/player.dart';

const _textFields = {
  'appVersion': 64,
  'buildNumber': 64,
  'androidVersion': 120,
  'deviceModel': 120,
};
const _playerTypes = {'none', 'audio', 'video', 'tv'};
const _recoveryPhases = {'trying', 'ready', 'succeeded', 'failed'};

/// A field allowlist, not a best-effort scrub of logs or settings. In particular,
/// a playback request contains credentials and must never be serialized here.
Map<String, Object> sanitizeFeedbackDiagnostics(Map<String, Object?> input) {
  final result = <String, Object>{};
  for (final key in _textFields.keys) {
    final value = input[key];
    if (value is! String) continue;
    final text = value.trim();
    if (text.isEmpty ||
        text.length > _textFields[key]! ||
        RegExp(r'[\x00-\x1f\x7f@]').hasMatch(text) ||
        text.contains('://')) {
      continue;
    }
    result[key] = text;
  }
  final playerType = input['playerType'];
  if (playerType is String && _playerTypes.contains(playerType)) {
    result['playerType'] = playerType;
  }
  final recoveryPhase = input['recoveryPhase'];
  if (recoveryPhase is String && _recoveryPhases.contains(recoveryPhase)) {
    result['recoveryPhase'] = recoveryPhase;
  }
  final alternativeCount = input['alternativeCount'];
  if (alternativeCount is int &&
      alternativeCount >= 0 &&
      alternativeCount <= 2) {
    result['alternativeCount'] = alternativeCount;
  }
  for (final key in const ['proxyEnabled', 'manualSelection']) {
    final value = input[key];
    if (value is bool) result[key] = value;
  }
  return Map.unmodifiable(result);
}

/// Builds a small, inspectable diagnostic summary without raw errors, URLs,
/// backend names, video identifiers, proxy addresses, cookies or log messages.
Map<String, Object> buildFeedbackDiagnostics({
  String? appVersion,
  String? buildNumber,
  String? androidVersion,
  String? deviceModel,
  required bool proxyEnabled,
  PlayerState? player,
}) {
  final recovery = player?.backendRecovery;
  return sanitizeFeedbackDiagnostics({
    'appVersion': appVersion,
    'buildNumber': buildNumber,
    'androidVersion': androidVersion,
    'deviceModel': deviceModel,
    'proxyEnabled': proxyEnabled,
    'playerType': player?.hasVideo == true
        ? (player!.isAudio ? 'audio' : 'video')
        : 'none',
    if (recovery != null) ...{
      'recoveryPhase': recovery.phase.name,
      'alternativeCount': recovery.alternativeIndex,
      'manualSelection': recovery.manual,
    },
  });
}

/// Called only after the user opts in. The UI shows the resulting map before
/// submission. No device identifier, Android fingerprint or raw plugin map is
/// retained. Optional device metadata being unavailable does not block a report.
Future<Map<String, Object>> collectFeedbackDiagnostics({
  PlayerState? player,
  Future<Map<String, Object?>> Function()? deviceDetails,
}) async {
  String? androidVersion;
  String? deviceModel;
  try {
    if (deviceDetails != null) {
      final details = await deviceDetails().timeout(const Duration(seconds: 3));
      if (details['androidVersion'] case final String version) {
        androidVersion = version;
      }
      if (details['deviceModel'] case final String model) deviceModel = model;
    } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final details = await DeviceInfoPlugin()
          .androidInfo
          .timeout(const Duration(seconds: 3));
      androidVersion = details.version.release;
      deviceModel = details.model;
    }
  } catch (_) {
    // Device metadata is optional. Avoid logging plugin exceptions, which may
    // contain identifying properties supplied by the platform.
  }
  return buildFeedbackDiagnostics(
    appVersion: globals.packageInfo?.version,
    buildNumber: globals.packageInfo?.buildNumber,
    androidVersion: androidVersion,
    deviceModel: deviceModel,
    proxyEnabled: NetworkProxy.instance.config.enabled,
    player: player,
  );
}
