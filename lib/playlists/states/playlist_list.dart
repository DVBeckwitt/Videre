import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/utils/models/paginated_list.dart';

import '../models/playlist.dart';

part 'playlist_list.freezed.dart';

const couldNotGetPlaylits = 'could-not-get-playlists';

class PlaylistListCubit extends Cubit<PlaylistListState> {
  final ScrollController scrollController = ScrollController();
  Timer? _loadMoreTimer;
  bool _loading = false;
  Completer<void>? _loadComplete;
  PlaylistListCubit(super.initialState) {
    onReady();
  }

  void onReady() {
    scrollController.addListener(onScrollEvent);
    getPlaylists();
  }

  void onScrollEvent() {
    if (isClosed ||
        _loading ||
        !scrollController.hasClients ||
        !state.paginatedList.getHasMore()) return;
    if (scrollController.offset >=
        scrollController.position.maxScrollExtent * 0.9) {
      _loadMoreTimer?.cancel();
      _loadMoreTimer =
          Timer(const Duration(milliseconds: 500), getMorePlaylists);
    }
  }

  Future<void> getMorePlaylists() async {
    if (!isClosed && state.paginatedList.getHasMore()) {
      await loadPlaylist(() async {
        final playlists = await state.paginatedList.getMoreItems();
        return [...state.playlists, ...playlists];
      });
    }
  }

  Future<void> refreshPlaylists() async {
    await _loadComplete?.future;
    await loadPlaylist(state.paginatedList.refresh);
  }

  Future<void> getPlaylists() async {
    await loadPlaylist(state.paginatedList.getItems);
  }

  Future<void> loadPlaylist(
      Future<List<Playlist>> Function() refreshFunction) async {
    if (_loading || isClosed) return;
    _loading = true;
    final completed = _loadComplete = Completer<void>();
    _loadMoreTimer?.cancel();
    emit(state.copyWith(error: '', loading: true));
    try {
      final playlists = await refreshFunction();
      if (!isClosed) {
        emit(state.copyWith(playlists: playlists, loading: false));
      }
    } catch (_) {
      if (!isClosed) {
        emit(state.copyWith(error: couldNotGetPlaylits, loading: false));
      }
    } finally {
      _loading = false;
      _loadComplete = null;
      completed.complete();
    }
  }

  @override
  Future<void> close() {
    _loadMoreTimer?.cancel();
    scrollController.dispose();
    return super.close();
  }
}

@freezed
sealed class PlaylistListState with _$PlaylistListState {
  const factory PlaylistListState(
      {required PaginatedList<Playlist> paginatedList,
      @Default([]) List<Playlist> playlists,
      @Default(true) bool loading,
      @Default('') String error}) = _PlaylistListState;
}
