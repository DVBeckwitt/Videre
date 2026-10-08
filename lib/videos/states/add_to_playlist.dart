import 'package:bloc/bloc.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/extensions.dart';
import 'package:logging/logging.dart';

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

  addToPlaylist(String playlistId) async {
    await service.addVideoToPlaylist(playlistId, state.videoId, video: video);
    await onReady();
  }

  Future<void> onReady() async {
    if (isClosed) return;
    await getAllPlaylists();
    await countPlaylistsForVideo();
    await checkVideoLikeStatus();
  }

  getAllPlaylists() async {
    emit(state.copyWith(loading: true));
    final playlists = await service.getUserPlaylists(postProcessing: false);
    if (!isClosed) emit(state.copyWith(playlists: playlists, loading: false));
  }

  Future<Playlist?> likePlaylist() async {
    Playlist? pl =
        state.playlists.firstWhereOrNull((pl) => pl.title == likePlaylistName);

    return pl;
  }

  checkVideoLikeStatus() async {
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

  countPlaylistsForVideo() async {
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
      }
    }
    if (!isClosed) await onReady();
  }

  saveVideoToPlaylist(String selectedPlaylistId) async {
    await service.addVideoToPlaylist(selectedPlaylistId, state.videoId,
        video: video);
    await onReady();
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
