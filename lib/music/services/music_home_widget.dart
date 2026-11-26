import 'dart:async';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

enum MusicHomeWidgetAction {
  play,
  pause,
  previous,
  next,
  save,
  like,
  unlike,
  shuffle
}

typedef MusicHomeWidgetShuffle = ({
  bool enabled,
  bool selected,
  int generation,
  int selectionRevision,
  int sessionRevision,
});

enum MusicHomeWidgetStatus {
  loading(MusicHomeWidgetAction.pause),
  buffering(MusicHomeWidgetAction.pause),
  playing(MusicHomeWidgetAction.pause),
  paused(MusicHomeWidgetAction.play),
  ended(MusicHomeWidgetAction.play),
  unavailable(null);

  const MusicHomeWidgetStatus(this.action);

  final MusicHomeWidgetAction? action;
}

typedef MusicHomeWidgetPlayback = ({
  (String, String, int) owner,
  String title,
  String artist,
  MusicHomeWidgetStatus status,
  bool canPrevious,
  bool canNext,
  bool canSave,
  bool? liked,
  String? deviceArtworkPath,
});

/// Projects the live Music player onto Android's launcher without maintaining
/// a second queue. A transport token belongs to one committed occurrence.
class MusicHomeWidget {
  static final _log = Logger('MusicHomeWidget');
  final MusicHomeWidgetPlayback? Function() _readPlayback;
  final Future<String?> Function(MusicHomeWidgetPlayback) _resolveArtwork;
  final void Function(MusicHomeWidgetAction) _onAction;
  final MusicHomeWidgetShuffle Function()? _readShuffle;
  final MethodChannel _channel;
  final List<StreamSubscription<Object?>> _subscriptions;
  MusicHomeWidgetPlayback? _published;
  MusicHomeWidgetShuffle? _publishedShuffle;
  String? _token;
  String? _likeToken;
  String? _artworkPath;
  String? _shuffleToken;
  bool _closed = false;

  MusicHomeWidget({
    required MusicHomeWidgetPlayback? Function() readPlayback,
    required Future<String?> Function(MusicHomeWidgetPlayback) resolveArtwork,
    required void Function(MusicHomeWidgetAction) onAction,
    required Iterable<Stream<Object?>> updates,
    MusicHomeWidgetShuffle Function()? readShuffle,
    MethodChannel channel = const MethodChannel('videre/music_home_widget'),
  })  : _readPlayback = readPlayback,
        _resolveArtwork = resolveArtwork,
        _onAction = onAction,
        _readShuffle = readShuffle,
        _channel = channel,
        _subscriptions = [] {
    _channel.setMethodCallHandler(_handleCall);
    _subscriptions.addAll(
      updates.map((stream) => stream.listen((_) => refresh())),
    );
    refresh();
  }

  void refresh() {
    if (_closed) return;
    final playback = _readPlayback();
    final shuffle = playback == null ? null : _readShuffle?.call();
    if (playback == _published && shuffle == _publishedShuffle) return;
    final ownerChanged = playback?.owner != _published?.owner;
    final artworkChanged = ownerChanged ||
        playback?.deviceArtworkPath != _published?.deviceArtworkPath;
    if (ownerChanged) {
      _token = playback == null ? null : const Uuid().v4();
    }
    // Retire old Like clicks without invalidating the transport controls.
    if (ownerChanged || playback?.liked != _published?.liked) {
      _likeToken = playback?.liked == null ? null : const Uuid().v4();
    }
    if (artworkChanged) _artworkPath = null;
    if (ownerChanged || shuffle != _publishedShuffle) {
      _shuffleToken = shuffle?.enabled == true ? const Uuid().v4() : null;
    }
    _published = playback;
    _publishedShuffle = shuffle;
    final token = _token;
    unawaited(_publish(playback, token, _likeToken, artworkPath: _artworkPath));
    if (artworkChanged && playback != null && token != null) {
      unawaited(_loadArtwork(playback, token));
    }
  }

  Future<void> _loadArtwork(
    MusicHomeWidgetPlayback playback,
    String token,
  ) async {
    String? path;
    try {
      path = await _resolveArtwork(playback);
    } catch (error) {
      _log.fine('Could not load Music launcher widget artwork '
          '(${error.runtimeType})');
      return;
    }
    if (path == null || _closed || _token != token) return;
    final live = _readPlayback();
    if (live?.owner != playback.owner ||
        live?.deviceArtworkPath != playback.deviceArtworkPath) {
      return;
    }
    _artworkPath = path;
    await _publish(_published, token, _likeToken, artworkPath: path);
  }

  Future<void> _publish(
    MusicHomeWidgetPlayback? playback,
    String? token,
    String? likeToken, {
    String? artworkPath,
  }) async {
    try {
      await _channel.invokeMethod<void>(
        'setPlayback',
        playback == null
            ? null
            : {
                'token': token,
                'title': playback.title,
                'artist': playback.artist,
                'status': playback.status.name,
                'playAction': playback.status.action?.name,
                'canPrevious': playback.canPrevious,
                'canNext': playback.canNext,
                'canSave': playback.canSave,
                'liked': playback.liked,
                'likeToken': likeToken,
                'artworkPath': artworkPath,
                'shuffleSelected': _publishedShuffle?.selected == true,
                'shuffleToken': _shuffleToken,
              },
      );
    } on MissingPluginException {
      // Some Flutter hosts do not provide the Android launcher plugin.
    } on PlatformException catch (error) {
      _log.fine('Could not update the Music launcher widget', error);
    }
  }

  Future<Object?> _handleCall(MethodCall call) async {
    if (call.method != 'transport') throw MissingPluginException();
    final arguments = call.arguments;
    if (_closed || arguments is! Map) return false;

    // The launcher can deliver an old click after the profile or queue changed
    // but before the next snapshot made it across the channel.
    final playback = _readPlayback();
    final action = arguments['action'];
    if (playback == null || playback.owner != _published?.owner) return false;
    if (action == 'shuffle') {
      final shuffle = _readShuffle?.call();
      if (_shuffleToken == null ||
          arguments['token'] != _shuffleToken ||
          shuffle?.enabled != true ||
          shuffle != _publishedShuffle) {
        refresh();
        return false;
      }
      _onAction(MusicHomeWidgetAction.shuffle);
      return true;
    }
    final token = action == 'like' || action == 'unlike' ? _likeToken : _token;
    if (token == null || arguments['token'] != token) return false;
    final enabledAction = switch (action) {
      'play' when playback.status.action == MusicHomeWidgetAction.play =>
        MusicHomeWidgetAction.play,
      'pause' when playback.status.action == MusicHomeWidgetAction.pause =>
        MusicHomeWidgetAction.pause,
      'previous' when playback.canPrevious => MusicHomeWidgetAction.previous,
      'next' when playback.canNext => MusicHomeWidgetAction.next,
      'save' when playback.canSave => MusicHomeWidgetAction.save,
      'like' when playback.liked == false => MusicHomeWidgetAction.like,
      'unlike' when playback.liked == true => MusicHomeWidgetAction.unlike,
      _ => null,
    };
    if (enabledAction == null) return false;
    _onAction(enabledAction);
    return true;
  }

  Future<void> close() async {
    _closed = true;
    _channel.setMethodCallHandler(null);
    await _publish(null, null, null);
    await Future.wait(
      _subscriptions.map((subscription) => subscription.cancel()),
    );
  }
}
