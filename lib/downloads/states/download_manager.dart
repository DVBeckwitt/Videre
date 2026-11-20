import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:bloc/bloc.dart';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:downloadsfolder/downloadsfolder.dart';
import 'package:flutter/services.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/download_playback_provenance.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/music/models/song_artwork.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/invidious_image.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/connectivity.dart';
import 'package:clipious/podcasts/services/podcast_downloads.dart';

import '../../player/states/player.dart';
import '../../network/gateway_session_bridge.dart';
import '../../network/nerdvpn_access.dart';
import '../../settings/models/errors/invidious_service_error.dart';
import '../../utils/interfaces/db.dart';
import '../../videos/models/adaptive_format.dart';
import '../../videos/models/dearrow.dart';
import '../../videos/models/sponsor_segment.dart';
import '../../videos/models/sponsor_segment_types.dart';
import '../../videos/models/video.dart';
import '../../videos/services/download_audio_tracks.dart';
import 'resumable_download.dart';
import '../services/download_rename.dart';
import '../services/download_recovery.dart';
import '../services/download_storage.dart';
import '../services/download_mux.dart';

part 'download_manager.freezed.dart';

final Logger log = Logger('DownloadState');
const _wifiSetting = 'downloads-wifi-only';
const _pausedSetting = 'downloads-paused';

Future<({int byteLength, String sha256})> _privateDownloadIntegrity(
        String path) =>
    Isolate.run(() async {
      final file = File(path);
      final before = await file.stat();
      final digest = await sha256.bind(file.openRead()).first;
      final after = await file.stat();
      if (before.type != FileSystemEntityType.file ||
          before.size <= 0 ||
          before.size != after.size ||
          before.modified != after.modified) {
        throw const FileSystemException('The downloaded file changed');
      }
      return (byteLength: after.size, sha256: digest.toString());
    });

class DownloadProgress {
  final CancelToken cancelToken;
  final DateTime? retryAt;
  int count = 0, total = 1;

  DownloadProgress(this.cancelToken, {this.retryAt});
}

class DownloadManagerCubit extends Cubit<DownloadManagerState> {
  final PlayerCubit player;
  final DownloadStorage storage;
  final Future<void> Function(
      {required String input,
      required String output,
      required DownloadedVideo video,
      required CancelToken token,
      String? sourceCodec,
      MusicDownloadFormat? inputFormat}) encodeMusic;
  late final Future<void> _ready;
  late IDbClient _library;
  StreamSubscription<dynamic>? _networkSubscription;
  late final StreamSubscription<({IDbClient database, Set<String> profiles})>
      _renames;
  final Set<Future<void>> _mutations = {};
  final Set<String> _deleting = {};
  final Set<String> _enqueuing = {};
  final Map<String, ({CancelToken token, Future<bool> result})> _exports = {};
  DownloadFolderPreferences _folders = const DownloadFolderPreferences();
  Future<void> _folderWrite = Future.value();
  final _folderChoiceRevision = <bool, int>{};
  int _musicFolderRevision = 0;
  Future<String?>? _pendingMusicFolder;
  bool _processing = false, _wifiConnected = false, _closing = false;
  bool _switchingProfile = false;
  int _generation = 0;
  String? _activeId;
  Future<void>? _activeJob;
  Completer<void>? _drainFinished;

  DownloadManagerCubit(super.initialState, this.player,
      {DownloadStorage? storage, this.encodeMusic = runMusicDownloadMux})
      : storage = storage ?? DownloadStorage() {
    _library = db.forProfile(db.profileId);
    _renames = localMusicDownloadRenames.listen((change) {
      if (identical(change.database, db) &&
          _current &&
          change.profiles.contains(_library.profileId)) {
        setVideos();
      }
    });
    _ready = onReady();
    NetworkProxy.instance.addBeforeApply(_proxyChanging);
  }

  bool get _current => !_closing && _library.profileId == db.profileId;

