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
    ]) {
      expect(MusicLayout.tryDecode(raw), isNull);
      expect(MusicLayout.decode(raw).destinations,
          const MusicLayout.defaults().destinations);
    }
  });
}
