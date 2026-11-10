import 'dart:convert';
import '../home/models/phone_navigation.dart';
import '../music/models/music_library_entry.dart';

import '../offline_subscriptions/models/offline_subscription.dart';
import '../playlists/models/playlist.dart';
import '../playlists/models/playlist_reference.dart';
import '../playlists/models/saved_playlist.dart';
import '../settings/models/db/settings.dart';
import '../settings/models/db/video_filter.dart';
import '../videos/models/db/history_video_cache.dart';
import '../videos/models/db/progress.dart';
import '../videos/models/music_metadata.dart';
import '../videos/models/video.dart';
import '../videos/models/sponsor_segment_types.dart';
import 'invidious_image.dart';
import 'models/image_object.dart';

/// A portable library, without logins, download paths, or expiring media URLs.
class UserBackup {
  final Map<String, List<Map<String, dynamic>>> sections;
  final bool subscriptionsOnly;

  UserBackup._(this.sections, {this.subscriptionsOnly = false});

  static const maxBytes = 10 * 1024 * 1024;
  static final _videoId = RegExp(r'^[a-zA-Z0-9_-]{11}$');
  static final _channelId = RegExp(r'^UC[a-zA-Z0-9_-]{22}$');
  static final _relativeImageRoute =
      RegExp(r'^/?(?:vi|vi_webp|s_p|pl_c|tvfilm_banner|ggpht|sb)/');
  static final _ambiguousImagePath =
      RegExp(r'%2e|%2f|%5c|%25|\\|(?:^|/)\.\.?(?:/|$)', caseSensitive: false);
  static const sectionNames = [
    'settings',
    'subscriptions',
    'filters',
    'progress',
    'history',
    'playlists',
    'watchState',
    'savedPlaylists'
  ];

  String encode() => jsonEncode({
        'format': 'videre',
        'version': 1,
        ...sections,
      });

  int get itemCount =>
      sections.values.fold(0, (sum, rows) => sum + rows.length);

