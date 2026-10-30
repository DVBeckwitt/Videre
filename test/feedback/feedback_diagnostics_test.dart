import 'dart:convert';

import 'package:clipious/feedback/services/feedback_diagnostics.dart';
import 'package:clipious/globals.dart' as globals;
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/player/models/backend_recovery.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  test('diagnostics admit only the documented primitive fields', () {
    final result = sanitizeFeedbackDiagnostics({
      'appVersion': '1.22.30-test.7',
      'buildNumber': '60883',
      'androidVersion': '16',
      'deviceModel': 'Pixel 8',
      'playerType': 'audio',
      'proxyEnabled': true,
      'recoveryPhase': 'failed',
      'alternativeCount': 2,
      'manualSelection': false,
      'cookie': 'SID=private',
      'authorization': 'Bearer private',
      'serverUrl': 'https://private.example',
      'backendLabel': 'private backend',
      'proxyHost': 'private.proxy',
      'videoId': 'privatevideo',
      'deviceId': 'unique-device-id',
      'logs': ['private message'],
      'error': 'https://media.example/signed?token=private',
    });
    expect(result, {
      'appVersion': '1.22.30-test.7',
      'buildNumber': '60883',
      'androidVersion': '16',
      'deviceModel': 'Pixel 8',
      'playerType': 'audio',
      'proxyEnabled': true,
      'recoveryPhase': 'failed',
      'alternativeCount': 2,
      'manualSelection': false,
    });
    expect(jsonEncode(result), isNot(contains('private')));
    expect(() => result['cookie'] = 'private', throwsUnsupportedError);
  });

  test('diagnostics discard malformed, oversized and sensitive-shaped values',
      () {
    expect(
      sanitizeFeedbackDiagnostics({
        'appVersion': List.filled(65, 'a').join(),
        'buildNumber': 60883,
        'androidVersion': '16\nSID=private',
        'deviceModel': 'https://private.example',
        'playerType': 'https://private.example',
        'proxyEnabled': 'true',
        'recoveryPhase': {'cookie': 'private'},
        'alternativeCount': 3,
        'manualSelection': 1,
      }),
      isEmpty,
    );
    expect(sanitizeFeedbackDiagnostics({'deviceModel': 'name@example.com'}),
        isEmpty);
    expect(
        sanitizeFeedbackDiagnostics(
            {'buildNumber': List.filled(65, '1').join()}),
        isEmpty);
    expect(
        sanitizeFeedbackDiagnostics(
            {'deviceModel': List.filled(121, 'a').join()}),
        isEmpty);
    expect(sanitizeFeedbackDiagnostics({'alternativeCount': -1}), isEmpty);
    expect(sanitizeFeedbackDiagnostics({'alternativeCount': 1.0}), isEmpty);
    expect(sanitizeFeedbackDiagnostics({'deviceModel': '  Pixel 8  '}),
        {'deviceModel': 'Pixel 8'});
  });

  test('recovery summary cannot expose the request credentials or video', () {
    final selector = BackendSelector(
      'COMPANION_ID',
      const [
        BackendOption('a', 'private backend A'),
        BackendOption('b', 'private backend B'),
      ],
      automaticFallback: true,
    );
    final server = selector.withSelection(
        Server(
            url: 'https://private.example',
            backendSelector: selector,
            customHeaders: {'Cookie': 'SID=private'}),
        'a');
    final request = BackendPlayback(server).next()!;
    final player = PlayerState.init(null).copyWith(
      currentlyPlaying: Video(videoId: 'privatevideo'),
      isAudio: true,
      requestedBackend: request,
      backendRecovery: BackendRecovery(
        phase: BackendRecoveryPhase.failed,
        request: request,
        videoId: 'privatevideo',
        manual: false,
      ),
    );
    final result = buildFeedbackDiagnostics(
        appVersion: '1.22.30', proxyEnabled: true, player: player);
    expect(result, {
      'appVersion': '1.22.30',
      'proxyEnabled': true,
      'playerType': 'audio',
      'recoveryPhase': 'failed',
      'alternativeCount': 1,
      'manualSelection': false,
    });
    expect(jsonEncode(result), isNot(contains('private')));
    expect(jsonEncode(result), isNot(contains('SID')));
  });

  test('idle state does not invent recovery information', () {
    final result = buildFeedbackDiagnostics(
        proxyEnabled: false, player: PlayerState.init(null));
    expect(result, {'proxyEnabled': false, 'playerType': 'none'});
  });

  test('collector selects device fields instead of exporting its raw map',
      () async {
    final before = globals.packageInfo;
    addTearDown(() => globals.packageInfo = before);
    globals.packageInfo = PackageInfo(
        appName: 'Videre',
        packageName: 'com.github.dvbeckwitt.videre',
        version: '1.22.30',
        buildNumber: '60883');
    final result = await collectFeedbackDiagnostics(
        deviceDetails: () async => {
              'androidVersion': '16',
              'deviceModel': 'Pixel 8',
              'fingerprint': 'private fingerprint',
              'serialNumber': 'private serial',
              'cookie': 'SID=private',
            });
    expect(result['appVersion'], '1.22.30');
    expect(result['buildNumber'], '60883');
    expect(result['androidVersion'], '16');
    expect(result['deviceModel'], 'Pixel 8');
    expect(jsonEncode(result), isNot(contains('private')));
  });

  test('missing device metadata remains optional and omits exception text',
      () async {
    final result = await collectFeedbackDiagnostics(deviceDetails: () async {
      throw StateError('private device metadata');
    });
    expect(result.containsKey('androidVersion'), isFalse);
    expect(result.containsKey('deviceModel'), isFalse);
    expect(jsonEncode(result), isNot(contains('private')));
  });
}
