import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/search/models/db/search_history_item.dart';
import 'package:clipious/search/models/search_sort_by.dart';
import 'package:clipious/search/states/search_filter.dart';

import '../../channels/models/channel.dart';
import '../../playlists/models/playlist.dart';
import '../../settings/states/settings.dart';

part 'search.freezed.dart';

class SearchCubit<T extends SearchState> extends Cubit<SearchState> {
  final SettingsCubit settings;
  Timer? _suggestionTimer;
  late String _query;
  int _suggestionRequest = 0;

  SearchCubit(super.initialState, this.settings) {
    onInit();
  }

  void onInit() {
    _query = state.queryController.text;
    state.queryController.addListener(getSuggestions);
    getHistory();
    if (state.searchNow) {
      search(state.queryController.value.text);
    }
  }

  @override
  Future<void> close() {
    _suggestionTimer?.cancel();
    state.queryController.dispose();
    return super.close();
  }

  void onFiltersChanged(SearchFiltersState newValue) {
    emit(state.copyWith(filters: newValue));
  }

  // returns true search is already cleared
  bool searchCleared() {
    if (state.queryController.value.text.isEmpty) {
      return true;
    } else {
      state.queryController.clear();
      emit(state.copyWith(showResults: false));
      return false;
    }
  }

  void clearSearch() {
    emit(state.copyWith(showResults: false));
  }

  void getSuggestions({bool hideResult = true}) {
    final query = state.queryController.text;
    // Moving the cursor should not dismiss the results.
    if (query == _query) return;
    _query = query;
    final request = ++_suggestionRequest;
    _suggestionTimer?.cancel();
    emit(state.copyWith(showResults: !hideResult, suggestions: []));
    if (query.isEmpty || settings.state.distractionFreeMode) return;

    _suggestionTimer = Timer(const Duration(milliseconds: 500), () async {
      try {
        final result = await service.getSearchSuggestion(query);
        if (!isClosed && request == _suggestionRequest) {
          emit(state.copyWith(suggestions: result.suggestions));
        }
      } catch (_) {
        // Suggestions are optional; keep search usable if the instance fails.
      }
    });
  }

  void getHistory() {
    if (isClosed) return;
    emit(state.copyWith(
        searchHistory:
            settings.state.useSearchHistory ? db.getSearchHistory() : []));
  }

  Future<void> search(String value) async {
    emit(state.copyWith(showResults: true));

    final query = state.queryController.text;
    if (query.isNotEmpty && settings.state.useSearchHistory) {
      await db.addToSearchHistory(SearchHistoryItem(
          query, (DateTime.now().millisecondsSinceEpoch / 1000).round()));
    }
    getHistory();
  }

  void setSearchQuery(String e) {
    state.queryController.text = e;
    search(e);
  }

  Future<void> removeFromHistory(String e) async {
    await db.deleteFromSearchHistory(e);
    getHistory();
  }
}

@freezed
sealed class SearchState with _$SearchState {
  const factory SearchState(
          {required TextEditingController queryController,
          @Default(false) bool searchNow,
          @Default([]) List<String> suggestions,
          @Default(SearchSortBy.relevance) SearchSortBy sortBy,
          @Default(false) bool showResults,
          @Default(1) int videoPage,
          @Default(1) int channelPage,
          @Default(1) int playlistPage,
          @Default([]) List<String> searchHistory,
          @Default(SearchFiltersState()) SearchFiltersState filters}) =
      _SearchState;

  static SearchState init(
      {TextEditingController? queryController,
      int? selectedIndex,
      List<Video>? videos,
      List<Channel>? channels,
      List<Playlist>? playlists,
      bool? useHistory,
      bool? searchNow,
      List<String>? suggestions,
      SearchSortBy? sortBy,
      bool? showResults,
      bool? loading,
      int? videoPage,
      channelPage,
      playlistPage,
      String? query}) {
    return SearchState(
        queryController:
            queryController ?? TextEditingController(text: query ?? ''),
        searchNow: searchNow ?? false,
        suggestions: suggestions ?? [],
        sortBy: sortBy ?? SearchSortBy.relevance,
        showResults: showResults ?? false,
        videoPage: videoPage ?? 1,
        channelPage: channelPage ?? 1,
        playlistPage: playlistPage ?? 1);
  }
}
