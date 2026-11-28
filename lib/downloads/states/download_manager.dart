import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:bloc/bloc.dart';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:downloadsfolder/downloadsfolder.dart';
import 'package:flutter/foundation.dart' show Listenable, ValueNotifier;
import 'package:flutter/services.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/downloads/models/music_offline_policy.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/download_playback_provenance.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/music/models/song_artwork.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/invidious_image.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:videre_proxy/videre_proxy.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/connectivity.dart';
import 'package:clipious/podcasts/services/podcast_downloads.dart';

import '../../music/services/cached_music.dart';
import '../../player/states/player.dart';
import '../../network/gateway_session_bridge.dart';
import '../../network/nerdvpn_access.dart';
import '../../playlists/models/playlist.dart';
import '../../settings/models/errors/invidious_service_error.dart';
import '../../utils/interfaces/db.dart';
import '../../videos/models/adaptive_format.dart';
import '../../videos/models/dearrow.dart';
import '../../videos/models/music_metadata.dart';
import '../../videos/models/sponsor_segment.dart';
import '../../videos/models/sponsor_segment_types.dart';
import '../../videos/models/video.dart';
import '../../videos/services/download_audio_tracks.dart';
import '../models/music_playlist_offline.dart';
import 'resumable_download.dart';
import '../services/download_rename.dart';
import '../services/download_recovery.dart';
import '../services/download_storage.dart';
import '../services/download_space.dart';
import '../services/download_transfer_rate.dart';
import '../services/download_mux.dart';
import '../services/explicit_music_download.dart';
import '../services/music_download_storage.dart';

part 'download_manager.freezed.dart';

final Logger log = Logger('DownloadState');
const _wifiSetting = 'downloads-wifi-only';
const _pausedSetting = 'downloads-paused';
const _keptOfflineSetting = 'music-playlists-kept-offline';
const _offlineDiscoverySetting = 'music-offline-discovery';
const _discoveryPolicy =
    MusicOfflinePolicy(quality: MusicOfflineQuality.dataSaver);

Future<int> _configuredDiscoveryBudget() async =>
    (await PlaybackCache.status()).maxBytes;

Future<({int byteLength, String sha256})> _privateDownloadIntegrity(
        String path) =>
    Isolate.run(() async {
      final file = File(path);
      final before = await file.stat();
      final digest = await sha256.bind(file.openRead()).first;
      final after = await file.stat();
      if (before.type != FileSystemEntityType.file ||
          before.size <= 0 ||
          before.size != after.size ||
          before.modified != after.modified) {
        throw const FileSystemException('The downloaded file changed');
      }
      return (byteLength: after.size, sha256: digest.toString());
    });

// The catalog only admits decoder-confirmed WebM or MP4 audio. Older entries
// lack MIME metadata. Identify WebM by its EBML header and let the MP4
// demuxer validate the other input, including files with a leading free box.
Future<DownloadContainer> _cachedMusicContainer(File file) async {
  final input = await file.open();
  try {
    final header = await input.read(4);
    if (header.length != 4) {
      throw const FormatException('Incomplete cached Music header');
    }
    return header[0] == 0x1a &&
            header[1] == 0x45 &&
            header[2] == 0xdf &&
            header[3] == 0xa3
        ? DownloadContainer.webm
        : DownloadContainer.mp4;
  } finally {
    await input.close();
  }
}

enum KeepCachedMusicResult {
  saved,
  alreadySaved,
  unavailable,
  conflictingDownload,
  failed,
}

class DownloadProgress {
  final CancelToken cancelToken;
  final DateTime? retryAt;
  final int? bytesPerSecond;
  int count = 0, total = 1;

  DownloadProgress(this.cancelToken, {this.retryAt, this.bytesPerSecond});
}

/// The jobs present when a Music removal confirmation was opened.
class MusicDownloadDeletionApproval {
  final DownloadManagerCubit _manager;
  final int _generation;
  final List<({DownloadedVideo video, Object incarnation})> _jobs;

  MusicDownloadDeletionApproval._(this._manager, this._generation, this._jobs);
}

class DownloadManagerCubit extends Cubit<DownloadManagerState> {
  final PlayerCubit player;
  final DownloadStorage storage;
  final Future<DownloadConnectivity> Function() _readConnectivity;
  final Stream<DownloadConnectivity>? _networkChanges;
  final Future<int> Function() _discoveryBudgetBytes;
  final Future<void> Function(
      {required String input,
      required String output,
      required DownloadedVideo video,
      required CancelToken token,
      String? sourceCodec,
      MusicDownloadFormat? inputFormat}) encodeMusic;
  final AudioExportProbe _probeAudioExport;
  final Future<void> Function(List<String>, CancelToken) _muxAudioExport;
  late final Future<void> _ready;
  Future<void>? _closeFuture;
  late IDbClient _library;
  StreamSubscription<DownloadConnectivity>? _networkSubscription;
  StreamSubscription<SettingsValue?>? _playlistSubscription;
  late final StreamSubscription<({IDbClient database, Set<String> profiles})>
      _renames;
  final Set<Future<void>> _mutations = {};
  final Set<String> _deleting = {};
  final Set<String> _enqueuing = {};
  final Map<String, Object> _musicDeletionIncarnations = {};
  final Map<String, ({CancelToken token, Future<bool> result, bool edited})>
      _exports = {};
  DownloadFolderPreferences _folders = const DownloadFolderPreferences();
  Future<void> _folderWrite = Future.value();
  Future<void> _offlineMusicWork = Future.value();
  CancelToken? _keepingCachedMusic;
  final _playlistOfflineChanges = ValueNotifier(0);
  final _discoveryOfflineChanges = ValueNotifier(0);
  Map<String, MusicOfflinePolicy>? _keptOfflinePlaylists;
  List<String>? _offlineDiscovery;
  String? _playlistSource;
  List<Playlist>? _localPlaylistSnapshot;
  Map<String, MusicOfflinePolicy>? _lastPlaylistPins;
  Map<String, ({Video video, MusicOfflinePolicy policy})>?
      _requiredPlaylistSongs;
  final _folderChoiceRevision = <bool, int>{};
  int _musicFolderRevision = 0;
  Future<String?>? _pendingMusicFolder;
  DownloadConnectivity _connectivity = (wifi: false, online: true);
  int _networkRevision = 0;
  bool _networkReady = false;
  bool _processing = false, _closing = false;
  bool _activeNeedsNetwork = false;
  CancelToken? _activeArtworkToken;
  bool _switchingProfile = false;
  int _generation = 0;
  String? _activeId;
  Future<void>? _activeJob;
  Completer<void>? _drainFinished;

  DownloadManagerCubit(super.initialState, this.player,
      {DownloadStorage? storage,
      this.encodeMusic = runMusicDownloadMux,
      AudioExportProbe audioExportProbe = probeAudioExport,
      Future<void> Function(List<String>, CancelToken) audioExportMux =
          runDownloadMux,
      Future<bool> Function()? wifiConnected,
      Stream<bool>? wifiChanges,
      Future<DownloadConnectivity> Function()? readConnectivity,
      Stream<DownloadConnectivity>? connectivityChanges,
      Future<int> Function()? discoveryBudgetBytes})
      : storage = storage ?? DownloadStorage(),
        _probeAudioExport = audioExportProbe,
        _muxAudioExport = audioExportMux,
        _discoveryBudgetBytes =
            discoveryBudgetBytes ?? _configuredDiscoveryBudget,
        _readConnectivity = readConnectivity ??
            (wifiConnected != null || wifiChanges != null || !Platform.isAndroid
                ? () async =>
                    (wifi: await wifiConnected?.call() ?? false, online: true)
                : readDownloadConnectivity),
        _networkChanges = connectivityChanges ??
            (wifiChanges != null
                ? wifiChanges.map((wifi) => (wifi: wifi, online: true))
                : Platform.isAndroid &&
                        wifiConnected == null &&
                        readConnectivity == null
                    ? downloadConnectivityChanges
                    : null) {
    _library = db.forProfile(db.profileId);
    _renames = localMusicDownloadRenames.listen((change) {
      if (identical(change.database, db) &&
          _current &&
          change.profiles.contains(_library.profileId)) {
        setVideos();
      }
    });
    _ready = onReady();
    NetworkProxy.instance.addBeforeApply(_proxyChanging);
  }

  bool get _current => !_closing && _library.profileId == db.profileId;

  DateTime? retryAtFor(DownloadedVideo video) {
    if (video.profileId != _library.profileId || video.accountId == null) {
      return null;
    }
    final account = _library.getAccount(video.accountId!);
    return account == null
        ? null
        : DownloadRecovery.retryAtFor(service, _library, account);
  }

  Future<T> _mutate<T>(Future<T> Function() action) {
    final result = Future<T>.sync(action);
    final settled =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _mutations.add(settled);
    unawaited(settled.then((_) => _mutations.remove(settled)));
    return result;
  }

  /// Called before changing the active person or account. A cancelled transfer
  /// can finish only in its original library; switching waits for all writers.
  Future<void> pauseForProfileSwitch() async {
    _switchingProfile = true;
    if (!_closing) _discoveryOfflineChanges.value++;
    _keepingCachedMusic?.cancel();
    for (final export in _exports.values) {
      export.token.cancel();
    }
    for (final progress in state.downloadProgresses.values) {
      progress.cancelToken.cancel();
    }
    await _ready;
    await Future.wait(List.of(_mutations));
    final paused = {
      ...state.pausedVideoIds,
      for (final video in _library.getAllDownloads())
        if (!video.downloadComplete) video.videoId,
    };
    await _library.saveSetting(
        SettingsValue(_pausedSetting, jsonEncode(paused.toList())));
    if (_current) emit(state.copyWith(pausedVideoIds: paused));
    await _activeJob;
    await _drainFinished?.future;
  }

  /// Called after the profile/account selection has committed. Paused jobs stay
  /// paused until resumed explicitly, and retain the account that created them.
  Future<void> reloadForProfile() async {
    await pauseForProfileSwitch();
    if (_closing) return;
    await _playlistSubscription?.cancel();
    _generation++;
    _library = db.forProfile(db.profileId);
    _deleting.clear();
    _enqueuing.clear();
    _musicDeletionIncarnations.clear();
    _loadLibrary();
    _switchingProfile = false;
    _discoveryOfflineChanges.value++;
    _watchPlaylistMembership();
    _networkChanged(_connectivity);
  }

  Future<void> _proxyChanging() async {
    final library = _library;
    final generation = _generation;
    // Stop current transfers before yielding, even while another consumer is
    // still disposing. Policy changes close the underlying HTTP connections;
    // these failures must be treated as cancellation rather than retried jobs.
    for (final progress in state.downloadProgresses.values) {
      progress.cancelToken.cancel();
    }
    await _ready;
    if (generation != _generation || _closing) return;
    final paused = {
      ...state.pausedVideoIds,
      for (final video in state.videos)
        if (!video.downloadComplete) video.videoId,
    };
    emit(state.copyWith(pausedVideoIds: paused));
    for (final progress in state.downloadProgresses.values) {
      progress.cancelToken.cancel();
    }
    await library.saveSetting(
        SettingsValue(_pausedSetting, jsonEncode(paused.toList())));
    await _activeJob;
  }

  Future<void> onReady() async {
    _loadLibrary();
    _watchPlaylistMembership();
    _networkSubscription = _networkChanges?.listen((connectivity) {
      _networkRevision++;
      _networkChanged(connectivity);
    }, onError: (Object error) {
      log.fine(
          'Download connectivity events are unavailable', error.runtimeType);
    });
    await _refreshConnectivity();
  }

