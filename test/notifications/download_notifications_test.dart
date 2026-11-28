import 'dart:async';

import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/download_notifications.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/notifications/notifications.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _job = DownloadedVideo(
    videoId: 'a-fresh-song',
    notificationTicket: '12345678-1234-4abc-8def-123456789abc',
    title: 'An online song',
    audioOnly: true,
    lengthSeconds: 120,
    quality: 'BEST');

const _target = (
  profileId: 'default',
  videoId: 'a-fresh-song',
  ticket: '12345678-1234-4abc-8def-123456789abc',
);

const _otherTicket = '22345678-1234-4abc-8def-123456789abc';

DownloadManagerState _state(DownloadedVideo job,
        {int? count, int? bytesPerSecond, bool paused = false}) =>
    DownloadManagerState(
      videos: [job],
      pausedVideoIds: paused ? {job.videoId} : const {},
      downloadProgresses: {
        if (count != null)
          job.videoId:
              DownloadProgress(CancelToken(), bytesPerSecond: bytesPerSecond)
                ..count = count
                ..total = 1000,
      },
    );

ReceivedAction _action(
        {int? id,
        String button = downloadNotificationRetryKey,
        Map<String, String> payload = _retryPayload}) =>
    ReceivedAction().fromMap({
      'id': id ?? downloadNotificationId(_target),
      'channelKey': downloadNotificationChannelKey,
      'buttonKeyPressed': button,
      'payload': payload,
    });

const _retryPayload = {
  'profileId': 'default',
  'videoId': 'a-fresh-song',
  'ticket': '12345678-1234-4abc-8def-123456789abc',
};

