import 'dart:convert';

import 'package:clipious/home/models/phone_navigation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('old Music top shortcut remains in its configured location', () {
    final restored = PhoneNavigation.decode(jsonEncode({
      'bottom': ['history', 'home', 'search'],
      'top': ['queue', 'music', 'downloads', 'playlist'],
      'startup': 'history',
    }))!;
    expect(restored.bottom, [
      PhoneNavigationItem.history,
      PhoneNavigationItem.home,
      PhoneNavigationItem.search,
    ]);
    expect(restored.top, [
      PhoneNavigationItem.queue,
      PhoneNavigationItem.music,
      PhoneNavigationItem.downloads,
      PhoneNavigationItem.playlist,
    ]);
    expect(restored.startup, PhoneNavigationItem.history);
    expect(restored.hidden, isNot(contains(PhoneNavigationItem.music)));
  });

  test('old Music bottom action becomes a tab in the same location', () {
    final restored = PhoneNavigation.decode(jsonEncode({
      'bottom': ['playlist', 'music', 'history', 'downloads'],
      'top': ['queue', 'home'],
      'startup': 'history',
    }))!;
    expect(restored.bottom, [
      PhoneNavigationItem.playlist,
      PhoneNavigationItem.music,
      PhoneNavigationItem.history,
      PhoneNavigationItem.downloads,
    ]);
    expect(restored.top, [PhoneNavigationItem.queue, PhoneNavigationItem.home]);
    expect(restored.startup, PhoneNavigationItem.history);
  });

  test('minimal old layout keeps its Music and Search placements', () {
    final restored = PhoneNavigation.decode(jsonEncode({
      'bottom': ['history', 'music'],
      'top': ['queue', 'search', 'downloads'],
      'startup': 'history',
    }))!;
    expect(restored.bottom,
        [PhoneNavigationItem.history, PhoneNavigationItem.music]);
    expect(restored.top, [
      PhoneNavigationItem.queue,
      PhoneNavigationItem.search,
      PhoneNavigationItem.downloads
    ]);
    expect(restored.startup, PhoneNavigationItem.history);
    expect(
        PhoneNavigation.decode(restored.encode())!.encode(), restored.encode());
  });

  test('unrelated saved layouts round-trip unchanged', () {
    final original = PhoneNavigation(
      [PhoneNavigationItem.history, PhoneNavigationItem.queue],
      [PhoneNavigationItem.downloads, PhoneNavigationItem.search],
      startup: PhoneNavigationItem.history,
    );
    expect(
        PhoneNavigation.decode(original.encode())!.encode(), original.encode());
  });

  test('the editor can reorder Music and then restore its default position',
      () {
    final layout = PhoneNavigation.defaults();
    expect(layout.top, isNot(contains(PhoneNavigationItem.music)));
    expect(layout.bottom.reversed.take(2),
        [PhoneNavigationItem.search, PhoneNavigationItem.music]);
    expect(layout.hidden, isNot(contains(PhoneNavigationItem.music)));
    final reordered = layout.move(
        PhoneNavigationItem.music, NavigationArea.bottom,
        before: PhoneNavigationItem.home)!;
    expect(reordered.bottom.first, PhoneNavigationItem.music);
    expect(
        reordered
            .move(PhoneNavigationItem.music, NavigationArea.bottom,
                before: PhoneNavigationItem.search)!
            .encode(),
        layout.encode());
  });

  test('invalid legacy layouts remain rejected during Music migration', () {
    for (final invalid in [
      {
        'bottom': ['music'],
        'top': ['home'],
        'startup': 'music'
      },
      {
        'bottom': ['home', 'music'],
        'top': ['music'],
        'startup': 'home'
      },
      {
        'bottom': ['home', 'search'],
        'top': ['music'],
        'startup': 'music'
      },
    ]) {
      expect(PhoneNavigation.decode(jsonEncode(invalid)), isNull);
    }
  });
}