  DateTime? retryAtFor(DownloadedVideo video) {
    if (video.profileId != _library.profileId || video.accountId == null) {
      return null;
    }
    final account = _library.getAccount(video.accountId!);
    return account == null
        ? null
        : DownloadRecovery.retryAtFor(service, _library, account);
  }

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
    for (final export in _exports.values) {
      export.token.cancel();
    }
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
      _networkSubscription = wifiConnectivityChanges.listen(_networkChanged,
          onError: (Object error) => _networkChanged(false));
      _wifiConnected = await isWifiConnected();
    }
    _networkChanged(_wifiConnected);
  }

  void _loadLibrary() {
    Set<String> paused = {};
    _folders = _readFolders();
    _pendingMusicFolder = null;
    try {
      final saved =
          jsonDecode(_library.getSettings(_pausedSetting)?.value ?? '[]');
      if (saved is List) paused = saved.whereType<String>().toSet();
    } on FormatException {
      // An interrupted settings import should not block the download library.
    }
    emit(_withFolders(state.copyWith(
        wifiOnly: _library.getSettings(_wifiSetting)?.value == 'true',
        pausedVideoIds: paused,
        downloadProgresses: {},
        videos: _library.getAllDownloads())));
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
        final database = db;
        final profileId = _library.profileId;
        await _library
            .saveSetting(SettingsValue(_wifiSetting, value.toString()));
        emit(state.copyWith(wifiOnly: value));
        _networkChanged(_wifiConnected);
        await PodcastDownloads.notifyWifiOnlyChanged(database, profileId);
      });

  DownloadFolderPreferences _readFolders() => DownloadFolderPreferences.decode(
      _library.getSettings(downloadFolderSetting)?.value);

  DownloadManagerState _withFolders(DownloadManagerState snapshot) =>
      snapshot.copyWith(
        folderUri: _folders.video.folder?.uri,
        folderName: _folders.video.folder?.name,
        usePrivateStorage: _folders.video.usePrivate,
        audioFolderUri: _folders.audio.folder?.uri,
        audioFolderName: _folders.audio.folder?.name,
        usePrivateAudioStorage: _folders.audio.usePrivate,
      );

  /// Updating one destination must not overwrite a concurrent change to the
  /// other one or a pre-Android-10 export picker that has just completed.
  Future<void> _writeFolders(
      DownloadFolderPreferences Function(DownloadFolderPreferences) update) {
    final generation = _generation;
    final writing = _folderWrite.then((_) async {
      if (!_current || _switchingProfile || generation != _generation) return;
      final next = update(_readFolders());
      final value = next.encode();
      if (value == null) {
        await _library.deleteSetting(downloadFolderSetting);
      } else {
        await _library.saveSetting(SettingsValue(downloadFolderSetting, value));
      }
      if (_current && !_switchingProfile && generation == _generation) {
        _folders = next;
        emit(_withFolders(state));
      }
    });
    _folderWrite =
        writing.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return _mutate(() => writing);
  }

  Future<void> chooseFolder({bool audioOnly = false}) =>
      _changeFolder(audioOnly, null);

  Future<void> usePrivateFolder({bool audioOnly = false}) =>
      _changeFolder(audioOnly, privateDownloadDestination);

  Future<void> useDefaultFolder({bool audioOnly = false}) =>
      _changeFolder(audioOnly, defaultDownloadDestination);

  Future<void> _changeFolder(
      bool audioOnly, DownloadDestination? destination) async {
    await _ready;
    if (!_current || _switchingProfile) return;
    final generation = _generation;
    final revision = (_folderChoiceRevision[audioOnly] ?? 0) + 1;
    _folderChoiceRevision[audioOnly] = revision;
    if (destination == null) {
      final folder = await storage
          .pickFolder(audioOnly ? state.audioFolderUri : state.folderUri);
      if (folder == null ||
          !_current ||
          _switchingProfile ||
          generation != _generation ||
          revision != _folderChoiceRevision[audioOnly]) {
        return;
      }
      destination = (folder: folder, usePrivate: false);
    }
    final selected = destination;
    // Re-selecting the audio default also lets an older Android device
    // replace a Music tree whose persisted permission has been revoked.
    final resetMusicFolder =
        audioOnly && selected == defaultDownloadDestination;
    if (resetMusicFolder) _musicFolderRevision++;
    await _writeFolders((previous) => DownloadFolderPreferences(
        video: audioOnly ? previous.video : selected,
        audio: audioOnly ? selected : previous.audio,
        legacyMusicFolder:
            resetMusicFolder ? null : previous.legacyMusicFolder));
  }

  Future<String?> _deviceMusicFolder() async {
    final generation = _generation;
    final shared = await storage.sharedMusicFolder();
    if (!_current || _switchingProfile || generation != _generation) {
      return null;
    }
    if (shared != null) return shared;
    if (_folders.legacyMusicFolder case final folder?) return folder.uri;
    final pending = _pendingMusicFolder ??= _pickMusicFolder();
    try {
      return await pending;
    } finally {
      if (identical(_pendingMusicFolder, pending)) _pendingMusicFolder = null;
    }
  }

  /// A batch gets one system folder prompt on Android versions before 10.
  Future<bool> prepareMusicDownloads() async {
    await _ready;
    if (!_current || _switchingProfile) return false;
    if (!storage.supportsSharedMusic ||
        state.usePrivateAudioStorage ||
        state.audioFolderUri != null) {
      return true;
    }
    return await _deviceMusicFolder() != null && _current && !_switchingProfile;
  }

  Future<String?> _pickMusicFolder() async {
    final generation = _generation;
    final revision = _musicFolderRevision;
    final folder = await storage.pickFolder(null);
    if (folder == null ||
        !_current ||
        _switchingProfile ||
        generation != _generation ||
        revision != _musicFolderRevision) {
      return null;
    }
    await _writeFolders((previous) => DownloadFolderPreferences(
        video: previous.video,
        audio: previous.audio,
        legacyMusicFolder: folder));
    return _current &&
            !_switchingProfile &&
            generation == _generation &&
            revision == _musicFolderRevision
        ? folder.uri
        : null;
  }

  void setVideos() {
    if (_current) emit(state.copyWith(videos: _library.getAllDownloads()));
  }

  Future<bool> addDownload(String videoId,
          {String quality = '720p',
          bool audioOnly = false,
          DownloadContainer? container,
          String? audioTrackId,
          String? captionLabel,
          Video? video}) =>
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
          final destination = audioOnly ? _folders.audio : _folders.video;
          var folder = destination.folder?.uri;
          final isMusic = audioOnly && quality == highestAudioDownloadQuality;
          final format =
              isMusic ? MusicDownloadFormat.forDatabase(_library) : null;
          final shareMusic =
              isMusic && storage.supportsSharedMusic && !destination.usePrivate;
          if (shareMusic && folder == null) {
            folder = await _deviceMusicFolder();
            if (folder == null || !_current || _switchingProfile) return false;
          }
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
              folderUri: folder,
              musicFormat: format,
              container: container,
              audioTrackId: audioTrackId,
              captionLabel: audioOnly ? null : captionLabel,
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
      DownloadContainer? container,
      String? audioTrackId,
      String? captionLabel,
      Map<String, Video> videosById = const {}}) async {
    var added = 0;
    final generation = _generation;
    for (final id in videoIds.toSet()) {
      if (generation != _generation || _switchingProfile) break;
      if (await addDownload(id,
          quality: quality,
          audioOnly: audioOnly,
          container: container,
          audioTrackId: audioTrackId,
          captionLabel: captionLabel,
          video: videosById[id])) {
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
    Future<String?>? deArrowTitle;
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
      final account = library.getAccount(video.accountId!);
      if (account == null || account.profileId != library.profileId) {
        throw StateError('The download account is no longer available');
      }
      final recovery =
          await DownloadRecovery.start(service, library, account, token);
      await recovery.run<void>((route) async {
        final server = route.server;
        final artworkToken = CancelToken();
        Future<void>? artwork;
        try {
          var vid = await Future.any([
            service.getDownloadVideo(video.videoId,
                route: route, checkCurrent: recovery.checkCurrent),
            token.whenCancel.then((error) => throw error),
          ]);
          recovery.checkCurrent();
          // The sheet can discover a usable default only in DASH. Repeat that
          // discovery even when the user left the audio choice on Automatic.
          final needsDefaultAudio = video.audioTrackId == null &&
              !(vid.adaptiveFormats ?? const <AdaptiveFormat>[]).any((format) =>
                  DownloadContainer.forAudio(format) != null &&
                  downloadMediaUrl(format, server) != null);
          if ((video.audioTrackId?.startsWith('dash:') ?? false) ||
              needsDefaultAudio) {
            vid = await Future.any([
              loadDownloadAudioTracks(vid, server,
                  client: service.httpClient,
                  checkCurrent: recovery.checkCurrent,
                  timeout: const Duration(seconds: 30)),
              token.whenCancel.then((error) => throw error),
            ]);
            recovery.checkCurrent();
          }
          // Admit routes before ranking tracks, so an unsupported high-bitrate
          // URL cannot hide a usable track from the selected instance.
          final mediaUrls = <AdaptiveFormat, String>{};
          for (final format in vid.adaptiveFormats ?? <AdaptiveFormat>[]) {
            final url = downloadMediaUrl(format, server);
            if (url != null) mediaUrls[format] = url;
          }
          final formats = DownloadFormats(mediaUrls.keys.toList(),
              audioTrackId: video.audioTrackId);
          // A saved document already has a container. Old jobs saved WebM.
          final savedContainer = video.container ??
              (video.storageUri == null ? null : DownloadContainer.webm);
          final selectedVideo = video.audioOnly
              ? null
              : formats.videoFor(video.quality, container: savedContainer);
          final automaticAudio =
              video.audioOnly && video.quality == highestAudioDownloadQuality
                  ? formats.highestBitrateAudioContainer
                  : formats.audioContainer;
          final container = savedContainer ??
              (selectedVideo == null
                  ? automaticAudio
                  : DownloadContainer.forVideo(selectedVideo));
          final audio = formats.audioFor(container);
          if (audio == null || (!video.audioOnly && selectedVideo == null)) {
            throw const DownloadFormatsUnavailable();
          }
          final caption = vid.captions
              .where((caption) => caption.label == video.captionLabel)
              .firstOrNull;
          if (video.captionLabel != null && caption == null) {
            throw const DownloadFormatsUnavailable();
          }
          var music = video.musicMetadata ?? vid.musicMetadata;
          var title = vid.title;
          if (!video.storeAsMusic &&
              video.musicMetadata == null &&
              library.getSettings(dearrowSettingName)?.value == 'true') {
            // Enrich the saved title once per job. Optional presentation
            // metadata cannot trigger a retry of an extraction backend.
            final enriched = deArrowTitle ??= DeArrow.processVideos([vid],
                    owner: library)
                .then<String?>((videos) => videos.first.title,
                    onError: (_) => null)
                .timeout(const Duration(seconds: 30), onTimeout: () => null);
            title = await Future.any([
                  enriched,
                  token.whenCancel.then((error) => throw error)
                ]) ??
                title;
            recovery.checkCurrent();
          }
          if (music != null && video.videoId == vid.videoId) {
            music = vid
                .resolveMusicMetadata(music)
                .withoutVideoThumbnailFallbacks(vid.videoThumbnails);
          }
          video = video.copyWith(
              // Interrupted/replaced output must never inherit old proof.
              playbackProvenance: null,
              title: music?.title ?? title ?? video.title,
              author: music?.artist ?? vid.author,
              musicMetadata: music,
              authorUrl: vid.authorUrl ?? video.authorUrl,
              lengthSeconds: vid.lengthSeconds ?? video.lengthSeconds,
              downloadFailed: false,
              authenticationRequired: false);
          await library.upsertDownload(video);
          setVideos();
          final segmentsForJob = sponsorSegments ??=
              _downloadSponsorSegments(video, library, token);
          // Automatic remains automatic until the output is published. A
          // second extractor may offer a different compatible container.
          final outputVideo = video.copyWith(container: container);
          final mediaPath = await outputVideo.downloadPath;
          final staging = await video.stagingPath;
          final audioPath = '$staging.audio.part';
          final videoPath = '$staging.video.part';
          final captionPath = '$staging.caption.vtt';
          final steps = (video.audioOnly ? 2 : 3) + (caption == null ? 0 : 1);
          Future<void> transfer(AdaptiveFormat format, String path, int step) {
            recovery.checkCurrent();
            final url = mediaUrls[format]!;
            final size = int.tryParse(format.clen);
            final rendition = RenditionIdentity.fromFormat(format, server);
            // Without immutable rendition proof, a refreshed URL (even on
            // the same backend) must begin a new file.
            final identity = rendition == null
                ? const Uuid().v4()
                : jsonEncode([
                    video.profileId,
                    video.accountId,
                    Uri.parse(server.url).origin,
                    video.videoId,
                    rendition.toJson()
                  ]);
            return downloadResumable(dio, url, path,
                cancelToken: token,
                identity: identity,
                beforeRequest: recovery.checkCurrent,
                expectedSize: size != null && size > 0 ? size : null,
                acceptsContentType: (contentType) {
                  final mime =
                      contentType?.split(';').first.trim().toLowerCase() ?? '';
                  return mime != 'text/html' &&
                      !mime.endsWith('json') &&
                      !mime.endsWith('xml');
                },
                headers: server.headersForUrl(url),
                onProgress: (count, total) =>
                    update(count, total, step, steps));
          }

          String? privateThumbnail(List<ImageObject>? images) =>
              ImageObject.getBestThumbnail(images?.where((image) {
                final url = invidiousImageUrl(image.url, server);
                return url != null && url.isNotEmpty;
              }).toList())
                  ?.url;
          final cover = video.songCoverUrl;
          final posters = music == null
              ? [if (privateThumbnail(vid.videoThumbnails) case final url?) url]
              : _stockPosterUrls(vid, server, artTrack: music.isArtTrack);
          if (cover != null || posters.isNotEmpty) {
            unawaited(token.whenCancel.then(artworkToken.cancel));
            // Optional artwork must not delay the first media request. Keep it
            // part of this job so pause, delete and proxy changes can join it.
            artwork = _downloadArtwork(dio, video, server, artworkToken,
                cover: cover, posters: posters);
          }
          await transfer(audio, audioPath, 0);
          if (!video.audioOnly) await transfer(selectedVideo!, videoPath, 1);
          recovery.checkCurrent();
          route.recordSuccess();
          if (caption != null) {
            final subtitles = await Future.any([
              service
                  .getPlaybackCaptions(video.videoId, caption, server: server)
                  .timeout(const Duration(seconds: 30)),
              token.whenCancel.then((error) => throw error),
            ]);
            if (token.isCancelled) throw token.cancelError!;
            await File(captionPath).writeAsString(subtitles);
            update(1, 1, steps - 2, steps);
          }
          recovery.checkCurrent();
          final output = '$staging.mux.${outputVideo.extension}';
          if (video.storeAsMusic) {
            await encodeMusic(
                input: audioPath,
                output: output,
                video: video,
                token: token,
                sourceCodec: audio.encoding);
          } else if (video.audioOnly) {
            await File(audioPath).copy(output);
          } else {
            await runDownloadMux([
              '-y',
              '-i',
              videoPath,
              '-i',
              audioPath,
              if (caption != null) ...[
                '-i',
                captionPath,
                '-map',
                '0:v:0',
                '-map',
                '1:a:0',
                '-map',
                '2:s:0',
                '-c:s',
                container == DownloadContainer.mp4 ? 'mov_text' : 'webvtt',
                '-metadata:s:s:0',
                'title=${caption.label}',
                if (caption.languageCode != null) ...[
                  '-metadata:s:s:0',
                  'language=${caption.languageCode}',
                ],
              ],
              '-c:v',
              'copy',
              '-c:a',
              'copy',
              output
            ], token);
          }
          recovery.checkCurrent();
          await artwork;
          video = video.copyWith(sponsorSegments: await segmentsForJob);
          recovery.checkCurrent();
          if (caption != null) {
            await File(captionPath).copy(await video.subtitlePath);
            if (token.isCancelled) throw token.cancelError!;
          }
          if (video.folderUri == null) {
            video = video.copyWith(container: container);
            await library.upsertDownload(video);
            recovery.checkCurrent();
            await File(output).rename(mediaPath);
          } else {
            final uri = await storage.prepareDocument(video.folderUri!,
                video.storageUri, outputVideo.fileName, outputVideo.mimeType);
            // Record ownership before writing so retries reuse this document
            // and deletion can clean up an interrupted save after a restart.
            video = video.copyWith(storageUri: uri, container: container);
            await library.upsertDownload(video);
            if (token.isCancelled) throw token.cancelError!;
            await storage.writeDocument(output, uri, token);
          }
          if (token.isCancelled) throw token.cancelError!;
          // Muzza reads saved media before its evictable playback cache. Our
          // files need owner/rendition proof and a fingerprint of final bytes,
          // including remuxed video and externally stored documents.
          DownloadPlaybackProvenance? provenance;
          try {
            final integrity = video.storageUri == null
                ? await _privateDownloadIntegrity(mediaPath)
                : await storage.inspectDocument(
                    video.storageUri!, video.folderUri!);
            if (integrity != null) {
              provenance = DownloadPlaybackProvenance.create(
                  video: vid,
                  server: server,
                  audioOnly: video.audioOnly,
                  container: container!,
                  audio: audio,
                  videoFormat: selectedVideo,
                  byteLength: integrity.byteLength,
                  sha256: integrity.sha256);
            }
          } catch (_) {
            // Failure of optional automatic reuse does not delete a completed
            // download or change its existing explicit-offline behavior.
            provenance = null;
          }
          if (token.isCancelled) throw token.cancelError!;
          await library.upsertDownload(video.copyWith(
              playbackProvenance: provenance,
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
        } finally {
          artworkToken.cancel();
          await artwork;
        }
      }, onWaiting: (retryAt) {
        if (!_current || token.isCancelled) return;
        final current = state.downloadProgresses[video.videoId];
        final waiting = DownloadProgress(token, retryAt: retryAt)
          ..count = current?.count ?? 0
          ..total = current?.total ?? 1;
        emit(state.copyWith(downloadProgresses: {video.videoId: waiting}));
      });
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
    if (error is DownloadCooldown) return false;
    if (error is NerdVpnAccessRequired) {
      return const {'missing', 'signInRequired'}.contains(error.state);
    }
    if (error is InvidiousServiceError && error.isGatewayAccessFailure) {
      return const {'credentials_required', 'invalid_credentials'}
          .contains(error.errorCode);
    }
    return null;
  }

  List<String> _stockPosterUrls(Video video, Server server,
      {required bool artTrack}) {
    final images = stockSongThumbnails(video.videoId, video.videoThumbnails,
        instanceUrl: server.url);
    if (images.isEmpty) return const [];
    final preferred = artTrack
        ? stockSongThumbnails(video.videoId, images, artTrack: true)
        : images;
    final ranked = ImageObject.getThumbnailUrlsByPreferredOrder(images);
    // Stock metadata lists sizes even when this upload has no HD poster.
    // Try the best source, then the advertised HQ and MQ before other sizes.
    return {
      ImageObject.getBestThumbnail(preferred)!.url,
      for (final name in ['hqdefault', 'mqdefault'])
        if (ranked.contains('/vi/${video.videoId}/$name.jpg'))
          '/vi/${video.videoId}/$name.jpg',
      ...ranked,
    }.take(4).toList(growable: false);
  }

  Future<void> _downloadArtwork(
      Dio dio, DownloadedVideo video, Server server, CancelToken token,
      {String? cover, required List<String> posters}) async {
    final deadline = Timer(const Duration(seconds: 5),
        () => token.cancel('Artwork download deadline'));
    try {
      for (final source in [if (cover != null) cover, ...posters]) {
        if (token.isCancelled) return;
        final File? target;
        if (source == cover) {
          target = await video.songCoverFile;
        } else if (video.musicMetadata != null) {
          target = await video.stockSongPosterFile;
        } else {
          target = File(await video.thumbnailPath);
        }
        final url = invidiousImageUrl(source, server);
        if (target == null || url == null || url.isEmpty) continue;
        if (await target.exists()) return;
        final partial = File('${target.path}.part');
        try {
          await target.parent.create(recursive: true);
          await dio.download(url, partial.path,
              cancelToken: token,
              options: Options(
                  headers: server.headersForUrl(url),
                  receiveDataWhenStatusError: false));
          if (token.isCancelled) return;
          if (await partial.length() == 0) continue;
          await partial.rename(target.path);
          return;
        } on DioException catch (error) {
          // A missing image can fall back to the next stock rendition.
          // Authentication, cooldowns and cancellation apply to all candidates.
          if (!const {404, 410}.contains(error.response?.statusCode)) return;
        } finally {
          if (await partial.exists()) await partial.delete();
        }
      }
    } on FileSystemException {
      log.fine('Thumbnail could not be saved; the media download can continue');
    } finally {
      deadline.cancel();
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
      '.caption.vtt',
      '.mux.webm',
      '.mux.mp4',
      '.mux.m4a',
      '.mux.mp3',
      '.mux.ogg',
      '.export-input.part',
      '.export.mp3',
      '.export.ogg',
      '.export.m4a',
    ]) {
      final file = File('$path$suffix');
      if (await file.exists()) await file.delete();
    }
    final artwork = File('${await video.thumbnailPath}.part');
    if (await artwork.exists()) await artwork.delete();
    final covers = await video.songCoverDirectory;
    if (await covers.exists()) {
      final current = {
        (await video.songCoverFile)?.path,
        (await video.stockSongPosterFile)?.path
      };
      await for (final entry in covers.list(followLinks: false)) {
        if (entry is File && !current.contains(entry.path)) {
          await entry.delete();
        }
      }
    }
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
          final export = _exports[video.videoId];
          if (export != null) {
            export.token.cancel();
            try {
              await export.result;
            } catch (_) {
              // The writer is now detached from the file being removed.
            }
          }
          state.downloadProgresses[video.videoId]?.cancelToken.cancel();
          if (_activeId == video.videoId) await _activeJob;
          // The active job may have created a document since this UI snapshot.
          video = _library.getDownloadByVideoId(video.videoId) ?? video;
          if (video.exportedMusic case final copy? when !copy.complete) {
            await storage.deleteDocument(copy.uri);
          }
          if (video.storageUri != null) {
            await storage.deleteDocument(video.storageUri!);
          }
          await _deleteParts(video);
          for (final path in [
            if (video.storageUri == null) await video.effectivePath,
            await video.downloadPath,
            await video.subtitlePath,
            await video.thumbnailPath
          ]) {
            final file = File(path);
            if (await file.exists()) await file.delete();
          }
          final covers = await video.songCoverDirectory;
          if (await covers.exists()) await covers.delete(recursive: true);
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

  /// Publishes an existing song without fetching it again or moving the original.
  Future<bool> exportMusic(DownloadedVideo video) {
    if (!_current ||
        _switchingProfile ||
        video.profileId != _library.profileId ||
        _deleting.contains(video.videoId)) {
      return Future.value(false);
    }
    final previous = _exports[video.videoId];
    if (previous != null) return previous.result;
    final token = CancelToken();
    final result = _mutate(() => _exportMusic(video.videoId, token))
        .whenComplete(() => _exports.remove(video.videoId));
    _exports[video.videoId] = (token: token, result: result);
    return result;
  }

  Future<bool> _exportMusic(String id, CancelToken token) async {
    await _ready;
    final library = _library;
    final saved = library.getDownloadByVideoId(id);
    if (token.isCancelled ||
        !_current ||
        _switchingProfile ||
        saved == null ||
        !saved.audioOnly ||
        saved.musicMetadata == null ||
        !saved.downloadComplete ||
        saved.downloadFailed ||
        (saved.storageUri != null && saved.storeAsMusic)) {
      return false;
    }
    final format = MusicDownloadFormat.forDatabase(library);
    final folder = await _deviceMusicFolder();
    if (folder == null || token.isCancelled) return false;
    final previous = saved.exportedMusic;
    final sameTarget = previous?.folder == folder && previous?.format == format;
    if (sameTarget && previous!.complete) {
      // Only confirmed absence warrants another copy. A temporary provider
      // failure leaves the original record intact so a later retry can find it.
      if (await storage.exportExists(previous.uri, folder)) return true;
    }
    if (previous != null && !previous.complete && !sameTarget) {
      await storage.deleteDocument(previous.uri);
    }
    final outputSong = saved.copyWith(musicFormat: format);
    final staging = await saved.stagingPath;
    final stageInput = File('$staging.export-input.part');
    final stageOutput = File('$staging.export.${outputSong.extension}');
    try {
      var input = await saved.effectivePath;
      if (saved.storageUri case final uri?) {
        if (saved.folderUri == null) {
          throw StateError('Missing download folder');
        }
        await storage.readDocument(
            uri, saved.folderUri!, stageInput.path, token);
        input = stageInput.path;
      }
      if (saved.musicFormat != format) {
        await encodeMusic(
            input: input,
            output: stageOutput.path,
            video: outputSong,
            inputFormat: saved.musicFormat,
            token: token);
        input = stageOutput.path;
      }
      if (token.isCancelled) return false;
      final uri = await storage.prepareDocument(
          folder,
          sameTarget && !previous!.complete ? previous.uri : null,
          outputSong.fileName,
          outputSong.mimeType);
      await library.saveDownloadExport(
          saved.videoId, ExportedMusicCopy(folder, uri, format));
      await storage.writeDocument(input, uri, token);
      await library.saveDownloadExport(saved.videoId,
          ExportedMusicCopy(folder, uri, format, complete: true));
      setVideos();
      return true;
    } finally {
      for (final file in [stageInput, stageOutput]) {
        if (await file.exists()) await file.delete();
      }
    }
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
    for (final export in _exports.values) {
      export.token.cancel();
    }
    for (final progress in state.downloadProgresses.values) {
      progress.cancelToken.cancel();
    }
    await _networkSubscription?.cancel();
    await _renames.cancel();
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
    @Default(false) bool usePrivateStorage,
    String? audioFolderUri,
    String? audioFolderName,
    @Default(false) bool usePrivateAudioStorage,
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
