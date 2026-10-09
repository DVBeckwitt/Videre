import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
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
  int _loadGeneration = 0;

  VideoCubit(
      super.initialState, this.downloadManager, this.player, this.settings) {
    onReady();
  }

  Future<void> onReady() async {
    if (isClosed) return;
    final generation = ++_loadGeneration;
    emit(state.copyWith(loadingVideo: true, error: ''));
    try {
      Video video = await service.getVideo(state.videoId);
      final isLoggedIn = await service.isLoggedIn();
      if (isClosed || generation != _loadGeneration) return;
      emit(state.copyWith(
          loadingVideo: false, video: video, isLoggedIn: isLoggedIn));

      getDownloadStatus();
      if (settings.state.useReturnYoutubeDislike) {
        unawaited(_loadDislikes(video.videoId, generation));
      }
    } catch (err) {
      late String error;
      if (err is InvidiousServiceError) {
        error = (err).message;
      } else {
        error = coulnotLoadVideos;
      }
      if (!isClosed && generation == _loadGeneration) {
        emit(state.copyWith(error: error, loadingVideo: false));
      }
    }
  }

  Future<void> _loadDislikes(String videoId, int generation) async {
    try {
      final dislikes = await service.getDislikes(videoId);
      if (!isClosed && generation == _loadGeneration) {
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
