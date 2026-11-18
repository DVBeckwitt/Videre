import 'package:bloc/bloc.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/extensions.dart';
import 'package:logging/logging.dart';
import 'package:clipious/recommendations/recommendation_service.dart';

import '../../globals.dart';
import '../../playlists/models/playlist.dart';

part 'add_to_playlist.freezed.dart';

const String likePlaylistName = '❤️';

class AddToPlaylistCubit extends Cubit<AddToPlaylistController> {
  final log = Logger('AddToPlaylistcubit');
  final Video? video;

  AddToPlaylistCubit(super.initialState, {this.video}) {
    onReady();
  }

  Future<void> addToPlaylist(String playlistId) async {
    final owner = RecommendationService.forProfile(db, db.profileId);
    final generation = owner.generation(_recommendationDomain);
    final alreadySaved = state.playlists.any((playlist) =>
        playlist.playlistId == playlistId &&
        playlist.videos.any((item) => item.videoId == state.videoId));
    await service.addVideoToPlaylist(playlistId, state.videoId, video: video);
    if (!alreadySaved) {
      await _recordPreference(owner, RecommendationFeedback.save, generation);
    }
    await onReady();
  }

  RecommendationDomain get _recommendationDomain => video?.musicMetadata == null
      ? RecommendationDomain.video
      : RecommendationDomain.music;

  Future<void> _recordPreference(RecommendationService owner,
      RecommendationFeedback feedback, int generation) async {
    final item = video;
    if (item == null || !owner.learningEnabled(_recommendationDomain)) return;
    try {
      await owner.feedback(item, _recommendationDomain, feedback,
          expectedGeneration: generation);
    } catch (_) {
      log.fine('Local recommendation learning unavailable');
    }
  }

  Future<void> onReady() async {
    if (isClosed) return;
    await getAllPlaylists();
    await countPlaylistsForVideo();
    await checkVideoLikeStatus();
  }

  Future<void> getAllPlaylists() async {
    emit(state.copyWith(loading: true));
    final playlists = await service.getUserPlaylists(postProcessing: false);
    if (!isClosed) emit(state.copyWith(playlists: playlists, loading: false));
  }

  Future<Playlist?> likePlaylist() async {
    Playlist? pl =
        state.playlists.firstWhereOrNull((pl) => pl.title == likePlaylistName);

    return pl;
  }

  Future<void> checkVideoLikeStatus() async {
    Playlist? p = await likePlaylist();
    Video? video = p?.videos
        .firstWhereOrNull((element) => element.videoId == state.videoId);

    bool isVideoLiked = video != null;

    if (!isClosed) {
      emit(state.copyWith(isVideoLiked: isVideoLiked));
      log.fine('video is currently liked ? $state.isVideoLiked');
    }
  }

  Future<Playlist?> createPlayList() async {
    await service.createPlayList(likePlaylistName, 'local');
    await onReady();
    return likePlaylist();
  }

  Future<void> countPlaylistsForVideo() async {
    int playListCount = state.playlists
        .where((list) =>
            list.videos.indexWhere((video) => video.videoId == state.videoId) >=
            0)
        .length;
    log.fine('playlist count ${state.playListCount}');
    if (!isClosed) {
      emit(state.copyWith(playListCount: playListCount));
    }
  }

  Future<void> toggleLike() async {
    final owner = RecommendationService.forProfile(db, db.profileId);
    final generation = owner.generation(_recommendationDomain);
    emit(state.copyWith(loading: true));

    await onReady();
    Playlist? p = await likePlaylist();
    p ??= await createPlayList();

    if (p != null) {
      if (state.isVideoLiked) {
        log.fine('Video is liked, unliking it');
        Video? v = p.videos
            .firstWhereOrNull((element) => element.videoId == state.videoId);
        final indexId = p.isLocal ? v?.videoId : v?.indexId;
        if (indexId != null) {
          await service.deleteUserPlaylistVideo(p.playlistId, indexId);
        }
      } else {
        log.fine('Video is not liked yet, we add it to the like playlist');
        await service.addVideoToPlaylist(p.playlistId, state.videoId,
            video: video);
        await _recordPreference(owner, RecommendationFeedback.like, generation);
      }
    }
    if (!isClosed) await onReady();
  }

  Future<void> saveVideoToPlaylist(String selectedPlaylistId) async {
    await addToPlaylist(selectedPlaylistId);
  }
}

@freezed
sealed class AddToPlaylistController with _$AddToPlaylistController {
  const factory AddToPlaylistController(String videoId,
      {@Default([]) List<Playlist> playlists,
      @Default(0) int playListCount,
      @Default(false) bool isVideoLiked,
      @Default(true) bool loading,
      @Default(false) bool isLoggedIn}) = _AddToPlaylistController;
}
