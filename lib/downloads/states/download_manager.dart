import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:dio/dio.dart';
import 'package:downloadsfolder/downloadsfolder.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:flutter/services.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../../player/states/player.dart';
import '../../videos/models/adaptive_format.dart';
import 'resumable_download.dart';

part 'download_manager.freezed.dart';

final Logger log = Logger('DownloadState');
const _wifiSetting = 'downloads-wifi-only';
const _pausedSetting = 'downloads-paused';

class DownloadProgress {
  final CancelToken cancelToken;
  int count = 0, total = 1;

  DownloadProgress(this.cancelToken);
}

class DownloadManagerCubit extends Cubit<DownloadManagerState> {
  final PlayerCubit player;
  late final Future<void> _ready;
  StreamSubscription<dynamic>? _networkSubscription;
  final Set<String> _deleting = {};
  final Set<String> _enqueuing = {};
  bool _processing = false, _wifiConnected = false, _closing = false;
  String? _activeId;
  Future<void>? _activeJob;

  DownloadManagerCubit(super.initialState, this.player) {
    _ready = onReady();
  }

  Future<void> onReady() async {
    Set<String> paused = {};
    try {
      final saved = jsonDecode(db.getSettings(_pausedSetting)?.value ?? '[]');
      if (saved is List) paused = saved.whereType<String>().toSet();
    } on FormatException {
      // An interrupted settings import should not block the download library.
    }
    emit(state.copyWith(
        wifiOnly: db.getSettings(_wifiSetting)?.value == 'true',
        pausedVideoIds: paused,
        videos: db.getAllDownloads()));
    if (Platform.isAndroid) {
      _networkSubscription = const EventChannel('videre/network_changes')
          .receiveBroadcastStream()
          .listen((value) => _networkChanged(value == true),
              onError: (Object error) => _networkChanged(false));
      try {
        _wifiConnected = await const MethodChannel('videre/network')
                .invokeMethod<bool>('isWifiConnected') ??
            false;
      } on PlatformException {
        _wifiConnected = false;
      } on MissingPluginException {
        _wifiConnected = false;
      }
    }
    _networkChanged(_wifiConnected);
  }

  bool get _networkAllowed => !state.wifiOnly || _wifiConnected;

  void _networkChanged(bool connected) {
    if (_closing) return;
    _wifiConnected = connected;
    emit(state.copyWith(waitingForWifi: !_networkAllowed));
    if (!_networkAllowed) {
      for (final progress in state.downloadProgresses.values) {
        progress.cancelToken.cancel();
      }
    } else {
      unawaited(_drain());
    }
  }

  Future<void> setWifiOnly(bool value) async {
    await _ready;
    await db.saveSetting(SettingsValue(_wifiSetting, value.toString()));
    emit(state.copyWith(wifiOnly: value));
    _networkChanged(_wifiConnected);
  }

  void setVideos() {
    if (!_closing) emit(state.copyWith(videos: db.getAllDownloads()));
  }

  Future<bool> addDownload(String videoId,
      {String quality = '720p', bool audioOnly = false}) async {
    await _ready;
    if (db.getDownloadByVideoId(videoId) != null ||
        _deleting.contains(videoId) ||
        !_enqueuing.add(videoId)) {
      return false;
    }
    try {
      await db.upsertDownload(DownloadedVideo(
          videoId: videoId,
          title: videoId,
          lengthSeconds: 0,
          quality: quality,
          audioOnly: audioOnly));
    } finally {
      _enqueuing.remove(videoId);
    }
    setVideos();
    unawaited(_drain());
    return true;
  }

  Future<int> addDownloads(Iterable<String> videoIds,
      {String quality = '720p', bool audioOnly = false}) async {
    var added = 0;
    for (final id in videoIds.toSet()) {
      if (await addDownload(id, quality: quality, audioOnly: audioOnly)) {
        added++;
      }
    }
    return added;
  }

  Future<void> _drain() async {
    if (_processing || _closing || !_networkAllowed) return;
    _processing = true;
    try {
      while (!_closing && _networkAllowed) {
        final next = db
            .getAllDownloads()
            .where((v) =>
                !v.downloadComplete &&
                !v.downloadFailed &&
                !state.pausedVideoIds.contains(v.videoId) &&
                !_deleting.contains(v.videoId))
            .firstOrNull;
        if (next == null) break;
        _activeId = next.videoId;
        _activeJob = _download(next);
        await _activeJob;
        _activeId = null;
        _activeJob = null;
      }
    } finally {
      _processing = false;
    }
  }

