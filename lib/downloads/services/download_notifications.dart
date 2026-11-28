import 'dart:async';

import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/utils/pretty_bytes.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';

const downloadNotificationChannelKey = 'music-downloads';
const downloadNotificationRetryKey = 'retry-music-download';
const downloadNotificationIdSpace = 0x40000000;

typedef DownloadNotificationTarget = ({
  String profileId,
  String videoId,
  String ticket,
});

enum DownloadNotificationStatus {
  downloading,
  complete,
  failed,
  signInRequired,
  storageFailed,
}

typedef DownloadNotificationSnapshot = ({
  DownloadNotificationTarget target,
  String title,
  DownloadNotificationStatus status,
  int? percent,
  int? bytesPerSecond,
});

bool _validTarget(DownloadNotificationTarget target) =>
    DownloadedVideo.isSafeFileId(target.profileId) &&
    DownloadedVideo.isSafeFileId(target.videoId) &&
    _uuidV4.stringMatch(target.ticket) == target.ticket;

final _uuidV4 = RegExp(
    r'[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}');

int downloadNotificationId(DownloadNotificationTarget target) {
  final hash = sha256
      .convert(
          '${target.profileId}/${target.videoId}/${target.ticket}'.codeUnits)
      .bytes;
  return downloadNotificationIdSpace |
      ((hash[0] & 0x3f) << 24) |
      (hash[1] << 16) |
      (hash[2] << 8) |
      hash[3];
}

Map<String, String> _retryPayload(DownloadNotificationTarget target) => {
      'profileId': target.profileId,
      'videoId': target.videoId,
      'ticket': target.ticket,
    };

DownloadNotificationTarget? downloadNotificationRetryTarget(
    ReceivedAction action) {
  if (action.channelKey != downloadNotificationChannelKey ||
      action.buttonKeyPressed != downloadNotificationRetryKey) {
    return null;
  }
  final profileId = action.payload?['profileId'];
  final videoId = action.payload?['videoId'];
  final ticket = action.payload?['ticket'];
  if (profileId == null || videoId == null || ticket == null) return null;
  final target = (profileId: profileId, videoId: videoId, ticket: ticket);
  return _validTarget(target) && action.id == downloadNotificationId(target)
      ? target
      : null;
}

class _JobNotification {
  _JobNotification({required this.existingResult});

  bool existingResult;
  DownloadNotificationSnapshot? desired;
  DownloadNotificationSnapshot? delivered;
  Duration? lastProgressUpdate;
}

/// Watches only explicitly queued Music jobs. Playback and download state never
/// depend on Android notification permission or a successful plugin call.
class DownloadNotifications {
  DownloadNotifications({
    required Future<bool> Function(DownloadNotificationSnapshot) publish,
    required Future<void> Function(DownloadNotificationTarget) cancel,
    required Future<void> Function() cancelAll,
    Duration Function()? elapsed,
  })  : _publish = publish,
        _cancel = cancel,
        _cancelAll = cancelAll,
        _elapsed = elapsed;

  factory DownloadNotifications.android(AppLocalizations Function() locale) {
    final android = AwesomeNotifications();
    final observer = DownloadNotifications(
      publish: (snapshot) async {
        if (!await android.isNotificationAllowed()) return false;
        final locals = locale();
        return android.createNotification(
          content: downloadNotificationContent(snapshot, locals),
          actionButtons: downloadNotificationActions(snapshot, locals),
        );
      },
      cancel: (target) => android.cancel(downloadNotificationId(target)),
      cancelAll: () => android
          .cancelNotificationsByChannelKey(downloadNotificationChannelKey),
    );
    _androidObserver = observer;
    return observer;
  }

  final Future<bool> Function(DownloadNotificationSnapshot) _publish;
  final Future<void> Function(DownloadNotificationTarget) _cancel;
  final Future<void> Function() _cancelAll;
  final Duration Function()? _elapsed;
  final Stopwatch _clock = Stopwatch()..start();
  final _jobs = <DownloadNotificationTarget, _JobNotification>{};
  Future<void> _pending = Future<void>.value();
  int _generation = 0;

  static final _log = Logger('DownloadNotifications');
  static DownloadNotifications? _androidObserver;
  static bool _permissionRequested = false;

  /// Called by the UI after it successfully submits a Music download.
  static Future<void> requestPermissionForExplicitDownload() async {
    final observer = _androidObserver;
    if (observer == null || _permissionRequested) return;
    _permissionRequested = true;
    try {
      final android = AwesomeNotifications();
      if (await android.isNotificationAllowed() ||
          await android.requestPermissionToSendNotifications(
              permissions: const [NotificationPermission.Alert])) {
        await observer.showLatest();
      }
    } catch (error) {
      _log.fine(
          'Could not enable download notifications (${error.runtimeType})');
    }
  }

