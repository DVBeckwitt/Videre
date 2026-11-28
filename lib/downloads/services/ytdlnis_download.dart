import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../videos/models/video.dart';

enum YtdlnisOpenResult { opened, unavailable, failed }

abstract final class YtdlnisDownload {
  static const _channel = MethodChannel('videre/ytdlnis_download');
  static final _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool canOpen(Video video) =>
      _supported &&
      !video.downloadPlaybackOnly &&
      video.explicitMusicDownload == null &&
      !video.hasRestrictedDownloadVisibility &&
      _videoId.stringMatch(video.videoId) == video.videoId;

  static Future<YtdlnisOpenResult> open(Video video,
      {required bool audioOnly}) async {
    if (!canOpen(video)) return YtdlnisOpenResult.unavailable;
    try {
      final result = await _channel.invokeMethod<String>('open', {
        'videoId': video.videoId,
        'audioOnly': audioOnly,
      });
      return switch (result) {
        'opened' => YtdlnisOpenResult.opened,
        'unavailable' => YtdlnisOpenResult.unavailable,
        _ => YtdlnisOpenResult.failed,
      };
    } on MissingPluginException {
      return YtdlnisOpenResult.unavailable;
    } on PlatformException {
      return YtdlnisOpenResult.failed;
    }
  }
}
