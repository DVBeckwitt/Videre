import 'dart:convert';

import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/utils/backup.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SembastSqfDb source, target;
  const id = 'abcdefghijk';
  const channel = 'UCabcdefghijklmnopqrstuv';

  setUp(() async {
    source = await SembastSqfDb.createInMemory();
    target = await SembastSqfDb.createInMemory();
    await source.addOfflineSubscription(
        const OfflineSubscription(channelId: channel, channelName: 'Example'));
    await source.saveSetting(SettingsValue(useDashSettingName, 'false'));
    await source
        .saveSetting(SettingsValue('playback-session', 'private session'));
    await source.saveProgress(Progress(0.4, id));
    await source.upsertHistoryVideo(
        HistoryVideoCache(id, 'Example video', 'Creator', ''));
    await source.saveFilter(VideoFilter(value: 'spoiler'));
    await source.upsertServer(
        const Server(url: 'https://example.com', authToken: 'secret'));
  });

  tearDown(() async {
    await source.close();
    await target.close();
  });

  test('portable backup restores local data without credentials or sessions',
      () async {
    final backup = await source.exportBackup();
    expect(backup.encode(), isNot(contains('secret')));
    expect(backup.encode(), isNot(contains('private session')));
    await target.restoreBackup(UserBackup.parse(backup.encode()));
    expect((await target.getOfflineSubscriptions()).single.channelId, channel);
    expect(target.getVideoProgress(id), 0.4);
    expect(target.getLocalHistory().single.title, 'Example video');
    expect(target.getAllFilters().single.value, 'spoiler');
    expect(target.getSettings(useDashSettingName)?.value, 'false');
    expect(await target.getServers(), isEmpty);
  });

  test('merge keeps existing values; replace preserves target accounts',
      () async {
    await target.saveSetting(SettingsValue(useDashSettingName, 'true'));
    await target.saveProgress(Progress(0.8, id));
    await target.upsertServer(
        const Server(url: 'https://target.example', authToken: 'keep'));
    final backup = await source.exportBackup();
    await target.restoreBackup(backup);
    expect(target.getSettings(useDashSettingName)?.value, 'true');
    expect(target.getVideoProgress(id), 0.8);
    await target.restoreBackup(backup, replace: true);
    expect(target.getSettings(useDashSettingName)?.value, 'false');
    expect(target.getVideoProgress(id), 0.4);
    expect((await target.getServers()).single.authToken, 'keep');
  });

  test('backup preserves destination notification permission and scheduling',
      () async {
    await source
        .saveSetting(SettingsValue(backgroundNotificationsSettingName, 'true'));
    await source.saveSetting(SettingsValue(backgroundCheckFrequency, '12'));
    final backup = await source.exportBackup();
    expect(backup.sections['settings']!.map((setting) => setting['name']),
        isNot(contains(backgroundNotificationsSettingName)));
    expect(backup.sections['settings']!.map((setting) => setting['name']),
        isNot(contains(backgroundCheckFrequency)));
    await target.saveSetting(SettingsValue(backgroundCheckFrequency, '3'));
    for (final enabled in ['true', 'false']) {
      await target.saveSetting(
          SettingsValue(backgroundNotificationsSettingName, enabled));
      for (final replace in [false, true]) {
        await target.restoreBackup(backup, replace: replace);
        expect(target.getSettings(backgroundNotificationsSettingName)?.value,
            enabled);
        expect(target.getSettings(backgroundCheckFrequency)?.value, '3');
      }
    }
    final data = jsonDecode(backup.encode()) as Map<String, dynamic>;
    expect(
        () => UserBackup.parse(jsonEncode({
              ...data,
              'settings': [
                SettingsValue(backgroundNotificationsSettingName, 'true')
                    .toJson()
              ]
            })),
        throwsFormatException);
  });

  test('invalid version, settings and progress fail before changing data',
      () async {
    final data = jsonDecode((await source.exportBackup()).encode())
        as Map<String, dynamic>;
    expect(() => UserBackup.parse(jsonEncode({...data, 'version': 99})),
        throwsFormatException);
    expect(
        () => UserBackup.parse(jsonEncode({
              ...data,
              'settings': [
                {'name': playerRepeat, 'value': '99'}
              ]
            })),
        throwsFormatException);
    expect(
        () => UserBackup.parse(jsonEncode({
              ...data,
              'progress': [
                {'videoId': id, 'progress': 2}
              ]
            })),
        throwsFormatException);
    expect(target.getAllSettings(), isEmpty);
  });

  test('NewPipe imports deduplicate and replace only subscriptions', () async {
    final row = {
      'service_id': 0,
      'url': 'https://www.youtube.com/channel/$channel',
      'name': 'Example'
    };
    final backup = UserBackup.parse(jsonEncode({
      'subscriptions': [row, row]
    }));
    expect(backup.subscriptionsOnly, isTrue);
    expect(backup.itemCount, 1);
    await target.saveProgress(Progress(0.7, id));
    await target.restoreBackup(backup, replace: true);
    expect((await target.getOfflineSubscriptions()).length, 1);
    expect(target.getVideoProgress(id), 0.7);
    expect(
        () => UserBackup.parse(jsonEncode({
              'subscriptions': [
                {...row, 'url': 'https://evil.example/channel/$channel'}
              ]
            })),
        throwsFormatException);
  });

  test('rejects filters and layouts that would break browsing', () async {
    final data = jsonDecode((await source.exportBackup()).encode())
        as Map<String, dynamic>;
    for (final filter in [
      VideoFilter(value: '['),
      VideoFilter(value: 'not a number')..type = FilterType.length,
    ]) {
      expect(
          () => UserBackup.parse(jsonEncode({
                ...data,
                'filters': [
                  {...filter.toJson(), 'uuid': 'test'}
                ]
              })),
          throwsFormatException);
    }
    expect(
        () => UserBackup.parse(jsonEncode({
              ...data,
              'settings': [
                SettingsValue(appLayoutSettingName, 'home,home').toJson()
              ]
            })),
        throwsFormatException);
  });

  test('local playlist merge preserves both lists of videos and strips streams',
      () async {
    Map<String, dynamic> playlist(String videoId) => {
          'playlistId': 'local:watch-later',
          'title': 'Watch Later',
          'author': '',
          'videoCount': 1,
          'videos': [
            {
              'videoId': videoId,
              'title': 'Saved',
              'authorId': 'UC1234567890123456789012',
              'dashUrl': 'https://secret.example/stream'
            }
          ],
        };
    await source.saveSetting(
        SettingsValue('local-playlists', jsonEncode([playlist(id)])));
    await target.saveSetting(SettingsValue(
        'local-playlists', jsonEncode([playlist('12345678901')])));
    final backup = await source.exportBackup();
    expect(backup.encode(), isNot(contains('secret.example')));
    expect(backup.sections['playlists']!.single['videos'].single['authorId'],
        'UC1234567890123456789012');
    await target.restoreBackup(backup);
    final lists =
        jsonDecode(target.getSettings('local-playlists')!.value) as List;
    expect(lists.single['videoCount'], 2);
  });

  test('history deletion also removes saved progress and resume queue',
      () async {
    await source.deleteLocalHistory(id);
    expect(source.getLocalHistory(), isEmpty);
    expect(source.getAllProgress(), isEmpty);
    expect(source.getSettings('playback-session'), isNull);
  });

  test('playlist backup retains long names and safe display metadata',
      () async {
    final title = List.filled(201, 'a').join();
    final playlist = Playlist(
        title: title,
        playlistId: 'local:test',
        author: '',
        videoCount: 1,
        videos: [
          Video(
            videoId: id,
            title: 'Saved',
            author: 'Creator',
            authorId: channel,
            authorUrl: 'https://www.youtube.com/channel/$channel',
            videoThumbnails: [
              ImageObject('high', 'https://example.com/image.jpg', 1280, 720),
              ImageObject('high', 'https://user:password@example.com/image.jpg',
                  1280, 720),
              ImageObject('high', 'file:///private/image.jpg', 1280, 720),
              ImageObject('high', 'https:/missing-host.jpg', 1280, 720),
            ],
          )
        ]);
    await source.saveSetting(
        SettingsValue(localPlaylistsSetting, jsonEncode([playlist.toJson()])));
    final backup = UserBackup.parse((await source.exportBackup()).encode());
    await target.restoreBackup(backup);
    final restored = Playlist.fromJson(
        (jsonDecode(target.getSettings(localPlaylistsSetting)!.value) as List)
            .single);
    expect(restored.title, title);
    final video = restored.videos.single;
    expect(video.author, 'Creator');
    expect(video.authorId, channel);
    expect(video.authorUrl, 'https://www.youtube.com/channel/$channel');
    expect(video.videoThumbnails.single.url, 'https://example.com/image.jpg');
    expect(video.indexId, id);
  });
}
