import 'package:json_annotation/json_annotation.dart';
import 'package:flutter/foundation.dart';

part 'progress.g.dart';

final playbackHistoryRevision = ValueNotifier(0);
const watchedProgressThreshold = 0.9;
// Duration stores microseconds in a signed 64-bit integer on native platforms.
const maximumPlaybackSeconds =
    0x7fffffffffffffff ~/ Duration.microsecondsPerSecond;

bool progressDisplayChanged(Progress? previous, Progress current) =>
    previous == null ||
    (previous.progress - current.progress).abs() >= 0.01 ||
    (previous.progress >= watchedProgressThreshold) !=
        (current.progress >= watchedProgressThreshold) ||
    (previous.positionSeconds ?? 0) ~/ 5 != (current.positionSeconds ?? 0) ~/ 5;

@JsonSerializable(createToJson: false)
class Progress {
  double progress = 0;

  String videoId;

  int? positionSeconds;

  int? durationSeconds;

  Progress(this.progress, this.videoId,
      {this.positionSeconds, this.durationSeconds});

  Progress.named(
      {required this.progress,
      required this.videoId,
      this.positionSeconds,
      this.durationSeconds});

  /// Old records only contain a fraction; completed fractions have no useful
  /// seek position. Precise records retain time even after the watched badge
  /// appears, and a changed video duration bounds the saved position.
  Duration resumePosition({int? durationSeconds}) {
    int? validDuration(int? seconds) =>
        seconds != null && seconds > 0 && seconds <= maximumPlaybackSeconds
            ? seconds
            : null;
    final duration =
        validDuration(durationSeconds) ?? validDuration(this.durationSeconds);
    final position = positionSeconds;
    if (position != null &&
        position >= 0 &&
        position <= maximumPlaybackSeconds) {
      return Duration(
          seconds: duration != null ? position.clamp(0, duration) : position);
    }
    if (duration == null ||
        !progress.isFinite ||
        progress <= 0 ||
        progress >= 1) {
      return Duration.zero;
    }
    return Duration(seconds: (progress * duration).round());
  }

  factory Progress.fromJson(Map<String, dynamic> json) =>
      _$ProgressFromJson(json);

  Map<String, dynamic> toJson() => {
        'progress': progress,
        'videoId': videoId,
        if (positionSeconds != null) 'positionSeconds': positionSeconds,
        if (durationSeconds != null) 'durationSeconds': durationSeconds,
      };
}
