import 'dart:convert';

import 'package:clipious/home/models/phone_navigation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('old Music top shortcut is removed without resetting customization', () {
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
      PhoneNavigationItem.downloads,
      PhoneNavigationItem.playlist,
    ]);
    expect(restored.startup, PhoneNavigationItem.history);
    expect(restored.hidden, isNot(contains(PhoneNavigationItem.music)));
  });

  test('old Music bottom action is removed while retaining tab order', () {
    final restored = PhoneNavigation.decode(jsonEncode({
      'bottom': ['playlist', 'music', 'history', 'downloads'],
      'top': ['queue', 'home'],
      'startup': 'history',
    }))!;
    expect(restored.bottom, [
      PhoneNavigationItem.playlist,
      PhoneNavigationItem.history,
      PhoneNavigationItem.downloads,
    ]);
    expect(restored.top, [PhoneNavigationItem.queue, PhoneNavigationItem.home]);
    expect(restored.startup, PhoneNavigationItem.history);
  });

  test('minimal old layout gains Search without duplicating its top shortcut',
      () {
    final restored = PhoneNavigation.decode(jsonEncode({
      'bottom': ['history', 'music'],
      'top': ['queue', 'search', 'downloads'],
      'startup': 'history',
    }))!;
    expect(restored.bottom,
        [PhoneNavigationItem.history, PhoneNavigationItem.search]);
    expect(restored.top,
        [PhoneNavigationItem.queue, PhoneNavigationItem.downloads]);
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

  test('Music cannot be reintroduced through the video navigation editor', () {
    final layout = PhoneNavigation.defaults();
    expect(layout.top, isNot(contains(PhoneNavigationItem.music)));
    expect(layout.bottom, isNot(contains(PhoneNavigationItem.music)));
    expect(layout.hidden, isNot(contains(PhoneNavigationItem.music)));
    for (final area in NavigationArea.values) {
      expect(layout.move(PhoneNavigationItem.music, area), isNull);
    }
  });

  test('invalid legacy layouts remain rejected during Music migration', () {
    for (final invalid in [
      {
        'bottom': ['music', 'downloads'],
        'top': ['home'],
        'startup': 'music'
      },
      {
        'bottom': ['home', 'music'],
        'top': ['music'],
        'startup': 'home'
      },
      {
        'bottom': ['home', 'music'],
        'top': ['search'],
        'startup': 'music'
      },
    ]) {
      expect(PhoneNavigation.decode(jsonEncode(invalid)), isNull);
    }
  });
}
