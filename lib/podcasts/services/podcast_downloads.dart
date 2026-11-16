import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipious/downloads/states/resumable_download.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/connectivity.dart';
import 'package:clipious/podcasts/models/podcast.dart';
import 'package:clipious/podcasts/services/podcast_http.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const podcastDownloadsSetting = 'podcast-downloads-v1';

class PodcastDownload {
  final String feedId;
  final String feedTitle;
  final PodcastEpisode episode;
  final int bytes;

  const PodcastDownload(
      {required this.feedId,
      required this.feedTitle,
      required this.episode,
      required this.bytes});

  Map<String, dynamic> toJson() => {
        'feedId': feedId,
        'feedTitle': feedTitle,
        'episode': episode.toJson(),
        'bytes': bytes,
      };

  static PodcastDownload? tryParse(Object? value) {
    if (value is! Map ||
        value['feedId'] is! String ||
        value['feedTitle'] is! String ||
        RegExp(r'^[a-f0-9]{64}$').stringMatch(value['feedId']) !=
            value['feedId'] ||
        (value['feedTitle'] as String).length > 1024 ||
        (value['feedTitle'] as String).trim().isEmpty ||
        value['bytes'] is! int ||
        value['bytes'] <= 0 ||
        value['bytes'] > PodcastDownloads.maximumDownloadBytes) {
      return null;
    }
    final episode = PodcastEpisode.tryParse(value['episode']);
    return episode == null
        ? null
        : PodcastDownload(
            feedId: value['feedId'],
            feedTitle: value['feedTitle'],
            episode: episode,
            bytes: value['bytes']);
  }
}

class PodcastDownloadProgress {
  final int received;
  final int total;

  const PodcastDownloadProgress(this.received, this.total);

  double? get fraction => total > 0 ? (received / total).clamp(0, 1) : null;
}

/// Private podcast files and completion metadata, fixed to one local profile.
/// These transfers never use Invidious accounts or the video download pipeline.
class PodcastDownloads extends ChangeNotifier {
  static const maximumDownloadBytes = 1024 * 1024 * 1024;
  static const _maximumEntries = 1000;
  static const _maximumMetadataBytes = 5 * 1024 * 1024;
  static final _owners = Expando<Map<String, PodcastDownloads>>();

  factory PodcastDownloads.forProfile(IDbClient database, String profileId,
          {Dio? client,
          Future<Directory> Function()? documentsDirectory,
          Future<bool> Function()? wifiConnected,
          Stream<bool>? networkChanges}) =>
      (_owners[database] ??= {}).putIfAbsent(
          profileId,
          () => PodcastDownloads._(
              database.forProfile(profileId),
              client,
              documentsDirectory ?? getApplicationDocumentsDirectory,
              wifiConnected,
              networkChanges));

  PodcastDownloads._(this._database, this._injectedClient, this._documents,
      this._wifiConnected, this._networkChanges);

  final IDbClient _database;
  final Dio? _injectedClient;
  final Future<Directory> Function() _documents;
  final Future<bool> Function()? _wifiConnected;
  final Stream<bool>? _networkChanges;
  final _errors = <String, String>{};
  final _progress = <String, PodcastDownloadProgress>{};
  final _removing = <String>{};
  Future<void> _writes = Future.value();
  Future<void>? _activeJob;
  CancelToken? _token;
  String? _activeId;
  String? _cachedValue;
  List<PodcastDownload> _entries = const [];
  bool _closed = false;

  String get profileId => _database.profileId;
  String? get activeId => _activeId;
  Map<String, String> get errors => Map.unmodifiable(_errors);
  Map<String, PodcastDownloadProgress> get progress =>
      Map.unmodifiable(_progress);
  bool isDownloading(String episodeId) => _activeId == episodeId;
  bool get _wifiOnly =>
      _database.getSettings('downloads-wifi-only')?.value == 'true';

  Future<bool> _onWifi() async {
    if (_wifiConnected != null) return _wifiConnected();
    if (!Platform.isAndroid) return false;
    return isWifiConnected();
  }

