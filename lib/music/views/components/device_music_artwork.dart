import 'dart:io';

import 'package:flutter/material.dart';

import '../../../globals.dart' show db;
import '../../models/device_music_artwork_preferences.dart';
import '../../models/local_music_track.dart';

/// Renders artwork from the current device catalog, with an embedded fallback.
class DeviceMusicArtwork extends StatelessWidget {
  DeviceMusicArtwork({
    super.key,
    required LocalMusicTrack track,
    required this.placeholder,
    this.thumbnail = false,
  })  : _embeddedPath = track.artPath,
        _adjacentPath = track.adjacentArtPath;

  DeviceMusicArtwork.album({
    super.key,
    required Iterable<LocalMusicTrack> tracks,
    required this.placeholder,
    this.thumbnail = false,
  })  : _embeddedPath =
            tracks.map((track) => track.artPath).nonNulls.firstOrNull,
        _adjacentPath =
            tracks.map((track) => track.adjacentArtPath).nonNulls.firstOrNull;

  final String? _embeddedPath;
  final String? _adjacentPath;
  final Widget placeholder;
  final bool thumbnail;

  @override
  Widget build(BuildContext context) {
    if (_embeddedPath == null && _adjacentPath == null) {
      return placeholder;
    }
    return ListenableBuilder(
      listenable: DeviceMusicArtworkPreferences.revision,
      builder: (context, _) {
        final preferences = DeviceMusicArtworkPreferences.forDatabase(db);
        final fit = preferences.crop == DeviceMusicArtworkCrop.fit
            ? BoxFit.contain
            : BoxFit.cover;

        Widget embedded() {
          final path = _embeddedPath;
          return path == null
              ? placeholder
              : _image(path, fit, () => placeholder,
                  decodeExtent: thumbnail ? 144 : null);
        }

        final adjacent = _adjacentPath;
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
    return Image(
      image: decodeExtent == null
          ? file
          : ResizeImage(file,
              width: decodeExtent,
              height: decodeExtent,
              policy: ResizeImagePolicy.fit),
      fit: fit,
      excludeFromSemantics: true,
      frameBuilder: (context, child, frame, synchronous) =>
          synchronous || frame != null ? child : placeholder,
      errorBuilder: (context, error, stack) => fallback(),
    );
  }
}
