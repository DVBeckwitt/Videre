import 'dart:async';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

enum MusicHomeWidgetAction { play, pause, previous, next, save }

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
});

/// Projects the live Music player onto Android's launcher without maintaining
/// a second queue. A transport token belongs to one committed occurrence.
class MusicHomeWidget {
  static final _log = Logger('MusicHomeWidget');
  final MusicHomeWidgetPlayback? Function() _readPlayback;
  final void Function(MusicHomeWidgetAction) _onAction;
  final MethodChannel _channel;
  final List<StreamSubscription<Object?>> _subscriptions;
  MusicHomeWidgetPlayback? _published;
  String? _token;
  bool _closed = false;

  MusicHomeWidget({
    required MusicHomeWidgetPlayback? Function() readPlayback,
    required void Function(MusicHomeWidgetAction) onAction,
    required Iterable<Stream<Object?>> updates,
    MethodChannel channel = const MethodChannel('videre/music_home_widget'),
  })  : _readPlayback = readPlayback,
        _onAction = onAction,
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
    if (playback == _published) return;
    if (playback?.owner != _published?.owner) {
      _token = playback == null ? null : const Uuid().v4();
    }
    _published = playback;
    unawaited(_publish(playback, _token));
  }

  Future<void> _publish(
    MusicHomeWidgetPlayback? playback,
    String? token,
  ) async {
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
    if (playback == null ||
        _token == null ||
        arguments['token'] != _token ||
        playback.owner != _published?.owner) {
      return false;
    }
    final enabledAction = switch (arguments['action']) {
      'play' when playback.status.action == MusicHomeWidgetAction.play =>
        MusicHomeWidgetAction.play,
      'pause' when playback.status.action == MusicHomeWidgetAction.pause =>
        MusicHomeWidgetAction.pause,
      'previous' when playback.canPrevious => MusicHomeWidgetAction.previous,
      'next' when playback.canNext => MusicHomeWidgetAction.next,
      'save' when playback.canSave => MusicHomeWidgetAction.save,
      _ => null,
    };
    if (enabledAction == null) return false;
    _onAction(enabledAction);
    return true;
  }

  Future<void> close() async {
    _closed = true;
    _channel.setMethodCallHandler(null);
    await _publish(null, null);
    await Future.wait(
      _subscriptions.map((subscription) => subscription.cancel()),
    );
  }
}