  List<PodcastDownload> get entries {
    final stored = _database.getSettings(podcastDownloadsSetting)?.value;
    if (_cachedValue == stored) return _entries;
    _cachedValue = stored;
    _entries = const [];
    if (stored == null || stored.length > _maximumMetadataBytes) {
      return _entries;
    }
    try {
      final value = jsonDecode(stored);
      if (value is! Map || value['version'] != 1 || value['entries'] is! List) {
        return _entries;
      }
      final unique = <String, PodcastDownload>{};
      for (final item in (value['entries'] as List).take(_maximumEntries)) {
        final download = PodcastDownload.tryParse(item);
        if (download != null) unique[download.episode.id] = download;
      }
      _entries = List.unmodifiable(unique.values);
    } on FormatException {
      // Damaged metadata never turns a staging file into an offline episode.
    }
    return _entries;
  }

  Future<File> _file(String episodeId, {bool createDirectory = false}) async {
    final root = await _documents();
    String digest(String text) => sha256.convert(utf8.encode(text)).toString();
    final folder = Directory(p.join(root.path, 'podcasts', digest(profileId)));
    if (createDirectory) await folder.create(recursive: true);
    return File(p.join(folder.path, '${digest(episodeId)}.audio'));
  }

  Future<String?> localPath(String episodeId) async {
    final download =
        entries.where((entry) => entry.episode.id == episodeId).firstOrNull;
    if (download == null) return null;
    final file = await _file(episodeId);
    Future<bool> matches(PodcastDownload candidate) async {
      try {
        return await file.exists() && await file.length() == candidate.bytes;
      } on FileSystemException {
        return false;
      }
    }

    if (await matches(download)) return file.path;
    var removed = false;
    var repaired = false;
    await _save((items) async {
      final latest =
          items.where((entry) => entry.episode.id == episodeId).firstOrNull;
      // Recheck inside the write queue: a completed retry may have repaired the
      // file while this caller was awaiting the first disk read.
      if (latest != null) {
        repaired = await matches(latest);
        if (!repaired) {
          items.removeWhere((entry) => entry.episode.id == episodeId);
          removed = true;
        }
      }
    });
    if (removed && !_closed) notifyListeners();
    return repaired ? file.path : null;
  }

  Future<void> _save(FutureOr<void> Function(List<PodcastDownload>) update) {
    return _writes = _writes.catchError((_) {}).then((_) async {
      final next = entries.toList();
      await update(next);
      final value = jsonEncode({
        'version': 1,
        'entries': next.map((entry) => entry.toJson()).toList(),
      });
      if (next.length > _maximumEntries ||
          utf8.encode(value).length > _maximumMetadataBytes) {
        throw StateError('The podcast download library is full.');
      }
      await _database
          .saveSetting(SettingsValue(podcastDownloadsSetting, value));
      _cachedValue = value;
      _entries = List.unmodifiable(next);
    });
  }

