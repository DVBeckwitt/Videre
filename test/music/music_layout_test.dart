import 'dart:convert';

import 'package:clipious/music/models/music_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('existing profiles without a layout use the original Music order', () {
    final layout = MusicLayout.decode(null);
    expect(layout.destinations, [
      MusicDestination.home,
      MusicDestination.search,
      MusicDestination.library,
    ]);
    expect(layout.shortcuts, [
      MusicShortcut.search,
      MusicShortcut.library,
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
      final saved =
          MusicLayout(destinations: destinations, shortcuts: shortcuts);
      final restored = MusicLayout.tryDecode(saved.encode());
      expect(restored?.destinations, destinations);
      expect(restored?.shortcuts, shortcuts);
    }
  });

  test(
      'malformed imports are distinguishable from intentionally hidden shortcuts',
      () {
    final valid = jsonDecode(const MusicLayout.defaults().encode())
        as Map<String, dynamic>;
    for (final raw in [
      '{',
      jsonEncode({...valid, 'version': 20}),
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
