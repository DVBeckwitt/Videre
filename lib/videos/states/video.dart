import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:logging/logging.dart';

import '../../downloads/services/download_playback_source.dart';
import '../../downloads/states/download_manager.dart';
import '../../globals.dart';
import '../../network/nerdvpn_access.dart';
import '../../player/models/backend_playback.dart';
import '../../player/states/player.dart';
import '../../service.dart';
import '../../settings/models/errors/invidious_service_error.dart';
import '../../settings/states/settings.dart';
import '../models/community_video_filter.dart';
import '../models/video.dart';

part 'video.freezed.dart';

const String coulnotLoadVideos = 'cannot-load-videos';
final log = Logger('Video');

class VideoCubit extends Cubit<VideoState> {
  final DownloadManagerCubit downloadManager;
  final PlayerCubit player;
  final SettingsCubit settings;
  final Duration? startAt;
  StreamSubscription<DownloadManagerState>? _downloadSubscription;
  StreamSubscription<(bool, String)>? _dislikeSettingsSubscription;
  int _loadGeneration = 0;
  int _dislikeGeneration = 0;

  VideoCubit(
      super.initialState, this.downloadManager, this.player, this.settings,
      {this.startAt}) {
    var dislikeSettings = (
      settings.state.useReturnYoutubeDislike,
      settings.state.returnYoutubeDislikeUrl,
    );
    _dislikeSettingsSubscription = settings.stream
        .map((state) =>
            (state.useReturnYoutubeDislike, state.returnYoutubeDislikeUrl))
        .listen((value) {
      if (isClosed || value == dislikeSettings) return;
      dislikeSettings = value;
      final generation = ++_dislikeGeneration;
      emit(state.copyWith(dislikes: null));
      final video = state.video;
      if (value.$1 && !state.loadingVideo && video != null) {
        unawaited(_loadDislikes(video.videoId, _loadGeneration, generation));
      }
    });
    onReady();
  }

  Future<void> onReady() async {
    if (isClosed) return;
    final generation = ++_loadGeneration;
    final database = db;
    final profileId = database.profileId;
    final videoId = state.videoId;
    bool isCurrent() =>
        !isClosed &&
        generation == _loadGeneration &&
        identical(db, database) &&
        database.profileId == profileId;
    emit(state.copyWith(
        loadingVideo: true,
        retryingVideo: false,
        error: '',
        requestedBackend: null));
    Video? local;
    try {
      // The details route loads metadata before PlayerCubit receives a normal
      // tap. Prime its existing optional cache now so initial skips can be ready
      // with that metadata, without delaying either local or online playback.
      try {
        unawaited(player
            .prepareSponsorSegments(videoId)
            .onError((_, stackTrace) => []));
      } catch (_) {
        // Optional preparation cannot turn a usable metadata/local load into
        // an error, including a synchronous settings/cache lookup failure.
      }
      // Ordinary video taps reach this route before the player. Restore saved
      // metadata here so a compatible completed download can start without an
      // online metadata request. Legacy or unavailable records remain optional.
      DownloadedVideo? download;
      try {
        download = database.getDownloadByVideoId(videoId);
      } catch (_) {}
      if (download?.playbackProvenance != null) {
        local = await prepareDownloadedPlaybackVideo(
            database: database,
            video: Video(videoId: videoId),
            audioOnly: false,
            preferredQuality: settings.state.rememberVideoQuality
                ? settings.state.lastVideoQuality
                : null,
            isCurrent: isCurrent);
        if (!isCurrent()) return;
        if (local != null) {
          final selected = await database.getCurrentlySelectedServer();
          if (!isCurrent() || !local.playbackConnection!.matches(selected)) {
            return;
          }
          emit(state.copyWith(
              loadingVideo: false, retryingVideo: false, video: local));
          getDownloadStatus();
        }
      }
      // Enrich the details after publishing the playable saved candidate. This
      // request must neither delay playback nor replace it with a load error.
      Video video = await service.getVideo(videoId,
          onBackendRequest: (request) {
        if (isCurrent() && local == null) {
          emit(state.copyWith(requestedBackend: request, retryingVideo: false));
        }
      },
          loadObserver: VideoLoadObserver(
              isCurrent: () =>
                  isCurrent() &&
                  (local == null ||
                      local.playbackConnection!
                          .matches(local.playbackConnection!.preferredServer)),
              onRetry: () {
                if (isCurrent() && state.loadingVideo) {
                  emit(state.copyWith(retryingVideo: true));
                }
              }));
      if (!isCurrent()) return;
      final isLoggedIn = await service.isLoggedIn();
      if (!isCurrent()) return;
      if (local != null) {
        final selected = await database.getCurrentlySelectedServer();
        if (!isCurrent() || !local.playbackConnection!.matches(selected)) {
          return;
        }
      }
      emit(state.copyWith(
          loadingVideo: false,
          retryingVideo: false,
          video: video,
          isLoggedIn: isLoggedIn));

      getDownloadStatus();
      if (settings.state.useReturnYoutubeDislike) {
        unawaited(
            _loadDislikes(video.videoId, generation, ++_dislikeGeneration));
      }
    } catch (err) {
      if (local != null) return;
      late String error;
      if (err is InvidiousServiceError) {
        error = (err).message;
      } else if (err is NerdVpnAccessRequired) {
        error = err.toString();
      } else {
        error = coulnotLoadVideos;
      }
      if (isCurrent()) {
        emit(state.copyWith(
            error: error, loadingVideo: false, retryingVideo: false));
      }
    }
  }