  Future<void> download(PodcastFeed feed, PodcastEpisode episode) async {
    if (_closed) throw StateError('Podcast downloads are closed.');
    if (_activeId != null) {
      throw StateError('Another podcast episode is downloading.');
    }
    if (_removing.contains(episode.id)) {
      throw StateError('This podcast download is being removed.');
    }
    PodcastUrlPolicy.validate(Uri.parse(episode.mediaUrl));
    final clean = PodcastEpisode.tryParse(episode.toJson());
    if (clean == null ||
        feed.id.isEmpty ||
        feed.id.length > 128 ||
        feed.title.isEmpty ||
        feed.title.length > 1024) {
      throw const FormatException('Invalid podcast episode.');
    }
    final token = CancelToken();
    final finished = Completer<void>();
    _activeId = episode.id;
    _token = token;
    _activeJob = finished.future;
    NetworkProxy.instance.addBeforeApply(cancelAll);
    _errors.remove(episode.id);
    _progress[episode.id] = const PodcastDownloadProgress(0, 0);
    notifyListeners();
    File? partial;
    File? finalFile;
    var committed = false;
    Dio? client;
    StreamSubscription<bool>? connectivity;
    try {
      if (await localPath(episode.id) != null) return;
      if (token.isCancelled) return;
      const wifiMessage = 'Connect to Wi-Fi to download this episode.';
      final network = _networkChanges ??
          (Platform.isAndroid ? wifiConnectivityChanges : null);
      void networkChanged(bool connected) {
        if (!connected && _wifiOnly && !token.isCancelled) {
          _errors[episode.id] = wifiMessage;
          token.cancel();
        }
      }

      connectivity = network?.listen(networkChanged,
          onError: (Object _) => networkChanged(false));
      if (_wifiOnly && !await _onWifi()) {
        _errors[episode.id] = wifiMessage;
        token.cancel();
      }
      if (token.isCancelled) return;
      if ((clean.lengthBytes ?? 0) > maximumDownloadBytes) {
        throw const FormatException('The download exceeds the allowed size');
      }
      if (entries.length >= _maximumEntries &&
          !entries.any((entry) => entry.episode.id == episode.id)) {
        throw StateError('The podcast download library is full.');
      }
      finalFile = await _file(episode.id, createDirectory: true);
      partial = File('${finalFile.path}.part');
      // Podcast URLs can serve changed media without changing the URL. Start
      // retries afresh rather than join unvalidated bytes from an older file.
      if (await partial.exists()) await partial.delete();
      client = _injectedClient ??
          (Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 30)))
            ..httpClientAdapter =
                IOHttpClientAdapter(createHttpClient: createPodcastHttpClient));
      var lastUpdate = DateTime(0);
      await downloadResumable(client, episode.mediaUrl, partial.path,
          cancelToken: token,
          identity: sha256.convert(utf8.encode(episode.mediaUrl)).toString(),
          // RSS enclosure lengths can be stale after dynamic ad insertion.
          // The response's byte ranges/Content-Length establish completeness.
          maximumBytes: maximumDownloadBytes, acceptsContentType: (value) {
        final mime = value?.split(';').first.trim().toLowerCase();
        return mime == null ||
            mime.isEmpty ||
            mime.startsWith('audio/') ||
            const {
              'application/octet-stream',
              'binary/octet-stream',
              'application/ogg',
              'application/mp4'
            }.contains(mime);
      }, onProgress: (received, total) {
        final now = DateTime.now();
        if (token.isCancelled ||
            _closed ||
            (received != total &&
                now.difference(lastUpdate).inMilliseconds < 250)) {
          return;
        }
        lastUpdate = now;
        _progress[episode.id] = PodcastDownloadProgress(received, total);
        notifyListeners();
      });
      if (token.isCancelled) return;
      final bytes = await partial.length();
      if (bytes <= 0 || bytes > maximumDownloadBytes) {
        throw const FormatException('Invalid podcast audio size.');
      }
      if (await finalFile.exists()) await finalFile.delete();
      await partial.rename(finalFile.path);
      if (token.isCancelled) return;
      await _save((items) {
        items.removeWhere((item) => item.episode.id == episode.id);
        items.add(PodcastDownload(
            feedId: feed.id,
            feedTitle: feed.title,
            episode: clean,
            bytes: bytes));
      });
      committed = true;
    } catch (error) {
      if (!token.isCancelled) {
        final message = error is FormatException &&
                error.message == 'The download exceeds the allowed size'
            ? 'Episodes larger than 1 GiB cannot be downloaded.'
            : error is FileSystemException
                ? 'Could not save this episode. Check available storage.'
                : 'Could not download this episode. Try again.';
        _errors[episode.id] = message;
        throw StateError(message);
      }
    } finally {
      NetworkProxy.instance.removeBeforeApply(cancelAll);
      await connectivity?.cancel();
      if (_injectedClient == null) client?.close(force: true);
      for (final file in [
        if (partial != null) partial,
        if (partial != null) File('${partial.path}.identity'),
        if (!committed && finalFile != null) finalFile,
      ]) {
        try {
          if (await file.exists()) await file.delete();
        } on FileSystemException {
          // An interrupted cleanup leaves only an unreferenced private file.
        }
      }
      _activeId = null;
      _token = null;
      _activeJob = null;
      _progress.remove(episode.id);
      finished.complete();
      if (!_closed) notifyListeners();
    }
  }

  void cancel(String episodeId) {
    if (_activeId == episodeId) _token?.cancel();
  }

  Future<void> cancelAll() async {
    _token?.cancel();
    await _activeJob;
    await _writes.catchError((_) {});
  }

  Future<void> remove(String episodeId) async {
    if (!_removing.add(episodeId)) return;
    try {
      cancel(episodeId);
      if (_activeId == episodeId) await _activeJob;
      // Remove the record first: interruption cannot leave an absent file
      // advertised as a completed download.
      await _save(
          (items) => items.removeWhere((item) => item.episode.id == episodeId));
      final file = await _file(episodeId);
      for (final owned in [
        file,
        File('${file.path}.part'),
        File('${file.path}.part.identity')
      ]) {
        if (await owned.exists()) await owned.delete();
      }
      _errors.remove(episodeId);
    } finally {
      _removing.remove(episodeId);
      if (!_closed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _token?.cancel();
    NetworkProxy.instance.removeBeforeApply(cancelAll);
    super.dispose();
  }
}