  Future<void> _refreshConnectivity() async {
    final revision = _networkRevision;
    var connectivity = _connectivity;
    try {
      connectivity = await _readConnectivity();
    } catch (error) {
      log.fine('Download connectivity could not be read', error.runtimeType);
    }
    // An event delivered during this request is newer than the requested read.
    if (revision == _networkRevision) _networkChanged(connectivity);
  }

  void _loadLibrary() {
    Set<String> paused = {};
    _folders = _readFolders();
    _pendingMusicFolder = null;
    try {
      final saved =
          jsonDecode(_library.getSettings(_pausedSetting)?.value ?? '[]');
      if (saved is List) paused = saved.whereType<String>().toSet();
    } on FormatException {
      // An interrupted settings import should not block the download library.
    }
    _playlistSource = null;
    _localPlaylistSnapshot = null;
    _lastPlaylistPins = null;
    _requiredPlaylistSongs = null;
    final pins = _library.getSettings(_keptOfflineSetting)?.value;
    try {
      final entries = jsonDecode(pins ?? '{}');
      _keptOfflinePlaylists = entries is Map<String, dynamic> &&
              entries.entries.every((entry) =>
                  entry.key.startsWith('local:') && entry.value is Map)
          ? entries.map(
              (id, policy) => MapEntry(id, MusicOfflinePolicy.fromJson(policy)))
          : null;
    } on FormatException {
      // An invalid owner list cannot authorize automatic removal.
      _keptOfflinePlaylists = null;
    }
    try {
      final ids = jsonDecode(
          _library.getSettings(_offlineDiscoverySetting)?.value ?? '[]');
      _offlineDiscovery = ids is List &&
              ids.every(
                  (id) => id is String && DownloadedVideo.isSafeFileId(id))
          ? List.unmodifiable(ids.cast<String>().toSet())
          : null;
    } on FormatException {
      _offlineDiscovery = null;
    }
    emit(_withFolders(state.copyWith(
        wifiOnly: _library.getSettings(_wifiSetting)?.value == 'true',
        pausedVideoIds: paused,
        downloadProgresses: {},
        spaceBlockedVideoIds: {},
        videos: _library.getAllDownloads())));
    _playlistOfflineChanges.value++;
    _discoveryOfflineChanges.value++;
  }

  void _networkChanged(DownloadConnectivity connectivity) {
    _connectivity = connectivity;
    _networkReady = true;
    if (!_current || _switchingProfile) return;
    emit(state.copyWith(
        networkConnected: connectivity.online,
        wifiConnected: connectivity.wifi,
        waitingForWifi: state.wifiOnly && !connectivity.wifi));
    if (_activeId case final id?) {
      final active = _library.getDownloadByVideoId(id);
      if (!connectivity.online ||
          state.waitingForWifi ||
          (active != null && state.waitingForWifiFor(active))) {
        _activeArtworkToken?.cancel();
        if (_activeNeedsNetwork) {
          state.downloadProgresses[id]?.cancelToken.cancel();
        }
      }
    }
    unawaited(_drain());
  }

  Future<void> setWifiOnly(bool value) => _mutate(() async {
        await _ready;
        if (!_current || _switchingProfile) return;
        final database = db;
        final profileId = _library.profileId;
        await _library
            .saveSetting(SettingsValue(_wifiSetting, value.toString()));
        emit(state.copyWith(wifiOnly: value));
        _networkChanged(_connectivity);
        await PodcastDownloads.notifyWifiOnlyChanged(database, profileId);
      });

  DownloadFolderPreferences _readFolders() => DownloadFolderPreferences.decode(
      _library.getSettings(downloadFolderSetting)?.value);

  DownloadManagerState _withFolders(DownloadManagerState snapshot) =>
      snapshot.copyWith(
        folderUri: _folders.video.folder?.uri,
        folderName: _folders.video.folder?.name,
        usePrivateStorage: _folders.video.usePrivate,
        audioFolderUri: _folders.audio.folder?.uri,
        audioFolderName: _folders.audio.folder?.name,
        usePrivateAudioStorage: _folders.audio.usePrivate,
      );

  /// Updating one destination must not overwrite a concurrent change to the
  /// other one or a pre-Android-10 export picker that has just completed.
  Future<void> _writeFolders(
      DownloadFolderPreferences Function(DownloadFolderPreferences) update) {
    final generation = _generation;
    final writing = _folderWrite.then((_) async {
      if (!_current || _switchingProfile || generation != _generation) return;
      final next = update(_readFolders());
      final value = next.encode();
      if (value == null) {
        await _library.deleteSetting(downloadFolderSetting);
      } else {
        await _library.saveSetting(SettingsValue(downloadFolderSetting, value));
      }
      if (_current && !_switchingProfile && generation == _generation) {
        _folders = next;
        emit(_withFolders(state));
      }
    });
    _folderWrite =
        writing.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return _mutate(() => writing);
  }

  Future<void> chooseFolder({bool audioOnly = false}) =>
      _changeFolder(audioOnly, null);

  Future<void> usePrivateFolder({bool audioOnly = false}) =>
      _changeFolder(audioOnly, privateDownloadDestination);

  Future<void> useDefaultFolder({bool audioOnly = false}) =>
      _changeFolder(audioOnly, defaultDownloadDestination);

  Future<void> _changeFolder(
      bool audioOnly, DownloadDestination? destination) async {
    await _ready;
    if (!_current || _switchingProfile) return;
    final generation = _generation;
    final revision = (_folderChoiceRevision[audioOnly] ?? 0) + 1;
    _folderChoiceRevision[audioOnly] = revision;
    if (destination == null) {
      final folder = await storage
          .pickFolder(audioOnly ? state.audioFolderUri : state.folderUri);
      if (folder == null ||
          !_current ||
          _switchingProfile ||
          generation != _generation ||
          revision != _folderChoiceRevision[audioOnly]) {
        return;
      }
      destination = (folder: folder, usePrivate: false);
    }
    final selected = destination;
    // Re-selecting the audio default also lets an older Android device
    // replace a Music tree whose persisted permission has been revoked.
    final resetMusicFolder =
        audioOnly && selected == defaultDownloadDestination;
    if (resetMusicFolder) _musicFolderRevision++;
    await _writeFolders((previous) => DownloadFolderPreferences(
        video: audioOnly ? previous.video : selected,
        audio: audioOnly ? selected : previous.audio,
        legacyMusicFolder:
            resetMusicFolder ? null : previous.legacyMusicFolder));
  }

  Future<String?> _deviceMusicFolder({bool allowPicker = true}) async {
    final generation = _generation;
    final shared = await storage.sharedMusicFolder();
    if (!_current || _switchingProfile || generation != _generation) {
      return null;
    }
    if (shared != null) return shared;
    if (_folders.legacyMusicFolder case final folder?) return folder.uri;
    if (!allowPicker) return null;
    final pending = _pendingMusicFolder ??= _pickMusicFolder();
    try {
      return await pending;
    } finally {
      if (identical(_pendingMusicFolder, pending)) _pendingMusicFolder = null;
    }
  }

  /// A batch gets one system folder prompt on Android versions before 10.
  Future<bool> prepareMusicDownloads() async {
    await _ready;
    if (!_current || _switchingProfile) return false;
    if (!storage.supportsSharedMusic ||
        state.usePrivateAudioStorage ||
        state.audioFolderUri != null) {
      return true;
    }
    return await _deviceMusicFolder() != null && _current && !_switchingProfile;
  }

  Future<String?> _pickMusicFolder() async {
    final generation = _generation;
    final revision = _musicFolderRevision;
    final folder = await storage.pickFolder(null);
    if (folder == null ||
        !_current ||
        _switchingProfile ||
        generation != _generation ||
        revision != _musicFolderRevision) {
      return null;
    }
    await _writeFolders((previous) => DownloadFolderPreferences(
        video: previous.video,
        audio: previous.audio,
        legacyMusicFolder: folder));
    return _current &&
            !_switchingProfile &&
            generation == _generation &&
            revision == _musicFolderRevision
        ? folder.uri
        : null;
  }

  void setVideos() {
    if (_current) emit(state.copyWith(videos: _library.getAllDownloads()));
  }

  Listenable get playlistOfflineChanges => _playlistOfflineChanges;

  Listenable get discoveryOfflineChanges => _discoveryOfflineChanges;

  bool _isDiscoveryProfile(String profileId) =>
      _canUpdateOfflineMusic && _library.profileId == profileId;

  List<String> offlineDiscoveryIds(String profileId) =>
      _isDiscoveryProfile(profileId) ? _offlineDiscovery ?? const [] : const [];

  Future<List<MusicFileProbe>> probeOfflineDiscovery(String profileId) async {
    final ids = offlineDiscoveryIds(profileId);
    if (ids.isEmpty) return const [];
    final generation = _generation;
    final wanted = ids.toSet();
    final files = await storage.probeMusicFiles(
        profileId,
        _library.getAllDownloads().where(
            (file) => wanted.contains(file.videoId) && file.downloadComplete));
    if (!_isDiscoveryProfile(profileId) ||
        generation != _generation ||
        !identical(ids, _offlineDiscovery)) {
      return const [];
    }
    final readable = {
      for (final file in files)
        if (readyMusicDownload(_library, file.download.videoId,
                fingerprint: musicDownloadFingerprint(file.download)) !=
            null)
          file.download.videoId: file,
    };
    return [
      for (final id in ids)
        if (readable[id] case final file?) file
    ];
  }

  /// The legacy playlist marker represents a job owned only by automatic Music
  /// collections. A manual request clears it for both playlist and discovery.
  bool isMusicDownloadPlaylistOnly(String videoId) =>
      _current && _library.isPlaylistOwnedMusicDownload(videoId);

  bool isMusicDownloadRequiredByPlaylist(String videoId) =>
      _current && _playlistSongsInUse()?.containsKey(videoId) == true;

  MusicPlaylistOfflineProgress? playlistOfflineProgress(Playlist playlist) {
    if (!_current ||
        _keptOfflinePlaylists?.containsKey(playlist.playlistId) != true) {
      return null;
    }
    final current = _readLocalPlaylists()
        ?.where((item) => item.playlistId == playlist.playlistId)
        .firstOrNull;
    if (current == null) return null;
    final songs = playlistOfflineSongs(current);
    final downloads = {for (final video in state.videos) video.videoId: video};
    var complete = 0;
    var needsAttention = 0;
    var waitingForWifi = false;
    var inProgress = 0.0;
    for (final id in songs.keys) {
      final file = downloads[id];
      if (file == null ||
          !file.audioOnly ||
          file.downloadFailed ||
          file.storageFailed ||
          file.authenticationRequired ||
          state.waitingForSpaceFor(file) ||
          state.pausedVideoIds.contains(id)) {
        needsAttention++;
      } else if (file.downloadComplete) {
        complete++;
      } else if (state.waitingForWifiFor(file)) {
        waitingForWifi = true;
      } else if (state.downloadProgresses[id] case final progress?
          when progress.total > 0) {
        inProgress += (progress.count / progress.total).clamp(0, 1);
      }
    }
    return MusicPlaylistOfflineProgress(
        total: songs.length,
        complete: complete,
        needsAttention: needsAttention,
        waitingForWifi: waitingForWifi,
        progress:
            songs.isEmpty ? null : (complete + inProgress) / songs.length);
  }

  Future<T> _queueOfflineMusicWork<T>(Future<T> Function() work) => _mutate(() {
        final next = _offlineMusicWork.then((_) => work());
        _offlineMusicWork =
            next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
        return next;
      });

  bool get _canUpdateOfflineMusic => _current && !_switchingProfile;

