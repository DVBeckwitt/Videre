import 'dart:async';

import 'package:clipious/utils/models/paginated_list.dart';
import 'package:clipious/utils/states/item_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Pages extends PaginatedList<int> {
  int moreCalls = 0;
  Future<List<int>> Function() initial = () async => [1];
  Future<List<int>> Function() more = () async => [2];

  @override
  Future<List<int>> getItems() => initial();

  @override
  Future<List<int>> getMoreItems() {
    moreCalls++;
    return more();
  }

  @override
  bool getHasMore() => true;

  @override
  bool hasRefresh() => true;

  @override
  Future<List<int>> refresh() => initial();
}

Future<ItemListCubit<int>> _loaded(_Pages pages) async {
  final cubit = ItemListCubit<int>(ItemListState(itemList: pages));
  await cubit.stream.firstWhere((state) => !state.loading);
  return cubit;
}

void main() {
  test('load-more future waits and overlapping requests load one page',
      () async {
    final next = Completer<List<int>>();
    final pages = _Pages()..more = () => next.future;
    final cubit = await _loaded(pages);
    addTearDown(cubit.close);

    var completed = false;
    final loading = cubit.getMoreItems().then((_) => completed = true);
    await cubit.getMoreItems();
    expect(pages.moreCalls, 1);
    expect(completed, isFalse);
    next.complete([2]);
    await loading;
    expect(cubit.state.items, [1, 2]);
    expect(cubit.state.loading, isFalse);
  });

  test('failed next page preserves loaded rows and can be retried', () async {
    final pages = _Pages()..more = () async => throw StateError('offline');
    final cubit = await _loaded(pages);
    addTearDown(cubit.close);

    await cubit.getMoreItems();
    expect(cubit.state.items, [1]);
    expect(cubit.state.error, ItemListErrors.couldNotFetchItems);
    expect(cubit.state.loading, isFalse);
    pages.more = () async => [2];
    await cubit.getMoreItems();
    expect(cubit.state.items, [1, 2]);
    expect(cubit.state.error, ItemListErrors.none);
  });

  test('closing a pending initial load ignores a late failure', () async {
    final first = Completer<List<int>>();
    final pages = _Pages()..initial = () => first.future;
    final cubit = ItemListCubit<int>(ItemListState(itemList: pages));
    await cubit.close();
    first.completeError(StateError('offline'));
    await Future<void>.delayed(Duration.zero);
    await cubit.getMoreItems();
    expect(pages.moreCalls, 0);
  });

  test('explicit refresh waits for a pending page and replaces stale rows',
      () async {
    final next = Completer<List<int>>();
    final pages = _Pages()..more = () => next.future;
    final cubit = await _loaded(pages);
    addTearDown(cubit.close);
    final loading = cubit.getMoreItems();
    pages.initial = () async => [3];
    final refresh = cubit.refreshItems();
    next.complete([2]);
    await loading;
    await refresh;
    expect(cubit.state.items, [3]);
  });

  testWidgets('scroll debounce belongs to each mounted list', (tester) async {
    final firstPages = _Pages();
    final secondPages = _Pages();
    final first = await _loaded(firstPages);
    final second = await _loaded(secondPages);
    await tester.pumpWidget(MaterialApp(
      home: Row(
        children: [
          for (final cubit in [first, second])
            Expanded(
              child: ListView.builder(
                controller: cubit.scrollController,
                itemExtent: 100,
                itemCount: 30,
                itemBuilder: (_, index) => Text('$index'),
              ),
            ),
        ],
      ),
    ));
    for (final cubit in [first, second]) {
      cubit.scrollController.jumpTo(
        cubit.scrollController.position.maxScrollExtent,
      );
    }
    await tester.pump(const Duration(milliseconds: 501));
    expect(firstPages.moreCalls, 1);
    expect(secondPages.moreCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await first.close();
    await second.close();
  });

  testWidgets('closing cancels a pending scroll request', (tester) async {
    final pages = _Pages();
    final cubit = await _loaded(pages);
    await tester.pumpWidget(MaterialApp(
      home: ListView.builder(
        controller: cubit.scrollController,
        itemExtent: 100,
        itemCount: 30,
        itemBuilder: (_, index) => Text('$index'),
      ),
    ));
    cubit.scrollController
        .jumpTo(cubit.scrollController.position.maxScrollExtent);
    await tester.pumpWidget(const SizedBox.shrink());
    await cubit.close();
    await tester.pump(const Duration(milliseconds: 501));
    expect(pages.moreCalls, 0);
    expect(tester.takeException(), isNull);
  });
}
