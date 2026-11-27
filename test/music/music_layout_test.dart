import 'dart:convert';

import 'package:clipious/music/models/music_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('profiles without a saved layout use the default Music order', () {
    final layout = MusicLayout.decode(null);
    expect(layout.destinations, [
      MusicDestination.home,
      MusicDestination.search,
      MusicDestination.library,
    ]);
    expect(layout.shortcuts, [
      MusicShortcut.search,
      MusicShortcut.library,
      MusicShortcut.likedSongs,
      MusicShortcut.charts,
      MusicShortcut.discover,
      MusicShortcut.recommendations,
    ]);
    expect(layout.visibleLibraryCategories, [
      MusicLibraryCategory.playlists,
      MusicLibraryCategory.songs,
      MusicLibraryCategory.onDevice,
      MusicLibraryCategory.channels,
      MusicLibraryCategory.downloads,
      MusicLibraryCategory.podcasts,
      MusicLibraryCategory.cachedSongs,
    ]);
  });

  test('version 1 keeps customized navigation and gets default categories', () {
    final layout = MusicLayout.tryDecode(jsonEncode({
      'version': 1,
      'destinations': ['library', 'home', 'search'],
      'shortcuts': ['charts', 'library'],
    }));
    expect(layout?.destinations, [
      MusicDestination.library,
      MusicDestination.home,
      MusicDestination.search,
    ]);
    expect(layout?.shortcuts, [MusicShortcut.charts, MusicShortcut.library]);
    expect(layout?.visibleLibraryCategories, MusicLibraryCategory.values);
  });

  test('hidden categories keep their order and can all be hidden', () {
    final order = MusicLibraryCategory.values.reversed.toList();
    final layout = const MusicLayout.defaults().copyWith(
      libraryCategories: order,
      hiddenLibraryCategories: {
        MusicLibraryCategory.songs,
        MusicLibraryCategory.downloads,
      },
    );
    final restored = MusicLayout.decode(layout.encode());
    expect(restored, layout);
    expect(restored.hashCode, layout.hashCode);
    expect(restored.visibleLibraryCategories, [
      MusicLibraryCategory.cachedSongs,
      MusicLibraryCategory.podcasts,
      MusicLibraryCategory.channels,
      MusicLibraryCategory.onDevice,
      MusicLibraryCategory.playlists,
    ]);
    expect(
        restored.copyWith(hiddenLibraryCategories: {}).visibleLibraryCategories,
        order);
    final allHidden = restored.copyWith(hiddenLibraryCategories: order.toSet());
    expect(MusicLayout.tryDecode(allHidden.encode())?.visibleLibraryCategories,
        isEmpty);
  });

  test('saved section order is independent of shortcut order and visibility',
      () {
    final destinations = [
      MusicDestination.library,
      MusicDestination.home,
      MusicDestination.search,
    ];
    for (final shortcuts in [
      [MusicShortcut.charts, MusicShortcut.library],
      <MusicShortcut>[],
    ]) {
      final saved = MusicLayout(
          destinations: destinations,
          shortcuts: shortcuts,
          gridSize: MusicGridSize.small,
          songTitleLines: MusicSongTitleLines.two,
          compactRows: true,
          slimNavigation: true,
          showHomeShortcuts: false,
          showRecentActivity: false);
      final restored = MusicLayout.tryDecode(saved.encode());
      expect(restored, saved);
      expect(restored?.titleLines(1), 2);
    }
  });

  test('both version 2 layout formats migrate without dropping preferences',
      () {
    const navigation = {
      'version': 2,
      'destinations': ['library', 'search', 'home'],
      'shortcuts': ['charts'],
    };
    const cache = MusicLibraryCategory.cachedSongs;
    final categoryOrder = [
      ...MusicLibraryCategory.values.reversed.where((item) => item != cache),
    ];
    final categories = MusicLayout.tryDecode(jsonEncode({
      ...navigation,
      'libraryCategories': categoryOrder.map((item) => item.name).toList(),
      'hiddenLibraryCategories': ['downloads'],
    }));
    expect(categories?.libraryCategories, [...categoryOrder, cache]);
    expect(
        categories?.hiddenLibraryCategories, {MusicLibraryCategory.downloads});
    expect(categories?.gridSize, MusicGridSize.medium);

    final appearance = MusicLayout.tryDecode(jsonEncode({
      ...navigation,
      'gridSize': 'large',
      'songTitleLines': 'two',
      'compactRows': true,
      'slimNavigation': true,
      'showHomeShortcuts': false,
      'showRecentActivity': false,
    }));
    expect(appearance?.libraryCategories, MusicLibraryCategory.values);
    expect(appearance?.gridSize, MusicGridSize.large);
    expect(appearance?.showHomeShortcuts, isFalse);

    final combined = categories!.copyWith(
      gridSize: appearance!.gridSize,
      showHomeShortcuts: appearance.showHomeShortcuts,
    );
    expect(MusicLayout.tryDecode(combined.encode()), combined);
    final beforeCache = jsonDecode(combined.encode()) as Map<String, dynamic>;
    beforeCache['libraryCategories'] =
        categoryOrder.map((item) => item.name).toList();
    expect(MusicLayout.tryDecode(jsonEncode(beforeCache)), combined);
  });

  test('version one keeps customized order and gains presentation defaults',
      () {
    final layout = MusicLayout.tryDecode(jsonEncode({
      'version': 1,
      'destinations': ['library', 'home', 'search'],
      'shortcuts': ['charts'],
    }));
    expect(
        layout,
        const MusicLayout.defaults().copyWith(destinations: [
          MusicDestination.library,
          MusicDestination.home,
          MusicDestination.search,
        ], shortcuts: [
          MusicShortcut.charts,
        ]));
    expect(layout?.titleLines(1), 1);
  });

  test(
      'malformed imports are distinguishable from intentionally hidden shortcuts',
      () {
    final valid = jsonDecode(const MusicLayout.defaults().encode())
        as Map<String, dynamic>;
    for (final raw in [
      '{',
      jsonEncode({...valid, 'version': 20}),
      jsonEncode({...valid, 'gridSize': 'huge'}),
      jsonEncode({...valid, 'compactRows': 1}),
      jsonEncode({...valid, 'shortcuts': 'charts'}),
      jsonEncode({
        ...valid,
        'shortcuts': ['unknown']
      }),
      jsonEncode({
        ...valid,
        'shortcuts': ['library', 'library']
      }),
      jsonEncode({
        ...valid,
        'destinations': ['library', 'search']
      }),
      jsonEncode({
        ...valid,
        'destinations': ['search', 'search', 'library']
      }),
      jsonEncode({...valid, 'libraryCategories': []}),
      jsonEncode({
        ...valid,
        'libraryCategories': List.filled(6, 'songs'),
      }),
      jsonEncode({
        ...valid,
        'hiddenLibraryCategories': ['songs', 'songs'],
      }),
      jsonEncode({
        ...valid,
        'hiddenLibraryCategories': ['unknown'],
      }),
    ]) {
      expect(MusicLayout.tryDecode(raw), isNull);
      expect(MusicLayout.decode(raw).destinations,
          const MusicLayout.defaults().destinations);
    }
  });
}