  void _watchPlaylistMembership() {
    _playlistSubscription = _library.watchSetting(localPlaylistsSetting).listen(
      (_) {
        if (!_canUpdateOfflineMusic ||
            _keptOfflinePlaylists == null ||
            (_keptOfflinePlaylists!.isEmpty &&
                _library.getPlaylistOwnedMusicDownloadIds().isEmpty)) {
          return;
        }
        unawaited(_queueOfflineMusicWork<void>(() async {
          await _ready;
          await _syncPlaylistDownloads();
          if (_canUpdateOfflineMusic) _playlistOfflineChanges.value++;
        }).catchError(_logPlaylistOfflineError));
      },
      onError: _logPlaylistOfflineError,
    );
  }

  void _logPlaylistOfflineError(Object error) {
    log.warning(
        'Could not update offline Music collections (${error.runtimeType})');
  }

  List<Playlist>? _readLocalPlaylists() {
    final source = _library.getSettings(localPlaylistsSetting)?.value;
    if (_playlistSource != source || _localPlaylistSnapshot == null) {
      _playlistSource = source;
      _lastPlaylistPins = null;
      try {
        _localPlaylistSnapshot = service.getLocalPlaylists(database: _library);
      } catch (error) {
        _localPlaylistSnapshot = null;
        _logPlaylistOfflineError(error);
      }
    }
    return _localPlaylistSnapshot;
  }

  Map<String, ({Video video, MusicOfflinePolicy policy})>?
      _playlistSongsInUse() {
    final pins = _keptOfflinePlaylists;
    if (pins == null) return null;
    if (pins.isEmpty) return const {};
    final playlists = _readLocalPlaylists();
    if (playlists == null) return null;
    if (!identical(pins, _lastPlaylistPins)) {
      _lastPlaylistPins = pins;
      final byId = {for (final list in playlists) list.playlistId: list};
      final songs = <String, ({Video video, MusicOfflinePolicy policy})>{};
      // A shared job uses the first pin's quality. Honor any Wi-Fi restriction
      // known before enqueueing, then retain that job's policy through retries.
      for (final entry in pins.entries) {
        final playlist = byId[entry.key];
        if (playlist == null) continue;
        for (final video in playlistOfflineSongs(playlist).values) {
          final existing = songs[video.videoId];
          if (existing == null) {
            songs[video.videoId] = (video: video, policy: entry.value);
          } else if (entry.value.wifiOnly && !existing.policy.wifiOnly) {
            songs[video.videoId] = (
              video: existing.video,
              policy: MusicOfflinePolicy(
                  quality: existing.policy.quality, wifiOnly: true),
            );
          }
        }
      }
      _requiredPlaylistSongs = songs;
    }
    return _requiredPlaylistSongs;
  }

  Future<void> _savePlaylistPins(Map<String, MusicOfflinePolicy> pins) async {
    await _library.saveSetting(SettingsValue(_keptOfflineSetting,
        jsonEncode(pins.map((id, policy) => MapEntry(id, policy.toJson())))));
    _keptOfflinePlaylists = pins;
    _playlistOfflineChanges.value++;
  }

  Future<bool> setPlaylistKeptOffline(String playlistId, bool enabled,
          {MusicOfflinePolicy policy = const MusicOfflinePolicy()}) =>
      _queueOfflineMusicWork(() async {
        await _ready;
        final pins = _keptOfflinePlaylists;
        if (!_canUpdateOfflineMusic || pins == null) return false;
        if (enabled) {
          final target = _readLocalPlaylists()
              ?.where((item) => item.isLocal && item.playlistId == playlistId)
              .firstOrNull;
          if (target == null) return false;
          if (playlistOfflineSongs(target)
                  .keys
                  .any((id) => _library.getDownloadByVideoId(id) == null) &&
              !await prepareMusicDownloads()) {
            return false;
          }
        }
        if (!_canUpdateOfflineMusic) return false;
        if (pins.containsKey(playlistId) != enabled) {
          final updated = {...pins};
          if (enabled) {
            updated[playlistId] = policy;
          } else {
            updated.remove(playlistId);
          }
          await _savePlaylistPins(updated);
        }
        await _syncPlaylistDownloads();
        return true;
      });

  Future<void> retryPlaylistOffline(String playlistId) =>
      _queueOfflineMusicWork(() async {
        await _ready;
        if (!_canUpdateOfflineMusic ||
            _keptOfflinePlaylists?.containsKey(playlistId) != true) {
          return;
        }
        final playlist = _readLocalPlaylists()
            ?.where((item) => item.playlistId == playlistId)
            .firstOrNull;
        if (playlist == null) return;
        final ids = playlistOfflineSongs(playlist).keys;
        if (ids.any((id) => _library.getDownloadByVideoId(id) == null) &&
            !await prepareMusicDownloads()) {
          return;
        }
        await _syncPlaylistDownloads();
        for (final id in ids) {
          if (!_canUpdateOfflineMusic ||
              _playlistSongsInUse()?.containsKey(id) != true) {
            continue;
          }
          final download = _library.getDownloadByVideoId(id);
          if (download == null || !download.audioOnly) continue;
          if (download.downloadFailed ||
              download.authenticationRequired ||
              download.storageFailed ||
              state.waitingForSpaceFor(download) ||
              state.pausedVideoIds.contains(id)) {
            await retryDownload(download);
          }
        }
      });

  /// Saves a snapshot of the current ranked shelf. Only another user action
  /// can replace it or enable new downloads for this selection.
  Future<bool> setOfflineDiscovery(String profileId, Iterable<Video> selected) {
    final songs = eligibleOfflineMusicSongs(selected);
    if (songs.isEmpty && selected.isNotEmpty) return Future.value(false);
    final generation = _generation;
    bool current() =>
        _isDiscoveryProfile(profileId) && generation == _generation;
    return _queueOfflineMusicWork(() async {
      await _ready;
      if (!current()) return false;
      final ids = List<String>.unmodifiable(songs.keys);
      await _library.saveSetting(
          SettingsValue(_offlineDiscoverySetting, jsonEncode(ids)));
      _offlineDiscovery = ids;
      _discoveryOfflineChanges.value++;
      await _cleanupUnusedOfflineMusic();
      for (final song in songs.values) {
        if (!current()) return false;
        final existing = _library.getDownloadByVideoId(song.videoId);
        if (existing == null) {
          await _addDownload(song.videoId,
              quality: highestAudioDownloadQuality,
              audioOnly: true,
              musicPolicy: _discoveryPolicy,
              video: song,
              managedOffline: true,
              privateStorage: true);
        } else if (_isDiscoveryManaged(song.videoId) &&
            (existing.downloadFailed ||
                existing.storageFailed ||
                existing.authenticationRequired ||
                state.pausedVideoIds.contains(song.videoId))) {
          await retryDownload(existing);
        }
      }
      return current();
    });
  }

  bool _discoveryWants(String videoId) =>
      _offlineDiscovery?.contains(videoId) == true;

  bool _isDiscoveryManaged(String videoId) =>
      _discoveryWants(videoId) &&
      _playlistSongsInUse()?.containsKey(videoId) != true &&
      _library.isPlaylistOwnedMusicDownload(videoId);

  Future<int?> _readDiscoveryBudget() async {
    try {
      return await _discoveryBudgetBytes().timeout(const Duration(seconds: 5));
    } on Exception {
      return null;
    }
  }

  Future<int?> _remainingDiscoveryBytes(String videoId) async {
    if (!_isDiscoveryManaged(videoId)) return null;
    final profile = _library;
    final budget = await _readDiscoveryBudget();
    if (budget == null || budget <= 0) return 0;
    final usage = await measureMusicDownloadStorage(
        profile.getAllDownloads().where((file) =>
            file.videoId != videoId && _isDiscoveryManaged(file.videoId)),
        profileId: profile.profileId,
        storage: storage);
    if (!_isDiscoveryManaged(videoId)) return null;
    return usage.incomplete ? 0 : (budget - usage.bytes).clamp(0, budget);
  }

  Future<void> reconcileOfflineDiscoveryBudget() {
    final generation = _generation;
    return _queueOfflineMusicWork(() async {
      await _ready;
      if (generation == _generation) await _trimDiscoveryOverflow();
    });
  }

  Future<void> _syncPlaylistDownloads() async {
    final pins = _keptOfflinePlaylists;
    if (!_canUpdateOfflineMusic || pins == null) return;
    final playlists = _readLocalPlaylists();
    if (playlists == null) return;
    final existing = playlists.map((playlist) => playlist.playlistId).toSet();
    final validPins = {...pins}..removeWhere((id, _) => !existing.contains(id));
    if (validPins.length != pins.length) await _savePlaylistPins(validPins);
    final songs = _playlistSongsInUse();
    if (songs == null) return;

    for (final (:video, :policy) in songs.values) {
      if (!_canUpdateOfflineMusic) return;
      if (_library.getDownloadByVideoId(video.videoId) != null) continue;
      try {
        await _addDownload(video.videoId,
            quality: highestAudioDownloadQuality,
            audioOnly: true,
            musicPolicy: policy,
            video: video,
            managedOffline: true);
      } catch (error) {
        _logPlaylistOfflineError(error);
      }
    }
    await _cleanupUnusedOfflineMusic();
    await _trimDiscoveryOverflow();
  }

  Future<void> _cleanupUnusedOfflineMusic() async {
    final playlists = _playlistSongsInUse();
    if (playlists == null || _offlineDiscovery == null) return;
    for (final id in _library.getPlaylistOwnedMusicDownloadIds()) {
      if (!_canUpdateOfflineMusic) return;
      if (playlists.containsKey(id) || _discoveryWants(id)) continue;
      final video = _library.getDownloadByVideoId(id);
      if (video == null) continue;
      try {
        await _deleteVideo(video, managedOnly: true);
      } catch (error) {
        // Keep the durable ownership marker so the next reconciliation retries.
        _logPlaylistOfflineError(error);
      }
    }
  }

  /// If a playlist lets go of a shared file, discovery can retain it only
  /// within its budget. The saved shelf order determines which files fit.
  Future<void> _trimDiscoveryOverflow() async {
    final candidates = _offlineDiscovery?.where(_isDiscoveryManaged).toList();
    if (!_canUpdateOfflineMusic || candidates == null || candidates.isEmpty) {
      return;
    }
    final budget = await _readDiscoveryBudget();
    if (budget == null) return;
    var remaining = budget;
    for (final id in candidates) {
      if (!_canUpdateOfflineMusic) return;
      final video = _library.getDownloadByVideoId(id);
      if (video == null ||
          !video.downloadComplete ||
          !_isDiscoveryManaged(id)) {
        continue;
      }
      final usage = await measureMusicDownloadStorage([video],
          profileId: _library.profileId, storage: storage);
      if (usage.incomplete) return;
      if (usage.bytes <= remaining) {
        remaining -= usage.bytes;
      } else {
        try {
          await _deleteVideo(video, managedOnly: true, trimDiscovery: true);
        } catch (error) {
          _logPlaylistOfflineError(error);
          return;
        }
      }
    }
  }

