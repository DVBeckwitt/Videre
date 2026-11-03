import 'package:bloc/bloc.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';

import '../../globals.dart';
import '../../utils/interfaces/db.dart';
import '../models/db/progress.dart';
import '../services/watch_history.dart';

part 'video_in_list.freezed.dart';

class VideoInListCubit extends Cubit<VideoInListState> {
  late final IDbClient _database;
  VideoInListCubit(super.initialState) {
    _database = db.forProfile(db.profileId);
    playbackHistoryRevision.addListener(updateProgress);
    onReady();
  }

  void onReady() {
    updateProgress();
  }

  void updateProgress() {
    if (state.video != null) {
      setProgress(_database.getVideoProgress(state.video!.videoId));
    }
  }

  void setProgress(double progress) {
    if (state.video != null) {
      emit(state.copyWith(
          progress: progress,
          watched: WatchRepository.forDatabase(_database)
                  ?.isWatched(state.video!.videoId) ??
              progress >= watchedProgressThreshold));
    }
  }

  @override
  Future<void> close() {
    playbackHistoryRevision.removeListener(updateProgress);
    return super.close();
  }

  void showVideoDetails() {
    if (state.video != null) {
      var video = state.video?.copyWith(filtered: false);
      emit(state.copyWith(video: video));
    }
  }
}

@freezed
sealed class VideoInListState with _$VideoInListState {
  @Assert('video == null || offlineVideo == null',
      'cannot provide both video and offline video')
  const factory VideoInListState(
      {@Default(0) double progress,
      @Default(false) bool watched,
      Video? video,
      DownloadedVideo? offlineVideo}) = _VideoInListState;
}
