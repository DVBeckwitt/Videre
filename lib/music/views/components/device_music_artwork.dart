import 'dart:io';

import 'package:clipious/utils/views/components/artwork_image_builder.dart';
import 'package:flutter/material.dart';

import '../../../globals.dart' show db;
import '../../models/device_music_artwork_preferences.dart';
import '../../models/local_music_track.dart';

typedef _CoverPaths = ({String? embedded, String? adjacent});

/// Renders artwork from the current device catalog, with an embedded fallback.
class DeviceMusicArtwork extends StatelessWidget {
  DeviceMusicArtwork({
    super.key,
    required LocalMusicTrack track,
    required this.placeholder,
    this.thumbnail = false,
    this.artworkImageBuilder,
  }) : _paths = (embedded: track.artPath, adjacent: track.adjacentArtPath);

  DeviceMusicArtwork.album({
    super.key,
    required Iterable<LocalMusicTrack> tracks,
    required this.placeholder,
    this.thumbnail = false,
  })  : artworkImageBuilder = null,
        _paths = (
          embedded: tracks.map((track) => track.artPath).nonNulls.firstOrNull,
          adjacent:
              tracks.map((track) => track.adjacentArtPath).nonNulls.firstOrNull,
        );

  DeviceMusicArtwork._thumbnail(this._paths, {required this.placeholder})
      : thumbnail = true,
        artworkImageBuilder = null,
        super(key: ValueKey(_paths));

  final _CoverPaths _paths;
  final Widget placeholder;
  final bool thumbnail;
  final ArtworkImageBuilder? artworkImageBuilder;

  @override
  Widget build(BuildContext context) {
    if (_paths.embedded == null && _paths.adjacent == null) {
      return placeholder;
    }
    return ListenableBuilder(
      listenable: DeviceMusicArtworkPreferences.revision,
      builder: (context, _) {
        final preferences = DeviceMusicArtworkPreferences.forDatabase(db);
        if (!preferences.loadCovers) return placeholder;
        final fit = preferences.crop == DeviceMusicArtworkCrop.fit
            ? BoxFit.contain
            : BoxFit.cover;

        Widget embedded() {
          final path = _paths.embedded;
          return path == null
              ? placeholder
              : _image(path, fit, () => placeholder,
                  decodeExtent: thumbnail ? 144 : null);
        }

        final adjacent = _paths.adjacent;
        if (adjacent == null ||
            preferences.source == DeviceMusicArtworkSource.embeddedOnly) {
          return embedded();
        }
        return LayoutBuilder(builder: (context, constraints) {
          final compact = thumbnail || constraints.biggest.longestSide <= 64;
          final extent = compact
              ? 144
              : preferences.quality == DeviceMusicArtworkQuality.high
                  ? 1024
                  : 512;
          return _image(adjacent, fit, embedded, decodeExtent: extent);
        });
      },
    );
  }

  Widget _image(String path, BoxFit fit, Widget Function() fallback,
      {required int? decodeExtent}) {
    final ImageProvider<Object> file = FileImage(File(path));
    final provider = decodeExtent == null
        ? file
        : ResizeImage(file,
            width: decodeExtent,
            height: decodeExtent,
            policy: ResizeImagePolicy.fit);
    return Image(
      image: provider,
      fit: fit,
      excludeFromSemantics: true,
      frameBuilder: (context, child, frame, synchronous) {
        if (!synchronous && frame == null) return placeholder;
        return artworkImageBuilder?.call(context, provider, child) ?? child;
      },
      errorBuilder: (context, error, stack) => fallback(),
    );
  }
}

/// A compact album-cover preview built from the row's current visible tracks.
class DeviceMusicCoverMosaic extends StatelessWidget {
  const DeviceMusicCoverMosaic({
    super.key,
    required this.tracks,
    required this.fallbackIcon,
  });

  final Iterable<LocalMusicTrack> tracks;
  final IconData fallbackIcon;

  // Android caches both sources by the same content digest, per grant.
  static final _cachedCoverName =
      RegExp(r'(?:^|[/\\])(?:adjacent-)?([A-Za-z0-9_-]{43})\.jpg$');

  static String _coverId(String path) =>
      _cachedCoverName.firstMatch(path)?.group(1) ?? path;

  static String? _firstPath(String? first, String? second) {
    if (first == null) return second;
    if (second == null) return first;
    return first.compareTo(second) <= 0 ? first : second;
  }

  List<_CoverPaths> _covers({required bool preferAdjacent}) {
    final albums = <String, _CoverPaths>{};
    for (final track in tracks) {
      final album = track.albumKey;
      final embedded = track.artPath;
      final adjacent = preferAdjacent ? track.adjacentArtPath : null;
      if (album == null || (embedded == null && adjacent == null)) continue;

      // Choose the same representative when the catalog returns tracks in a
      // different order. Keep both sources for the usual loader fallback.
      final previous = albums[album];
      albums[album] = (
        embedded: _firstPath(previous?.embedded, embedded),
        adjacent: _firstPath(previous?.adjacent, adjacent),
      );
    }

    final keys = albums.keys.toList()..sort();
    final used = <String>{};
    final selected = <_CoverPaths>[];
    for (final key in keys) {
      final cover = albums[key]!;
      if (!used.add(_coverId(cover.adjacent ?? cover.embedded!))) continue;
      selected.add(cover);
      if (selected.length == 4) break;
    }
    return [
      for (final cover in selected)
        (
          adjacent: cover.adjacent,
          // Reserve primary covers first so a failed image cannot fall back
          // to artwork already displayed by another tile.
          embedded: cover.adjacent == null ||
                  (cover.embedded != null &&
                      used.add(_coverId(cover.embedded!)))
              ? cover.embedded
              : null,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: 48,
        child: ListenableBuilder(
          listenable: DeviceMusicArtworkPreferences.revision,
          builder: (context, _) {
            final preferences = DeviceMusicArtworkPreferences.forDatabase(db);
            final fallback = Center(child: Icon(fallbackIcon));
            if (!preferences.loadCovers) return fallback;
            final covers = _covers(
              preferAdjacent:
                  preferences.source == DeviceMusicArtworkSource.preferAdjacent,
            );
            if (covers.isEmpty) return fallback;
            final tilePlaceholder = Center(
              child: Icon(fallbackIcon, size: covers.length == 1 ? 24 : 14),
            );

            Widget column(Iterable<_CoverPaths> tiles) => Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final cover in tiles)
                        Expanded(
                          child: DeviceMusicArtwork._thumbnail(
                            cover,
                            placeholder: tilePlaceholder,
                          ),
                        ),
                    ],
                  ),
                );

            final split = covers.length == 2 ? 1 : 2;
            return ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Row(
                  children: [
                    column(covers.take(split)),
                    if (covers.length > split) column(covers.skip(split)),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