  void observe(DownloadManagerState state, String profileId) {
    final seen = <DownloadNotificationTarget>{};
    for (final job in state.videos) {
      final ticket = job.notificationTicket;
      if (ticket == null || job.profileId != profileId || !job.audioOnly) {
        continue;
      }
      final target =
          (profileId: profileId, videoId: job.videoId, ticket: ticket);
      if (!_validTarget(target)) continue;
      seen.add(target);
      final progress = state.downloadProgresses[job.videoId];
      final status = _status(job, state, progress);
      final terminal =
          status != null && status != DownloadNotificationStatus.downloading;
      // Retained history is not a new result on startup or profile changes.
      final entry = _jobs.putIfAbsent(
          target, () => _JobNotification(existingResult: terminal));
      if (terminal && entry.existingResult) continue;
      final existingResult = entry.existingResult;
      entry.existingResult = false;
      final previous = entry.desired;
      if (status == null) {
        entry.desired = null;
        entry.lastProgressUpdate = null;
        if (previous != null || existingResult) _cancelWhileIdle(target, entry);
        continue;
      }
      if (terminal) {
        entry.desired = (
          target: target,
          title: job.title,
          status: status,
          percent: null,
          bytesPerSecond: null,
        );
      } else {
        final sample = progress!;
        final fraction = sample.total > 0 ? sample.count / sample.total : 0.0;
        final rate = sample.bytesPerSecond;
        entry.desired = (
          target: target,
          title: job.title,
          status: status,
          percent: (fraction * 100).round().clamp(0, 100).toInt(),
          bytesPerSecond: rate != null && rate > 0 ? rate : null,
        );
        final now = _elapsed?.call() ?? _clock.elapsed;
        final lastUpdate = entry.lastProgressUpdate;
        if (lastUpdate != null &&
            now - lastUpdate < const Duration(seconds: 1)) {
          continue;
        }
        entry.lastProgressUpdate = now;
      }
      if (entry.desired != entry.delivered) _post(target, entry);
    }

    for (final target
        in _jobs.keys.where((key) => !seen.contains(key)).toList()) {
      _jobs.remove(target);
      _enqueue(() => _cancel(target));
    }
  }

  static DownloadNotificationStatus? _status(DownloadedVideo job,
      DownloadManagerState state, DownloadProgress? sample) {
    if (job.downloadComplete) return DownloadNotificationStatus.complete;
    if (job.authenticationRequired) {
      return DownloadNotificationStatus.signInRequired;
    }
    if (job.storageFailed) return DownloadNotificationStatus.storageFailed;
    if (job.downloadFailed) return DownloadNotificationStatus.failed;
    if (sample == null ||
        sample.retryAt != null ||
        state.pausedVideoIds.contains(job.videoId) ||
        state.waitingForSpaceFor(job) ||
        state.waitingForWifiFor(job) ||
        state.waitingForNetworkFor(job)) {
      return null;
    }
    return DownloadNotificationStatus.downloading;
  }

  void _post(DownloadNotificationTarget target, _JobNotification entry) {
    _enqueue(() async {
      final desired = entry.desired;
      if (_jobs[target] != entry ||
          desired == null ||
          desired == entry.delivered) {
        return;
      }
      if (await _publish(desired)) entry.delivered = desired;
    });
  }

  void _cancelWhileIdle(
      DownloadNotificationTarget target, _JobNotification entry) {
    _enqueue(() async {
      if (_jobs[target] != entry || entry.desired != null) return;
      await _cancel(target);
      entry.delivered = null;
    });
  }

  /// Retries the latest notification state after the Android permission dialog.
  Future<void> showLatest() {
    for (final entry in _jobs.entries) {
      if (entry.value.desired != null) _post(entry.key, entry.value);
    }
    return _pending;
  }

  /// Retire queued and already displayed notifications before changing owners.
  Future<void> clear() {
    _generation++;
    _jobs.clear();
    return _enqueue(_cancelAll);
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final generation = _generation;
    _pending = _pending.then((_) async {
      if (generation != _generation) return;
      try {
        await operation();
      } catch (error) {
        _log.fine(
            'Download notification operation failed (${error.runtimeType})');
      }
    });
    return _pending;
  }

  @visibleForTesting
  Future<void> get idle => _pending;
}

NotificationContent downloadNotificationContent(
    DownloadNotificationSnapshot snapshot, AppLocalizations locals) {
  final status = snapshot.status;
  final active = status == DownloadNotificationStatus.downloading;
  final retry = status != DownloadNotificationStatus.complete && !active;
  final percent = snapshot.percent;
  final rate = snapshot.bytesPerSecond;
  final text = switch (status) {
    DownloadNotificationStatus.downloading => [
        locals.downloadNotificationDownloading,
        if (percent != null)
          locals.downloadNotificationProgress(
              NumberFormat.decimalPattern(locals.localeName).format(percent)),
        if (rate != null)
          locals.downloadNotificationRate(prettyBytes(rate.toDouble())),
      ].join(' · '),
    DownloadNotificationStatus.complete => locals.downloadNotificationComplete,
    DownloadNotificationStatus.failed => locals.downloadNotificationFailed,
    DownloadNotificationStatus.signInRequired => locals.downloadSignInRequired,
    DownloadNotificationStatus.storageFailed => locals.downloadFolderError,
  };
  return NotificationContent(
    id: downloadNotificationId(snapshot.target),
    channelKey: downloadNotificationChannelKey,
    title: snapshot.title,
    body: text,
    category: active
        ? NotificationCategory.Progress
        : retry
            ? NotificationCategory.Error
            : NotificationCategory.Status,
    notificationLayout:
        active ? NotificationLayout.ProgressBar : NotificationLayout.Default,
    progress: active ? percent?.toDouble() : null,
    timeoutAfter: active ? const Duration(minutes: 2) : null,
    autoDismissible: !active,
    payload: retry ? _retryPayload(snapshot.target) : null,
  );
}

List<NotificationActionButton> downloadNotificationActions(
        DownloadNotificationSnapshot snapshot, AppLocalizations locals) =>
    switch (snapshot.status) {
      DownloadNotificationStatus.failed ||
      DownloadNotificationStatus.signInRequired ||
      DownloadNotificationStatus.storageFailed =>
        [
          NotificationActionButton(
              key: downloadNotificationRetryKey, label: locals.retry),
        ],
      _ => const [],
    };
