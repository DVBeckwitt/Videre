import '../../videos/models/video.dart';

enum MediaCommandType {
  play,
  pause,
  seek,
  mute,
  unmute,
  speed,
  pitch,
  switchVideo,
  switchToOfflineVideo,
  // those are more to let the player know if they need to do anything when the full screen status changes
  enterFullScreen,
  exitFullScreen
}

class MediaCommand<T> {
  final MediaCommandType type;
  final T? value;
  final bool Function()? canExecute;

  const MediaCommand(this.type, {this.value, this.canExecute});
}

class SwitchVideoValue {
  Video video;
  Duration? startAt;

  SwitchVideoValue({required this.video, this.startAt});
}
