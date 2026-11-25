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
  podcasts,
  cachedSongs;

  String label(AppLocalizations locals) => switch (this) {
        playlists => locals.musicPlaylists,
        songs => locals.musicSongs,
        onDevice => locals.onDevice,
        channels => locals.channels,
        downloads => locals.downloads,
        podcasts => locals.podcasts,
        cachedSongs => locals.musicCachedSongs,
      };

  bool isAvailable({
    required bool tv,
    required bool deviceFolders,
    bool playbackCache = false,
  }) =>
      (this != onDevice || deviceFolders) &&
      (this != downloads || !tv) &&
      (this != cachedSongs || playbackCache);
}

enum MusicGridSize {
  small(96),
  medium(140),
  large(180);

  const MusicGridSize(this.minimumWidth);
  final double minimumWidth;
}

enum MusicSongTitleLines { automatic, one, two }

class MusicLayout {
  final List<MusicDestination> destinations;
  final List<MusicShortcut> shortcuts;
  final List<MusicLibraryCategory> libraryCategories;
  final Set<MusicLibraryCategory> hiddenLibraryCategories;
  final MusicGridSize gridSize;
  final MusicSongTitleLines songTitleLines;
  final bool compactRows;
  final bool slimNavigation;
  final bool showHomeShortcuts;
  final bool showRecentActivity;

