import 'dart:convert';

import 'package:clipious/home/models/home_tabs_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const available = [
    HomeTabsLayout.forYou,
    HomeTabsLayout.yourFeeds,
    HomeTabsLayout.discover,
    'topic:music',
  ];

  test('new and legacy settings hide Continue watching without hiding tabs',
      () {
    final layout = HomeTabsLayout.decode(null);
    expect(layout.continueWatching, isFalse);
    expect(layout.orderedIds(available), available);
    expect(HomeTabsLayout.decode(layout.encode()).orderedIds(available),
        available);
  });

  test('explicit empty layout survives reopening and newly learned topics', () {
    final saved = HomeTabsLayout(enabledOrder: []);
    final restored = HomeTabsLayout.decode(saved.encode());
    expect(restored.enabledOrder, isEmpty);
    expect(restored.orderedIds([...available, 'topic:new']), isEmpty);
  });

  test(
      'custom order preserves temporarily unavailable topics and filters new ones',
      () {
    final saved = HomeTabsLayout(enabledOrder: [
      'topic:missing',
      HomeTabsLayout.discover,
      HomeTabsLayout.forYou,
      HomeTabsLayout.discover,
    ], continueWatching: true);
    final restored = HomeTabsLayout.decode(saved.encode());
    expect(restored.continueWatching, isTrue);
    expect(restored.orderedIds(available),
        [HomeTabsLayout.discover, HomeTabsLayout.forYou]);
    expect(restored.orderedIds(['topic:missing', ...available]),
        ['topic:missing', HomeTabsLayout.discover, HomeTabsLayout.forYou]);
    expect(restored.enabledOrder, hasLength(3));
  });

  test('invalid imported settings are distinguishable from a valid empty order',
      () {
    for (final value in [
      '{',
      jsonEncode({'version': 2, 'enabledOrder': [], 'continueWatching': false}),
      jsonEncode(
          {'version': 1, 'enabledOrder': 'no', 'continueWatching': false}),
      jsonEncode({
        'version': 1,
        'enabledOrder': [4],
        'continueWatching': false
      }),
      jsonEncode({
        'version': 1,
        'enabledOrder': ['topic:'],
        'continueWatching': false
      }),
      jsonEncode(
          {'version': 1, 'enabledOrder': [], 'continueWatching': 'true'}),
    ]) {
      expect(HomeTabsLayout.tryDecode(value), isNull);
      expect(HomeTabsLayout.decode(value).enabledOrder, isNull);
    }
    expect(HomeTabsLayout.tryDecode(HomeTabsLayout(enabledOrder: []).encode()),
        isNotNull);
  });
}
