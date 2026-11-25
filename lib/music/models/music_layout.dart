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

enum MusicLibraryCategory {
  playlists,
  songs,
  onDevice,
  channels,
  downloads,
  podcasts;

  String label(AppLocalizations locals) => switch (this) {
        playlists => locals.musicPlaylists,
        songs => locals.musicSongs,
        onDevice => locals.onDevice,
        channels => locals.channels,
        downloads => locals.downloads,
        podcasts => locals.podcasts,
      };

  bool isAvailable({required bool tv, required bool deviceFolders}) =>
      (this != onDevice || deviceFolders) && (this != downloads || !tv);
}

class MusicLayout {
  final List<MusicDestination> destinations;
  final List<MusicShortcut> shortcuts;
  final List<MusicLibraryCategory> libraryCategories;
  final Set<MusicLibraryCategory> hiddenLibraryCategories;

  MusicLayout({
    required List<MusicDestination> destinations,
    required List<MusicShortcut> shortcuts,
    List<MusicLibraryCategory> libraryCategories = MusicLibraryCategory.values,
    Set<MusicLibraryCategory> hiddenLibraryCategories = const {},
  })  : destinations = List.unmodifiable(destinations),
        shortcuts = List.unmodifiable(shortcuts),
        libraryCategories = List.unmodifiable(libraryCategories),
        hiddenLibraryCategories = Set.unmodifiable(hiddenLibraryCategories) {
    if (destinations.length != MusicDestination.values.length ||
        destinations.toSet().length != destinations.length ||
        shortcuts.toSet().length != shortcuts.length ||
        libraryCategories.length != MusicLibraryCategory.values.length ||
        libraryCategories.toSet().length != libraryCategories.length) {
      throw ArgumentError('Invalid Music layout');
    }
  }

  const MusicLayout.defaults()
      : destinations = MusicDestination.values,
        shortcuts = MusicShortcut.values,
        libraryCategories = MusicLibraryCategory.values,
        hiddenLibraryCategories = const {};

  Iterable<MusicLibraryCategory> get visibleLibraryCategories =>
      libraryCategories
          .where((item) => !hiddenLibraryCategories.contains(item));

  MusicLayout copyWith({
    List<MusicDestination>? destinations,
    List<MusicShortcut>? shortcuts,
    List<MusicLibraryCategory>? libraryCategories,
    Set<MusicLibraryCategory>? hiddenLibraryCategories,
  }) =>
      MusicLayout(
        destinations: destinations ?? this.destinations,
        shortcuts: shortcuts ?? this.shortcuts,
        libraryCategories: libraryCategories ?? this.libraryCategories,
        hiddenLibraryCategories:
            hiddenLibraryCategories ?? this.hiddenLibraryCategories,
      );

  String encode() => jsonEncode({
        'version': 2,
        'destinations': destinations.map((item) => item.name).toList(),
        'shortcuts': shortcuts.map((item) => item.name).toList(),
        'libraryCategories':
            libraryCategories.map((item) => item.name).toList(),
        'hiddenLibraryCategories': [
          for (final item in libraryCategories)
            if (hiddenLibraryCategories.contains(item)) item.name,
        ],
      });

  static MusicLayout decode(String? raw) =>
      tryDecode(raw) ?? const MusicLayout.defaults();

  static MusicLayout? tryDecode(String? raw) {
    if (raw == null || raw.length > 2048) return null;
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return null;
      final version = data['version'];
      if ((version != 1 || data.length != 3) &&
          (version != 2 || data.length != 5)) {
        return null;
      }
      final destinations =
          _items(data['destinations'], MusicDestination.values);
      final shortcuts = _items(data['shortcuts'], MusicShortcut.values);
      if (destinations == null ||
          destinations.length != MusicDestination.values.length ||
          shortcuts == null) {
        return null;
      }
      if (version == 1) {
        return MusicLayout(destinations: destinations, shortcuts: shortcuts);
      }
      final categories =
          _items(data['libraryCategories'], MusicLibraryCategory.values);
      final hidden =
          _items(data['hiddenLibraryCategories'], MusicLibraryCategory.values);
      if (categories == null ||
          categories.length != MusicLibraryCategory.values.length ||
          hidden == null) {
        return null;
      }
      return MusicLayout(
        destinations: destinations,
        shortcuts: shortcuts,
        libraryCategories: categories,
        hiddenLibraryCategories: hidden.toSet(),
      );
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
      listEquals(shortcuts, other.shortcuts) &&
      listEquals(libraryCategories, other.libraryCategories) &&
      setEquals(hiddenLibraryCategories, other.hiddenLibraryCategories);

  @override
  int get hashCode => Object.hash(
        Object.hashAll(destinations),
        Object.hashAll(shortcuts),
        Object.hashAll(libraryCategories),
        Object.hashAllUnordered(hiddenLibraryCategories),
      );
}
