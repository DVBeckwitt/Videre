import 'dart:convert';

import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import 'db/home_layout.dart';

enum PhoneNavigationItem {
  home(HomeDataSource.home),
  subscription(HomeDataSource.subscription),
  history(HomeDataSource.history),
  search(HomeDataSource.search),
  downloads(HomeDataSource.downloads),
  queue(null),
  music(null),
  playlist(HomeDataSource.playlist),
  popular(HomeDataSource.popular),
  trending(HomeDataSource.trending),
  searchHistory(HomeDataSource.searchHistory);

  const PhoneNavigationItem(this.source);
  final HomeDataSource? source;

  bool get isTab =>
      this == music || (source?.route != null && this != downloads);
  IconData get icon =>
      this == music ? Icons.music_note : source?.getIcon() ?? Icons.queue_music;
  String label(AppLocalizations locals) => this == music
      ? locals.music
      : source?.getLabel(locals) ?? locals.videoQueue;
}

enum NavigationArea { bottom, top, hidden }

/// Phone-only preferences. Tablet/TV sections keep their existing settings.
class PhoneNavigation {
  static const _version = 2;
  final List<PhoneNavigationItem> bottom, top;
  final PhoneNavigationItem startup;

  PhoneNavigation(
      Iterable<PhoneNavigationItem> bottom, Iterable<PhoneNavigationItem> top,
      {PhoneNavigationItem? startup})
      : bottom = List.unmodifiable(bottom),
        top = List.unmodifiable(top),
        startup = bottom.contains(startup) && (startup?.isTab ?? false)
            ? startup!
            : bottom.firstWhere((item) => item.isTab);

  factory PhoneNavigation.defaults() => PhoneNavigation(const [
        PhoneNavigationItem.home,
        PhoneNavigationItem.subscription,
        PhoneNavigationItem.history,
        PhoneNavigationItem.music,
        PhoneNavigationItem.search,
      ], const [
        PhoneNavigationItem.downloads,
        PhoneNavigationItem.queue,
        PhoneNavigationItem.playlist,
      ]);

  factory PhoneNavigation.fromLegacy(List<HomeDataSource> sources, int first) {
    final bottom = sources
        .where((source) =>
            source.route != null && source != HomeDataSource.playlist)
        .map((source) => PhoneNavigationItem.values
            .firstWhere((item) => item.source == source))
        .toSet()
        .toList();
    if (!bottom.any((item) => item.isTab)) {
      bottom.insert(0, PhoneNavigationItem.home);
    }
    bottom.add(PhoneNavigationItem.search);
    final top = [...bottom.skip(5), ...PhoneNavigation.defaults().top]
        .where((item) => !bottom.take(5).contains(item))
        .toSet()
        .toList();
    return PhoneNavigation(bottom.take(5), top,
            startup: PhoneNavigationItem.values
                .where((item) => item.source == sources.elementAtOrNull(first))
                .firstOrNull)
        ._withLegacyMusic();
  }

  List<PhoneNavigationItem> get hidden => PhoneNavigationItem.values
      .where((item) => !bottom.contains(item) && !top.contains(item))
      .toList();

  /// Prior versions exposed Music from the mode selector. Keep explicit places,
  /// and restore access for layouts that relied on that selector.
  PhoneNavigation _withLegacyMusic() {
    if (bottom.contains(PhoneNavigationItem.music) ||
        top.contains(PhoneNavigationItem.music)) {
      return this;
    }
    final nextBottom = [...bottom];
    final nextTop = [...top];
    // A full custom bar keeps all five items and gains a top shortcut.
    final target = nextBottom.length < 5 ? nextBottom : nextTop;
    final search = target.indexOf(PhoneNavigationItem.search);
    target.insert(
        search < 0 ? target.length : search, PhoneNavigationItem.music);
    return PhoneNavigation(nextBottom, nextTop, startup: startup);
  }

  List<PhoneNavigationItem> items(NavigationArea area) => switch (area) {
        NavigationArea.bottom => bottom,
        NavigationArea.top => top,
        NavigationArea.hidden => hidden,
      };

  static bool _valid(
          List<PhoneNavigationItem> bottom, List<PhoneNavigationItem> top) =>
      bottom.length >= 2 &&
      bottom.length <= 5 &&
      bottom.any((item) => item.isTab) &&
      {...bottom, ...top}.length == bottom.length + top.length;

  /// Insertion is relative to an item, avoiding shifting drag indexes.
  PhoneNavigation? move(PhoneNavigationItem item, NavigationArea area,
      {PhoneNavigationItem? before}) {
    if (before == item) return this;
    final nextBottom = [...bottom]..remove(item);
    final nextTop = [...top]..remove(item);
    final target = switch (area) {
      NavigationArea.bottom => nextBottom,
      NavigationArea.top => nextTop,
      NavigationArea.hidden => null,
    };
    if (target != null) {
      final index = before == null ? -1 : target.indexOf(before);
      target.insert(index < 0 ? target.length : index, item);
    }
    return _valid(nextBottom, nextTop)
        ? PhoneNavigation(nextBottom, nextTop, startup: startup)
        : null;
  }

  PhoneNavigation startAt(PhoneNavigationItem item) =>
      PhoneNavigation(bottom, top, startup: item);

  PhoneNavigation available({required bool searchHistory, bool music = true}) {
    bool permitted(PhoneNavigationItem item) =>
        (searchHistory || item != PhoneNavigationItem.searchHistory) &&
        (music || item != PhoneNavigationItem.music);
    final nextBottom = bottom.where(permitted).toList();
    final nextTop = top.where(permitted).toList();
    if (nextBottom.length == bottom.length && nextTop.length == top.length) {
      return this;
    }
    if (!nextBottom.any((item) => item.isTab)) {
      nextBottom.insert(0, PhoneNavigationItem.home);
    }
    if (nextBottom.length < 2) {
      nextBottom.add(PhoneNavigationItem.search);
    }
    nextTop.removeWhere(nextBottom.contains);
    return PhoneNavigation(nextBottom, nextTop, startup: startup);
  }

  String encode() => jsonEncode({
        'version': _version,
        'bottom': bottom.map((item) => item.name).toList(),
        'top': top.map((item) => item.name).toList(),
        'startup': startup.name,
      });

  static PhoneNavigation? decode(String? value) {
    if (value == null) return null;
    try {
      final json = jsonDecode(value) as Map<String, dynamic>;
      final version = json['version'];
      if (version != null && version != _version) return null;
      List<PhoneNavigationItem> read(String key) => (json[key] as List)
          .map((name) => PhoneNavigationItem.values.byName(name as String))
          .toList();
      final bottom = read('bottom'), top = read('top');
      if (!_valid(bottom, top)) return null;
      final startup =
          PhoneNavigationItem.values.byName(json['startup'] as String);
      if (!bottom.contains(startup) || !startup.isTab) return null;
      final layout = PhoneNavigation(bottom, top, startup: startup);
      return version == null ? layout._withLegacyMusic() : layout;
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    } on TypeError {
      return null;
    }
  }
}
