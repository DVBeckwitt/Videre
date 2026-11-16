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
    final podcast = controller.activePodcast;
    if (podcast != null) {
      await podcast.resume();
    } else {
      controller.play();
    }
  }

  @override
  Future<void> pause() async {
    final podcast = controller.activePodcast;
    if (podcast != null) {
      await podcast.pause();
    } else {
      controller.pause();
    }
  }

  @override
  Future<void> stop() async {
    final podcast = controller.activePodcast;
    if (podcast != null) {
      await podcast.stop();
    } else {
      controller.hide();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    final podcast = controller.activePodcast;
    if (podcast != null) {
      await podcast.seek(position);
    } else {
      controller.seek(position);
    }
  }

  @override
  Future<void> skipToNext() async {
    if (controller.activePodcast != null) {
      await fastForward();
    } else {
      controller.playNext();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (controller.activePodcast != null) {
      await rewind();
    } else {
      controller.playPrevious();
    }
  }

  @override
  Future<void> fastForward() async {
    final podcast = controller.activePodcast;
    if (podcast != null) {
      await podcast.seek(podcast.position + const Duration(seconds: 30));
    } else {
      controller.fastForward();
    }
  }

  @override
  Future<void> rewind() async {
    final podcast = controller.activePodcast;
    if (podcast != null) {
      await podcast.seek(podcast.position - const Duration(seconds: 15));
    } else {
      controller.rewind();
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (controller.activePodcast == null) {
      await controller.skipToVideo(index);
    }
  }

  @override
  Future<void> setSpeed(double speed) async {
    final podcast = controller.activePodcast;
    if (podcast != null) await podcast.setSpeed(speed);
  }
}
