import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/search/models/db/search_history_item.dart';
import 'package:clipious/search/models/search_sort_by.dart';
import 'package:clipious/search/states/search_filter.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:logging/logging.dart';

import '../../settings/states/settings.dart';
import '../../settings/models/db/settings.dart';
import '../../network/content_link.dart';

part 'search.freezed.dart';

const _compactResultsSetting = 'video-search-compact-results';

class SearchCubit<T extends SearchState> extends Cubit<SearchState> {
  final SettingsCubit settings;
  final bool showSuggestionsWithResults;
  final compactResults = ValueNotifier<bool>(
      db.getSettings(_compactResultsSetting)?.value == 'true');
  Timer? _suggestionTimer;
  late String _query;
  String _submittedQuery = '';
  int _suggestionRequest = 0;

  String get submittedQuery => _submittedQuery;
  bool get canRestoreResults =>
      _submittedQuery.isNotEmpty && !state.showResults;

  SearchCubit(super.initialState, this.settings,
      {this.showSuggestionsWithResults = false}) {
    onInit();
  }

  void onInit() {
    _query = state.queryController.text;
    if (state.showResults) _submittedQuery = _query.trim();
    state.queryController.addListener(getSuggestions);
    getHistory();
    if (state.searchNow) {
      search(state.queryController.value.text);
    }
  }

  @override
  Future<void> close() {
    _suggestionTimer?.cancel();
    compactResults.dispose();
    state.queryController.dispose();
    return super.close();
  }

  Future<void> toggleResultLayout() async {
    final compact = !compactResults.value;
    compactResults.value = compact;
    await db
        .forProfile(db.profileId)
        .saveSetting(SettingsValue(_compactResultsSetting, '$compact'));
  }

  void onFiltersChanged(SearchFiltersState newValue) {
    emit(state.copyWith(filters: newValue));
  }

  void editQuery() {
    if (state.showResults) emit(state.copyWith(showResults: false));
  }

  // Flow SearchScreen.kt's BackHandler restores the submitted query and its
  // results when Back is pressed during an edit. No search is submitted here.
  bool restoreResults() {
    if (!canRestoreResults) return false;
    _setQueryWithoutSuggestions(_submittedQuery);
    emit(state.copyWith(showResults: true, suggestions: const []));
    return true;
  }

  void _setQueryWithoutSuggestions(String query) {
    _suggestionTimer?.cancel();
    _suggestionRequest++;
    _query = query;
    if (state.queryController.text != query) {
      state.queryController.value = TextEditingValue(
          text: query,
          selection: TextSelection.collapsed(offset: query.length));
    }
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

  void getSuggestions({bool hideResult = true}) {
    final query = state.queryController.text;
    // Moving the cursor should not dismiss the results.
    if (query == _query) return;
    _query = query;
    final request = ++_suggestionRequest;
    _suggestionTimer?.cancel();
    emit(state.copyWith(showResults: !hideResult, suggestions: []));
    if (query.isEmpty ||
        settings.state.distractionFreeMode ||
        ContentLink.parseAddress(query,
                server: settings.appCubit.state.server) !=
            null) {
      return;
    }

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
    final query = value.trim();
    if (query.isEmpty) return;
    if (settings.appCubit.tryOpenPastedAppLink(query)) {
      _setQueryWithoutSuggestions(query);
      if (state.suggestions.isNotEmpty) {
        emit(state.copyWith(suggestions: const []));
      }
      return;
    }
    _submittedQuery = query;
    if (!showSuggestionsWithResults) {
      _setQueryWithoutSuggestions(query);
    } else if (state.queryController.text != query) {
      state.queryController.value = TextEditingValue(
          text: query,
          selection: TextSelection.collapsed(offset: query.length));
    }
    emit(state.copyWith(
      showResults: true,
      suggestions: showSuggestionsWithResults ? state.suggestions : const [],
    ));

    if (settings.state.useSearchHistory) {
      final recommendations =
          RecommendationService.forProfile(db, db.profileId);
      final generation = recommendations.generation(RecommendationDomain.video);
      await db.addToSearchHistory(SearchHistoryItem(
          query, (DateTime.now().millisecondsSinceEpoch / 1000).round()));
      try {
        await recommendations.recordSearch(query, RecommendationDomain.video,
            expectedGeneration: generation);
      } catch (_) {
        // Search remains usable if optional local learning cannot checkpoint.
        Logger('SearchCubit').fine('Local recommendation learning unavailable');
      }
    }
    getHistory();
  }

  void setSearchQuery(String e) {
    unawaited(search(e));
  }

  Future<void> removeFromHistory(String e) async {
    await db.deleteFromSearchHistory(e);
    getHistory();
  }

  Future<void> clearHistory() async {
    await db.clearSearchHistory();
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
      bool? searchNow,
      List<String>? suggestions,
      SearchSortBy? sortBy,
      bool? showResults,
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