void main() {
  final published = <DownloadNotificationSnapshot>[];
  final cancelled = <DownloadNotificationTarget>[];
  late DownloadNotifications notifications;
  late Duration now;
  late bool permission;
  late int cleared;
  late Completer<void>? publishBlocked;

  setUp(() {
    published.clear();
    cancelled.clear();
    now = Duration.zero;
    permission = true;
    cleared = 0;
    publishBlocked = null;
    notifications = DownloadNotifications(
      publish: (snapshot) async {
        if (!permission) return false;
        published.add(snapshot);
        await publishBlocked?.future;
        return true;
      },
      cancel: (target) async => cancelled.add(target),
      cancelAll: () async {
        cleared++;
      },
      elapsed: () => now,
    );
  });

  test('reports percent and transfer speed, updates quietly, and completes',
      () async {
    notifications.observe(
        _state(_job, count: 120, bytesPerSecond: 20000), 'default');
    await notifications.idle;
    now = const Duration(milliseconds: 400);
    notifications.observe(
        _state(_job, count: 290, bytesPerSecond: 33000), 'default');
    await notifications.idle;
    expect(published, hasLength(1));
    now = const Duration(seconds: 1);
    notifications.observe(
        _state(_job, count: 290, bytesPerSecond: 33000), 'default');
    await notifications.idle;
    notifications.observe(
        _state(_job.copyWith(downloadComplete: true)), 'default');
    await notifications.idle;

    expect(published.map((item) => item.percent), [12, 29, null]);
    expect(published.map((item) => item.bytesPerSecond), [20000, 33000, null]);
    expect(published.last.status, DownloadNotificationStatus.complete);
    expect(published.map((item) => item.target).toSet(), {_target});

    final locals = lookupAppLocalizations(const Locale('en'));
    final active = downloadNotificationContent(published.first, locals);
    expect(active.notificationLayout, NotificationLayout.ProgressBar);
    expect(active.progress, 12);
    expect(active.body, contains('20 KB/s'));
    expect(active.payload, isNull);
    expect(downloadNotificationContent(published.last, locals).id, active.id);
    expect(downloadNotificationActions(published.last, locals), isEmpty);
  });

  test('shows failures once and cancels when retry becomes pending', () async {
    notifications.observe(_state(_job), 'default');
    final failed = _state(_job.copyWith(downloadFailed: true));
    notifications.observe(failed, 'default');
    await notifications.idle;
    notifications.observe(failed, 'default');
    await notifications.idle;
    final locals = lookupAppLocalizations(const Locale('en'));
    final notice = downloadNotificationContent(published.single, locals);
    expect(notice.body, 'Download failed');
    expect(notice.payload, _retryPayload);
    expect(downloadNotificationActions(published.single, locals).single.key,
        downloadNotificationRetryKey);

    notifications.observe(_state(_job), 'default');
    await notifications.idle;
    expect(cancelled, [_target]);
  });

  test('does not report old results, automatic jobs, or other profiles',
      () async {
    notifications.observe(
        _state(_job.copyWith(downloadComplete: true)), 'default');
    notifications.observe(
        _state(_job.copyWith(notificationTicket: null), count: 300), 'default');
    notifications.observe(_state(_job, count: 100), 'another-owner');
    await notifications.idle;
    expect(published, isEmpty);
  });

  test('can show a fast result when first-download permission is granted',
      () async {
    permission = false;
    notifications.observe(_state(_job), 'default');
    notifications.observe(
        _state(_job.copyWith(downloadComplete: true)), 'default');
    await notifications.idle;
    expect(published, isEmpty);
    permission = true;
    await notifications.showLatest();
    expect(published.single.status, DownloadNotificationStatus.complete);
  });

  test('retires a notification left by a previous app process', () async {
    notifications.observe(
        _state(_job.copyWith(downloadFailed: true)), 'default');
    await notifications.idle;
    expect(published, isEmpty);

    notifications.observe(const DownloadManagerState(), 'default');
    await notifications.idle;
    expect(cancelled, [_target]);
  });

  test('pausing and removing the exact job retire its notification', () async {
    notifications.observe(_state(_job, count: 50), 'default');
    await notifications.idle;
    notifications.observe(_state(_job, count: 50, paused: true), 'default');
    await notifications.idle;
    expect(cancelled, [_target]);

    notifications.observe(_state(_job, count: 100), 'default');
    await notifications.idle;
    notifications.observe(const DownloadManagerState(), 'default');
    await notifications.idle;
    expect(cancelled, [_target, _target]);
  });

  test('clears in-flight delivery and drops old updates on profile switch',
      () async {
    publishBlocked = Completer<void>();
    notifications.observe(_state(_job, count: 200), 'default');
    await Future<void>.delayed(Duration.zero);
    expect(published, hasLength(1));

    notifications.observe(
        _state(_job.copyWith(downloadFailed: true)), 'default');
    final clearedFuture = notifications.clear();
    expect(cleared, 0);
    publishBlocked!.complete();
    await clearedFuture;
    expect(cleared, 1);
    expect(published, hasLength(1));
  });

  test('routes only the exact validated Retry button and payload', () async {
    final received = <DownloadNotificationTarget>[];
    final oldRetry = NotificationController.onDownloadRetry;
    final oldCanHandle = NotificationController.canHandleActions;
    addTearDown(() {
      NotificationController.onDownloadRetry = oldRetry;
      NotificationController.canHandleActions = oldCanHandle;
    });
    NotificationController.onDownloadRetry =
        (profileId, videoId, ticket) async {
      received.add((profileId: profileId, videoId: videoId, ticket: ticket));
    };

    for (final action in [
      _action(button: ''),
      _action(id: 10),
      _action(payload: {..._retryPayload, 'ticket': 'bad-token'}),
      _action(payload: {..._retryPayload, 'ticket': _otherTicket}),
    ]) {
      await NotificationController.onActionReceivedMethod(action);
    }
    NotificationController.canHandleActions = () => false;
    await NotificationController.onActionReceivedMethod(_action());
    expect(received, isEmpty);
    NotificationController.canHandleActions = () => true;
    await NotificationController.onActionReceivedMethod(_action());
    expect(received, [_target]);
  });
}
