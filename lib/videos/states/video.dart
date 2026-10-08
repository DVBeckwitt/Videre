import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/videos/models/dislike.dart';
import 'package:logging/logging.dart';

import '../../downloads/states/download_manager.dart';
import '../../globals.dart';
import '../../player/states/player.dart';
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

  VideoCubit(
      super.initialState, this.downloadManager, this.player, this.settings) {
    onReady();
  }

  Future<void> onReady() async {
    if (isClosed) return;
    emit(state.copyWith(loadingVideo: true, error: ''));
    try {
      Video video = await service.getVideo(state.videoId);
      var dislikes = state.dislikes;

      try {
        if (settings.state.useReturnYoutubeDislike) {
          Dislike dislike = await service.getDislikes(state.videoId);
          dislikes = dislike.dislikes;
        }
      } catch (e) {
        log.info("Failed to get dislikes for video ${state.videoId}");
      }

      final isLoggedIn = await service.isLoggedIn();
      if (isClosed) return;
      emit(state.copyWith(
          loadingVideo: false,
          video: video,
          dislikes: dislikes,
          isLoggedIn: isLoggedIn));

      getDownloadStatus();
    } catch (err) {
      late String error;
      if (err is InvidiousServiceError) {
        error = (err).message;
      } else {
        error = coulnotLoadVideos;
      }
      if (!isClosed) emit(state.copyWith(error: error, loadingVideo: false));
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
      int? dislikes,
      @Default(true) loadingVideo,
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
