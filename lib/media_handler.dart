import 'package:audio_service/audio_service.dart';
import 'package:clipious/player/states/player.dart';

class MediaHandler extends BaseAudioHandler
    with
        QueueHandler, // mix in default queue callback implementations
        SeekHandler {
  final PlayerCubit controller;

  MediaHandler(this.controller) {
    controller.attachMediaHandler(this);
  }

  /// Retire the previous person's native session without the closing animation.
  Future<void> clearSession() async {
    playbackState.add(PlaybackState());
    queue.add(const <MediaItem>[]);
    queueTitle.add('');
    await playbackState.firstWhere(
        (state) => state.processingState == AudioProcessingState.idle);
    // audio_service ignores null metadata at the native boundary. Send an
    // empty item while idle to clear Android's retained title and artwork and
    // invalidate any pending artwork fetch from the previous person.
    const empty = MediaItem(id: '', title: '', artist: '');
    mediaItem.add(empty);
    await mediaItem.firstWhere((item) => identical(item, empty));
    mediaItem.add(null);
  }

  // mix in default seek callback implementations

  // The most common callbacks:
  @override
  Future<void> play() async {
    // All 'play' requests from all origins route to here. Implement this
    // callback to start playing audio appropriate to your app. e.g. music
    controller.play();
  }

  @override
  Future<void> pause() async {
    controller.pause();
  }

  @override
  Future<void> stop() async {
    controller.hide();
  }

  @override
  Future<void> seek(Duration position) async {
    controller.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    controller.playNext();
  }

  @override
  Future<void> skipToPrevious() async {
    controller.playPrevious();
  }

  @override
  Future<void> fastForward() async {
    controller.fastForward();
  }

  @override
  Future<void> rewind() async {
    controller.rewind();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    await controller.skipToVideo(index);
  }
}
