import 'package:flutter/foundation.dart';

import '../../downloads/models/downloaded_video.dart';
import '../../downloads/services/download_storage.dart';
import '../models/local_music_track.dart';
import '../models/on_device_music_entry.dart';
import 'local_music_library.dart';

/// Combines current device catalog rows with readable downloads for one profile.
class OnDeviceMusicDownloads extends ChangeNotifier {
  OnDeviceMusicDownloads({DownloadStorage? storage})
      : _storage = storage ?? DownloadStorage();

  final DownloadStorage _storage;
  String? _profile;
  int _revision = 0;
  bool _disposed = false;
  Map<String, DownloadedVideo> _requested = const {};
  List<MusicFileProbe> _available = const [];
  Map<LocalMusicTrack, String> _aliases = const {};
  List<LocalMusicTrack>? _checkedTracks;

  String? aliasProof(LocalMusicTrack track) => _aliases[track];

  List<OnDeviceMusicEntry> entries(
      LocalMusicLibrary library, String profileId) {
    final visible = library.visibleTracks;
    if (_profile != profileId || _available.isEmpty) {
      return [for (final track in visible) OnDeviceMusicEntry.device(track)];
    }

    final currentAliases = {
      for (final entry in _aliases.entries)
        if (identical(library.trackById(entry.key.playbackId), entry.key))
          entry.key: entry.value,
    };
    final hidden = library.hiddenDownloadProofs;
    final indexed = currentAliases.values.toSet();
    // Until the first scan and alias check finish, app-owned downloads may
    // already be readable. Private files cannot alias the device catalog.
    final hasLocalAliasSources = library.roots.any(
        (root) => !root.isDocumentProvider && !library.isRootUnavailable(root));
    final showShared = !hasLocalAliasSources ||
        library.error != null ||
        identical(_checkedTracks, library.tracks);
    final listed = <String>{};
    return [
      for (final track in visible)
        if (currentAliases[track] case final proof?) ...[
          if (!hidden.contains(proof) && listed.add(proof))
            OnDeviceMusicEntry.device(track),
        ] else
          OnDeviceMusicEntry.device(track),
      for (final file in _available)
        if (_requested[file.download.videoId] == file.download &&
            (showShared || file.download.storageUri == null) &&
            !indexed.contains(file.identity) &&
            !hidden.contains(file.identity) &&
            listed.add(file.identity))
          OnDeviceMusicEntry.download(file.download, file.identity,
              sizeBytes: file.byteLength),
    ];
  }

  Future<void> refresh(LocalMusicLibrary library, String profileId,
      Iterable<DownloadedVideo> downloads,
      {bool Function()? isCurrent}) async {
    if (_disposed || isCurrent?.call() == false) return;
    final rev = ++_revision;
    bool current() =>
        !_disposed && _revision == rev && isCurrent?.call() != false;
    if (_profile != profileId) {
      _profile = profileId;
      _available = const [];
      _aliases = const {};
      _checkedTracks = null;
    }
    final requested = {
      for (final file in downloads)
        if (file.profileId == profileId) file.videoId: file,
    };
    _requested = requested;
    final available =
        await _storage.probeMusicFiles(profileId, requested.values);
    if (!current()) return;
    final selection = library.selectionId;
    final tracks = library.tracks;
    final loaded = library.loaded && !library.scanning;
    final matches =
        await library.verifiedDownloadAliases(available, isCurrent: current);
    if (!current()) return;
    final identities = {
      for (final file in available) file.download.videoId: file.identity,
    };
    final aliases = matches == null
        ? _aliases
        : {
            for (final entry in matches.entries)
              if (identities[entry.key] case final proof?)
                for (final track in entry.value) track: proof,
          };
    if (matches != null) {
      try {
        await library.rememberHiddenDownloadAliases(aliases,
            isCurrent: current);
      } catch (_) {
        // A saved decision may already belong to a profile that just closed.
      }
    }
    if (!current()) return;
    _available = available;
    _aliases = aliases;
    if (loaded &&
        library.acceptsSessionSelection(selection) &&
        identical(library.tracks, tracks)) {
      _checkedTracks = tracks;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