  /// Shares the mutation queue with playlist reconciliation and deletion.
  Future<KeepCachedMusicResult> keepCachedMusicSong(
    Server server,
    CachedMusicSong song, {
    MusicOfflinePolicy policy = const MusicOfflinePolicy(),
  }) {
    final generation = _generation;
    final database = db;
    return _queueOfflineMusicWork(() async {
      await _ready;
      final library = _library;
      final owner = cachedMusicOwner(server);
      final selection = owner == null
          ? null
          : CachedMusicPlayback(owner, song.rendition)
              .source(server, song.videoId)?['cachedMusic'];
      bool current() =>
          _canUpdateOfflineMusic &&
          identical(db, database) &&
          generation == _generation &&
          server.profileId == library.profileId;

      if (selection is! Map<String, Object?> || !current()) {
        return KeepCachedMusicResult.unavailable;
      }
      try {
        final account = await library.getCurrentlySelectedServer();
        if (!current() || cachedMusicOwner(account) != owner) {
          return KeepCachedMusicResult.unavailable;
        }
        if (library.getDownloadByVideoId(song.videoId) case final existing?) {
          final playable = readyMusicDownload(library, song.videoId);
          if (playable == null ||
              playable.accountId != account.accountId ||
              await storage.musicFileProof(playable, verifyCompletion: true) ==
                  null ||
              jsonEncode(
                      library.getDownloadByVideoId(song.videoId)?.toJson()) !=
                  jsonEncode(existing.toJson())) {
            return KeepCachedMusicResult.conflictingDownload;
          }
          if (!current()) return KeepCachedMusicResult.unavailable;
          final wasDiscoveryManaged = _isDiscoveryManaged(song.videoId);
          if (!await library.makeMusicDownloadExplicit(song.videoId)) {
            return KeepCachedMusicResult.alreadySaved;
          }
          _playlistOfflineChanges.value++;
          if (wasDiscoveryManaged) _discoveryOfflineChanges.value++;
          return KeepCachedMusicResult.saved;
        }
        return await _saveCachedMusicSong(
            library, account, song, selection, policy, current);
      } catch (error) {
        log.warning('Could not keep cached Music (${error.runtimeType})');
        return current()
            ? KeepCachedMusicResult.failed
            : KeepCachedMusicResult.unavailable;
      }
    });
  }

  Future<KeepCachedMusicResult> _saveCachedMusicSong(
    IDbClient library,
    Server account,
    CachedMusicSong song,
    Map<String, Object?> selection,
    MusicOfflinePolicy policy,
    bool Function() current,
  ) async {
    final token = _keepingCachedMusic = CancelToken();
    File? snapshot;
    File? staged;
    File? publishedFile;
    String? publishedDocument;
    var committed = false;
    try {
      final destination = _folders.audio;
      var folder = destination.folder?.uri;
      if (folder == null &&
          storage.supportsSharedMusic &&
          !destination.usePrivate) {
        folder = await _deviceMusicFolder();
        if (!current()) return KeepCachedMusicResult.unavailable;
        if (folder == null) return KeepCachedMusicResult.failed;
      }
      if (!current()) return KeepCachedMusicResult.unavailable;

      final path = await PlaybackCache.copyCachedMusicSong(selection);
      if (path == null) return KeepCachedMusicResult.unavailable;
      snapshot = File(path);
      if (!current()) return KeepCachedMusicResult.unavailable;

      var download = DownloadedVideo(
        videoId: song.videoId,
        title: song.title,
        author: song.artist,
        musicMetadata: MusicMetadata(title: song.title, artist: song.artist),
        lengthSeconds: song.lengthSeconds,
        profileId: library.profileId,
        accountId: account.accountId,
        quality: highestAudioDownloadQuality,
        audioOnly: true,
        folderUri: folder,
        musicFormat: MusicDownloadFormat.forDatabase(library),
        musicPolicy: policy,
        container: await _cachedMusicContainer(snapshot),
        downloadComplete: true,
      );
      final privatePath = folder == null ? await download.downloadPath : null;
      staged = File('${privatePath ?? path}.${const Uuid().v4()}.part');
      await encodeMusic(
        input: path,
        output: staged.path,
        video: download,
        token: token,
      );
      if (!current()) return KeepCachedMusicResult.unavailable;
      final length = await staged.length();
      if (length == 0) return KeepCachedMusicResult.failed;
      if (privatePath != null) {
        if (await File(privatePath).exists()) {
          return KeepCachedMusicResult.failed;
        }
        publishedFile = await staged.rename(privatePath);
      } else {
        publishedDocument = await storage.prepareDocument(
            folder!, null, download.fileName, download.mimeType);
        await storage.writeDocument(staged.path, publishedDocument, token);
        download = download.copyWith(storageUri: publishedDocument);
      }
      if (!current()) return KeepCachedMusicResult.unavailable;
      final files =
          await storage.probeMusicFiles(library.profileId, [download]);
      if (files.singleOrNull?.byteLength != length) {
        return KeepCachedMusicResult.failed;
      }
      if (!current()) return KeepCachedMusicResult.unavailable;
      if (library.getDownloadByVideoId(song.videoId) != null) {
        return KeepCachedMusicResult.conflictingDownload;
      }
      await library.upsertDownload(download);
      committed = true;
      _musicDeletionIncarnations.remove(song.videoId);
      setVideos();
      _playlistOfflineChanges.value++;
      return KeepCachedMusicResult.saved;
    } finally {
      _keepingCachedMusic = null;
      if (!committed && publishedDocument != null) {
        try {
          await storage.deleteDocument(publishedDocument);
        } on Exception catch (error) {
          log.warning('Could not clean up cached Music (${error.runtimeType})');
        }
      }
      for (final file in [snapshot, staged, if (!committed) publishedFile]) {
        if (file == null) continue;
        try {
          if (await file.exists()) await file.delete();
        } on FileSystemException catch (error) {
          log.warning('Could not clean up cached Music (${error.runtimeType})');
        }
      }
    }
  }

  Future<bool> addDownload(String videoId,
          {String quality = '720p',
          bool audioOnly = false,
          MusicOfflinePolicy? musicPolicy,
          DownloadContainer? container,
          String? audioTrackId,
          String? captionLabel,
          Video? video}) =>
      _queueOfflineMusicWork(() => _addDownload(videoId,
          quality: quality,
          audioOnly: audioOnly,
          musicPolicy: musicPolicy,
          container: container,
          audioTrackId: audioTrackId,
          captionLabel: captionLabel,
          video: video));

  MusicMetadata _musicDownloadLabels(String id, Video? video,
          [DownloadedVideo? existing]) =>
      video?.musicMetadata ??
      MusicMetadata(
        title: video?.title?.trim().isNotEmpty == true
            ? video!.title!
            : existing?.title ?? id,
        artist: video?.author?.trim().isNotEmpty == true
            ? video!.author!
            : existing?.author ?? '',
      );

  Future<bool> _addDownload(String videoId,
      {required String quality,
      required bool audioOnly,
      MusicOfflinePolicy? musicPolicy,
      DownloadContainer? container,
      String? audioTrackId,
      String? captionLabel,
      Video? video,
      bool managedOffline = false,
      bool privateStorage = false}) async {
    await _ready;
    if (!_current ||
        _switchingProfile ||
        (video != null && video.videoId != videoId) ||
        !DownloadedVideo.isSafeFileId(videoId) ||
        _deleting.contains(videoId) ||
        !_enqueuing.add(videoId)) {
      return false;
    }
    final library = _library;
    final generation = _generation;
    final isMusic = audioOnly && quality == highestAudioDownloadQuality;
    bool current() =>
        _canUpdateOfflineMusic &&
        identical(library, _library) &&
        generation == _generation &&
        !_deleting.contains(videoId);
    try {
      final existing = library.getDownloadByVideoId(videoId);
      if (existing != null) {
        if (managedOffline || !audioOnly || !existing.audioOnly) return false;
        final wasPlaylistOnly = library.isPlaylistOwnedMusicDownload(videoId);
        final wasDiscoveryManaged = _isDiscoveryManaged(videoId);
        final changed = isMusic
            ? await library.adoptMusicDownload(
                existing, _musicDownloadLabels(videoId, video, existing),
                notificationTicket: existing.downloadComplete ||
                        state.pausedVideoIds.contains(videoId)
                    ? null
                    : const Uuid().v4())
            : await library.makeMusicDownloadExplicit(videoId);
        if (!changed || !current()) return false;
        if (wasPlaylistOnly) {
          _playlistOfflineChanges.value++;
          if (wasDiscoveryManaged && !existing.downloadComplete) {
            // Restart the constrained transfer as explicit, retaining its
            // selected renditions and the profile's Wi-Fi setting.
            state.downloadProgresses[videoId]?.cancelToken.cancel();
            await retryDownload(existing);
          }
        }
        if (!current()) return false;
        setVideos();
        unawaited(_drain());
        return true;
      }
      final destination = privateStorage
          ? privateDownloadDestination
          : (audioOnly ? _folders.audio : _folders.video);
      var folder = destination.folder?.uri;
      final format = isMusic ? MusicDownloadFormat.forDatabase(library) : null;
      final shareMusic =
          isMusic && storage.supportsSharedMusic && !destination.usePrivate;
      if (shareMusic && folder == null) {
        folder = await _deviceMusicFolder(allowPicker: !managedOffline);
        if (folder == null || !current()) return false;
      }
      final account = await library.getCurrentlySelectedServer();
      if (!current()) return false;
      if (managedOffline &&
          !_discoveryWants(videoId) &&
          _playlistSongsInUse()?.containsKey(videoId) != true) {
        return false;
      }
      _musicDeletionIncarnations.remove(videoId);
      final music =
          isMusic ? _musicDownloadLabels(videoId, video) : video?.musicMetadata;
      final download = DownloadedVideo(
          videoId: videoId,
          title: music?.title ?? video?.title ?? videoId,
          author: music?.artist ?? video?.author,
          authorUrl: video?.authorUrl,
          musicMetadata: music,
          notificationTicket:
              isMusic && !managedOffline ? const Uuid().v4() : null,
          profileId: library.profileId,
          accountId: account.accountId,
          lengthSeconds: video?.lengthSeconds ?? 0,
          quality: quality,
          folderUri: folder,
          musicFormat: format,
          musicPolicy: isMusic ? musicPolicy : null,
          container: container,
          audioTrackId: audioTrackId,
          captionLabel: audioOnly ? null : captionLabel,
          audioOnly: audioOnly);
      if (managedOffline) {
        if (!await library.insertPlaylistOwnedMusicDownload(download)) {
          return false;
        }
      } else {
        await library.upsertDownload(download);
      }
    } finally {
      _enqueuing.remove(videoId);
    }
    if (!current()) return false;
    setVideos();
    unawaited(_drain());
    return true;
  }

  Future<int> addDownloads(Iterable<String> videoIds,
      {String quality = '720p',
      bool audioOnly = false,
      MusicOfflinePolicy? musicPolicy,
      DownloadContainer? container,
      String? audioTrackId,
      String? captionLabel,
      Map<String, Video> videosById = const {}}) async {
    var added = 0;
    final generation = _generation;
    for (final id in videoIds.toSet()) {
      if (generation != _generation || _switchingProfile) break;
      if (await addDownload(id,
          quality: quality,
          audioOnly: audioOnly,
          musicPolicy: musicPolicy,
          container: container,
          audioTrackId: audioTrackId,
          captionLabel: captionLabel,
          video: videosById[id])) {
        added++;
      }
    }
    return added;
  }

  bool get _canDrain =>
      _current &&
      !_switchingProfile &&
      !NetworkProxy.instance.isChanging &&
      _networkReady &&
      _connectivity.online &&
      !state.waitingForWifi;

  Future<void> _drain() async {
    if (_processing || !_canDrain) return;
    _processing = true;
    final finished = _drainFinished = Completer<void>();
    try {
      while (_canDrain) {
        final next = _library
            .getAllDownloads()
            .where((v) =>
                !v.downloadComplete &&
                !v.downloadFailed &&
                !v.authenticationRequired &&
                !state.waitingForWifiFor(v) &&
                !state.spaceBlockedVideoIds.contains(v.videoId) &&
                !state.pausedVideoIds.contains(v.videoId) &&
                !_deleting.contains(v.videoId) &&
                (!_library.isPlaylistOwnedMusicDownload(v.videoId) ||
                    _discoveryWants(v.videoId) ||
                    _playlistSongsInUse()?.containsKey(v.videoId) == true))
            .firstOrNull;
        if (next == null) break;
        _activeId = next.videoId;
        _activeJob = _download(next);
        await _activeJob;
        _activeId = null;
        _activeJob = null;
        if (_canUpdateOfflineMusic &&
            _library.getDownloadByVideoId(next.videoId)?.downloadComplete ==
                true &&
            _isDiscoveryManaged(next.videoId)) {
          // A playlist can release its interest while a transfer is publishing.
          // Reconcile settled files after the active job has released its slot.
          unawaited(_queueOfflineMusicWork(_trimDiscoveryOverflow)
              .catchError(_logPlaylistOfflineError));
        }
      }
    } finally {
      _processing = false;
      finished.complete();
      _drainFinished = null;
    }
  }

