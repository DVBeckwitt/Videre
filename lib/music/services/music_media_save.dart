import 'dart:async';

import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/notifications/notifications.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

typedef MusicMediaSaveRequest = ({
  IdedVideo entry,
  LocalMusicTrack? deviceTrack,
  bool Function() isCurrent,
});
const musicMediaSaveActionPrefix = 'videre.music.savePlaylist.';

/// A media command can request a picker while Android has no visible Activity.
/// Keep the selected entry in this Flutter engine and send only a ticket to the
/// system notification that can bring the existing Activity forward.
class MusicMediaSave extends ChangeNotifier {
  static final _log = Logger('MusicMediaSave');

  ({String ticket, MusicMediaSaveRequest request})? _pending;
  Timer? _expiration;
  Future<void> _notification = Future.value();
  bool _ready = false;
  bool _presenting = false;
  bool _disposed = false;

  bool get hasReadyRequest => _ready && !_presenting;

  void request(MusicMediaSaveRequest request, String label) {
    if (_disposed || _presenting || !request.isCurrent()) return;
    final ticket = const Uuid().v4();
    _pending = (ticket: ticket, request: request);
    _expiration?.cancel();
    _expiration = Timer(const Duration(minutes: 2), clear);
    _ready =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (_ready) {
      notifyListeners();
    } else {
      _updateNotification(() async {
        if (_pending?.ticket == ticket && !_ready && request.isCurrent()) {
          await MusicPlaylistSaveNotification.show(label, ticket);
        }
      });
    }
  }

  // Tapping the media card also works when regular notifications are disabled.
  void open([String? ticket]) {
    final pending = _pending;
    if (pending == null || (ticket != null && pending.ticket != ticket)) return;
    _ready = true;
    notifyListeners();
  }

  void dismiss(String ticket) {
    if (_pending?.ticket == ticket) clear();
  }

  MusicMediaSaveRequest? take() {
    final pending = _pending;
    if (!_ready || _presenting || pending == null) return null;
    clear();
    if (!pending.request.isCurrent()) return null;
    _presenting = true;
    return pending.request;
  }

  void finish() => _presenting = false;

  void clear() {
    if (_pending == null) return;
    _pending = null;
    _expiration?.cancel();
    _expiration = null;
    _ready = false;
    _updateNotification(MusicPlaylistSaveNotification.dismiss);
  }

  void _updateNotification(Future<void> Function() update) {
    _notification = _notification.then((_) async {
      try {
        await update();
      } catch (_) {
        _log.fine('Music playlist notification unavailable.');
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    clear();
    super.dispose();
  }
}