  Future<void> _loadDislikes(
      String videoId, int generation, int dislikeGeneration) async {
    try {
      final dislikes = await service.getDislikes(videoId);
      if (!isClosed &&
          generation == _loadGeneration &&
          dislikeGeneration == _dislikeGeneration) {
        emit(state.copyWith(dislikes: dislikes.dislikes));
      }
    } catch (_) {
      log.info('Failed to get dislikes for video $videoId');
    }
  }

  getDownloadStatus() {
    _downloadSubscription ??= downloadManager.stream.listen(_setDownloadStatus);
    _setDownloadStatus(downloadManager.state);
  }

  void initStreamListener() => getDownloadStatus();

  void _setDownloadStatus(DownloadManagerState downloads) {
    if (isClosed) return;
    final video =
        downloads.videos.where((v) => v.videoId == state.videoId).firstOrNull;
    final progress = downloads.downloadProgresses[state.videoId];
    emit(state.copyWith(
        downloadedVideo: video,
        downloading: progress != null &&
            !(video == null
                ? downloads.waitingForWifi
                : downloads.waitingForWifiFor(video)) &&
            !downloads.pausedVideoIds.contains(state.videoId),
        downloadProgress: video?.downloadComplete == true
            ? 1
            : progress != null && progress.total > 0
                ? progress.count / progress.total
                : 0));
  }

  @override
  close() async {
    ++_loadGeneration;
    await _dislikeSettingsSubscription?.cancel();
    await _downloadSubscription?.cancel();
    return super.close();
  }

  onDownload() {
    emit(state.copyWith(downloading: true, downloadProgress: 0));
  }

  togglePlayRecommendedNext(bool? value) {
    settings.setPlayRecommendedNext(value ?? false);
  }

  void restartVideo(bool? audio) {
    if (state.video != null) {
      player.showBigPlayer();
      player.seek(startAt ?? Duration.zero);
    }
  }

  void playVideo(bool? audio, {bool selectedByUser = true}) {
    if (state.video != null) {
      List<Video> videos = [state.video!];
      if (!settings.state.distractionFreeMode &&
          settings.state.playRecommendedNext) {
        videos.addAll(state.video!.recommendedVideos
            .where((video) => !hideCommunityVideo(video)));
      }
      if (selectedByUser) player.noteWatchSelection(state.video!.videoId);
      player.playVideo(videos, audio: audio, startAt: startAt);
    }
  }
}

@freezed
sealed class VideoState with _$VideoState {
  const factory VideoState(
      {Video? video,
      BackendPlayback? requestedBackend,
      int? dislikes,
      @Default(true) loadingVideo,
      @Default(false) bool retryingVideo,
      required String videoId,
      required bool isLoggedIn,
      @Default(false) bool downloading,
      @Default(0) double downloadProgress,
      DownloadedVideo? downloadedVideo,
      @Default(1) double opacity,
      @Default('') String error}) = _VideoState;

  const VideoState._();

  static VideoState init({required String videoId}) {
    return VideoState(videoId: videoId, isLoggedIn: false);
  }

  bool get downloadFailed => downloadedVideo?.downloadFailed ?? false;

  bool get isDownloaded {
    if (video != null) {
      return downloadedVideo != null;
    } else {
      return false;
    }
  }
}