  factory UserBackup.parse(String text) {
    if (utf8.encode(text).length > maxBytes) {
      throw const FormatException('The file is larger than 10 MiB.');
    }
    try {
      final data = jsonDecode(text) as Map<String, dynamic>;
      if (data['format'] != 'videre') return UserBackup._newPipe(data);
      if (data['version'] != 1) {
        throw const FormatException('This backup version is not supported.');
      }
      final sections = <String, List<Map<String, dynamic>>>{};
      for (final name in sectionNames) {
        // These additions remain optional in existing version 1 libraries.
        final rows = (const ['watchState', 'savedPlaylists'].contains(name)
            ? data[name] ?? []
            : data[name]) as List;
        if (rows.length > 50000) {
          throw const FormatException('Too many entries.');
        }
        sections[name] = rows.map((row) {
          final value = Map<String, dynamic>.from(row as Map);
          switch (name) {
            case 'savedPlaylists':
              final saved = SavedPlaylist.tryParse({
                ...value,
                'reference': {
                  'kind': PlaylistSourceKind.public.name,
                  'playlistId': value['playlistId'],
                  'profileId': 'portable',
                },
              });
              if (saved == null ||
                  saved.reference.playlistId.startsWith('IVP') ||
                  saved.reference.playlistId.startsWith('local:')) {
                throw const FormatException('Invalid saved playlist.');
              }
              return portablePlaylist(saved);
            case 'watchState':
              final videoId = value['videoId'];
              final manual = value['manualWatched'];
              if (videoId is! String ||
                  !_videoId.hasMatch(videoId) ||
                  (manual != null && manual is! bool) ||
                  value['localPlayback'] is! bool ||
                  value['completed'] is! bool) {
                throw const FormatException('Invalid watched state.');
              }
              // Account observations, credentials, pending operations and
              // session revisions never travel with a portable library.
              return {
                'videoId': videoId,
                'manualWatched': manual,
                'localPlayback': value['localPlayback'],
                'completed': value['completed'],
              };
            case 'settings':
              final setting = SettingsValue.fromJson(value);
              if (!validSetting(setting)) {
                throw FormatException('Unsupported setting: ${setting.name}');
              }
              return setting.toJson();
            case 'subscriptions':
              final sub = OfflineSubscription.fromJson(value);
              if (!_channelId.hasMatch(sub.channelId) ||
                  sub.channelName.length > 1000) {
                throw const FormatException('Invalid subscription.');
              }
              return sub.toJson();
            case 'progress':
              for (final field in ['positionSeconds', 'durationSeconds']) {
                final seconds = value[field];
                if (seconds != null &&
                    (seconds is! int ||
                        seconds < 0 ||
                        seconds > maximumPlaybackSeconds)) {
                  throw const FormatException('Invalid playback position.');
                }
              }
              final progress = Progress.fromJson(value);
              if (!_videoId.hasMatch(progress.videoId) ||
                  !progress.progress.isFinite ||
                  progress.progress < 0 ||
                  progress.progress > 1) {
                throw const FormatException('Invalid playback progress.');
              }
              return progress.toJson();
            case 'history':
              final video = HistoryVideoCache.fromJson(value);
              if (!_videoId.hasMatch(video.videoId) ||
                  video.title.length > 1000) {
                throw const FormatException('Invalid history entry.');
              }
              video.thumbnail =
                  _safeThumbnailUrl(video.thumbnail, videoArtwork: true) ?? '';
              video.musicMetadata = _safeMusicMetadata(video.musicMetadata);
              return video.toJson();
            case 'filters':
              final filter = VideoFilter.fromJson(value);
              final id = value['uuid'] as String;
              if (id.isEmpty ||
                  id.length > 100 ||
                  (filter.value?.length ?? 0) > 1000 ||
                  filter.daysOfWeek.any((day) => day < 1 || day > 7) ||
                  !RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d$')
                      .hasMatch(filter.startTime) ||
                  !RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d$')
                      .hasMatch(filter.endTime)) {
                throw const FormatException('Invalid filter.');
              }
              if (filter.type == FilterType.length) {
                if (int.tryParse(filter.value ?? '0') == null) {
                  throw const FormatException('Invalid numeric filter.');
                }
              } else {
                RegExp(filter.value ?? '', caseSensitive: false);
              }
              return {...filter.toJson(), 'uuid': id};
            case 'playlists':
              final playlist = Playlist.fromJson(value);
              if (!playlist.playlistId.startsWith('local:') ||
                  playlist.playlistId.length > 100 ||
                  playlist.title.trim().isEmpty ||
                  playlist.videos.length > 10000) {
                throw const FormatException('Invalid local playlist.');
              }
              final videos = playlist.videos.map((video) {
                if (!_videoId.hasMatch(video.videoId)) {
                  throw const FormatException('Invalid playlist video.');
                }
                return Video(
                    videoId: video.videoId,
                    indexId: video.videoId,
                    title: video.title,
                    author: video.author,
                    authorId: video.authorId,
                    authorUrl:
                        _safeHttpUrl(video.authorUrl) ? video.authorUrl : null,
                    videoThumbnails: _safeThumbnails(video.videoThumbnails,
                        videoArtwork: true),
                    musicMetadata: _safeMusicMetadata(video.musicMetadata),
                    lengthSeconds: video.lengthSeconds);
              }).toList();
              final clean = Playlist(
                  playlistId: playlist.playlistId,
                  title: playlist.title,
                  type: 'local',
                  author: '',
                  videos: videos,
                  videoCount: videos.length);
              return {
                ...clean.toJson(),
                'videos': videos.map((video) => video.toJson()).toList()
              };
          }
          throw const FormatException('Unknown backup section.');
        }).toList();
      }
      return UserBackup._(sections);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException(
          'Choose a Videre backup or NewPipe subscriptions JSON file.');
    }
  }