  Future<void> _download(DownloadedVideo video) async {
    final library = _library;
    final token = CancelToken();
    final progress = DownloadProgress(token);
    _activeNeedsNetwork = true;
    String? currentMux;
    emit(state.copyWith(downloadProgresses: {video.videoId: progress}));
    final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30)));
    Future<List<SponsorSegment>>? sponsorSegments;
    Future<String?>? deArrowTitle;
    final elapsed = Stopwatch()..start();
    Duration? lastUpdate;
    void update(int count, int total, int step, int steps,
        {int? bytesPerSecond}) {
      final now = elapsed.elapsed;
      final previous = lastUpdate;
      if (token.isCancelled ||
          !_current ||
          (count != total &&
              previous != null &&
              now - previous < const Duration(milliseconds: 250))) {
        return;
      }
      lastUpdate = now;
      // Reserve the final step for muxing; a downloaded audio track isn't a video.
      final fraction =
          (step + (total > 0 ? (count / total).clamp(0, 1) : 0)) / steps;
      final next = DownloadProgress(token, bytesPerSecond: bytesPerSecond)
        ..count = (fraction * 1000).round()
        ..total = 1000;
      emit(state.copyWith(downloadProgresses: {video.videoId: next}));
    }

    try {
      if (video.profileId != library.profileId) {
        throw StateError('The download belongs to another profile');
      }
      if (video.accountId == null) {
        // Bind old queued records exactly once before their first resumed
        // request. All later retries and restarts resolve this same account.
        final account = await library.getCurrentlySelectedServer();
        if (token.isCancelled) throw token.cancelError!;
        video = video.copyWith(accountId: account.accountId);
        await library.upsertDownload(video);
      }
      if (video.folderUri != null) await storage.checkFolder(video.folderUri!);
      final account = library.getAccount(video.accountId!);
      if (account == null || account.profileId != library.profileId) {
        throw StateError('The download account is no longer available');
      }
      if (token.isCancelled) throw token.cancelError!;
      final maximumBytes = await _remainingDiscoveryBytes(video.videoId);
      if (token.isCancelled) throw token.cancelError!;
      if (maximumBytes == 0) throw const DownloadSizeLimitExceeded();
      final recovery =
          await DownloadRecovery.start(service, library, account, token);
      await recovery.run<void>((route) async {
        final server = route.server;
        final artworkToken = _activeArtworkToken = CancelToken();
        Future<void>? artwork;
        try {
          var vid = await Future.any([
            service.getDownloadVideo(video.videoId,
                route: route, checkCurrent: recovery.checkCurrent),
            token.whenCancel.then((error) => throw error),
          ]);
          recovery.checkCurrent();
          // The sheet can discover a usable default only in DASH. Repeat that
          // discovery even when the user left the audio choice on Automatic.
          final needsDefaultAudio = video.audioTrackId == null &&
              !(vid.adaptiveFormats ?? const <AdaptiveFormat>[]).any((format) =>
                  DownloadContainer.forAudio(format) != null &&
                  downloadMediaUrl(format, server) != null);
          if ((video.audioTrackId?.startsWith('dash:') ?? false) ||
              needsDefaultAudio) {
            vid = await Future.any([
              loadDownloadAudioTracks(vid, server,
                  client: service.httpClient,
                  checkCurrent: recovery.checkCurrent,
                  timeout: const Duration(seconds: 30)),
              token.whenCancel.then((error) => throw error),
            ]);
            recovery.checkCurrent();
          }
          // Admit routes before ranking tracks, so an unsupported high-bitrate
          // URL cannot hide a usable track from the selected instance.
          final mediaUrls = <AdaptiveFormat, String>{};
          for (final format in vid.adaptiveFormats ?? <AdaptiveFormat>[]) {
            final url = downloadMediaUrl(format, server);
            if (url != null) mediaUrls[format] = url;
          }
          final formats = DownloadFormats(mediaUrls.keys.toList(),
              audioTrackId: video.audioTrackId,
              musicQuality: video.musicPolicy?.quality);
          // A saved document already has a container. Old jobs saved WebM.
          final savedContainer = video.container ??
              (video.storageUri == null ? null : DownloadContainer.webm);
          final selectedVideo = video.audioOnly
              ? null
              : formats.videoFor(video.quality, container: savedContainer);
          final automaticAudio =
              video.audioOnly && video.quality == highestAudioDownloadQuality
                  ? formats.preferredBitrateAudioContainer
                  : formats.audioContainer;
          final container = savedContainer ??
              (selectedVideo == null
                  ? automaticAudio
                  : DownloadContainer.forVideo(selectedVideo));
          final audio = formats.audioFor(container);
          if (container == null ||
              audio == null ||
              (!video.audioOnly && selectedVideo == null)) {
            throw const DownloadFormatsUnavailable();
          }
          final caption = vid.captions
              .where((caption) => caption.label == video.captionLabel)
              .firstOrNull;
          if (video.captionLabel != null && caption == null) {
            throw const DownloadFormatsUnavailable();
          }
          var music = video.musicMetadata ?? vid.musicMetadata;
          var title = vid.title;
          if (!video.storeAsMusic &&
              video.musicMetadata == null &&
              library.getSettings(dearrowSettingName)?.value == 'true') {
            // Enrich the saved title once per job. Optional presentation
            // metadata cannot trigger a retry of an extraction backend.
            final enriched = deArrowTitle ??= DeArrow.processVideos([vid],
                    owner: library)
                .then<String?>((videos) => videos.first.title,
                    onError: (_) => null)
                .timeout(const Duration(seconds: 30), onTimeout: () => null);
            title = await Future.any([
                  enriched,
                  token.whenCancel.then((error) => throw error)
                ]) ??
                title;
            recovery.checkCurrent();
          }
          if (music != null && video.videoId == vid.videoId) {
            music = vid
                .resolveMusicMetadata(music)
                .withoutVideoThumbnailFallbacks(vid.videoThumbnails);
          }
          video = video.copyWith(
              // Interrupted/replaced output must never inherit old proof.
              playbackProvenance: null,
              title: music?.title ?? title ?? video.title,
              author: music?.artist ?? vid.author,
              musicMetadata: music,
              authorUrl: vid.authorUrl ?? video.authorUrl,
              lengthSeconds: vid.lengthSeconds ?? video.lengthSeconds,
              downloadFailed: false,
              authenticationRequired: false);
          await library.upsertDownload(video);
          setVideos();
          final segmentsForJob = sponsorSegments ??=
              _downloadSponsorSegments(video, library, token);
          // Automatic remains automatic until the output is published. A
          // second extractor may offer a different compatible container.
          final outputVideo = video.copyWith(container: container);
          final mediaPath = await outputVideo.downloadPath;
          final staging = await video.stagingPath;
          final audioPath = '$staging.audio.part';
          final videoPath = '$staging.video.part';
          final captionPath = '$staging.caption.vtt';
          final steps = (video.audioOnly ? 2 : 3) + (caption == null ? 0 : 1);
          ({int? size, String path, String url, String identity}) mediaPart(
              AdaptiveFormat format, String path) {
            final size = int.tryParse(format.clen);
            final rendition =
                RenditionIdentity.fromSelection(vid, format, server);
            // Without immutable rendition proof, a refreshed URL (even on
            // the same backend) must begin a new file.
            final identity = rendition == null
                ? const Uuid().v4()
                : jsonEncode([
                    video.profileId,
                    video.accountId,
                    Uri.parse(server.url).origin,
                    video.videoId,
                    rendition.toJson()
                  ]);
            return (
              size: size != null && size > 0 ? size : null,
              path: path,
              url: mediaUrls[format]!,
              identity: identity,
            );
          }

          final parts = [
            mediaPart(audio, audioPath),
            if (selectedVideo != null) mediaPart(selectedVideo, videoPath),
          ];
          final output = '$staging.mux.${outputVideo.extension}';
          final destination = video.folderUri;
          final existingDestination = await _pendingDocumentSize(video);
          // The retry already replaces this uncommitted output. Release it
          // before preflight so it can't prevent a retry after space is freed.
          await _deleteStagedMux(output);
          var knownPartGrowth = 0;
          var knownInputBytes = 0;
          var allSizesKnown = true;
          for (final part in parts) {
            final size = part.size;
            if (size == null) {
              allSizesKnown = false;
              continue;
            }
            recovery.checkCurrent();
            final reusable = await compatibleDownloadBytes(part.path,
                identity: part.identity,
                expectedSize: size,
                maximumBytes: maximumBytes,
                discardIncompatible: true);
            knownInputBytes += size;
            knownPartGrowth += size - reusable;
          }
          // A stream copy budgets the staged input sizes. The exact published
          // length is checked after muxing. Transcoded sizes are unknown here.
          final plannedOutput =
              allSizesKnown && !video.storeAsMusic ? knownInputBytes : 0;
          await checkDownloadSpace(storage, {
            staging: knownPartGrowth + plannedOutput,
            if (destination != null)
              destination:
                  remainingDownloadGrowth(plannedOutput, existingDestination),
          });
          recovery.checkCurrent();

          Future<void> transfer(int step) {
            final part = parts[step];
            final rate = DownloadTransferRate();
            return downloadResumable(dio, part.url, part.path,
                cancelToken: token,
                identity: part.identity,
                beforeRequest: recovery.checkCurrent,
                expectedSize: part.size,
                checkCapacity: (transfer) async {
                  final writes = transfer.minimumWriteBytes;
                  if (writes == null) return;
                  final reclaimed =
                      transfer.offset == 0 ? transfer.existingBytes : 0;
                  await checkDownloadSpace(storage,
                      {part.path: remainingDownloadGrowth(writes, reclaimed)});
                },
                maximumBytes: maximumBytes,
                acceptsContentType: container.acceptsResponseType,
                headers: server.headersForUrl(part.url),
                onProgress: (count, total) => update(count, total, step, steps,
                    bytesPerSecond: rate.observe(count, elapsed.elapsed)));
          }

          String? privateThumbnail(List<ImageObject>? images) =>
              ImageObject.getBestThumbnail(images?.where((image) {
                final url = invidiousImageUrl(image.url, server);
                return url != null && url.isNotEmpty;
              }).toList())
                  ?.url;
          final cover = video.songCoverUrl;
          final posters = music == null
              ? [if (privateThumbnail(vid.videoThumbnails) case final url?) url]
              : _stockPosterUrls(vid, server, artTrack: music.isArtTrack);
          if (maximumBytes == null && (cover != null || posters.isNotEmpty)) {
            unawaited(token.whenCancel.then(artworkToken.cancel));
            // Optional artwork must not delay the first media request. Keep it
            // part of this job so pause, delete and proxy changes can join it.
            artwork = _downloadArtwork(dio, video, server, artworkToken,
                cover: cover, posters: posters);
          }
          for (var step = 0; step < parts.length; step++) {
            await transfer(step);
            recovery.checkCurrent();
          }
          recovery.checkCurrent();
          route.recordSuccess();
          if (caption != null) {
            final subtitles = await Future.any([
              service
                  .getPlaybackCaptions(video.videoId, caption, server: server)
                  .timeout(const Duration(seconds: 30)),
              token.whenCancel.then((error) => throw error),
            ]);
            if (token.isCancelled) throw token.cancelError!;
            final bytes = utf8.encode(subtitles);
            await checkDownloadSpace(storage, {
              captionPath: remainingDownloadGrowth(
                  bytes.length, await downloadFileBytes(captionPath))
            });
            recovery.checkCurrent();
            await File(captionPath).writeAsBytes(bytes);
            update(1, 1, steps - 2, steps);
          }
          recovery.checkCurrent();
          _activeNeedsNetwork = false;
          currentMux = output;
          final captionBytes =
              caption == null ? 0 : await downloadFileBytes(captionPath);
          final subtitlePath =
              caption == null ? null : await video.subtitlePath;
          final subtitleGrowth = subtitlePath == null
              ? 0
              : remainingDownloadGrowth(
                  captionBytes, await downloadFileBytes(subtitlePath));
          if (!video.storeAsMusic) {
            var muxBudget = captionBytes;
            for (final part in parts) {
              muxBudget += await File(part.path).length();
            }
            await checkDownloadSpace(storage, {
              staging: muxBudget + subtitleGrowth,
              if (destination != null)
                destination:
                    remainingDownloadGrowth(muxBudget, existingDestination),
            });
          }
          recovery.checkCurrent();
          if (video.storeAsMusic) {
            await encodeMusic(
                input: audioPath,
                output: output,
                video: outputVideo,
                token: token,
                sourceCodec: audio.encoding);
          } else if (video.audioOnly) {
            await File(audioPath).copy(output);
          } else {
            await runDownloadMux([
              '-y',
              '-i',
              videoPath,
              '-i',
              audioPath,
              if (caption != null) ...[
                '-i',
                captionPath,
                '-map',
                '0:v:0',
                '-map',
                '1:a:0',
                '-map',
                '2:s:0',
                '-c:s',
                container == DownloadContainer.mp4 ? 'mov_text' : 'webvtt',
                '-metadata:s:s:0',
                'title=${caption.label}',
                if (caption.languageCode != null) ...[
                  '-metadata:s:s:0',
                  'language=${caption.languageCode}',
                ],
              ],
              '-c:v',
              'copy',
              '-c:a',
              'copy',
              output
            ], token);
          }
          recovery.checkCurrent();
          await artwork;
          video = video.copyWith(sponsorSegments: await segmentsForJob);
          recovery.checkCurrent();
          final remainingBytes = await _remainingDiscoveryBytes(video.videoId);
          if (remainingBytes != null &&
              await File(output).length() > remainingBytes) {
            throw const DownloadSizeLimitExceeded();
          }
          recovery.checkCurrent();
          final outputBytes = await File(output).length();
          await checkDownloadSpace(storage, {
            if (subtitlePath != null) subtitlePath: subtitleGrowth,
            if (destination != null)
              destination:
                  remainingDownloadGrowth(outputBytes, existingDestination),
          });
          recovery.checkCurrent();
          if (subtitlePath != null) {
            await File(captionPath).copy(subtitlePath);
            if (token.isCancelled) throw token.cancelError!;
          }
          if (video.folderUri == null) {
            video = video.copyWith(container: container);
            await library.upsertDownload(video);
            recovery.checkCurrent();
            await File(output).rename(mediaPath);
          } else {
            final uri = await storage.prepareDocument(video.folderUri!,
                video.storageUri, outputVideo.fileName, outputVideo.mimeType);
            // Record ownership before writing so retries reuse this document
            // and deletion can clean up an interrupted save after a restart.
            video = video.copyWith(storageUri: uri, container: container);
            await library.upsertDownload(video);
            if (token.isCancelled) throw token.cancelError!;
            await storage.writeDocument(output, uri, token);
          }
          if (token.isCancelled) throw token.cancelError!;
          // Muzza reads saved media before its evictable playback cache. Our
          // files need owner/rendition proof and a fingerprint of final bytes,
          // including remuxed video and externally stored documents.
          DownloadPlaybackProvenance? provenance;
          try {
            final integrity = video.storageUri == null
                ? await _privateDownloadIntegrity(mediaPath)
                : await storage.inspectDocument(
                    video.storageUri!, video.folderUri!);
            if (integrity != null) {
              provenance = DownloadPlaybackProvenance.create(
                  video: vid,
                  server: server,
                  audioOnly: video.audioOnly,
                  container: container,
                  audio: audio,
                  videoFormat: selectedVideo,
                  byteLength: integrity.byteLength,
                  sha256: integrity.sha256);
            }
          } catch (_) {
            // Failure of optional automatic reuse does not delete a completed
            // download or change its existing explicit-offline behavior.
            provenance = null;
          }
          if (token.isCancelled) throw token.cancelError!;
          await library.upsertDownload(video.copyWith(
              playbackProvenance: provenance,
              downloadComplete: true,
              downloadFailed: false,
              authenticationRequired: false,
              storageFailed: false));
          setVideos();
          update(1, 1, steps - 1, steps);
          try {
            await _deleteParts(video);
          } on FileSystemException catch (error) {
            log.fine(
                'The completed download has leftover temporary files', error);
          }
          return;
        } finally {
          artworkToken.cancel();
          _activeArtworkToken = null;
          await artwork;
        }
      }, onTransportFailure: () async {
        if (_activeNeedsNetwork) await _refreshConnectivity();
      }, onWaiting: (retryAt) {
        if (!_current || token.isCancelled) return;
        final current = state.downloadProgresses[video.videoId];
        final waiting = DownloadProgress(token, retryAt: retryAt)
          ..count = current?.count ?? 0
          ..total = current?.total ?? 1;
        emit(state.copyWith(downloadProgresses: {video.videoId: waiting}));
      });
    } catch (error, stack) {
      if (!token.isCancelled && !_closing) {
        if (isDownloadOutOfSpace(error)) {
          if (currentMux case final output?) await _deleteStagedMux(output);
          if (_current && !token.isCancelled) {
            emit(state.copyWith(spaceBlockedVideoIds: {
              ...state.spaceBlockedVideoIds,
              video.videoId
            }));
          }
          return;
        }
        if (error is DownloadSizeLimitExceeded) {
          try {
            await _deleteParts(video);
          } on FileSystemException catch (cleanupError) {
            log.fine('Could not clear temporary discovery files', cleanupError);
          }
          if (token.isCancelled) return;
        }
        final signInRequired = _accessPauseNeedsSignIn(error);
        if (signInRequired != null) {
          final paused = {...state.pausedVideoIds, video.videoId};
          await library.upsertDownload(video.copyWith(
              downloadFailed: false,
              authenticationRequired: signInRequired,
              downloadComplete: false));
          await library.saveSetting(
              SettingsValue(_pausedSetting, jsonEncode(paused.toList())));
          if (_current) emit(state.copyWith(pausedVideoIds: paused));
          return;
        }
        log.warning(
            'Download failed for ${video.videoId}; partial files are kept (${error.runtimeType})',
            null,
            stack);
        await library.upsertDownload(video.copyWith(
            downloadFailed: true,
            downloadComplete: false,
            storageFailed: error is PlatformException &&
                error.code == 'DOWNLOAD_STORAGE'));
      }
    } finally {
      _activeNeedsNetwork = false;
      dio.close(force: true);
      if (_current) {
        emit(state.copyWith(downloadProgresses: {}));
        setVideos();
      }
    }
  }

  Future<int> _pendingDocumentSize(DownloadedVideo video) async {
    final uri = video.storageUri;
    final folder = video.folderUri;
    if (uri == null || folder == null) return 0;
    try {
      return await storage.documentSize(uri, folder) ?? 0;
    } on PlatformException {
      return 0;
    } on MissingPluginException {
      return 0;
    }
  }

  Future<void> _deleteStagedMux(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (error) {
      log.fine('Could not remove the unfinished mux output',
          error.osError?.errorCode);
    }
  }

  Future<List<SponsorSegment>> _downloadSponsorSegments(
      DownloadedVideo video, IDbClient library, CancelToken token) async {
    if (video.musicMetadata == null || token.isCancelled) {
      return video.sponsorSegments;
    }
    final categories = SponsorSegmentType.values
        .where((type) =>
            type.isEnabled(library.getSettings(type.settingsName())?.value))
        .toList();
    if (categories.isEmpty) return video.sponsorSegments;
    try {
      final segments = await Future.any([
        service.getSponsorSegments(video.videoId, categories),
        // The service has no cancellation token. A late result never writes to
        // disk, and profile switches/deletion do not wait for this lookup.
        token.whenCancel.then((_) => video.sponsorSegments),
      ]).timeout(const Duration(seconds: 3),
          onTimeout: () => video.sponsorSegments);
      // Keep raw categories/actions/timings so playback can apply the current
      // preferences offline. Non-finite numbers cannot be persisted as JSON.
      final cacheable = segments
          .where((segment) => segment.segment.every((time) => time.isFinite))
          .toList();
      // Service also returns an empty list for transport/HTTP failures, so an
      // optional refresh without usable data must preserve the offline cache.
      return cacheable.isEmpty ? video.sponsorSegments : cacheable;
    } catch (_) {
      return video.sponsorSegments;
    }
  }

  /// Access failures need an explicit resume after account settings recover.
  /// Waiting, disabled access and cooldowns do not require another sign-in.
  static bool? _accessPauseNeedsSignIn(Object error) {
    if (error is DioException && error.error != null) {
      return _accessPauseNeedsSignIn(error.error!);
    }
    if (error is GatewayAuthenticationRequired) return true;
    if (error is DownloadCooldown) return false;
    if (error is NerdVpnAccessRequired) {
      return const {'missing', 'signInRequired'}.contains(error.state);
    }
    if (error is InvidiousServiceError && error.isGatewayAccessFailure) {
      return const {'credentials_required', 'invalid_credentials'}
          .contains(error.errorCode);
    }
    return null;
  }

  List<String> _stockPosterUrls(Video video, Server server,
      {required bool artTrack}) {
    final images = stockSongThumbnails(video.videoId, video.videoThumbnails,
        instanceUrl: server.url);
    if (images.isEmpty) return const [];
    final preferred = artTrack
        ? stockSongThumbnails(video.videoId, images, artTrack: true)
        : images;
    final ranked = ImageObject.getThumbnailUrlsByPreferredOrder(images);
    // Stock metadata lists sizes even when this upload has no HD poster.
    // Try the best source, then the advertised HQ and MQ before other sizes.
    return {
      ImageObject.getBestThumbnail(preferred)!.url,
      for (final name in ['hqdefault', 'mqdefault'])
        if (ranked.contains('/vi/${video.videoId}/$name.jpg'))
          '/vi/${video.videoId}/$name.jpg',
      ...ranked,
    }.take(4).toList(growable: false);
  }

  Future<void> _downloadArtwork(
      Dio dio, DownloadedVideo video, Server server, CancelToken token,
      {String? cover, required List<String> posters}) async {
    final deadline = Timer(const Duration(seconds: 5),
        () => token.cancel('Artwork download deadline'));
    try {
      for (final source in [if (cover != null) cover, ...posters]) {
        if (token.isCancelled) return;
        final File? target;
        if (source == cover) {
          target = await video.songCoverFile;
        } else if (video.musicMetadata != null) {
          target = await video.stockSongPosterFile;
        } else {
          target = File(await video.thumbnailPath);
        }
        final url = invidiousImageUrl(source, server);
        if (target == null || url == null || url.isEmpty) continue;
        if (await target.exists()) return;
        final partial = File('${target.path}.part');
        try {
          await target.parent.create(recursive: true);
          await dio.download(url, partial.path,
              cancelToken: token,
              options: Options(
                  headers: server.headersForUrl(url),
                  receiveDataWhenStatusError: false));
          if (token.isCancelled) return;
          if (await partial.length() == 0) continue;
          await partial.rename(target.path);
          return;
        } on DioException catch (error) {
          // A missing image can fall back to the next stock rendition.
          // Authentication, cooldowns and cancellation apply to all candidates.
          if (!const {404, 410}.contains(error.response?.statusCode)) return;
        } finally {
          if (await partial.exists()) await partial.delete();
        }
      }
    } on FileSystemException {
      log.fine('Thumbnail could not be saved; the media download can continue');
    } finally {
      deadline.cancel();
    }
  }

  Future<void> pauseDownload(DownloadedVideo video) => _mutate(() async {
        await _ready;
        if (!_current ||
            _switchingProfile ||
            video.profileId != _library.profileId) {
          return;
        }
        final paused = {...state.pausedVideoIds, video.videoId};
        emit(state.copyWith(pausedVideoIds: paused));
        state.downloadProgresses[video.videoId]?.cancelToken.cancel();
        await _library.saveSetting(
            SettingsValue(_pausedSetting, jsonEncode(paused.toList())));
      });

  Future<void> retryDownload(DownloadedVideo video) =>
      _mutate(() => _retryDownload(video.profileId, video.videoId));

  Future<void> retryDownloadFromNotification(
          String profileId, String videoId, String ticket) =>
      _mutate(
          () => _retryDownload(profileId, videoId, notificationTicket: ticket));

  Future<void> _retryDownload(String profileId, String videoId,
      {String? notificationTicket}) async {
    await _ready;
    final library = _library;
    bool canRetry() =>
        _current &&
        !_switchingProfile &&
        identical(library, _library) &&
        profileId == library.profileId &&
        !_deleting.contains(videoId);
    bool ownsNotification(DownloadedVideo? video) =>
        notificationTicket == null ||
        (video != null &&
            video.notificationTicket == notificationTicket &&
            !video.downloadComplete &&
            (video.downloadFailed ||
                video.authenticationRequired ||
                video.storageFailed ||
                state.spaceBlockedVideoIds.contains(videoId)));
    if (!canRetry() ||
        !ownsNotification(library.getDownloadByVideoId(videoId))) {
      return;
    }

    final paused = {...state.pausedVideoIds}..remove(videoId);
    emit(state.copyWith(pausedVideoIds: paused));
    await library.saveSetting(
        SettingsValue(_pausedSetting, jsonEncode(paused.toList())));
    if (!canRetry()) return;
    // A captured job can finish or be replaced while its control is open.
    final current = library.getDownloadByVideoId(videoId);
    if (current == null ||
        current.downloadComplete ||
        !ownsNotification(current)) {
      return;
    }
    if (current.downloadFailed ||
        current.authenticationRequired ||
        current.storageFailed) {
      await library.upsertDownload(current.copyWith(
          downloadFailed: false,
          authenticationRequired: false,
          storageFailed: false));
    }
    if (!canRetry()) return;
    final blocked = {...state.spaceBlockedVideoIds}..remove(videoId);
    emit(state.copyWith(spaceBlockedVideoIds: blocked));
    setVideos();
    if (!_connectivity.online) await _refreshConnectivity();
    unawaited(_drain());
  }

  Future<void> _deleteParts(DownloadedVideo video) async {
    final path = await video.stagingPath;
    for (final suffix in downloadStagingSuffixes) {
      final file = File('$path$suffix');
      if (await file.exists()) await file.delete();
    }
    final artwork = File('${await video.thumbnailPath}.part');
    if (await artwork.exists()) await artwork.delete();
    final covers = await video.songCoverDirectory;
    if (await covers.exists()) {
      final current = {
        (await video.songCoverFile)?.path,
        (await video.stockSongPosterFile)?.path
      };
      await for (final entry in covers.list(followLinks: false)) {
        if (entry is File && !current.contains(entry.path)) {
          await entry.delete();
        }
      }
    }
  }

  // Titles, progress and retry state can change while the confirmation is open.
  // The persisted owner, job options and output identify the confirmed target.
  bool _sameMusicDownload(DownloadedVideo requested, DownloadedVideo saved) =>
      requested.hasSameMusicSource(saved);

  MusicDownloadDeletionApproval captureMusicDeletion(
      List<DownloadedVideo> selection) {
    final jobs = <({DownloadedVideo video, Object incarnation})>[];
    final seen = <String>{};
    if (_current && !_switchingProfile) {
      for (final video in selection) {
        if (video.profileId != _library.profileId ||
            !DownloadedVideo.isSafeFileId(video.videoId) ||
            _deleting.contains(video.videoId)) {
          continue;
        }
        final saved = _library.getDownloadByVideoId(video.videoId);
        if (saved == null ||
            !_sameMusicDownload(video, saved) ||
            !seen.add(video.videoId)) {
          continue;
        }
        jobs.add((
          video: saved,
          incarnation:
              _musicDeletionIncarnations.putIfAbsent(video.videoId, Object.new)
        ));
      }
    }
    return MusicDownloadDeletionApproval._(this, _generation, jobs);
  }

  /// Removes matching jobs one at a time. Missing, replaced or inaccessible
  /// files do not prevent the other confirmed jobs from being removed.
  Future<int> deleteMusicSelection(MusicDownloadDeletionApproval approval,
      {required bool Function() isCurrent}) async {
    bool current() =>
        _current &&
        !_switchingProfile &&
        identical(approval._manager, this) &&
        approval._generation == _generation &&
        isCurrent();
    var removed = 0;
    for (final job in approval._jobs) {
      if (!current()) break;
      try {
        if (await _queueOfflineMusicWork(() => _deleteVideo(job.video,
            selectionIsCurrent: () =>
                current() &&
                identical(_musicDeletionIncarnations[job.video.videoId],
                    job.incarnation)))) {
          removed++;
        }
      } on Exception catch (error) {
        if (error is! PlatformException && error is! FileSystemException) {
          rethrow;
        }
        log.warning(
            'Could not remove a selected Music download (${error.runtimeType})');
      }
    }
    return removed;
  }

  Future<bool> deleteVideo(DownloadedVideo video) =>
      _queueOfflineMusicWork(() => _deleteVideo(video));

  Future<bool> _deleteVideo(DownloadedVideo requested,
          {bool Function()? selectionIsCurrent,
          bool managedOnly = false,
          bool trimDiscovery = false}) =>
      _mutate(() async {
        await _ready;
        if (!DownloadedVideo.isSafeFileId(requested.videoId) ||
            !DownloadedVideo.isSafeFileId(requested.profileId)) {
          throw const FormatException('Invalid download identity');
        }
        if (!_current ||
            _switchingProfile ||
            requested.profileId != _library.profileId ||
            selectionIsCurrent?.call() == false) {
          return false;
        }
        final saved = _library.getDownloadByVideoId(requested.videoId);
        bool canRemove(DownloadedVideo video) {
          if (!video.audioOnly) return !managedOnly;
          final required = _playlistSongsInUse();
          if (managedOnly) {
            return required != null &&
                _offlineDiscovery != null &&
                !required.containsKey(video.videoId) &&
                _discoveryWants(video.videoId) == trimDiscovery &&
                _library.isPlaylistOwnedMusicDownload(video.videoId);
          }
          return required?.containsKey(video.videoId) != true;
        }

        if (saved == null ||
            !canRemove(saved) ||
            (selectionIsCurrent != null &&
                !_sameMusicDownload(requested, saved)) ||
            !_deleting.add(requested.videoId)) {
          return false;
        }
        var video = saved;
        var resumeIfAbandoned = false;
        try {
          final export = _exports[video.videoId];
          if (export != null) {
            export.token.cancel();
            try {
              await export.result;
            } catch (_) {
              // The writer is now detached from the file being removed.
            }
          }
          final token = state.downloadProgresses[video.videoId]?.cancelToken;
          resumeIfAbandoned =
              _activeId == video.videoId && token != null && !token.isCancelled;
          token?.cancel();
          if (_activeId == video.videoId) await _activeJob;
          // The active job may have created a document since this UI snapshot.
          final latest = _library.getDownloadByVideoId(video.videoId);
          if (selectionIsCurrent != null &&
              (!selectionIsCurrent() ||
                  latest == null ||
                  !_sameMusicDownload(requested, latest))) {
            return false;
          }
          video = latest ?? video;
          if (!canRemove(video)) return false;
          if (video.exportedMusic case final copy? when !copy.complete) {
            await storage.deleteDocument(copy.uri);
          }
          if (video.incompleteMusicEdit case final copy? when !copy.complete) {
            // An interruption between provider publication and the database
            // commit can leave an already finished user copy in this slot.
            if (!await _isPublishedMusicEdit(copy)) {
              await storage.deleteDocument(copy.uri);
            }
          }
          if (video.storageUri != null) {
            await storage.deleteDocument(video.storageUri!);
          }
          await _deleteParts(video);
          for (final path in [
            if (video.storageUri == null) await video.effectivePath,
            await video.downloadPath,
            await video.subtitlePath,
            await video.thumbnailPath
          ]) {
            final file = File(path);
            if (await file.exists()) await file.delete();
          }
          final covers = await video.songCoverDirectory;
          if (await covers.exists()) await covers.delete(recursive: true);
          if (selectionIsCurrent != null) {
            final remaining = _library.getDownloadByVideoId(video.videoId);
            if (remaining == null ||
                !_sameMusicDownload(requested, remaining)) {
              return false;
            }
          }
          await _library.deleteDownload(video);
          _musicDeletionIncarnations.remove(video.videoId);
          resumeIfAbandoned = false;
          final paused = {...state.pausedVideoIds}..remove(video.videoId);
          await _library.saveSetting(
              SettingsValue(_pausedSetting, jsonEncode(paused.toList())));
          final blocked = {...state.spaceBlockedVideoIds}
            ..remove(video.videoId);
          emit(state.copyWith(
              pausedVideoIds: paused, spaceBlockedVideoIds: blocked));
          setVideos();
          return true;
        } finally {
          _deleting.remove(video.videoId);
          // The drain may have finished while this job was reserved for deletion.
          if (resumeIfAbandoned) unawaited(_drain());
        }
      });

  bool canPlayAll() =>
      _current &&
      !_switchingProfile &&
      state.videos.any((v) => v.downloadComplete && !v.downloadFailed);
  void playAll() {
    if (!_current || _switchingProfile) return;
    player.playOfflineVideos(state.videos
        .where((v) => v.downloadComplete && !v.downloadFailed)
        .toList());
  }

  /// Publishes an existing song without fetching it again or moving the original.
  Future<bool> exportMusic(DownloadedVideo video) =>
      _startMusicExport(video, edited: false);

  Future<bool> exportMusicWithoutSponsorSegments(DownloadedVideo video) =>
      _startMusicExport(video, edited: true);

  Future<bool> _startMusicExport(DownloadedVideo video,
      {required bool edited}) {
    if (!_current ||
        _switchingProfile ||
        video.profileId != _library.profileId ||
        _deleting.contains(video.videoId)) {
      return Future.value(false);
    }
    final previous = _exports[video.videoId];
    if (previous != null) {
      return previous.edited == edited ? previous.result : Future.value(false);
    }
    final token = CancelToken();
    final result = _mutate(() => _exportMusic(video, token, edited: edited))
        .whenComplete(() => _exports.remove(video.videoId));
    _exports[video.videoId] = (token: token, result: result, edited: edited);
    return result;
  }

  Future<bool> _isPublishedMusicEdit(ExportedMusicCopy copy) async {
    final digest = copy.outputSha256;
    if (digest == null) return false;
    try {
      final stored = await storage.inspectDocument(copy.uri, copy.folder);
      return stored != null && stored.byteLength > 0 && stored.sha256 == digest;
    } on PlatformException {
      // A pending, moved, or missing document cannot prove publication.
      return false;
    }
  }

  Future<bool> _exportMusic(DownloadedVideo requested, CancelToken token,
      {required bool edited}) async {
    await _ready;
    final library = _library;
    final saved = library.getDownloadByVideoId(requested.videoId);
    if (token.isCancelled ||
        !_current ||
        _switchingProfile ||
        saved == null ||
        !requested.hasSameMusicSource(saved) ||
        !saved.downloadComplete ||
        saved.downloadFailed ||
        (!edited && saved.storageUri != null && saved.storeAsMusic)) {
      return false;
    }
    bool current() {
      if (token.isCancelled ||
          !_current ||
          _switchingProfile ||
          !identical(library, _library) ||
          _deleting.contains(saved.videoId)) {
        return false;
      }
      final latest = library.getDownloadByVideoId(saved.videoId);
      return latest != null &&
          !latest.downloadFailed &&
          saved.hasSameMusicSource(latest);
    }

    final categories = <SponsorSegmentType>{
      if (edited)
        for (final type in SponsorSegmentType.values)
          if (type.isEnabled(library.getSettings(type.settingsName())?.value))
            type,
    };
    if (edited &&
        !saved.sponsorSegments.any((segment) =>
            segment.actionType == 'skip' &&
            categories.contains(segment.category))) {
      throw const NoSponsorAudioSegments();
    }
    final format = MusicDownloadFormat.forDatabase(library);
    final folder = await _deviceMusicFolder();
    if (folder == null || !current()) return false;
    final previous = edited
        ? (saved.editedMusicExport?.complete == true
            ? saved.editedMusicExport
            : null)
        : saved.exportedMusic;
    final pendingEdit = edited ? saved.incompleteMusicEdit : null;
    bool conflictsWithSavedCopy(String uri) =>
        uri == saved.storageUri ||
        uri == saved.exportedMusic?.uri ||
        uri == previous?.uri;
    final sameDestination =
        previous?.folder == folder && previous?.format == format;
    if (!edited && sameDestination && previous!.complete) {
      // Only confirmed absence warrants another copy. A temporary provider
      // failure leaves the original record intact so a later retry can find it.
      if (await storage.exportExists(previous.uri, folder)) return current();
    }
    final outputSong = saved.copyWith(musicFormat: format);
    final staging = await saved.stagingPath;
    final stageInput = File('$staging.export-input.part');
    final stageOutput = File('$staging.export.${outputSong.extension}');
    try {
      var input = await saved.effectivePath;
      final sourceUri = saved.storageUri;
      final sourceFolder = saved.folderUri;
      if (sourceUri != null && sourceFolder == null) {
        throw StateError('Missing download folder');
      }
      if (edited) {
        final sourceBytes = sourceUri == null
            ? await File(input).length()
            : saved.playbackProvenance?.byteLength ??
                await storage.documentSize(sourceUri, sourceFolder!);
        if (sourceBytes != null) {
          await checkDownloadSpace(storage, {
            stageInput.path: remainingDownloadGrowth(
                sourceBytes, await downloadFileBytes(stageInput.path))
          });
        }
        if (!current()) return false;
      }
      if (sourceUri != null) {
        await storage.readDocument(
            sourceUri, sourceFolder!, stageInput.path, token);
        input = stageInput.path;
      } else if (edited) {
        // Hash and encode the same snapshot. Poll cancellation while copying so
        // profile changes or deletion do not wait for the entire source file.
        final target = await stageInput.open(mode: FileMode.write);
        try {
          await for (final chunk in File(input).openRead()) {
            if (token.isCancelled) return false;
            await target.writeFrom(chunk);
          }
        } finally {
          await target.close();
        }
        input = stageInput.path;
      }
      if (!current()) return false;
      String? signature;
      var publishedPending = false;
      ({int byteLength, String sha256})? editedOutput;
      if (edited) {
        final source = await _probeAudioExport(input, saved, token);
        final edit = SponsorAudioEdit(
            sourceDuration: source.duration,
            segments: saved.sponsorSegments,
            categories: categories);
        final integrity = await _privateDownloadIntegrity(input);
        final provenance = saved.playbackProvenance;
        if (provenance != null &&
            !provenance.matchesOutput(
                byteLength: integrity.byteLength, sha256: integrity.sha256)) {
          throw const FormatException('The original download changed');
        }
        signature = sha256
            .convert(utf8.encode(jsonEncode([
              1,
              integrity.sha256,
              format.name,
              outputSong.musicPolicy?.quality.targetBitrate,
              edit.timingSignature,
            ])))
            .toString();
        if (!current()) return false;
        if (sameDestination &&
            previous!.complete &&
            previous.editSignature == signature &&
            await storage.exportExists(previous.uri, folder)) {
          return current();
        }
        if (pendingEdit != null && !conflictsWithSavedCopy(pendingEdit.uri)) {
          publishedPending = await _isPublishedMusicEdit(pendingEdit);
          if (!current()) return false;
          if (publishedPending &&
              pendingEdit.editSignature == signature &&
              pendingEdit.folder == folder &&
              pendingEdit.format == format) {
            await library.saveDownloadExport(
                saved.videoId,
                ExportedMusicCopy(folder, pendingEdit.uri, format,
                    complete: true,
                    editSignature: signature,
                    outputSha256: pendingEdit.outputSha256),
                expectedSource: saved);
            setVideos();
            return true;
          }
        }
        await _muxAudioExport(
            musicMuxArguments(
                input: input,
                output: stageOutput.path,
                video: outputSong,
                inputFormat: saved.musicFormat,
                sourceCodec: source.codec,
                edit: edit),
            token);
        final output =
            await _probeAudioExport(stageOutput.path, outputSong, token);
        if (!edit.matchesOutput(output, format)) {
          throw const FormatException('The edited audio did not verify');
        }
        editedOutput = await _privateDownloadIntegrity(stageOutput.path);
        await _deleteStagedMux(stageInput.path);
        await checkDownloadSpace(storage, {folder: editedOutput.byteLength});
        input = stageOutput.path;
      } else if (saved.musicFormat != format) {
        await encodeMusic(
            input: input,
            output: stageOutput.path,
            video: outputSong,
            inputFormat: saved.musicFormat,
            token: token);
        input = stageOutput.path;
      }
      if (!current()) return false;
      final sameTarget =
          sameDestination && previous?.editSignature == signature;
      if (pendingEdit != null && !publishedPending) {
        if (conflictsWithSavedCopy(pendingEdit.uri)) {
          throw StateError('The edited export needs a separate destination');
        }
        // A lingering provisional file failed the verified-completion check.
        // Start a new document rather than writing over a moved or stale URI.
        await storage.deleteDocument(pendingEdit.uri);
        if (!current()) return false;
      } else if (previous != null && !previous.complete && !sameTarget) {
        await storage.deleteDocument(previous.uri);
        if (!current()) return false;
      }
      final name = signature == null
          ? outputSong.fileName
          : '${p.basenameWithoutExtension(outputSong.fileName)}'
              '_sponsorblock-${signature.substring(0, 12)}.${outputSong.extension}';
      final uri = await storage.prepareDocument(
          folder,
          sameTarget && !previous!.complete ? previous.uri : null,
          name,
          outputSong.mimeType);
      // A provider must not send an edit back to the original or a completed
      // copy. Those documents belong to the user.
      if (edited &&
          (conflictsWithSavedCopy(uri) ||
              (publishedPending && uri == pendingEdit?.uri))) {
        throw StateError('The edited export needs a separate destination');
      }
      var hasReceipt = false;
      var complete = false;
      try {
        if (!current()) return false;
        await library.saveDownloadExport(
            saved.videoId,
            ExportedMusicCopy(folder, uri, format,
                editSignature: signature, outputSha256: editedOutput?.sha256),
            expectedSource: edited ? saved : null);
        hasReceipt = true;
        if (!current()) return false;
        await storage.writeDocument(input, uri, token);
        if (!current()) return false;
        if (editedOutput != null) {
          final published = await storage.inspectDocument(uri, folder);
          if (published != editedOutput) {
            throw const FormatException('The published edit did not verify');
          }
          if (!current()) return false;
        }
        await library.saveDownloadExport(
            saved.videoId,
            ExportedMusicCopy(folder, uri, format,
                complete: true,
                editSignature: signature,
                outputSha256: editedOutput?.sha256),
            expectedSource: edited ? saved : null);
        complete = true;
        setVideos();
        return true;
      } finally {
        // Edited output can be visible through some providers before the
        // write finishes. Remove it on failure. A pending receipt may point to
        // a missing document, which a later retry handles without overwriting.
        if (!complete && (edited || !hasReceipt)) {
          try {
            await storage.deleteDocument(uri);
          } catch (error, trace) {
            log.warning(
                'Could not remove an incomplete Music export', error, trace);
          }
        }
      }
    } catch (_) {
      if (edited && token.isCancelled) return false;
      rethrow;
    } finally {
      for (final file in [stageInput, stageOutput]) {
        if (await file.exists()) await file.delete();
      }
    }
  }

  Future<void> copyToDownloadFolder(DownloadedVideo video) async {
    if (!_current ||
        _switchingProfile ||
        video.profileId != _library.profileId) {
      return;
    }
    final file = File(await video.effectivePath);
    if (await file.exists()) {
      final name =
          '${video.title.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_').replaceAll(RegExp(r'_{2,}'), '')}_${video.videoId}${p.extension(file.path)}';
      await copyFileIntoDownloadFolder(file.path, name);
    }
  }

  @override
  Future<void> close() async {
    await (_closeFuture ??= _closeDownloads());
    return super.close();
  }

  Future<void> _closeDownloads() async {
    NetworkProxy.instance.removeBeforeApply(_proxyChanging);
    _closing = true;
    _keepingCachedMusic?.cancel();
    for (final export in _exports.values) {
      export.token.cancel();
    }
    for (final progress in state.downloadProgresses.values) {
      progress.cancelToken.cancel();
    }
    await _networkSubscription?.cancel();
    await _playlistSubscription?.cancel();
    await _renames.cancel();
    await Future.wait(List.of(_mutations));
    await _activeJob;
    _playlistOfflineChanges.dispose();
    _discoveryOfflineChanges.dispose();
  }
}

