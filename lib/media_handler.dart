import 'dart:async';
import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:audio_service/audio_service.dart';
import 'package:clipious/music/services/music_media_controls.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/app_languages.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/on_device_music_entry.dart';
import 'package:clipious/music/services/android_auto_music.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/on_device_music_downloads.dart';
import 'package:clipious/player/states/player.dart';

typedef CarQueueRow = ({String occurrence, MediaItem item});

class MediaHandler extends BaseAudioHandler with SeekHandler {
  final PlayerCubit controller;
  static const _carChannel = MethodChannel('videre/car_media');
  static const _systemRecentRoot = 'system-resume-recent';
  Future<void>? _androidResume;

  static Future<bool> hasMediaActivity() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      return await _carChannel.invokeMethod<bool>('hasMediaActivity') ?? true;
    } on MissingPluginException {
      return true;
    }
  }

  static final _log = Logger('MediaHandler');
  static const _firstCarId = 1000000000;
  static int _nextCarId = _firstCarId;
  static const _queueBrowsePrefix = 'car-queue-browse:';
  static const _queueBrowseRoot = '${_queueBrowsePrefix}root';
  late final _queueBrowseRowPrefix = '$_queueBrowsePrefix${const Uuid().v4()}:';
  Object? _browseSession;
  Object? _carQueueOwner;
  List<CarQueueRow> _carRows = const [];
  Map<String, int> _carIds = const {};
  bool _carQueueReady = false;
  int _carQueueRevision = 0;
  bool _queueBrowseUsed = false;
  String? _queueBrowseCurrent;
  bool? _browseAddOnDevice;
  Future<void> _carQueueMutations = Future.value();

  late final carMusic = AndroidAutoMusic(
    session: () => controller.androidAutoSession,
    database: () => db,
    catalog: musicCatalogService,
    loadPlaylists: (database) => service.getLocalPlaylists(database: database),
    loadDevice: _loadDevice,
    playVideos: controller.playAndroidAutoMusic,
    playDevice: (entries, index, title, current) =>
        controller.playOnDeviceMusic(entries,
            startIndex: index, queueTitle: title, isCurrent: current),
    labels: _labels,
  );

  MediaHandler(this.controller) {
    controller.attachMediaHandler(this);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _carChannel.setMethodCallHandler(_handleCarCall);
    }
  }

  AppLocalizations _labels() {
    final saved = parseSavedLocale(controller.settings.state.locale);
    final locale = saved ?? PlatformDispatcher.instance.locale;
    return lookupAppLocalizations(
      AppLocalizations.delegate.isSupported(locale)
          ? locale
          : const Locale('en'),
    );
  }

  Future<List<OnDeviceMusicEntry>> _loadDevice() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return [];
    final scope = controller.androidAutoSession;
    bool current() => scope != null && controller.androidAutoSession == scope;
    if (!current()) return [];
    final profile = db.profileId;
    final owner = db.forProfile(profile);
    final library = LocalMusicLibrary.instance;
    final downloads = OnDeviceMusicDownloads();
    try {
      await library.initialize();
      if (!current()) return [];
      await library.revalidate();
      if (!current()) return [];
      if (library.enabled && !library.unavailable && !library.loaded) {
        await library.refresh();
      }
      if (!current()) return [];
      await downloads.refresh(library, profile, owner.getAllDownloads(),
          isCurrent: current);
      if (!current()) return [];
      return [
        for (final entry in downloads.entries(library, profile))
          if (entry.deviceTrack == null ||
              (library.enabled && !library.unavailable))
            entry,
      ];
    } on Exception catch (error) {
      _log.fine('Could not read car media files (${error.runtimeType})');
      return [];
    } finally {
      downloads.dispose();
    }
  }

  void refreshCarBrowser({bool force = false}) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final current = controller.androidAutoSession;
    if (!force && current == _browseSession) return;
    if (current == null ||
        (_browseSession != null && _browseSession != current)) {
      clearCarQueue();
    }
    _browseSession = current;
    final parents = carMusic.loadedParents;
    carMusic.invalidate();
    for (final parent in parents) {
      unawaited(_refreshCarParent(parent));
    }
  }

  Future<void> _refreshCarParent(String parent) async {
    try {
      await _carChannel.invokeMethod<void>('notifyChildrenChanged', parent);
    } on MissingPluginException {
      // The bridge is Android-only and may be absent in a test engine.
    } on PlatformException catch (error) {
      _log.fine('Could not refresh the car media browser (${error.code})');
    }
  }

  Future<Object?> _handleCarCall(MethodCall call) async {
    switch (call.method) {
      case 'getQueueBrowseChildren':
        _beginQueueBrowse();
        return _getQueueBrowseChildren(call.arguments as String);
      case 'getQueueBrowseItem':
        _beginQueueBrowse();
        final id = call.arguments as String;
        final row = _findCarRow(id);
        if (row != null) {
          final actions = controller.androidAutoQueueActions([row.occurrence]);
          return _encodeCarRow(_browseQueueRow(row),
              queueActions: actions[row.occurrence] ?? const {});
        }
        final item = switch (id) {
          _queueBrowseRoot => _currentCarRows.isEmpty ? null : _queueFolder,
          _ => await carMusic.getMediaItem(id),
        };
        return item == null ? null : _encodeCarRow(item);
      case 'searchQueueBrowse':
        _beginQueueBrowse();
        final rows = await carMusic.search(call.arguments as String);
        return rows.map(_encodeCarRow).toList();
      case 'mutateMusicQueue':
        final args = call.arguments as Map;
        final action = AndroidAutoQueueAction.values
            .where((value) => value.name == args['action'])
            .firstOrNull;
        final id = args['mediaId'];
        return action != null && id is String
            ? _mutateCarQueue(action, id)
            : false;
      default:
        throw MissingPluginException();
    }
  }

  void _beginQueueBrowse() {
    if (_queueBrowseUsed) return;
    _queueBrowseUsed = true;
    _browseAddOnDevice = _canAddOnDevice;
  }

  List<CarQueueRow> get _currentCarRows => _carQueueOwner != null &&
          _carQueueOwner == controller.androidAutoQueueOwner
      ? _carRows
      : const [];

  MediaItem get _queueFolder => MediaItem(
        id: _queueBrowseRoot,
        title: _labels().musicQueue,
        playable: false,
      );

  MediaItem _browseQueueRow(CarQueueRow row) =>
      row.item.copyWith(id: '$_queueBrowseRowPrefix${_carIds[row.occurrence]}');

  CarQueueRow? _findCarRow(String id) {
    if (!id.startsWith(_queueBrowseRowPrefix)) return null;
    final number = int.tryParse(id.substring(_queueBrowseRowPrefix.length));
    if (number == null) return null;
    return _currentCarRows
        .where((row) => _carIds[row.occurrence] == number)
        .firstOrNull;
  }

  Future<List<Map<String, Object?>>> _getQueueBrowseChildren(
    String parent,
  ) async {
    if (parent == _queueBrowseRoot) {
      final rows = _currentCarRows;
      final actions =
          controller.androidAutoQueueActions(rows.map((row) => row.occurrence));
      return [
        for (final row in rows)
          _encodeCarRow(_browseQueueRow(row),
              queueActions: actions[row.occurrence] ?? const {}),
      ];
    }
    final children = await carMusic.getChildren(parent);
    return [
      for (final child in children) _encodeCarRow(child),
      if (parent == AudioService.browsableRootId && _currentCarRows.isNotEmpty)
        _encodeCarRow(_queueFolder),
    ];
  }

  bool? get _canAddOnDevice => controller.androidAutoEditableQueue == null
      ? null
      : controller.state.videos.isEmpty;

  Map<String, Object?> _encodeCarRow(MediaItem item,
      {Set<AndroidAutoQueueAction>? queueActions}) {
    final device =
        queueActions == null ? carMusic.isOnDeviceSong(item.id) : null;
    final actions = queueActions ??
        {
          if (device != null && _canAddOnDevice == device)
            AndroidAutoQueueAction.addToQueue,
        };
    return {
      'id': item.id,
      'title': item.title,
      'artist': item.artist,
      'album': item.album,
      'durationMs': item.duration?.inMilliseconds,
      'playable': item.playable != false,
      'actions': actions.map((action) => action.name).toList(),
    };
  }

  Future<bool> _mutateCarQueue(AndroidAutoQueueAction action, String id) {
    final owner = controller.androidAutoEditableQueue;
    final occurrence = _findCarRow(id)?.occurrence;
    final onDevice = carMusic.isOnDeviceSong(id);
    if (owner == null ||
        (action == AndroidAutoQueueAction.addToQueue
            ? onDevice == null || onDevice != _canAddOnDevice
            : occurrence == null)) {
      return Future.value(false);
    }
    final edit = _carQueueMutations.then((_) async {
      if (controller.androidAutoEditableQueue != owner) return false;
      if (action != AndroidAutoQueueAction.addToQueue) {
        if (_findCarRow(id)?.occurrence != occurrence) return false;
        return controller.editAndroidAutoQueue(owner, occurrence!, action);
      }
      final song = await carMusic.resolveQueueSong(id);
      if (song == null) return false;
      return controller.addToAndroidAutoQueue(
        owner,
        video: song.video,
        device: song.device,
      );
    });
    // A failed source lookup must not prevent subsequent car requests.
    _carQueueMutations = edit.then<void>(
      (_) {},
      onError: (Object error) {
        _log.fine('Could not edit the car media queue (${error.runtimeType})');
      },
    );
    return edit;
  }

  void refreshCarQueueBrowseActions() {
    if (!_queueBrowseUsed) return;
    final add = _canAddOnDevice;
    if (add != _browseAddOnDevice) {
      _browseAddOnDevice = add;
      for (final parent in carMusic.loadedParents) {
        unawaited(_refreshCarParent(parent));
      }
    }
    unawaited(_refreshCarParent(_queueBrowseRoot));
  }

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId,
      [Map<String, dynamic>? options]) async {
    if (parentMediaId != _systemRecentRoot) {
      return carMusic.getChildren(parentMediaId);
    }
    final recent = await controller.androidRecentMusic();
    return recent == null ? [] : [recent];
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) =>
      carMusic.getMediaItem(mediaId);

  @override
  Future<List<MediaItem>> search(String query,
          [Map<String, dynamic>? extras]) =>
      carMusic.search(query, extras);

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    final row = _findCarRow(mediaId);
    if (row != null) {
      await controller.selectQueueOccurrence(row.occurrence);
    } else {
      await carMusic.playFromMediaId(mediaId);
    }
  }

  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) =>
      carMusic.playFromSearch(query, extras);

  @override
  Future<void> playMediaItem(MediaItem mediaItem) =>
      playFromMediaId(mediaItem.id);

  void publishCarQueue(Object? owner, List<CarQueueRow> rows, String title,
      {String? current}) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final sameOwner = owner == _carQueueOwner;
    final sameRows = sameOwner && listEquals(rows, _carRows);
    final visibilityChanged = rows.isEmpty != _carRows.isEmpty;
    final activeChanged = current != _queueBrowseCurrent;
    _queueBrowseCurrent = current;
    if (_queueBrowseUsed && (!sameRows || activeChanged)) {
      scheduleMicrotask(() {
        if (visibilityChanged) {
          unawaited(_refreshCarParent(AudioService.browsableRootId));
        }
        refreshCarQueueBrowseActions();
      });
    }
    if ((sameRows && _carQueueReady) || (rows.isEmpty && _carRows.isEmpty)) {
      return;
    }
    final previous = sameOwner ? _carIds : const <String, int>{};
    _carQueueOwner = owner;
    _carRows = rows;
    _carIds = {
      for (final row in rows)
        row.occurrence: previous[row.occurrence] ?? _nextCarId++,
    };
    _carQueueReady = false;
    if (title != queueTitle.value) queueTitle.add(title);
    unawaited(_publishNativeCarQueue(++_carQueueRevision));
  }

  void clearCarQueue() => publishCarQueue(null, const [], '');

  Future<void> _publishNativeCarQueue(int revision) async {
    try {
      final published = await _carChannel.invokeMethod<bool>('setMusicQueue', [
        for (final row in _carRows)
          {
            'id': _carIds[row.occurrence],
            'mediaId': row.item.id,
            'title': row.item.title,
            'artist': row.item.artist,
            'album': row.item.album,
          },
      ]);
      if (revision != _carQueueRevision || published != true) return;
      _carQueueReady = true;
      final active = carQueueItemId(controller.state.currentQueueId);
      if (active != null && controller.androidAutoSession != null) {
        final state = playbackState.value;
        playbackState.add(state.copyWith(
          queueIndex: active,
          systemActions: {...state.systemActions, MediaAction.skipToQueueItem},
        ));
      }
    } on MissingPluginException {
      // The bridge can be absent in a test engine.
    } on PlatformException catch (error) {
      _log.fine('Could not publish the car media queue (${error.code})');
    }
  }

  int? carQueueItemId(String? occurrence) =>
      _carQueueReady ? _carIds[occurrence] : null;

  /// Retire the previous person's native session without the closing animation.
  Future<void> clearSession() async {
    refreshCarBrowser(force: true);
    playbackState.add(PlaybackState());
    clearCarQueue();
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
    if (controller.ownsAudioDecoder && controller.state.isClosing) return;
    final podcast = controller.activePodcast;
    if (podcast != null) {
      await podcast.resume();
    } else if (!controller.ownsAudioDecoder ||
        controller.state.hasVideo ||
        !controller.state.isHidden) {
      controller.play();
    } else {
      await (_androidResume ??= _resumeAndroidMusic().whenComplete(() {
        _androidResume = null;
      }));
    }
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    // The legacy callback combines play, pause, toggle and headset commands.
    // Native cold Play is dispatched separately after checking the raw key.
    if (!controller.ownsAudioDecoder ||
        controller.state.hasVideo ||
        !controller.state.isHidden ||
        controller.activePodcast != null) {
      await super.click(button);
    }
  }

  Future<void> _resumeAndroidMusic() async {
    PlaybackState? provisional;
    final restored = await controller.resumeMusicFromAndroid(() async {
      final loading = PlaybackState(
        controls: [MediaControl.pause, MediaControl.stop],
        processingState: AudioProcessingState.loading,
        playing: true,
      );
      provisional = loading;
      playbackState.add(loading);
      try {
        return await _carChannel.invokeMethod<bool>('awaitResumeForeground') ??
            false;
      } on PlatformException catch (error) {
        _log.fine('Android could not start media foreground (${error.code})');
        return false;
      } on MissingPluginException {
        return false;
      }
    });
    if (!restored &&
        provisional != null &&
        identical(playbackState.value, provisional)) {
      // The failed request has no decoder to publish idle on its behalf.
      await clearSession();
    }
  }

  @override
  Future<void> pause() async {
    final podcast = controller.activePodcast;
    if (podcast != null) {
      await podcast.pause();
    } else {
      if (_androidResume != null) {
        controller.cancelPendingAndroidMusicResumption();
      }
      controller.pause();
    }
  }

  @override
  Future<void> stop() async {
    final podcast = controller.activePodcast;
    if (podcast != null) {
      await podcast.stop();
    } else {
      await controller.stopFromAndroidTransport();
    }
  }

  @override
  Future<void> onTaskRemoved() => PlayerCubit.stopForTaskRemoval(this);

  @override
  Future<dynamic> customAction(String name,
      [Map<String, dynamic>? extras]) async {
    if (isMusicMediaAction(name)) {
      await PlayerCubit.dispatchMusicMediaAction(this, name);
      return;
    }
    return super.customAction(name, extras);
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
    if (controller.activePodcast != null) return;
    if (index < _firstCarId) {
      if (_carRows.isEmpty || !_carQueueReady) {
        await controller.skipToVideo(index);
      }
      return;
    }
    if (!_carQueueReady || controller.androidAutoSession == null) return;
    for (final entry in _carIds.entries) {
      if (entry.value == index) {
        await controller.selectQueueOccurrence(entry.key);
        return;
      }
    }
  }

  @override
  Future<void> setSpeed(double speed) async {
    final podcast = controller.activePodcast;
    if (podcast != null) await podcast.setSpeed(speed);
  }
}
