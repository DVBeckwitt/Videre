import 'package:flutter/foundation.dart';

/// Marker actions for the currently admitted Music audio source.
class MusicAbRepeatControls {
  const MusicAbRepeatControls({
    required this.generation,
    required this.sourceRevision,
    required this.mark,
    required this.clear,
    this.start,
    this.end,
  });

  final int generation;
  final int sourceRevision;
  final Duration? start;
  final Duration? end;
  final bool Function() mark;
  final VoidCallback clear;

  bool get isActive => end != null;
}
