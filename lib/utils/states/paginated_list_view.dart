import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/utils/models/paginated_list.dart';
import 'package:logging/logging.dart';

part 'paginated_list_view.freezed.dart';

class PaginatedListCubit<T> extends Cubit<PaginatedListViewController<T>> {
  final ScrollController scrollController = ScrollController();
  final _log = Logger('PaginatedListCubit');
  Timer? _loadMoreTimer;
  bool _loading = false;
  Future<List<T>> Function()? _failedLoad;

  PaginatedListCubit(super.initialState) {
    onInit();
  }

  void onInit() {
    scrollController.addListener(getMore);
    getItems();
  }

  @override
  Future<void> close() {
    _loadMoreTimer?.cancel();
    _failedLoad = null;
    scrollController.dispose();
    return super.close();
  }

  Future<void> getItems() => _loadItems(state.paginatedList.getItems);

  Future<void> retry() async {
    final load = _failedLoad;
    if (load != null) await _loadItems(load);
  }

  Future<void> getMoreItems() async {
    if (!isClosed && state.paginatedList.getHasMore()) {
      await _loadItems(() async {
        final items = await state.paginatedList.getMoreItems();
        return [...state.items, ...items];
      });
    }
  }

  void getMore() {
    if (isClosed ||
        _loading ||
        !scrollController.hasClients ||
        !state.paginatedList.getHasMore()) return;
    if (scrollController.offset >=
        scrollController.position.maxScrollExtent * 0.9) {
      _loadMoreTimer?.cancel();
      _loadMoreTimer = Timer(const Duration(milliseconds: 250), getMoreItems);
    }
  }

  Future<void> _loadItems(Future<List<T>> Function() load) async {
    if (_loading || isClosed) return;
    _loading = true;
    _loadMoreTimer?.cancel();
    _failedLoad = null;
    emit(state.copyWith(loading: true, hasError: false));
    try {
      final items = await load();
      if (!isClosed) emit(state.copyWith(loading: false, items: items));
    } catch (error) {
      _log.warning('Unable to load items', error);
      if (!isClosed) {
        _failedLoad = load;
        emit(state.copyWith(loading: false, hasError: true));
      }
    } finally {
      _loading = false;
    }
  }
}

@freezed
sealed class PaginatedListViewController<T>
    with _$PaginatedListViewController<T> {
  const factory PaginatedListViewController(
      {required PaginatedList<T> paginatedList,
      @Default([]) List<T> items,
      @Default(false) bool hasError,
      @Default(false) bool loading}) = _PaginatedListViewController<T>;

  static PaginatedListViewController<V> init<V>(
      {required PaginatedList<V> paginatedList, List<V>? startItems}) {
    return PaginatedListViewController<V>(
        paginatedList: paginatedList, items: startItems ?? []);
  }
}
