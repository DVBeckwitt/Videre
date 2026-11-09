import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/network/nerdvpn_access.dart';

import '../models/paginated_list.dart';

part 'item_list.freezed.dart';

enum ItemListErrors {
  none,
  couldNotFetchItems,
  invalidScope,
  nerdVpnApprovalPending
}

class ItemListCubit<T> extends Cubit<ItemListState<T>> {
  final ScrollController scrollController = ScrollController();
  Timer? _loadMoreTimer;
  bool _loading = false;
  Completer<void>? _loadComplete;
  Future<List<T>> Function()? _failedLoad;
  late List<T> _items;

  ItemListCubit(super.initialState) {
    _items = state.items;
    state.itemList.changes?.addListener(_visibilityChanged);
    onReady();
  }

  void _visibilityChanged() {
    if (!isClosed) {
      emit(state.copyWith(items: state.itemList.visibleItems(_items)));
    }
  }

  @override
  Future<void> close() {
    state.itemList.changes?.removeListener(_visibilityChanged);
    _loadMoreTimer?.cancel();
    _failedLoad = null;
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
        List<T> currentItems = List.from(_items)..addAll(items);
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

  /// Retry the failed request without resetting its page or continuation.
  Future<void> retryItems() async {
    final request = _failedLoad;
    if (request != null) await loadItems(request);
  }

  Future<void> loadItems(Future<List<T>> Function() refreshFunction) async {
    if (isClosed || _loading) return;
    _loadMoreTimer?.cancel();
    _loading = true;
    _failedLoad = null;
    final completion = _loadComplete = Completer<void>();
    emit(state.copyWith(error: ItemListErrors.none, loading: true));
    try {
      var items = await refreshFunction();
      if (!isClosed) {
        _items = items;
        emit(state.copyWith(
            loading: false, items: state.itemList.visibleItems(items)));
      }
    } catch (err) {
      late ItemListErrors error;
      if (err is NerdVpnAccessRequired && err.state == 'waiting') {
        error = ItemListErrors.nerdVpnApprovalPending;
      } else if (err is InvidiousServiceError &&
          err.message == "Invalid scope") {
        error = ItemListErrors.invalidScope;
      } else {
        error = ItemListErrors.couldNotFetchItems;
      }
      if (!isClosed) {
        _failedLoad = refreshFunction;
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
