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
  final Future<bool?> Function()? chooseOpen;
  final bool Function()? isLinkSourceActive;
  final compactResults = ValueNotifier<bool>(
      db.getSettings(_compactResultsSetting)?.value == 'true');
  Timer? _suggestionTimer;
  late String _query;
  String _submittedQuery = '';
  Object _resultScope = Object();
  int _suggestionRequest = 0;

  String get submittedQuery => _submittedQuery;
  Object get resultScope => _resultScope;
  bool isShowingResultsFor(Object scope) =>
      !isClosed && state.showResults && _resultScope == scope;
  bool get canRestoreResults =>
      _submittedQuery.isNotEmpty && !state.showResults;

  SearchCubit(super.initialState, this.settings,
      {this.showSuggestionsWithResults = false,
      this.chooseOpen,
      this.isLinkSourceActive}) {
    onInit();
  }

  void onInit() {
    _query = state.queryController.text;
    if (state.showResults) _submittedQuery = _query.trim();
    state.queryController.addListener(getSuggestions);
    getHistory();
    if (state.searchNow) {
      // A search route already specifies the action. Its query can contain a
      // URL, but only a new submission can ask to open that URL.
      unawaited(_submit(state.queryController.text, checkForLink: false));
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
        ContentLink.completeWebAddress(query) != null) {
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

  Future<void> search(String value) => _submit(value, checkForLink: true);

  Future<void> _submit(String value, {required bool checkForLink}) async {
    final query = value.trim();
    if (query.isEmpty) return;
    var recordHistory = true;
    if (checkForLink && ContentLink.completeWebAddress(query) != null) {
      // Ignore a second IME submission while the choice dialog has focus.
      if (isLinkSourceActive?.call() == false) return;
      _setQueryWithoutSuggestions(query);
      final request = _suggestionRequest;
      bool current() =>
          !isClosed &&
          request == _suggestionRequest &&
          (isLinkSourceActive?.call() ?? true);
      if (state.suggestions.isNotEmpty) {
        emit(state.copyWith(suggestions: const []));
      }
      final action = await settings.appCubit.submitPastedAppLink(query,
          chooseOpen: chooseOpen, isCurrent: current);
      if (!current() || action == PastedLinkAction.handled) return;
      if (action == PastedLinkAction.searchAsText) recordHistory = false;
    }
    if (query != _submittedQuery || !state.showResults) {
      _resultScope = Object();
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

    if (recordHistory && settings.state.useSearchHistory) {
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
