import 'package:bloc/bloc.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/comments/models/video_comments.dart';

import '../../globals.dart';
import '../../settings/models/errors/invidious_service_error.dart';

part 'comments.freezed.dart';

class CommentsCubit extends Cubit<CommentsState> {
  bool _loading = false;

  CommentsCubit(super.initialState) {
    onReady();
  }

  void onReady() {
    getComments();
  }

  Future<void> loadMore() async {
    if (state.continuation != null) await getComments();
  }

  Future<void> getComments() async {
    if (_loading || isClosed) return;
    _loading = true;
    final previous = state;
    emit(state.copyWith(error: '', loadingComments: true));

    try {
      final comments = await service.getComments(previous.video.videoId,
          continuation: previous.continuation,
          sortBy: previous.sortBy,
          source: previous.source);
      if (isClosed) return;
      emit(state.copyWith(
          comments: VideoComments(
              comments.commentCount ?? previous.comments.commentCount,
              previous.video.videoId,
              comments.continuation,
              [...previous.comments.comments, ...comments.comments]),
          loadingComments: false,
          continuation: comments.continuation));
    } catch (err) {
      if (!isClosed) {
        // Leave the current page and continuation available for retry.
        emit(state.copyWith(
            loadingComments: false,
            error:
                err is InvidiousServiceError ? err.message : err.toString()));
      }
    } finally {
      _loading = false;
    }
  }
}

@freezed
sealed class CommentsState with _$CommentsState {
  const factory CommentsState(
      {required Video video,
      @Default(true) bool loadingComments,
      String? continuation,
      @Default(false) bool continuationLoaded,
      required VideoComments comments,
      @Default('') String error,
      String? source,
      String? sortBy}) = _CommentsState;

  static CommentsState init(
      {required Video video,
      bool? loadingComments,
      String? continuation,
      bool? continuationLoaded,
      String? error,
      String? source,
      String? sortBy}) {
    var comments = VideoComments(0, video.videoId, continuation, []);

    return CommentsState(
        video: video,
        comments: comments,
        loadingComments: loadingComments ?? true,
        continuation: continuation,
        continuationLoaded: continuationLoaded ?? false,
        error: error ?? '',
        source: source,
        sortBy: sortBy);
  }
}