  factory UserBackup._newPipe(Map<String, dynamic> data) {
    final rows = data['subscriptions'] as List;
    if (rows.isEmpty || rows.length > 50000) {
      throw const FormatException(
          'The subscription list is empty or too large.');
    }
    final subscriptions = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final uri = Uri.parse(row['url'] as String);
      if (row['service_id'] != 0 ||
          !['https', 'http'].contains(uri.scheme) ||
          !['www.youtube.com', 'youtube.com', 'm.youtube.com']
              .contains(uri.host) ||
          uri.userInfo.isNotEmpty ||
          uri.pathSegments.length != 2 ||
          uri.pathSegments.first != 'channel' ||
          !_channelId.hasMatch(uri.pathSegments.last)) {
        throw const FormatException(
            'Only YouTube channel subscriptions are supported.');
      }
      final name = row['name'] as String;
      if (name.length > 1000) {
        throw const FormatException('Invalid channel name.');
      }
      final sub = OfflineSubscription(
          channelId: uri.pathSegments.last, channelName: name);
      subscriptions[sub.channelId] = sub.toJson();
    }
    return UserBackup._({
      for (final name in sectionNames)
        name: name == 'subscriptions' ? subscriptions.values.toList() : []
    }, subscriptionsOnly: true);
  }

  static MusicMetadata? _safeMusicMetadata(MusicMetadata? music) =>
      music == null
          ? null
          : MusicMetadata(
              title: music.title,
              artist: music.artist,
              album: music.album,
              thumbnails: _safeThumbnails(music.thumbnails));

  /// Account access and profile ownership are never part of a portable save.
  static Map<String, dynamic> portablePlaylist(SavedPlaylist playlist) {
    final value = playlist.toJson()..remove('reference');
    return {'playlistId': playlist.reference.playlistId, ...value};
  }

  static List<ImageObject> _safeThumbnails(List<ImageObject> thumbnails,
          {bool videoArtwork = false}) =>
      [
        for (final image in thumbnails)
          if (_safeThumbnailUrl(image.url, videoArtwork: videoArtwork)
              case final url?)
            ImageObject(image.quality, url, image.width, image.height),
      ];

  static String? _safeThumbnailUrl(String value, {required bool videoArtwork}) {
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    if (_safeHttpUri(uri)) {
      // Catalog metadata may contain signed query parameters. Use only the
      // public display path, as the Music bookmark sanitizer does.
      return videoArtwork ? value : uri.toString().split(RegExp(r'[?#]')).first;
    }
    if (!videoArtwork || uri.hasAuthority || uri.hasScheme) return null;
    final path = uri.path;
    // Relative URLs will be requested from the destination's selected server.
    // Only known image routes may resolve there after import.
    return _relativeImageRoute.hasMatch(path) &&
            !_ambiguousImagePath.hasMatch(path) &&
            isInvidiousThumbnailUrl(path)
        ? path
        : null;
  }

  static bool _safeHttpUrl(String? value) {
    final uri = value == null ? null : Uri.tryParse(value);
    return uri != null && _safeHttpUri(uri);
  }

  static bool _safeHttpUri(Uri uri) =>
      const {'http', 'https'}.contains(uri.scheme) &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;

  static bool validSetting(SettingsValue setting) {
    final name = setting.name, value = setting.value;
    if (name == 'music-library-v1') return _validMusicLibrary(value);
    if (value.length > 2048) return false;
    const booleans = {
      dynamicTheme,
      useDashSettingName,
      playerShuffle,
      playerAutoplayOnLoad,
      playerAutoplayQueue,
      playRecommendedNextSettingName,
      useProxySettingName,
      useReturnYoutubeDislikeSettingName,
      blackBackgroundSettingName,
      rememberLastSubtitle,
      remeberPlaybackSpeed,
      rememberVideoQualitySettingName,
      lockOrientationFullScreen,
      fillFullScreen,
      useSearchHistorySettingName,
      skipExponentialSettingName,
      distractionFreeModeSettingName,
      hideWatchedSubscriptionsSettingName,
      subtitleBackground,
      dearrowSettingName,
      dearrowThumbnailsSettingName,
      fullScreenOnLandscapeSettingName,
      screenControlsSettingName,
      'downloads-wifi-only',
    };
    if (booleans.contains(name)) return value == 'true' || value == 'false';
    if (SponsorSegmentType.values.any((type) => type.settingsName() == name)) {
      return value == 'true' || value == 'false';
    }
    const ranges = {
      onOpenSettingName: (0, 10),
      playerRepeat: (0, 2),
      searchHistoryLimitSettingName: (1, 100000),
      skipStepSettingName: (1, 600),
      lastVideoQualitySettingName: (0, 16384),
    };
    if (ranges.containsKey(name)) {
      final number = int.tryParse(value), range = ranges[name]!;
      return number != null && number >= range.$1 && number <= range.$2;
    }
    if (name == lastSpeedSettingName || name == subtitleSizeSettingName) {
      final number = double.tryParse(value);
      return number != null &&
          number.isFinite &&
          number > 0 &&
          number <= (name == lastSpeedSettingName ? 10 : 200);
    }
    return switch (name) {
      'home-content-mode' => const ['videos', 'music'].contains(value),
      'home-experience' =>
        const ['videosAndMusic', 'videosOnly', 'musicOnly'].contains(value),
      phoneNavigationSettingName => PhoneNavigation.decode(value) != null,
      browsingCountry => RegExp(r'^[A-Z]{2}$').hasMatch(value),
      localeSettingName =>
        RegExp(r'^[a-z]{2,3}(?:[_-][A-Za-z0-9]{2,8})*$').hasMatch(value),
      lastSubtitle => value.length < 128,
      themeModeSettingName => ['system', 'light', 'dark'].contains(value),
      motionPreferenceSettingName =>
        ['system', 'reduced', 'off'].contains(value),
      navigationBarLabelBehaviorSettingName =>
        ['alwaysShow', 'alwaysHide', 'onlyShowSelected'].contains(value),
      tvAppLayoutSettingName => value.isEmpty ||
          (value.split(',').toSet().length == value.split(',').length &&
              value.split(',').every((item) => const {
                    'popular',
                    'trending',
                    'subscription',
                    'history',
                    'playlist',
                    'search'
                  }.contains(item))),
      appLayoutSettingName =>
        value.split(',').toSet().length == value.split(',').length &&
            value.split(',').every((item) => const {
                  'home',
                  'popular',
                  'trending',
                  'subscription',
                  'history',
                  'playlist',
                  'downloads',
                  'searchHistory',
                  'search'
                }.contains(item)),
      _ => false,
    };
  }

  /// Merge collection data stored in a preference row without discarding saved
  /// items as though the entire library were a single ordinary preference.
  static String mergeMusicLibrary(String existing, String incoming) {
    if (!_validMusicLibrary(existing) || !_validMusicLibrary(incoming)) {
      throw const FormatException('The Music library cannot be merged.');
    }
    final entries = <String, dynamic>{};
    final playlists = <String>{};
    for (final value in [existing, incoming]) {
      final data = jsonDecode(value) as Map<String, dynamic>;
      for (final row in data['entries'] as List) {
        // Existing metadata and ordering win when the same bookmark is in both
        // libraries; different kinds may legitimately share a catalog ID.
        entries.putIfAbsent('${row['kind']}:${row['id']}', () => row);
      }
      playlists.addAll((data['playlists'] as List).cast<String>());
    }
    final merged = jsonEncode({
      'version': 1,
      'entries': entries.values.toList(),
      'playlists': playlists.toList(),
    });
    if (!_validMusicLibrary(merged)) {
      throw const FormatException(
          'The combined Music library exceeds its size or item limit.');
    }
    return merged;
  }

  /// Music bookmarks can exceed ordinary preference sizes. Keep their own
  /// bound below the complete backup limit, and accept only canonical display
  /// metadata produced by the library sanitizer. Unknown fields never travel.
  static bool _validMusicLibrary(String value) {
    if (value.length > musicLibraryMaximumBytes ||
        utf8.encode(value).length > musicLibraryMaximumBytes) {
      return false;
    }
    try {
      final data = jsonDecode(value);
      if (data is! Map ||
          data.length != 3 ||
          data['version'] is! int ||
          data['version'] != 1 ||
          data['entries'] is! List ||
          data['playlists'] is! List) {
        return false;
      }
      final entries = data['entries'] as List;
      final playlists = data['playlists'] as List;
      if (entries.length > musicLibraryMaximumEntries ||
          playlists.length > musicLibraryMaximumEntries) {
        return false;
      }
      final identities = <String>{};
      for (final row in entries) {
        if (row is! Map) return false;
        final entry = MusicLibraryEntry.tryParse(row);
        if (entry == null) return false;
        final canonical = entry.toJson();
        // Older v1 backups omitted the artwork source marker. Keep the
        // canonical check for every other field in the row.
        if (!row.containsKey('usesVideoThumbnails')) {
          canonical.remove('usesVideoThumbnails');
        }
        if (!_sameJson(row, canonical) ||
            !identities.add('${entry.kind.name}:${entry.id}')) {
          return false;
        }
      }
      final localIds = <String>{};
      final localId = RegExp(r'^local:[A-Za-z0-9_-]{1,128}$');
      for (final id in playlists) {
        if (id is! String ||
            localId.stringMatch(id) != id ||
            !localIds.add(id)) {
          return false;
        }
      }
      return true;
    } on FormatException {
      return false;
    }
  }

  static bool _sameJson(Object? left, Object? right) {
    if (left is Map && right is Map) {
      return left.length == right.length &&
          left.keys.every((key) =>
              right.containsKey(key) && _sameJson(left[key], right[key]));
    }
    if (left is List && right is List) {
      return left.length == right.length &&
          Iterable.generate(left.length)
              .every((index) => _sameJson(left[index], right[index]));
    }
    // JSON numeric equality treats 0.0 and 0 as equal in Dart. The bookmark
    // schema uses integers, so do not let malformed dimensions pass as zero.
    if (left is num || right is num) {
      return left is int && right is int && left == right;
    }
    return left == right;
  }
}
