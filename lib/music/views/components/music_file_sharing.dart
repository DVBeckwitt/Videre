import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../downloads/models/downloaded_video.dart';
import '../../../downloads/services/download_storage.dart';
import '../../../downloads/services/explicit_music_download.dart';
import '../../../globals.dart' show db;
import '../../../l10n/generated/app_localizations.dart';
import '../../models/local_music_track.dart';
import '../../services/local_music_library.dart';

bool get supportsMusicFileSharing =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

bool canShareDownloadedMusicFile(DownloadedVideo file) =>
    supportsMusicFileSharing &&
    file.profileId == db.profileId &&
    file.audioOnly &&
    file.downloadComplete &&
    !file.downloadFailed &&
    !file.storageFailed &&
    !file.authenticationRequired;

Future<void> shareLocalMusicFile(
        BuildContext context, LocalMusicLibrary library, LocalMusicTrack track,
        {required bool Function() isCurrent}) =>
    _shareFile(context, isCurrent, () => library.shareTrack(track));

Future<void> shareDownloadedMusicFile(
    BuildContext context, DownloadedVideo file,
    {String? expectedIdentity, required bool Function() isCurrent}) {
  final database = db;
  final owner = database.forProfile(file.profileId);
  final fingerprint = musicDownloadFingerprint(file);
  DownloadedVideo? ready() =>
      readyMusicDownload(owner, file.videoId, fingerprint: fingerprint);
  bool current() =>
      identical(db, database) &&
      canShareDownloadedMusicFile(file) &&
      isCurrent();

  return _shareFile(context, current, () async {
    final saved = ready();
    if (saved == null) return false;
    return DownloadStorage().shareMusicFile(saved,
        expectedIdentity: expectedIdentity,
        isCurrent: () => current() && ready() != null);
  });
}

Future<void> _shareFile(BuildContext context, bool Function() isCurrent,
    Future<bool> Function() openShareSheet) async {
  if (!supportsMusicFileSharing || !context.mounted || !isCurrent()) return;
  try {
    if (await openShareSheet()) return;
  } on PlatformException {
    // The file, grant or Android chooser can disappear before it is opened.
  } on MissingPluginException {
    // No Android share receiver is available in this environment.
  }
  if (context.mounted && isCurrent()) {
    final locals = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(locals.musicShareAudioFileError)));
  }
}