  Future<void> _download(DownloadedVideo video) async {
    final token = CancelToken();
    final progress = DownloadProgress(token);
    emit(state.copyWith(downloadProgresses: {video.videoId: progress}));
    final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30)));
    var lastUpdate = DateTime(0);
    void update(int count, int total, int step, int steps) {
      final now = DateTime.now();
      if (token.isCancelled ||
          _closing ||
          (count != total && now.difference(lastUpdate).inMilliseconds < 250)) {
        return;
      }
      lastUpdate = now;
      // Reserve the final step for muxing; a downloaded audio track isn't a video.
      final fraction =
          (step + (total > 0 ? (count / total).clamp(0, 1) : 0)) / steps;
      final next = DownloadProgress(token)
        ..count = (fraction * 1000).round()
        ..total = 1000;
      emit(state.copyWith(downloadProgresses: {video.videoId: next}));
    }

    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          if (token.isCancelled) throw token.cancelError!;
          // Signed media URLs expire. Refresh them before every retry.
          final vid = await service
              .getVideo(video.videoId)
              .timeout(const Duration(seconds: 30));
          if (token.isCancelled) throw token.cancelError!;
          video = video.copyWith(
              title: vid.title ?? video.title,
              author: vid.author,
              authorUrl: vid.authorUrl,
              lengthSeconds: vid.lengthSeconds ?? 0,
              downloadFailed: false);
          await db.upsertDownload(video);
          setVideos();
          final formats = vid.adaptiveFormats ?? <AdaptiveFormat>[];
          final audios = formats
              .where((f) => f.type.contains('audio/webm'))
              .toList()
            ..sort((a, b) => (int.tryParse(b.bitrate ?? '') ?? 0)
                .compareTo(int.tryParse(a.bitrate ?? '') ?? 0));
          int height(String? quality) =>
              int.tryParse(RegExp(r'^\d+').stringMatch(quality ?? '') ?? '') ??
              0;
          final videos = formats
              .where(
                  (f) => f.encoding == 'vp9' && f.type.contains('video/webm'))
              .toList()
            ..sort((a, b) =>
                height(b.qualityLabel).compareTo(height(a.qualityLabel)));
          final selectedVideo = videos
                  .where((f) => f.qualityLabel == video.quality)
                  .firstOrNull ??
              videos
                  .where((f) => height(f.qualityLabel) <= height(video.quality))
                  .firstOrNull ??
              videos.lastOrNull;
          if (audios.isEmpty || (!video.audioOnly && selectedVideo == null)) {
            throw StateError(
                'This video has no downloadable ${video.quality} WebM stream');
          }
          final server = await db.getCurrentlySelectedServer();
          final mediaPath = await video.downloadPath;
          final audioPath = '$mediaPath.audio.part';
          final videoPath = '$mediaPath.video.part';
          final steps = video.audioOnly ? 2 : 3;
          Future<void> transfer(AdaptiveFormat format, String path, int step) {
            final size = int.tryParse(format.clen);
            return downloadResumable(dio, format.url, path,
                cancelToken: token,
                identity: '${format.itag}:${format.clen}:${format.lmt}',
                expectedSize: size != null && size > 0 ? size : null,
                headers: server.headersForUrl(format.url),
                onProgress: (count, total) =>
                    update(count, total, step, steps));
          }

          final thumb = ImageObject.getBestThumbnail(vid.videoThumbnails)?.url;
          if (thumb != null &&
              !await File(await video.thumbnailPath).exists()) {
            try {
              await dio.download(thumb, await video.thumbnailPath,
                  cancelToken: token,
                  options: Options(headers: server.headersForUrl(thumb)));
            } on DioException catch (error) {
              if (CancelToken.isCancel(error)) rethrow;
              log.fine(
                  'Thumbnail unavailable; the media download can continue');
            }
          }
          await transfer(audios.first, audioPath, 0);
          if (!video.audioOnly) await transfer(selectedVideo!, videoPath, 1);
          if (token.isCancelled) throw token.cancelError!;
          final output = '$mediaPath.mux.webm';
          if (video.audioOnly) {
            await File(audioPath).copy(output);
          } else {
            final session = await FFmpegKit.executeWithArguments([
              '-y',
              '-i',
              videoPath,
              '-i',
              audioPath,
              '-c:v',
              'copy',
              '-c:a',
              'copy',
              output
            ]);
            if (!((await session.getReturnCode())?.isValueSuccess() ?? false)) {
              throw StateError(
                  'Could not merge the downloaded audio and video');
            }
          }
          if (token.isCancelled) throw token.cancelError!;
          await File(output).rename(mediaPath);
          await db.upsertDownload(
              video.copyWith(downloadComplete: true, downloadFailed: false));
          setVideos();
          update(1, 1, steps - 1, steps);
          try {
            await _deleteParts(video);
          } on FileSystemException catch (error) {
            log.fine(
                'The completed download has leftover temporary files', error);
          }
          return;
        } catch (error) {
          if (token.isCancelled || _closing) return;
          if (attempt == 2 ||
              error is StateError ||
              error is FileSystemException) rethrow;
          await Future.any([
            Future<void>.delayed(Duration(seconds: 1 << attempt)),
            token.whenCancel
          ]);
        }
      }
    } catch (error, stack) {
      if (!token.isCancelled && !_closing) {
        log.warning(
            'Download failed for ${video.videoId}; partial files are kept',
            error,
            stack);
        await db.upsertDownload(
            video.copyWith(downloadFailed: true, downloadComplete: false));
      }
    } finally {
      dio.close(force: true);
      if (!_closing) {
        emit(state.copyWith(downloadProgresses: {}));
        setVideos();
      }
    }
  }

  Future<void> pauseDownload(DownloadedVideo video) async {
    final paused = {...state.pausedVideoIds, video.videoId};
    emit(state.copyWith(pausedVideoIds: paused));
    state.downloadProgresses[video.videoId]?.cancelToken.cancel();
    await db.saveSetting(
        SettingsValue(_pausedSetting, jsonEncode(paused.toList())));
  }

  Future<void> retryDownload(DownloadedVideo video) async {
    final paused = {...state.pausedVideoIds}..remove(video.videoId);
    emit(state.copyWith(pausedVideoIds: paused));
    await db.saveSetting(
        SettingsValue(_pausedSetting, jsonEncode(paused.toList())));
    await db.upsertDownload(video.copyWith(downloadFailed: false));
    setVideos();
    unawaited(_drain());
  }

  Future<void> _deleteParts(DownloadedVideo video) async {
    final path = await video.downloadPath;
    for (final suffix in [
      '.audio.part',
      '.audio.part.identity',
      '.video.part',
      '.video.part.identity',
      '.mux.webm'
    ]) {
      final file = File('$path$suffix');
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> deleteVideo(DownloadedVideo video) async {
    _deleting.add(video.videoId);
    state.downloadProgresses[video.videoId]?.cancelToken.cancel();
    if (_activeId == video.videoId) await _activeJob;
    await _deleteParts(video);
    for (final path in [await video.effectivePath, await video.thumbnailPath]) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
    await db.deleteDownload(video);
    final paused = {...state.pausedVideoIds}..remove(video.videoId);
    await db.saveSetting(
        SettingsValue(_pausedSetting, jsonEncode(paused.toList())));
    emit(state.copyWith(pausedVideoIds: paused));
    _deleting.remove(video.videoId);
    setVideos();
  }

  bool canPlayAll() =>
      state.videos.any((v) => v.downloadComplete && !v.downloadFailed);
  void playAll() => player.playOfflineVideos(state.videos
      .where((v) => v.downloadComplete && !v.downloadFailed)
      .toList());

  Future<void> copyToDownloadFolder(DownloadedVideo video) async {
    final file = File(await video.effectivePath);
    if (await file.exists()) {
      final name =
          '${video.title.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_').replaceAll(RegExp(r'_{2,}'), '')}_${video.videoId}${p.extension(file.path)}';
      await copyFileIntoDownloadFolder(file.path, name);
    }
  }

  @override
  Future<void> close() async {
    _closing = true;
    for (final progress in state.downloadProgresses.values) {
      progress.cancelToken.cancel();
    }
    await _networkSubscription?.cancel();
    await _activeJob;
    return super.close();
  }
}

@freezed
sealed class DownloadManagerState with _$DownloadManagerState {
  const factory DownloadManagerState({
    @Default([]) List<DownloadedVideo> videos,
    @Default({}) Map<String, DownloadProgress> downloadProgresses,
    @Default({}) Set<String> pausedVideoIds,
    @Default(false) bool wifiOnly,
    @Default(false) bool waitingForWifi,
  }) = _DownloadManagerState;

  const DownloadManagerState._();

  double get totalProgress {
    var downloaded = 0, total = 0;
    for (final progress in downloadProgresses.values) {
      downloaded += progress.count;
      total += progress.total;
    }
    return total == 0 ? 0 : (downloaded / total).clamp(0, 1);
  }
}
