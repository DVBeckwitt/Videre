import 'dart:convert';

import '../offline_subscriptions/models/offline_subscription.dart';
import '../playlists/models/playlist.dart';
import '../settings/models/db/settings.dart';
import '../settings/models/db/video_filter.dart';
import '../videos/models/db/history_video_cache.dart';
import '../videos/models/db/progress.dart';
import '../videos/models/video.dart';
import '../videos/models/sponsor_segment_types.dart';

/// A portable library, without logins, download paths, or expiring media URLs.
class UserBackup {
  final Map<String, List<Map<String, dynamic>>> sections;
  final bool subscriptionsOnly;

  UserBackup._(this.sections, {this.subscriptionsOnly = false});

  static const maxBytes = 10 * 1024 * 1024;
  static final _videoId = RegExp(r'^[a-zA-Z0-9_-]{11}$');
  static final _channelId = RegExp(r'^UC[a-zA-Z0-9_-]{22}$');
  static const sectionNames = [
    'settings',
    'subscriptions',
    'filters',
    'progress',
    'history',
    'playlists'
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
        final rows = data[name] as List;
        if (rows.length > 50000)
          throw const FormatException('Too many entries.');
        sections[name] = rows.map((row) {
          final value = Map<String, dynamic>.from(row as Map);
          switch (name) {
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
              if (!_safeHttpUrl(video.thumbnail)) video.thumbnail = '';
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
                    videoThumbnails: video.videoThumbnails
                        .where((thumbnail) => _safeHttpUrl(thumbnail.url))
                        .toList(),
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
      if (name.length > 1000)
        throw const FormatException('Invalid channel name.');
      final sub = OfflineSubscription(
          channelId: uri.pathSegments.last, channelName: name);
      subscriptions[sub.channelId] = sub.toJson();
    }
    return UserBackup._({
      for (final name in sectionNames)
        name: name == 'subscriptions' ? subscriptions.values.toList() : []
    }, subscriptionsOnly: true);
  }

  static bool _safeHttpUrl(String? value) {
    final uri = value == null ? null : Uri.tryParse(value);
    return uri != null &&
        ['http', 'https'].contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  static bool validSetting(SettingsValue setting) {
    final name = setting.name, value = setting.value;
    if (value.length > 2048) return false;
    const booleans = {
      dynamicTheme,
      useDashSettingName,
      playerShuffle,
      playerAutoplayOnLoad,
      playRecommendedNextSettingName,
      useProxySettingName,
      useReturnYoutubeDislikeSettingName,
      blackBackgroundSettingName,
      rememberLastSubtitle,
      remeberPlaybackSpeed,
      lockOrientationFullScreen,
      fillFullScreen,
      useSearchHistorySettingName,
      skipExponentialSettingName,
      distractionFreeModeSettingName,
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
      browsingCountry => RegExp(r'^[A-Z]{2}$').hasMatch(value),
      localeSettingName =>
        RegExp(r'^[a-z]{2,3}(?:[_-][A-Za-z0-9]{2,8})*$').hasMatch(value),
      lastSubtitle => value.length < 128,
      themeModeSettingName => ['system', 'light', 'dark'].contains(value),
      navigationBarLabelBehaviorSettingName =>
        ['alwaysShow', 'alwaysHide', 'onlyShowSelected'].contains(value),
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
}
