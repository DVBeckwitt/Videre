import 'package:flutter/painting.dart';

/// How to present the video frame within the player viewport.
enum VideoDisplayMode {
  fit(BoxFit.contain),
  crop(BoxFit.cover),
  stretch(BoxFit.fill),
  ratio4x3(BoxFit.contain, 4 / 3),
  ratio3x2(BoxFit.contain, 3 / 2),
  ratio16x9(BoxFit.contain, 16 / 9),
  ratio21x9(BoxFit.contain, 21 / 9);

  const VideoDisplayMode(this.boxFit, [this.aspectRatio]);

  final BoxFit boxFit;
  final double? aspectRatio;

  static VideoDisplayMode? fromStorage(String? value) {
    for (final mode in values) {
      if (mode.name == value) return mode;
    }
    return null;
  }
}
