import 'dart:async';
import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:audio_service/audio_service.dart';
import 'package:clipious/music/services/music_media_save.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
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
  static final _log = Logger('MediaHandler');
  static const _firstCarId = 1000000000;
  static int _nextCarId = _firstCarId;
  Object? _browseSession;
  Object? _carQueueOwner;
  List<CarQueueRow> _carRows = const [];
  Map<String, int> _carIds = const {};
  bool _carQueueReady = false;
  int _carQueueRevision = 0;

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
    labels: () {
      final saved = parseSavedLocale(controller.settings.state.locale);
      final locale = saved ?? PlatformDispatcher.instance.locale;
      return lookupAppLocalizations(
          AppLocalizations.delegate.isSupported(locale)
              ? locale
              : const Locale('en'));
    },
  );

  MediaHandler(this.controller) {
    controller.attachMediaHandler(this);
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

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId,
          [Map<String, dynamic>? options]) =>
      carMusic.getChildren(parentMediaId);

  @override
  Future<MediaItem?> getMediaItem(String mediaId) =>
      carMusic.getMediaItem(mediaId);

  @override
  Future<List<MediaItem>> search(String query,
          [Map<String, dynamic>? extras]) =>
      carMusic.search(query, extras);

  @override
  Future<void> playFromMediaId(String mediaId,
          [Map<String, dynamic>? extras]) =>
      carMusic.playFromMediaId(mediaId);

  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) =>
      carMusic.playFromSearch(query, extras);

  @override
  Future<void> playMediaItem(MediaItem mediaItem) =>
      playFromMediaId(mediaItem.id);

  void publishCarQueue(Object? owner, List<CarQueueRow> rows, String title) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final sameOwner = owner == _carQueueOwner;
    if (sameOwner && listEquals(rows, _carRows) && _carQueueReady) return;
    if (rows.isEmpty && _carRows.isEmpty) return;
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
    // All 'play' requests from all origins route to here. Implement this
    // callback to start playing audio appropriate to your app. e.g. music
    final podcast = controller.activePodcast;
    if (podcast != null) {
      await podcast.resume();
    } else {
      controller.play();
    }
  }

  @override
  Future<void> pause() async {
    final podcast = controller.activePodcast;
    if (podcast != null) {
      await podcast.pause();
    } else {
      controller.pause();
    }
  }

  @override
  Future<void> stop() async {
    final podcast = controller.activePodcast;
    if (podcast != null) {
      await podcast.stop();
    } else {
      controller.hide();
    }
  }

  @override
  Future<void> onTaskRemoved() => PlayerCubit.stopForTaskRemoval(this);

  @override
  Future<dynamic> customAction(String name,
      [Map<String, dynamic>? extras]) async {
    if (name.startsWith(musicMediaSaveActionPrefix)) {
      PlayerCubit.requestMediaPlaylistSave(this, name);
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
