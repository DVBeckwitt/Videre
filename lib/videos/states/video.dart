import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:logging/logging.dart';

import '../../downloads/states/download_manager.dart';
import '../../globals.dart';
import '../../network/nerdvpn_access.dart';
import '../../player/models/backend_playback.dart';
import '../../player/states/player.dart';
import '../../service.dart';
import '../../settings/models/errors/invidious_service_error.dart';
import '../../settings/states/settings.dart';
import '../models/video.dart';

part 'video.freezed.dart';

const String coulnotLoadVideos = 'cannot-load-videos';
final log = Logger('Video');

class VideoCubit extends Cubit<VideoState> {
  final DownloadManagerCubit downloadManager;
  final PlayerCubit player;
  final SettingsCubit settings;
  StreamSubscription<DownloadManagerState>? _downloadSubscription;
  StreamSubscription<(bool, String)>? _dislikeSettingsSubscription;
  int _loadGeneration = 0;
  int _dislikeGeneration = 0;

  VideoCubit(
      super.initialState, this.downloadManager, this.player, this.settings) {
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
    emit(state.copyWith(
        loadingVideo: true,
        retryingVideo: false,
        error: '',
        requestedBackend: null));
    try {
      Video video =
          await service.getVideo(state.videoId, onBackendRequest: (request) {
        if (!isClosed && generation == _loadGeneration) {
          emit(state.copyWith(requestedBackend: request, retryingVideo: false));
        }
      },
              loadObserver: VideoLoadObserver(
                  isCurrent: () => !isClosed && generation == _loadGeneration,
                  onRetry: () {
                    if (!isClosed &&
                        generation == _loadGeneration &&
                        state.loadingVideo) {
                      emit(state.copyWith(retryingVideo: true));
                    }
                  }));
      if (isClosed || generation != _loadGeneration) return;
      final isLoggedIn = await service.isLoggedIn();
      if (isClosed || generation != _loadGeneration) return;
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
      late String error;
      if (err is InvidiousServiceError) {
        error = (err).message;
      } else if (err is NerdVpnAccessRequired) {
        error = err.toString();
      } else {
        error = coulnotLoadVideos;
      }
      if (!isClosed && generation == _loadGeneration) {
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
            !downloads.waitingForWifi &&
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
      player.seek(Duration.zero);
    }
  }

  void playVideo(bool? audio) {
    if (state.video != null) {
      List<Video> videos = [state.video!];
      if (!settings.state.distractionFreeMode &&
          settings.state.playRecommendedNext) {
        videos.addAll(state.video?.recommendedVideos ?? []);
      }
      player.playVideo(videos, audio: audio);
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
