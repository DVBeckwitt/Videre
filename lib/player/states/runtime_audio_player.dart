import 'dart:async';

import 'package:logging/logging.dart';

import '../models/media_command.dart';
import 'audio_player.dart';
import 'player.dart';

/// Owns the main Android player's decoder for the life of the Flutter engine.
class RuntimeAudioPlayer {
  final PlayerCubit _player;
  final _retiring = <Future<void>>{};
  late final StreamSubscription<PlayerState> _changes;
  MediaCommand? _lastCommand;
  AudioPlayerCubit? _decoder;

  RuntimeAudioPlayer(this._player) {
    _changes = _player.stream.listen(_update);
    _update(_player.state);
  }

  AudioPlayerCubit? get decoder => _decoder;

  void _update(PlayerState state) {
    final command = state.mediaCommand;
    final changed = _lastCommand != command;
    _lastCommand = command;
    if (!state.isAudio || !state.hasVideo) {
      _releaseDecoder();
      return;
    }

    final existing = _decoder;
    if (existing == null) {
      // Another selection may already have superseded this stream event.
      final current = _player.state;
      if (!current.isAudio || current.currentQueueId != state.currentQueueId) {
        return;
      }
      _decoder = AudioPlayerCubit(
          AudioPlayerState(
              video: state.currentlyPlaying,
              offlineVideo: state.offlineCurrentlyPlaying),
          _player,
          _player.settings);
    } else if (changed && command != null) {
      existing.handleCommand(command);
    }
  }

  void _releaseDecoder() {
    final closing = _decoder;
    _decoder = null;
    if (closing == null) return;
    final released = closing.close().catchError((Object error) {
      Logger('AudioPlayerController')
          .fine('Audio decoder cleanup failed (${error.runtimeType})');
    });
    _retiring.add(released);
    unawaited(released.then((_) => _retiring.remove(released)));
  }

  Future<void> close() async {
    await _changes.cancel();
    _releaseDecoder();
    await Future.wait(_retiring);
  }
}
