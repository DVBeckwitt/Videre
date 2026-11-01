import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';

import '../models/paginated_list.dart';

part 'item_list.freezed.dart';

enum ItemListErrors { none, couldNotFetchItems, invalidScope }

class ItemListCubit<T> extends Cubit<ItemListState<T>> {
  final ScrollController scrollController = ScrollController();
  Timer? _loadMoreTimer;
  bool _loading = false;
  Completer<void>? _loadComplete;

  ItemListCubit(super.initialState) {
    onReady();
  }

  @override
  Future<void> close() {
    _loadMoreTimer?.cancel();
    scrollController.dispose();
    return super.close();
  }

  void onReady() {
    getItems();
    scrollController.addListener(onScrollEvent);
  }

  void onScrollEvent() {
    if (!isClosed && !_loading && state.itemList.getHasMore()) {
      if (!scrollController.hasClients) return;
      if (scrollController.position.maxScrollExtent * 0.9 <
          scrollController.offset) {
        _loadMoreTimer?.cancel();
        _loadMoreTimer = Timer(const Duration(milliseconds: 500), getMoreItems);
      }
    }
  }

  Future<void> getMoreItems() async {
    if (!isClosed && !_loading && state.itemList.getHasMore()) {
      await loadItems(() async {
        List<T> items = await state.itemList.getMoreItems();
        List<T> currentItems = List.from(state.items)..addAll(items);
        return currentItems;
      });
    }
  }

  Future<void> refreshItems() async {
    await _loadComplete?.future;
    await loadItems(state.itemList.refresh);
  }

  Future<void> getItems() async {
    await loadItems(state.itemList.getItems);
  }

  Future<void> loadItems(Future<List<T>> Function() refreshFunction) async {
    if (isClosed || _loading) return;
    _loadMoreTimer?.cancel();
    _loading = true;
    final completion = _loadComplete = Completer<void>();
    emit(state.copyWith(error: ItemListErrors.none, loading: true));
    try {
      var items = await refreshFunction();
      if (!isClosed) {
        emit(state.copyWith(loading: false, items: items));
      }
    } catch (err) {
      late ItemListErrors error;
      if (err is InvidiousServiceError && err.message == "Invalid scope") {
        error = ItemListErrors.invalidScope;
      } else {
        error = ItemListErrors.couldNotFetchItems;
      }
      if (!isClosed) {
        emit(state.copyWith(error: error, loading: false));
      }
    } finally {
      _loading = false;
      _loadComplete = null;
      completion.complete();
    }
  }
}

@freezed
sealed class ItemListState<T> with _$ItemListState<T> {
  const factory ItemListState({
    required PaginatedList<T> itemList,
    @Default([]) List<T> items,
    @Default(true) bool loading,
    @Default(ItemListErrors.none) ItemListErrors error,
  }) = _ItemListState<T>;
}
