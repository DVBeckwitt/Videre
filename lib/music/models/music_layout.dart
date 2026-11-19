import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';

enum MusicDestination {
  home(Icons.home_outlined),
  search(Icons.search),
  library(Icons.library_music_outlined);

  const MusicDestination(this.icon);
  final IconData icon;

  String label(AppLocalizations locals) => switch (this) {
        home => locals.home,
        search => locals.search,
        library => locals.musicLibrary,
      };
}

enum MusicShortcut {
  search,
  library,
  charts,
  discover,
  recommendations;

  String label(AppLocalizations locals) => switch (this) {
        search => locals.search,
        library => locals.musicLibrary,
        charts => locals.musicTopCharts,
        discover => locals.musicDiscover,
        recommendations => locals.localRecommendations,
      };
}

class MusicLayout {
  final List<MusicDestination> destinations;
  final List<MusicShortcut> shortcuts;

  MusicLayout({
    required List<MusicDestination> destinations,
    required List<MusicShortcut> shortcuts,
  })  : destinations = List.unmodifiable(destinations),
        shortcuts = List.unmodifiable(shortcuts) {
    if (destinations.length != MusicDestination.values.length ||
        destinations.toSet().length != destinations.length ||
        shortcuts.toSet().length != shortcuts.length) {
      throw ArgumentError('Invalid Music layout');
    }
  }

  const MusicLayout.defaults()
      : destinations = MusicDestination.values,
        shortcuts = MusicShortcut.values;

  MusicLayout copyWith(
          {List<MusicDestination>? destinations,
          List<MusicShortcut>? shortcuts}) =>
      MusicLayout(
          destinations: destinations ?? this.destinations,
          shortcuts: shortcuts ?? this.shortcuts);

  String encode() => jsonEncode({
        'version': 1,
        'destinations': destinations.map((item) => item.name).toList(),
        'shortcuts': shortcuts.map((item) => item.name).toList(),
      });

  static MusicLayout decode(String? raw) =>
      tryDecode(raw) ?? const MusicLayout.defaults();

  static MusicLayout? tryDecode(String? raw) {
    if (raw == null || raw.length > 2048) return null;
    try {
      final data = jsonDecode(raw);
      if (data is! Map || data.length != 3 || data['version'] != 1) return null;
      final destinations =
          _items(data['destinations'], MusicDestination.values);
      final shortcuts = _items(data['shortcuts'], MusicShortcut.values);
      if (destinations == null ||
          destinations.length != MusicDestination.values.length ||
          shortcuts == null) {
        return null;
      }
      return MusicLayout(destinations: destinations, shortcuts: shortcuts);
    } on FormatException {
      return null;
    }
  }

  static List<T>? _items<T extends Enum>(Object? raw, List<T> values) {
    if (raw is! List || raw.length > values.length) return null;
    final byName = values.asNameMap();
    final result = <T>[];
    for (final name in raw) {
      final item = byName[name];
      if (item == null || result.contains(item)) return null;
      result.add(item);
    }
    return result;
  }

  @override
  bool operator ==(Object other) =>
      other is MusicLayout &&
      listEquals(destinations, other.destinations) &&
      listEquals(shortcuts, other.shortcuts);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(destinations), Object.hashAll(shortcuts));
}
