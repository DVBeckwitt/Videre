import 'package:bloc/bloc.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'tv_search.freezed.dart';

class TvSearchCubit extends Cubit<TvSearchState> {
  final FocusNode resultFocus = FocusNode();
  final FocusNode searchFocus = FocusNode();
  final ScrollController scrollController = ScrollController();

  TvSearchCubit(super.initialState);

  @override
  Future<void> close() {
    resultFocus.dispose();
    searchFocus.dispose();
    scrollController.dispose();
    return super.close();
  }

  KeyEventResult handleResultScopeKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent && event.logicalKey == LogicalKeyboardKey.goBack) {
      searchFocus.requestFocus();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Object? _resultScope;

  TvSearchState resultsFor(Object scope) =>
      scope == _resultScope ? state : const TvSearchState();

  void setHasVideo(Object scope, bool hasVideos) {
    if (isClosed) return;
    _updateResults(scope, resultsFor(scope).copyWith(hasVideos: hasVideos));
  }

  void setHasChannels(Object scope, bool hasChannels) {
    if (isClosed) return;
    _updateResults(scope, resultsFor(scope).copyWith(hasChannels: hasChannels));
  }

  void setHasPlaylists(Object scope, bool hasPlaylists) {
    if (isClosed) return;
    _updateResults(
        scope, resultsFor(scope).copyWith(hasPlaylists: hasPlaylists));
  }

  void _updateResults(Object scope, TvSearchState next) {
    _resultScope = scope;
    emit(next);
  }
}

@freezed
sealed class TvSearchState with _$TvSearchState {
  const factory TvSearchState(
      {@Default(false) bool hasVideos,
      @Default(false) bool hasChannels,
      @Default(false) bool hasPlaylists}) = _TvSearchState;
}
