import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bloc/bloc.dart';
import 'package:dio/dio.dart';
import 'package:downloadsfolder/downloadsfolder.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:flutter/services.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/invidious_image.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:clipious/network/network_proxy.dart';

import '../../player/states/player.dart';
import '../../network/gateway_session_bridge.dart';
import '../../network/nerdvpn_access.dart';
import '../../settings/models/errors/invidious_service_error.dart';
import '../../utils/interfaces/db.dart';
import '../../videos/models/adaptive_format.dart';
import '../../videos/models/sponsor_segment.dart';
import '../../videos/models/sponsor_segment_types.dart';
import '../../videos/models/video.dart';
import 'resumable_download.dart';
import '../services/download_storage.dart';

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
  final DownloadStorage storage;
  late final Future<void> _ready;
  late IDbClient _library;
  StreamSubscription<dynamic>? _networkSubscription;
  final Set<Future<void>> _mutations = {};
  final Set<String> _deleting = {};
  final Set<String> _enqueuing = {};
  bool _processing = false, _wifiConnected = false, _closing = false;
  bool _switchingProfile = false;
  int _generation = 0;
  String? _activeId;
  Future<void>? _activeJob;
  Completer<void>? _drainFinished;

  DownloadManagerCubit(super.initialState, this.player,
      {DownloadStorage? storage})
      : storage = storage ?? DownloadStorage() {
    _library = db.forProfile(db.profileId);
    _ready = onReady();
    NetworkProxy.instance.addBeforeApply(_proxyChanging);
  }

  bool get _current => !_closing && _library.profileId == db.profileId;

  Future<T> _mutate<T>(Future<T> Function() action) {
    final result = Future<T>.sync(action);
    final settled =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _mutations.add(settled);
    unawaited(settled.then((_) => _mutations.remove(settled)));
    return result;
  }

  /// Called before changing the active person or account. A cancelled transfer
  /// can finish only in its original library; switching waits for all writers.
  Future<void> pauseForProfileSwitch() async {
    _switchingProfile = true;
    for (final progress in state.downloadProgresses.values) {
      progress.cancelToken.cancel();
    }
    await _ready;
    await Future.wait(List.of(_mutations));
    final paused = {
      ...state.pausedVideoIds,
      for (final video in _library.getAllDownloads())
        if (!video.downloadComplete) video.videoId,
    };
    await _library.saveSetting(
        SettingsValue(_pausedSetting, jsonEncode(paused.toList())));
    if (_current) emit(state.copyWith(pausedVideoIds: paused));
    await _activeJob;
    await _drainFinished?.future;
  }

  /// Called after the profile/account selection has committed. Paused jobs stay
  /// paused until resumed explicitly, and retain the account that created them.
  Future<void> reloadForProfile() async {
    await pauseForProfileSwitch();
    if (_closing) return;
    _generation++;
    _library = db.forProfile(db.profileId);
    _deleting.clear();
    _enqueuing.clear();
    _loadLibrary();
    _switchingProfile = false;
    _networkChanged(_wifiConnected);
  }

  Future<void> _proxyChanging() async {
    final library = _library;
    final generation = _generation;
    // Stop current transfers before yielding, even while another consumer is
    // still disposing. Policy changes close the underlying HTTP connections;
    // these failures must be treated as cancellation rather than retried jobs.
    for (final progress in state.downloadProgresses.values) {
      progress.cancelToken.cancel();
    }
    await _ready;
    if (generation != _generation || _closing) return;
    final paused = {
      ...state.pausedVideoIds,
      for (final video in state.videos)
        if (!video.downloadComplete) video.videoId,
    };
    emit(state.copyWith(pausedVideoIds: paused));
    for (final progress in state.downloadProgresses.values) {
      progress.cancelToken.cancel();
    }
    await library.saveSetting(
        SettingsValue(_pausedSetting, jsonEncode(paused.toList())));
    await _activeJob;
  }

  Future<void> onReady() async {
    _loadLibrary();
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

  void _loadLibrary() {
    Set<String> paused = {};
    DownloadFolder? folder;
    try {
      folder = DownloadFolder.fromJson(jsonDecode(
          _library.getSettings(downloadFolderSetting)?.value ?? 'null'));
    } on FormatException {
      // Invalid local preferences fall back to private storage.
    }
    try {
      final saved =
          jsonDecode(_library.getSettings(_pausedSetting)?.value ?? '[]');
      if (saved is List) paused = saved.whereType<String>().toSet();
    } on FormatException {
      // An interrupted settings import should not block the download library.
    }
    emit(state.copyWith(
        folderUri: folder?.uri,
        folderName: folder?.name,
        wifiOnly: _library.getSettings(_wifiSetting)?.value == 'true',
        pausedVideoIds: paused,
        downloadProgresses: {},
        videos: _library.getAllDownloads()));
  }

  bool get _networkAllowed => !state.wifiOnly || _wifiConnected;

  void _networkChanged(bool connected) {
    if (!_current) return;
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

  Future<void> setWifiOnly(bool value) => _mutate(() async {
        await _ready;
        if (!_current || _switchingProfile) return;
        await _library
            .saveSetting(SettingsValue(_wifiSetting, value.toString()));
        emit(state.copyWith(wifiOnly: value));
        _networkChanged(_wifiConnected);
      });

  Future<void> chooseFolder() async {
    await _ready;
    if (!_current || _switchingProfile) return;
    final generation = _generation;
    final library = _library;
    final folder = await storage.pickFolder(state.folderUri);
    if (folder == null ||
        !_current ||
        _switchingProfile ||
        generation != _generation) {
      return;
    }
    await library.saveSetting(
        SettingsValue(downloadFolderSetting, jsonEncode(folder.toJson())));
    if (_current && generation == _generation) {
      emit(state.copyWith(folderUri: folder.uri, folderName: folder.name));
    }
  }

  Future<void> usePrivateFolder() => _mutate(() async {
        await _ready;
        if (!_current || _switchingProfile) return;
        await _library.deleteSetting(downloadFolderSetting);
        if (_current) emit(state.copyWith(folderUri: null, folderName: null));
      });

  void setVideos() {
    if (_current) emit(state.copyWith(videos: _library.getAllDownloads()));
  }

  Future<bool> addDownload(String videoId,
          {String quality = '720p', bool audioOnly = false, Video? video}) =>
      _mutate(() async {
        await _ready;
        if (!_current ||
            _switchingProfile ||
            (video != null && video.videoId != videoId) ||
            !DownloadedVideo.isSafeFileId(videoId) ||
            _library.getDownloadByVideoId(videoId) != null ||
            _deleting.contains(videoId) ||
            !_enqueuing.add(videoId)) {
          return false;
        }
        try {
          final account = await _library.getCurrentlySelectedServer();
          if (!_current || _switchingProfile) return false;
          await _library.upsertDownload(DownloadedVideo(
              videoId: videoId,
              title: video?.musicMetadata?.title ?? video?.title ?? videoId,
              author: video?.musicMetadata?.artist ?? video?.author,
              authorUrl: video?.authorUrl,
              musicMetadata: video?.musicMetadata,
              profileId: _library.profileId,
              accountId: account.accountId,
              lengthSeconds: video?.lengthSeconds ?? 0,
              quality: quality,
              folderUri: state.folderUri,
              audioOnly: audioOnly));
        } finally {
          _enqueuing.remove(videoId);
        }
        setVideos();
        unawaited(_drain());
        return true;
      });

  Future<int> addDownloads(Iterable<String> videoIds,
      {String quality = '720p',
      bool audioOnly = false,
      Map<String, Video> videosById = const {}}) async {
    var added = 0;
    final generation = _generation;
    for (final id in videoIds.toSet()) {
      if (generation != _generation || _switchingProfile) break;
      if (await addDownload(id,
          quality: quality, audioOnly: audioOnly, video: videosById[id])) {
        added++;
      }
    }
    return added;
  }

  Future<void> _drain() async {
    if (_processing || !_current || _switchingProfile || !_networkAllowed) {
      return;
    }
    _processing = true;
    final finished = _drainFinished = Completer<void>();
    try {
      while (_current && !_switchingProfile && _networkAllowed) {
        final next = _library
            .getAllDownloads()
            .where((v) =>
                !v.downloadComplete &&
                !v.downloadFailed &&
                !v.authenticationRequired &&
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
      finished.complete();
      _drainFinished = null;
    }
  }

  Future<void> _download(DownloadedVideo video) async {
    final library = _library;
    final token = CancelToken();
    final progress = DownloadProgress(token);
    emit(state.copyWith(downloadProgresses: {video.videoId: progress}));
    final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30)));
    Future<List<SponsorSegment>>? sponsorSegments;
    var lastUpdate = DateTime(0);
    void update(int count, int total, int step, int steps) {
      final now = DateTime.now();
      if (token.isCancelled ||
          !_current ||
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
      if (video.profileId != library.profileId) {
        throw StateError('The download belongs to another profile');
      }
      if (video.accountId == null) {
        // Bind old queued records exactly once before their first resumed
        // request. All later retries and restarts resolve this same account.
        final account = await library.getCurrentlySelectedServer();
        if (token.isCancelled) throw token.cancelError!;
        video = video.copyWith(accountId: account.accountId);
        await library.upsertDownload(video);
      }
      if (video.folderUri != null) await storage.checkFolder(video.folderUri!);
      for (var attempt = 0; attempt < 3; attempt++) {
        final artworkToken = CancelToken();
        Future<void>? artwork;
        try {
          if (token.isCancelled) throw token.cancelError!;
          // Signed media URLs expire. Refresh them before every retry.
          final server = library.getAccount(video.accountId!);
          if (server == null || server.profileId != library.profileId) {
            throw StateError('The download account is no longer available');
          }
          if (token.isCancelled) throw token.cancelError!;
          final vid = await Future.any([
            service
                .getVideo(video.videoId, serverOverride: server)
                .timeout(const Duration(seconds: 30)),
            // Metadata requests do not accept a cancellation token. Release
            // pause/delete/proxy changes promptly and ignore any late result.
            token.whenCancel.then((error) => throw error),
          ]);
          if (token.isCancelled) throw token.cancelError!;
          final formats = DownloadFormats(vid.adaptiveFormats);
          // A saved document already has a container. Old jobs saved WebM.
          final savedContainer = video.container ??
              (video.storageUri == null ? null : DownloadContainer.webm);
          final selectedVideo = video.audioOnly
              ? null
              : formats.videoFor(video.quality, container: savedContainer);
          final container = savedContainer ??
              (selectedVideo == null
                  ? formats.audioContainer
                  : DownloadContainer.forVideo(selectedVideo));
          final audio = formats.audioFor(container);
          if (audio == null || (!video.audioOnly && selectedVideo == null)) {
            throw StateError(
                'This video has no compatible tracks for the download');
          }
          final music = video.musicMetadata ?? vid.musicMetadata;
          video = video.copyWith(
              container: container,
              title: music?.title ?? vid.title ?? video.title,
              author: music?.artist ?? vid.author,
              musicMetadata: music,
              authorUrl: vid.authorUrl ?? video.authorUrl,
              lengthSeconds: vid.lengthSeconds ?? video.lengthSeconds,
              downloadFailed: false,
              authenticationRequired: false);
          await library.upsertDownload(video);
          setVideos();
          sponsorSegments ??= _downloadSponsorSegments(video, library, token);
          final mediaPath = await video.downloadPath;
          final staging = await video.stagingPath;
          final audioPath = '$staging.audio.part';
          final videoPath = '$staging.video.part';
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

          final thumb = ImageObject.getBestThumbnail(
                  music?.thumbnails.isNotEmpty == true
                      ? music!.thumbnails
                      : vid.videoThumbnails)
              ?.url;
          if (thumb != null && thumb.isNotEmpty) {
            unawaited(token.whenCancel.then(artworkToken.cancel));
            // Optional artwork must not delay the first media request. Keep it
            // part of this job so pause, delete and proxy changes can join it.
            artwork = _downloadArtwork(dio, video, thumb, server, artworkToken);
          }
          await transfer(audio, audioPath, 0);
          if (!video.audioOnly) await transfer(selectedVideo!, videoPath, 1);
          if (token.isCancelled) throw token.cancelError!;
          final output = '$staging.mux.${video.extension}';
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
          await artwork;
          video = video.copyWith(sponsorSegments: await sponsorSegments);
          if (token.isCancelled) throw token.cancelError!;
          if (video.folderUri == null) {
            await File(output).rename(mediaPath);
          } else {
            final uri = await storage.prepareDocument(video.folderUri!,
                video.storageUri, video.fileName, video.mimeType);
            // Record ownership before writing so retries reuse this document
            // and deletion can clean up an interrupted save after a restart.
            video = video.copyWith(storageUri: uri);
            await library.upsertDownload(video);
            if (token.isCancelled) throw token.cancelError!;
            await storage.writeDocument(output, uri, token);
          }
          await library.upsertDownload(video.copyWith(
              downloadComplete: true,
              downloadFailed: false,
              authenticationRequired: false,
              storageFailed: false));
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
              _accessPauseNeedsSignIn(error) != null ||
              (error is PlatformException &&
                  error.code == 'DOWNLOAD_STORAGE') ||
              error is StateError ||
              error is FileSystemException) {
            rethrow;
          }
          await Future.any([
            Future<void>.delayed(Duration(seconds: 1 << attempt)),
            token.whenCancel
          ]);
        } finally {
          artworkToken.cancel();
          await artwork;
        }
      }
    } catch (error, stack) {
      if (!token.isCancelled && !_closing) {
        final signInRequired = _accessPauseNeedsSignIn(error);
        if (signInRequired != null) {
          final paused = {...state.pausedVideoIds, video.videoId};
          await library.upsertDownload(video.copyWith(
              downloadFailed: false,
              authenticationRequired: signInRequired,
              downloadComplete: false));
          await library.saveSetting(
              SettingsValue(_pausedSetting, jsonEncode(paused.toList())));
          if (_current) emit(state.copyWith(pausedVideoIds: paused));
          return;
        }
        log.warning(
            'Download failed for ${video.videoId}; partial files are kept (${error.runtimeType})',
            null,
            stack);
        await library.upsertDownload(video.copyWith(
            downloadFailed: true,
            downloadComplete: false,
            storageFailed: error is PlatformException &&
                error.code == 'DOWNLOAD_STORAGE'));
      }
    } finally {
      dio.close(force: true);
      if (_current) {
        emit(state.copyWith(downloadProgresses: {}));
        setVideos();
      }
    }
  }

  Future<List<SponsorSegment>> _downloadSponsorSegments(
      DownloadedVideo video, IDbClient library, CancelToken token) async {
    if (video.musicMetadata == null || token.isCancelled) {
      return video.sponsorSegments;
    }
    final categories = SponsorSegmentType.values
        .where((type) =>
            type.isEnabled(library.getSettings(type.settingsName())?.value))
        .toList();
    if (categories.isEmpty) return video.sponsorSegments;
    try {
      final segments = await Future.any([
        service.getSponsorSegments(video.videoId, categories),
        // The service has no cancellation token. A late result never writes to
        // disk, and profile switches/deletion do not wait for this lookup.
        token.whenCancel.then((_) => video.sponsorSegments),
      ]).timeout(const Duration(seconds: 3),
          onTimeout: () => video.sponsorSegments);
      // Keep raw categories/actions/timings so playback can apply the current
      // preferences offline. Non-finite numbers cannot be persisted as JSON.
      final cacheable = segments
          .where((segment) => segment.segment.every((time) => time.isFinite))
          .toList();
      // Service also returns an empty list for transport/HTTP failures, so an
      // optional refresh without usable data must preserve the offline cache.
      return cacheable.isEmpty ? video.sponsorSegments : cacheable;
    } catch (_) {
      return video.sponsorSegments;
    }
  }

  /// Access failures need an explicit resume after account settings recover.
  /// Waiting, disabled access and cooldowns do not require another sign-in.
  static bool? _accessPauseNeedsSignIn(Object error) {
    if (error is DioException && error.error != null) {
      return _accessPauseNeedsSignIn(error.error!);
    }
    if (error is GatewayAuthenticationRequired) return true;
    if (error is NerdVpnAccessRequired) {
      return const {'missing', 'signInRequired'}.contains(error.state);
    }
    if (error is InvidiousServiceError && error.isGatewayAccessFailure) {
      return const {'credentials_required', 'invalid_credentials'}
          .contains(error.errorCode);
    }
    return null;
  }

  Future<void> _downloadArtwork(Dio dio, DownloadedVideo video, String thumb,
      Server server, CancelToken token) async {
    final deadline = Timer(const Duration(seconds: 5),
        () => token.cancel('Artwork download deadline'));
    File? partial;
    try {
      final target = File(await video.thumbnailPath);
      partial = File('${target.path}.part');
      if (token.isCancelled || await target.exists()) return;
      final url = invidiousImageUrl(thumb, server);
      await dio.download(url, partial.path,
          cancelToken: token,
          options: Options(
              headers: server.headersForUrl(url),
              // Covers are optional; do not try to decode an error response
              // whose body may not match its advertised content type.
              receiveDataWhenStatusError: false));
      if (!token.isCancelled) await partial.rename(target.path);
    } on DioException {
      log.fine('Thumbnail unavailable; the media download can continue');
    } on FileSystemException {
      log.fine('Thumbnail could not be saved; the media download can continue');
    } finally {
      deadline.cancel();
      try {
        if (partial != null && await partial.exists()) await partial.delete();
      } on FileSystemException {
        log.fine('The artwork download has a leftover temporary file');
      }
    }
  }

  Future<void> pauseDownload(DownloadedVideo video) => _mutate(() async {
        await _ready;
        if (!_current ||
            _switchingProfile ||
            video.profileId != _library.profileId) {
          return;
        }
        final paused = {...state.pausedVideoIds, video.videoId};
        emit(state.copyWith(pausedVideoIds: paused));
        state.downloadProgresses[video.videoId]?.cancelToken.cancel();
        await _library.saveSetting(
            SettingsValue(_pausedSetting, jsonEncode(paused.toList())));
      });

  Future<void> retryDownload(DownloadedVideo video) => _mutate(() async {
        await _ready;
        if (!_current ||
            _switchingProfile ||
            video.profileId != _library.profileId ||
            _deleting.contains(video.videoId)) {
          return;
        }
        final paused = {...state.pausedVideoIds}..remove(video.videoId);
        emit(state.copyWith(pausedVideoIds: paused));
        await _library.saveSetting(
            SettingsValue(_pausedSetting, jsonEncode(paused.toList())));
        if (_closing || _deleting.contains(video.videoId)) return;
        // A sheet can remain open while the job completes or is removed. Only
        // retry the current saved job; a captured UI snapshot must not restore it.
        final current = _library.getDownloadByVideoId(video.videoId);
        if (current == null || current.downloadComplete) return;
        if (current.downloadFailed || current.authenticationRequired) {
          await _library.upsertDownload(current.copyWith(
              downloadFailed: false,
              authenticationRequired: false,
              storageFailed: false));
        }
        setVideos();
        unawaited(_drain());
      });

  Future<void> _deleteParts(DownloadedVideo video) async {
    final path = await video.stagingPath;
    for (final suffix in [
      '.audio.part',
      '.audio.part.identity',
      '.video.part',
      '.video.part.identity',
      '.mux.webm',
      '.mux.mp4',
      '.mux.m4a',
    ]) {
      final file = File('$path$suffix');
      if (await file.exists()) await file.delete();
    }
    final artwork = File('${await video.thumbnailPath}.part');
    if (await artwork.exists()) await artwork.delete();
  }

  Future<void> deleteVideo(DownloadedVideo video) => _mutate(() async {
        await _ready;
        if (!DownloadedVideo.isSafeFileId(video.videoId) ||
            !DownloadedVideo.isSafeFileId(video.profileId)) {
          throw const FormatException('Invalid download identity');
        }
        if (!_current ||
            _switchingProfile ||
            video.profileId != _library.profileId) {
          return;
        }
        final saved = _library.getDownloadByVideoId(video.videoId);
        if (saved == null) return;
        video = saved;
        _deleting.add(video.videoId);
        try {
          state.downloadProgresses[video.videoId]?.cancelToken.cancel();
          if (_activeId == video.videoId) await _activeJob;
          // The active job may have created a document since this UI snapshot.
          video = _library.getDownloadByVideoId(video.videoId) ?? video;
          if (video.storageUri != null) {
            await storage.deleteDocument(video.storageUri!);
          }
          await _deleteParts(video);
          for (final path in [
            if (video.storageUri == null) await video.effectivePath,
            await video.downloadPath,
            await video.thumbnailPath
          ]) {
            final file = File(path);
            if (await file.exists()) await file.delete();
          }
          await _library.deleteDownload(video);
          final paused = {...state.pausedVideoIds}..remove(video.videoId);
          await _library.saveSetting(
              SettingsValue(_pausedSetting, jsonEncode(paused.toList())));
          emit(state.copyWith(pausedVideoIds: paused));
          setVideos();
        } finally {
          _deleting.remove(video.videoId);
        }
      });

  bool canPlayAll() =>
      _current &&
      !_switchingProfile &&
      state.videos.any((v) => v.downloadComplete && !v.downloadFailed);
  void playAll() {
    if (!_current || _switchingProfile) return;
    player.playOfflineVideos(state.videos
        .where((v) => v.downloadComplete && !v.downloadFailed)
        .toList());
  }

  Future<void> copyToDownloadFolder(DownloadedVideo video) async {
    if (!_current ||
        _switchingProfile ||
        video.profileId != _library.profileId) {
      return;
    }
    final file = File(await video.effectivePath);
    if (await file.exists()) {
      final name =
          '${video.title.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_').replaceAll(RegExp(r'_{2,}'), '')}_${video.videoId}${p.extension(file.path)}';
      await copyFileIntoDownloadFolder(file.path, name);
    }
  }

  @override
  Future<void> close() async {
    NetworkProxy.instance.removeBeforeApply(_proxyChanging);
    _closing = true;
    for (final progress in state.downloadProgresses.values) {
      progress.cancelToken.cancel();
    }
    await _networkSubscription?.cancel();
    await Future.wait(List.of(_mutations));
    await _activeJob;
    return super.close();
  }
}

@freezed
sealed class DownloadManagerState with _$DownloadManagerState {
  const factory DownloadManagerState({
    String? folderUri,
    String? folderName,
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
