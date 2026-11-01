import 'dart:async';

import 'package:clipious/channels/models/channel_videos.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/states/playlist_list.dart';
import 'package:clipious/utils/models/paginated_list.dart';
import 'package:clipious/utils/states/paginated_list_view.dart';
import 'package:clipious/utils/views/components/paginated_list_view.dart';
import 'package:clipious/utils/views/tv/components/tv_horizontal_paginated_list.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _DeferredList<T> extends PaginatedList<T> {
  final requests = <Completer<List<T>>>[];
  bool hasMore = true;

  @override
  Future<List<T>> getItems() {
    final response = Completer<List<T>>();
    requests.add(response);
    return response.future;
  }

  @override
  Future<List<T>> getMoreItems() => getItems();

  @override
  Future<List<T>> refresh() => getItems();

  @override
  bool getHasMore() => hasMore;

  @override
  bool hasRefresh() => true;
}

const _first = Playlist(
    title: 'First', playlistId: 'first', author: 'Author', videoCount: 0);
const _second = Playlist(
    title: 'Second', playlistId: 'second', author: 'Author', videoCount: 0);

Future<void> _flush() => Future<void>.delayed(Duration.zero);

Widget _scrollViews(List<ScrollController> controllers) => MaterialApp(
      home: Row(
        children: [
          for (final controller in controllers)
            Expanded(
              child: ListView(
                controller: controller,
                children: const [SizedBox(height: 2000)],
              ),
            ),
        ],
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('page refresh preserves loaded pages on fixed-size endpoints', () async {
    final requests = <(int, int)>[];
    final list = PageBasedPaginatedList<int>(
      maxResults: 2,
      getItemsFunc: (page, maxResults) async {
        requests.add((page, maxResults));
        return [page * 2 - 1, page * 2];
      },
    );
    await list.getItems();
    await list.getMoreItems();
    expect(await list.refresh(), [1, 2, 3, 4]);
    expect(requests, [(1, 2), (2, 2), (1, 2), (2, 2)]);
    expect(await list.getMoreItems(), [5, 6]);
  });

  test('page refresh updates exhaustion when the source grows or shrinks',
      () async {
    var items = [1];
    final list = PageBasedPaginatedList<int>(
      maxResults: 2,
      getItemsFunc: (page, maxResults) async =>
          items.skip((page - 1) * maxResults).take(maxResults).toList(),
    );
    await list.getItems();
    expect(list.getHasMore(), isFalse);
    items = [1, 2, 3, 4, 5];
    expect(await list.refresh(), [1, 2]);
    expect(list.getHasMore(), isTrue);
    await list.getMoreItems();
    await list.getMoreItems();
    expect(list.getHasMore(), isFalse);
    items = [1, 2, 3];
    expect(await list.refresh(), [1, 2, 3]);
    expect(list.page, 2);
    expect(list.getHasMore(), isFalse);
  });

  test('failed page refresh preserves the previous pagination cursor',
      () async {
    var fail = false;
    final list = PageBasedPaginatedList<int>(
      maxResults: 2,
      getItemsFunc: (page, maxResults) async {
        if (fail && page == 2) throw StateError('offline');
        return page == 3 ? [5] : [page * 2 - 1, page * 2];
      },
    );
    await list.getItems();
    await list.getMoreItems();
    await list.getMoreItems();
    fail = true;
    await expectLater(list.refresh(), throwsStateError);
    expect(list.page, 3);
    expect(list.getHasMore(), isFalse);
    fail = false;
    expect(await list.refresh(), [1, 2, 3, 4, 5]);
  });

  test('failed continuation refresh preserves the previous next page',
      () async {
    final requested = <String?>[];
    var fail = false;
    final list = ContinuationList<Video>((continuation) async {
      requested.add(continuation);
      if (fail) throw StateError('offline');
      return VideosWithContinuation(
          [Video(videoId: 'video')], continuation == null ? 'next' : null);
    });
    await list.getItems();
    fail = true;
    await expectLater(list.refresh(), throwsStateError);
    expect(list.getHasMore(), isTrue);
    fail = false;
    await list.getMoreItems();
    expect(requested, [null, null, 'next']);
    expect(list.getHasMore(), isFalse);
  });

  test('playlist pagination appends without mutating prior state', () async {
    final list = _DeferredList<Playlist>();
    final cubit = PlaylistListCubit(PlaylistListState(paginatedList: list));
    addTearDown(cubit.close);
    list.requests.single.complete([_first]);
    await _flush();
    final previous = cubit.state;

    final loading = cubit.getMorePlaylists();
    await cubit.getMorePlaylists();
    expect(list.requests, hasLength(2));
    list.requests.last.complete([_second]);
    await loading;

    expect(previous.playlists, [_first]);
    expect(cubit.state.playlists, [_first, _second]);
    expect(cubit.state.loading, isFalse);
    expect(cubit.state.error, isEmpty);
  });

  test('playlist failure keeps loaded rows and completes an awaited retry',
      () async {
    final list = _DeferredList<Playlist>();
    final cubit = PlaylistListCubit(PlaylistListState(paginatedList: list));
    addTearDown(cubit.close);
    list.requests.single.complete([_first]);
    await _flush();

    final loading = cubit.getMorePlaylists();
    list.requests.last.completeError(StateError('offline'));
    await loading;
    expect(cubit.state.playlists, [_first]);
    expect(cubit.state.loading, isFalse);
    expect(cubit.state.error, couldNotGetPlaylits);

    var refreshed = false;
    final refresh = cubit.refreshPlaylists().then((_) => refreshed = true);
    await _flush();
    expect(refreshed, isFalse);
    list.requests.last.complete([_second]);
    await refresh;
    expect(cubit.state.playlists, [_second]);
    expect(cubit.state.error, isEmpty);
  });

  test('generic pagination serializes loads and retains items on failure',
      () async {
    final list = _DeferredList<int>();
    final cubit = PaginatedListCubit<int>(
        PaginatedListViewController.init(paginatedList: list));
    addTearDown(cubit.close);
    await cubit.getMoreItems();
    expect(list.requests, hasLength(1));
    list.requests.single.complete([1]);
    await _flush();

    final loading = cubit.getMoreItems();
    await cubit.getMoreItems();
    expect(list.requests, hasLength(2));
    list.requests.last.completeError(StateError('offline'));
    await loading;
    expect(cubit.state.items, [1]);
    expect(cubit.state.loading, isFalse);
    expect(cubit.state.hasError, isTrue);

    final retry = cubit.retry();
    list.requests.last.complete([2]);
    await retry;
    expect(cubit.state.items, [1, 2]);
    expect(cubit.state.hasError, isFalse);
  });

  test('playlist refresh waits for pagination before replacing stale rows',
      () async {
    final list = _DeferredList<Playlist>();
    final cubit = PlaylistListCubit(PlaylistListState(paginatedList: list));
    addTearDown(cubit.close);
    list.requests.single.complete([_first]);
    await _flush();
    final more = cubit.getMorePlaylists();
    final refresh = cubit.refreshPlaylists();
    expect(list.requests, hasLength(2));
    list.requests.last.complete([_second]);
    await more;
    await _flush();
    expect(list.requests, hasLength(3));
    list.requests.last.complete([_second]);
    await refresh;
    expect(cubit.state.playlists, [_second]);
  });

  for (final isTv in [false, true]) {
    testWidgets('${isTv ? 'TV' : 'phone'} list can retry an initial failure',
        (tester) async {
      final list = _DeferredList<int>();
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: isTv
              ? TvHorizontalPaginatedListView<int>(
                  paginatedList: list,
                  itemBuilder: (item) => Text('Item $item'),
                  getPlaceHolder: () => const SizedBox(width: 20),
                )
              : PaginatedListView<int>(
                  paginatedList: list,
                  itemBuilder: (item) => Text('Item $item'),
                ),
        ),
      ));
      list.requests.single.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      expect(list.requests, hasLength(2));
      list.requests.last.complete([1]);
      await tester.pumpAndSettle();
      expect(find.text('Item 1'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });
  }

  for (final fails in [false, true]) {
    test('closed lists ignore late ${fails ? 'failures' : 'responses'}',
        () async {
      final playlists = _DeferredList<Playlist>();
      final playlistCubit =
          PlaylistListCubit(PlaylistListState(paginatedList: playlists));
      final items = _DeferredList<int>();
      final itemCubit = PaginatedListCubit<int>(
          PaginatedListViewController.init(paginatedList: items));
      await playlistCubit.close();
      await itemCubit.close();
      if (fails) {
        playlists.requests.single.completeError(StateError('offline'));
        items.requests.single.completeError(StateError('offline'));
      } else {
        playlists.requests.single.complete([_first]);
        items.requests.single.complete([1]);
      }
      await _flush();
      await playlistCubit.getMorePlaylists();
      await itemCubit.getMoreItems();
      expect(playlists.requests, hasLength(1));
      expect(items.requests, hasLength(1));
    });
  }

  testWidgets('playlist lists independently load after passing 90 percent',
      (tester) async {
    final lists = [_DeferredList<Playlist>(), _DeferredList<Playlist>()];
    final cubits = [
      for (final list in lists)
        PlaylistListCubit(PlaylistListState(paginatedList: list)),
    ];
    for (final cubit in cubits) {
      addTearDown(cubit.close);
    }
    for (final list in lists) {
      list.requests.single.complete([_first]);
    }
    await tester.pump();
    await tester.pumpWidget(
        _scrollViews(cubits.map((c) => c.scrollController).toList()));
    for (final cubit in cubits) {
      cubit.scrollController
          .jumpTo(cubit.scrollController.position.maxScrollExtent * .95);
    }
    await tester.pump(const Duration(milliseconds: 500));
    for (final list in lists) {
      expect(list.requests, hasLength(2));
      list.requests.last.complete([_second]);
    }
    await tester.pump();
    expect(cubits.every((c) => c.state.playlists.length == 2), isTrue);
  });

  testWidgets('generic lists own and cancel their pending pagination',
      (tester) async {
    final lists = [
      _DeferredList<int>(),
      _DeferredList<int>(),
      _DeferredList<int>(),
    ];
    final cubits = [
      for (final list in lists)
        PaginatedListCubit<int>(
            PaginatedListViewController.init(paginatedList: list)),
    ];
    for (final cubit in cubits) {
      addTearDown(() async {
        if (!cubit.isClosed) await cubit.close();
      });
    }
    for (final list in lists) {
      list.requests.single.complete([1]);
    }
    await tester.pump();
    await tester.pumpWidget(
        _scrollViews(cubits.map((c) => c.scrollController).toList()));
    for (final cubit in cubits) {
      cubit.scrollController
          .jumpTo(cubit.scrollController.position.maxScrollExtent);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await cubits.last.close();
    await tester.pump(const Duration(milliseconds: 250));
    for (final list in lists.take(2)) {
      expect(list.requests, hasLength(2));
      list.requests.last.complete([2]);
    }
    expect(lists.last.requests, hasLength(1));
    await tester.pump();
  });
}