  MusicLayout({
    required List<MusicDestination> destinations,
    required List<MusicShortcut> shortcuts,
    List<MusicLibraryCategory> libraryCategories = MusicLibraryCategory.values,
    Set<MusicLibraryCategory> hiddenLibraryCategories = const {},
    this.gridSize = MusicGridSize.medium,
    this.songTitleLines = MusicSongTitleLines.automatic,
    this.compactRows = false,
    this.slimNavigation = false,
    this.showHomeShortcuts = true,
    this.showRecentActivity = true,
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
        hiddenLibraryCategories = const {},
        gridSize = MusicGridSize.medium,
        songTitleLines = MusicSongTitleLines.automatic,
        compactRows = false,
        slimNavigation = false,
        showHomeShortcuts = true,
        showRecentActivity = true;

  Iterable<MusicLibraryCategory> get visibleLibraryCategories =>
      libraryCategories
          .where((item) => !hiddenLibraryCategories.contains(item));

  MusicLayout copyWith({
    List<MusicDestination>? destinations,
    List<MusicShortcut>? shortcuts,
    List<MusicLibraryCategory>? libraryCategories,
    Set<MusicLibraryCategory>? hiddenLibraryCategories,
    MusicGridSize? gridSize,
    MusicSongTitleLines? songTitleLines,
    bool? compactRows,
    bool? slimNavigation,
    bool? showHomeShortcuts,
    bool? showRecentActivity,
  }) =>
      MusicLayout(
        destinations: destinations ?? this.destinations,
        shortcuts: shortcuts ?? this.shortcuts,
        libraryCategories: libraryCategories ?? this.libraryCategories,
        hiddenLibraryCategories:
            hiddenLibraryCategories ?? this.hiddenLibraryCategories,
        gridSize: gridSize ?? this.gridSize,
        songTitleLines: songTitleLines ?? this.songTitleLines,
        compactRows: compactRows ?? this.compactRows,
        slimNavigation: slimNavigation ?? this.slimNavigation,
        showHomeShortcuts: showHomeShortcuts ?? this.showHomeShortcuts,
        showRecentActivity: showRecentActivity ?? this.showRecentActivity,
      );

  int titleLines(int fallback) => explicitTitleLines ?? fallback;

  int? get explicitTitleLines => switch (songTitleLines) {
        MusicSongTitleLines.automatic => null,
        MusicSongTitleLines.one => 1,
        MusicSongTitleLines.two => 2,
      };

  String encode() => jsonEncode({
        'version': 3,
        'destinations': destinations.map((item) => item.name).toList(),
        'shortcuts': shortcuts.map((item) => item.name).toList(),
        'libraryCategories':
            libraryCategories.map((item) => item.name).toList(),
        'hiddenLibraryCategories': [
          for (final item in libraryCategories)
            if (hiddenLibraryCategories.contains(item)) item.name,
        ],
        'gridSize': gridSize.name,
        'songTitleLines': songTitleLines.name,
        'compactRows': compactRows,
        'slimNavigation': slimNavigation,
        'showHomeShortcuts': showHomeShortcuts,
        'showRecentActivity': showRecentActivity,
      });

  static MusicLayout decode(String? raw) =>
      tryDecode(raw) ?? const MusicLayout.defaults();

  static MusicLayout? tryDecode(String? raw) {
    if (raw == null || raw.length > 2048) return null;
    try {
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic>) return null;
      final sections = switch ((data['version'], data.length)) {
        (1, 3) => (categories: false, appearance: false),
        (2, 5) => (categories: true, appearance: false),
        (2, 9) => (categories: false, appearance: true),
        (3, 11) => (categories: true, appearance: true),
        _ => null,
      };
      if (sections == null) return null;
      final destinations =
          _items(data['destinations'], MusicDestination.values);
      final shortcuts = _items(data['shortcuts'], MusicShortcut.values);
      if (destinations == null ||
          destinations.length != MusicDestination.values.length ||
          shortcuts == null) {
        return null;
      }
      var layout =
          MusicLayout(destinations: destinations, shortcuts: shortcuts);
      if (sections.categories) {
        final categories =
            _items(data['libraryCategories'], MusicLibraryCategory.values);
        final hidden = _items(
            data['hiddenLibraryCategories'], MusicLibraryCategory.values);
        if (categories == null || hidden == null) return null;
        const cache = MusicLibraryCategory.cachedSongs;
        if (categories.length == MusicLibraryCategory.values.length - 1 &&
            !categories.contains(cache) &&
            !hidden.contains(cache)) {
          categories.add(cache);
        }
        if (categories.length != MusicLibraryCategory.values.length) {
          return null;
        }
        layout = layout.copyWith(
          libraryCategories: categories,
          hiddenLibraryCategories: hidden.toSet(),
        );
      }
      if (!sections.appearance) return layout;

      final gridSize = MusicGridSize.values.asNameMap()[data['gridSize']];
      final songTitleLines =
          MusicSongTitleLines.values.asNameMap()[data['songTitleLines']];
      final compactRows = data['compactRows'];
      final slimNavigation = data['slimNavigation'];
      final showHomeShortcuts = data['showHomeShortcuts'];
      final showRecentActivity = data['showRecentActivity'];
      if (gridSize == null ||
          songTitleLines == null ||
          compactRows is! bool ||
          slimNavigation is! bool ||
          showHomeShortcuts is! bool ||
          showRecentActivity is! bool) {
        return null;
      }
      return layout.copyWith(
        gridSize: gridSize,
        songTitleLines: songTitleLines,
        compactRows: compactRows,
        slimNavigation: slimNavigation,
        showHomeShortcuts: showHomeShortcuts,
        showRecentActivity: showRecentActivity,
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
      setEquals(hiddenLibraryCategories, other.hiddenLibraryCategories) &&
      gridSize == other.gridSize &&
      songTitleLines == other.songTitleLines &&
      compactRows == other.compactRows &&
      slimNavigation == other.slimNavigation &&
      showHomeShortcuts == other.showHomeShortcuts &&
      showRecentActivity == other.showRecentActivity;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(destinations),
        Object.hashAll(shortcuts),
        Object.hashAll(libraryCategories),
        Object.hashAllUnordered(hiddenLibraryCategories),
        gridSize,
        songTitleLines,
        compactRows,
        slimNavigation,
        showHomeShortcuts,
        showRecentActivity,
      );
}
