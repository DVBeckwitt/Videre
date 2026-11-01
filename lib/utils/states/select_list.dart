import 'package:bloc/bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:logging/logging.dart';

part 'select_list.freezed.dart';

class SelectListCubit<T> extends Cubit<SelectListState<T>> {
  int _request = 0;

  SelectListCubit(super.initialState);

  Future<void> filterItems(
      Future<List<T>> Function(String filter)? asyncSearch,
      bool Function(String filter, T value)? searchFilter,
      List<T>? values,
      String searchQuery) async {
    if (isClosed) return;
    final request = ++_request;
    emit(state.copyWith(loading: true, hasError: false));
    try {
      final List<T> result;
      if (searchFilter != null && values != null) {
        result = values
            .where((element) => searchFilter(searchQuery, element))
            .toList();
      } else if (asyncSearch != null) {
        result = await asyncSearch(searchQuery);
      } else {
        result = values ?? [];
      }
      if (!isClosed && request == _request) {
        emit(state.copyWith(filteredItems: result, loading: false));
      }
    } catch (error, stackTrace) {
      if (!isClosed && request == _request) {
        Logger('SelectList')
            .warning('Unable to search items', error, stackTrace);
        emit(state.copyWith(loading: false, hasError: true));
      }
    }
  }
}

@freezed
sealed class SelectListState<T> with _$SelectListState<T> {
  const factory SelectListState(
      {@Default([]) List<T> filteredItems,
      @Default(false) bool loading,
      @Default(false) bool hasError}) = _SelectListState<T>;
}
