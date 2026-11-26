import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../downloads/models/downloaded_video.dart';
import '../../../downloads/services/download_storage.dart';
import '../../../downloads/services/explicit_music_download.dart';
import '../../../globals.dart' show db;
import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../models/local_music_track.dart';
import '../../services/local_music_library.dart';
import 'music_file_sharing.dart';

class MusicRingtoneSource {
  final bool Function() _isCurrent;
  final Future<bool> Function() _probe;
  final Future<String?> Function() _set;

  const MusicRingtoneSource._(this._isCurrent, this._probe, this._set);

  static MusicRingtoneSource? local(
      LocalMusicLibrary library, LocalMusicTrack track,
      {required bool Function() isCurrent}) {
    if (!supportsMusicFileSharing || isTv) return null;
    return MusicRingtoneSource._(
      isCurrent,
      () => library.canSetTrackRingtone(track),
      () => library.setTrackRingtone(track),
    );
  }

  static MusicRingtoneSource? download(DownloadedVideo file,
      {String? expectedIdentity, required bool Function() isCurrent}) {
    if (isTv || !canShareDownloadedMusicFile(file)) return null;
    final database = db;
    final owner = database.forProfile(file.profileId);
    final fingerprint = musicDownloadFingerprint(file);
    final storage = DownloadStorage();
    bool current() =>
        identical(db, database) &&
        db.profileId == file.profileId &&
        isCurrent();
    DownloadedVideo? ready() =>
        readyMusicDownload(owner, file.videoId, fingerprint: fingerprint);
    return MusicRingtoneSource._(
      current,
      () async {
        final saved = ready();
        return saved != null &&
            await storage.canSetMusicRingtone(saved,
                expectedIdentity: expectedIdentity, isCurrent: current);
      },
      () async {
        final saved = ready();
        return saved == null
            ? null
            : storage.setMusicRingtone(saved,
                expectedIdentity: expectedIdentity,
                isCurrent: () => current() && ready() != null);
      },
    );
  }

  Future<bool> _isAvailable() async {
    if (!_isCurrent()) return false;
    try {
      return await _probe() && _isCurrent();
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> set(BuildContext context) async {
    if (!context.mounted || !_isCurrent()) return;
    final database = db;
    final profile = database.profileId;
    String? outcome;
    try {
      outcome = await _set();
    } on MissingPluginException {
      outcome = 'unavailable';
    } on PlatformException {
      // The source or the system settings activity may have disappeared.
    }
    if (!context.mounted ||
        !identical(db, database) ||
        db.profileId != profile) {
      return;
    }
    final locals = AppLocalizations.of(context)!;
    final message = switch (outcome) {
      'set' => locals.musicRingtoneSet,
      'cancelled' => locals.musicRingtoneCancelled,
      'unavailable' => locals.musicRingtoneUnavailable,
      _ => locals.musicRingtoneFailed,
    };
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Resolves file access when a song menu opens, without delaying its other items.
class MusicRingtoneMenuItem<T> extends PopupMenuEntry<T> {
  final T value;
  final MusicRingtoneSource source;

  const MusicRingtoneMenuItem(
      {super.key, required this.value, required this.source});

  @override
  double get height => 0;

  @override
  bool represents(T? value) => this.value == value;

  @override
  State<MusicRingtoneMenuItem<T>> createState() =>
      _MusicRingtoneMenuItemState<T>();
}

class _MusicRingtoneMenuItemState<T> extends State<MusicRingtoneMenuItem<T>> {
  late final Future<bool> _available = widget.source._isAvailable();

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
      future: _available,
      builder: (context, snapshot) => snapshot.data == true
          ? PopupMenuItem<T>(
              value: widget.value,
              child: Text(AppLocalizations.of(context)!.musicSetRingtone))
          : const SizedBox.shrink());
}