@freezed
sealed class DownloadManagerState with _$DownloadManagerState {
  const factory DownloadManagerState({
    String? folderUri,
    String? folderName,
    @Default(false) bool usePrivateStorage,
    String? audioFolderUri,
    String? audioFolderName,
    @Default(false) bool usePrivateAudioStorage,
    @Default([]) List<DownloadedVideo> videos,
    @Default({}) Map<String, DownloadProgress> downloadProgresses,
    @Default({}) Set<String> pausedVideoIds,
    @Default(false) bool wifiOnly,
    @Default(false) bool waitingForWifi,
    @Default(false) bool wifiConnected,
    @Default(true) bool networkConnected,
    @Default({}) Set<String> spaceBlockedVideoIds,
  }) = _DownloadManagerState;

  const DownloadManagerState._();

  bool waitingForWifiFor(DownloadedVideo video) =>
      waitingForWifi || (!wifiConnected && video.musicPolicy?.wifiOnly == true);

  bool _canWait(DownloadedVideo video) =>
      !video.downloadComplete &&
      !video.downloadFailed &&
      !video.storageFailed &&
      !video.authenticationRequired &&
      !pausedVideoIds.contains(video.videoId);

  bool waitingForSpaceFor(DownloadedVideo video) =>
      _canWait(video) && spaceBlockedVideoIds.contains(video.videoId);

  bool waitingForNetworkFor(DownloadedVideo video) =>
      _canWait(video) &&
      !networkConnected &&
      !downloadProgresses.containsKey(video.videoId);

  double get totalProgress {
    var downloaded = 0, total = 0;
    for (final progress in downloadProgresses.values) {
      downloaded += progress.count;
      total += progress.total;
    }
    return total == 0 ? 0 : (downloaded / total).clamp(0, 1);
  }
}
