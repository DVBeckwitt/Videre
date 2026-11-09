import 'dart:convert';
import 'package:clipious/home/models/phone_navigation.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_library_service.dart';

import 'package:clipious/offline_subscriptions/models/offline_subscription.dart';
import 'package:clipious/downloads/services/download_storage.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/utils/backup.dart';
import 'package:clipious/utils/invidious_image.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SembastSqfDb source, target;
  const id = 'abcdefghijk';
  const channel = 'UCabcdefghijklmnopqrstuv';

  test('Music mode survives backup with only supported values', () async {
    for (final mode in ['videos', 'music']) {
      await source.saveSetting(SettingsValue('home-content-mode', mode));
      await target.restoreBackup(await source.exportBackup(), replace: true);
      expect(target.getSettings('home-content-mode')?.value, mode);
    }
    expect(UserBackup.validSetting(SettingsValue('home-content-mode', 'other')),
        isFalse);
  });

  test('home experience backup preserves Music saves in every supported mode',
      () async {
    const song = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: id, title: 'Saved music');
    final library = MusicLibraryService.forProfile(source, source.profileId);
    await library.save(song);
    await library.markLocalPlaylist('local:empty-music');
    final storedLibrary = source.getSettings(musicLibrarySettingName)!.value;
    for (final experience in ['videosAndMusic', 'videosOnly', 'musicOnly']) {
      await source.saveSetting(SettingsValue('home-experience', experience));
      await target.restoreBackup(
          UserBackup.parse((await source.exportBackup()).encode()),
          replace: true);
      expect(target.getSettings('home-experience')?.value, experience);
      expect(target.getSettings(musicLibrarySettingName)?.value, storedLibrary);
      expect(
          MusicLibraryService.forProfile(target, target.profileId)
              .entries
              .single
              .id,
          song.id);
    }
    for (final invalid in ['videos', 'music', 'other', '']) {
      expect(UserBackup.validSetting(SettingsValue('home-experience', invalid)),
          isFalse);
    }
  });

  test('larger Music library backups preserve every bookmark and empty list',
      () async {
    final library = MusicLibraryService.forProfile(source, source.profileId);
    await Future.wait([
      for (var index = 0; index < 30; index++)
        library.save(MusicLibraryEntry(
            kind: MusicLibraryKind.song,
            id: 'song${index.toString().padLeft(7, '0')}',
            title: 'Saved song $index',
            subtitle: 'Artist',
            album: 'Album')),
      library.save(const MusicLibraryEntry(
          kind: MusicLibraryKind.album, id: 'MPREalbum', title: 'Saved album')),
      library.save(const MusicLibraryEntry(
          kind: MusicLibraryKind.artist, id: channel, title: 'Saved artist')),
      library.save(const MusicLibraryEntry(
          kind: MusicLibraryKind.playlist,
          id: 'PLpublic',
          title: 'Public playlist')),
    ]);
    await library.markLocalPlaylist('local:empty-music');
    final stored = source.getSettings(musicLibrarySettingName)!;
    expect(stored.value.length, greaterThan(2048));
    final backup = UserBackup.parse((await source.exportBackup()).encode());
    await target.restoreBackup(backup);
    expect(target.getSettings(musicLibrarySettingName)?.value, stored.value);
    final restored = MusicLibraryService.forProfile(target, target.profileId);
    expect(restored.entries, hasLength(33));
    expect(
        restored.isMusicPlaylist(const Playlist(
            title: 'Empty Music',
            playlistId: 'local:empty-music',
            author: '',
            videoCount: 0)),
        isTrue);
  });

  test('Music library restore respects merge, replace and target profile',
      () async {
    const incoming = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: id, title: 'Incoming song');
    const existing = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: '12345678901', title: 'Existing song');
    final original = MusicLibraryService.forProfile(target, target.profileId);
    await original.save(existing);
    await MusicLibraryService.forProfile(source, source.profileId)
        .save(incoming);
    final backup = await source.exportBackup();
    await target.restoreBackup(backup);
    expect(
        original.entries.map((entry) => entry.id), [existing.id, incoming.id]);

    final next = await target.createProfile('Import destination');
    final fixedTarget = target.forProfile(next.id);
    final destination = MusicLibraryService.forProfile(target, next.id);
    await target.useProfile(next.id);
    await fixedTarget.restoreBackup(backup, replace: true);
    expect(destination.entries.single.id, incoming.id);
    expect(
        original.entries.map((entry) => entry.id), [existing.id, incoming.id]);

    await destination.save(existing);
    await fixedTarget.restoreBackup(backup, replace: true);
    expect(destination.entries.single.id, incoming.id);
    expect(
        original.entries.map((entry) => entry.id), [existing.id, incoming.id]);
  });

  test(
      'Music merge keeps existing bookmarks and imports distinct saves and empty playlists',
      () async {
    const existing = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: id, title: 'Existing title');
    const duplicate = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: id, title: 'Imported title');
    const incoming = [
      MusicLibraryEntry(
          kind: MusicLibraryKind.song, id: '12345678901', title: 'New song'),
      MusicLibraryEntry(
          kind: MusicLibraryKind.album, id: 'MPREalbum', title: 'New album'),
      MusicLibraryEntry(
          kind: MusicLibraryKind.artist, id: channel, title: 'New artist'),
      MusicLibraryEntry(
          kind: MusicLibraryKind.playlist,
          id: 'PLpublic',
          title: 'New playlist'),
    ];
    const oldPlaylist = Playlist(
        playlistId: 'local:old-music',
        title: 'Old Music',
        author: '',
        videoCount: 0);
    const newPlaylist = Playlist(
        playlistId: 'local:new-music',
        title: 'New Music',
        author: '',
        videoCount: 0);
    final library = MusicLibraryService.forProfile(target, target.profileId);
    final importLibrary =
        MusicLibraryService.forProfile(source, source.profileId);
    await library.save(existing);
    await library.markLocalPlaylist(oldPlaylist.playlistId);
    await target.saveSetting(
        SettingsValue('local-playlists', jsonEncode([oldPlaylist.toJson()])));
    await importLibrary.save(duplicate);
    for (final entry in incoming) {
      await importLibrary.save(entry);
    }
    await importLibrary.markLocalPlaylist(newPlaylist.playlistId);
    await importLibrary.markLocalPlaylist(oldPlaylist.playlistId);
    await source.saveSetting(
        SettingsValue('local-playlists', jsonEncode([newPlaylist.toJson()])));
    final backup = await source.exportBackup();

    await target.restoreBackup(backup);
    expect(library.entries.first.toJson(), existing.toJson());
    expect(
        library.entries.map((entry) => entry.toJson()),
        unorderedEquals(
            [existing, ...incoming].map((entry) => entry.toJson())));
    final playlists = (jsonDecode(target.getSettings('local-playlists')!.value)
            as List)
        .map((row) => Playlist.fromJson(Map<String, dynamic>.from(row as Map)))
        .toList();
    expect(playlists.map((playlist) => playlist.playlistId),
        [oldPlaylist.playlistId, newPlaylist.playlistId]);
    expect(playlists.every(library.isMusicPlaylist), isTrue);
    final firstMerge = target.getSettings(musicLibrarySettingName)!.value;
    await target.restoreBackup(backup);
    expect(target.getSettings(musicLibrarySettingName)!.value, firstMerge);
  });

  for (final bound in ['bookmarks', 'playlist markers', 'UTF-8 bytes']) {
    test('Music merge exceeding $bound rolls back the entire restore',
        () async {
      String musicData({required bool incoming}) {
        final count = switch (bound) {
          'bookmarks' => incoming ? 1 : musicLibraryMaximumEntries,
          'UTF-8 bytes' => 700,
          _ => 0,
        };
        final prefix = incoming ? 'incoming' : 'existing';
        return jsonEncode({
          'version': 1,
          'entries': [
            for (var index = 0; index < count; index++)
              MusicLibraryEntry(
                      kind: MusicLibraryKind.song,
                      id: '$prefix-$index',
                      title:
                          bound == 'UTF-8 bytes' ? '🎵' * 1024 : 'Saved song')
                  .toJson(),
          ],
          'playlists': [
            if (bound == 'playlist markers')
              for (var index = 0;
                  index < (incoming ? 1 : musicLibraryMaximumEntries);
                  index++)
                'local:$prefix-$index',
          ],
        });
      }

      await source.saveSetting(SettingsValue('home-content-mode', 'music'));
      await source.saveSetting(
          SettingsValue(musicLibrarySettingName, musicData(incoming: true)));
      await target.saveSetting(
          SettingsValue(musicLibrarySettingName, musicData(incoming: false)));
      await target.saveSetting(SettingsValue(useDashSettingName, 'true'));
      await target
          .saveSetting(SettingsValue('playback-session', 'keep session'));
      await target.saveProgress(Progress(0.8, id));
      await target.upsertHistoryVideo(
          HistoryVideoCache(id, 'Existing video', 'Existing creator', ''));
      await target.addOfflineSubscription(const OfflineSubscription(
          channelId: 'UC1234567890123456789012',
          channelName: 'Existing channel'));
      await target.saveFilter(VideoFilter(value: 'existing filter'));
      final before = (await target.exportBackup()).encode();
      final backup = await source.exportBackup();
      expect(
          UserBackup.validSetting(source.getSettings(musicLibrarySettingName)!),
          isTrue);
      expect(
          UserBackup.validSetting(target.getSettings(musicLibrarySettingName)!),
          isTrue);

      await expectLater(target.restoreBackup(backup), throwsFormatException);
      expect((await target.exportBackup()).encode(), before);
      expect(target.getSettings('home-content-mode'), isNull);
      expect(target.getSettings('playback-session')?.value, 'keep session');
    });
  }

  test('sanitized Music artwork remains canonical through backup round trips',
      () async {
    final library = MusicLibraryService.forProfile(source, source.profileId);
    await library.save(MusicLibraryEntry(
        kind: MusicLibraryKind.album,
        id: 'MPREalbum',
        title: 'Artwork album',
        thumbnails: [
          ImageObject(
              'high',
              'https://IMAGES.example:443/covers/%E2%99%AB%20album.png?token=private#part',
              512,
              512),
        ]));
    final saved = library.entries.single;
    expect(
        MusicLibraryEntry.tryParse(saved.toJson())?.toJson(), saved.toJson());
    expect(
        UserBackup.validSetting(source.getSettings(musicLibrarySettingName)!),
        isTrue);
    final first = (await source.exportBackup()).encode();
    await target.restoreBackup(UserBackup.parse(first));
    final restored = MusicLibraryService.forProfile(target, target.profileId);
    expect(restored.entries.single.toJson(), saved.toJson());
    expect((await target.exportBackup()).encode(), isNot(contains('private')));
  });

  test('Music history backup keeps safe covers and strips unsafe URLs',
      () async {
    const cover = 'https://catalog.example/covers/%E2%99%AB%20cover.jpg';
    await source.upsertHistoryVideo(HistoryVideoCache(
        id, 'Song', 'Artist', cover,
        musicMetadata:
            MusicMetadata(title: 'Song', artist: 'Artist', thumbnails: [
          ImageObject(null, '$cover?token=private-cover#hidden', 120, 120),
          ImageObject(null, 'file:///data/cover.jpg', 120, 120),
          ImageObject(
              null, 'https://user:secret@catalog.example/cover.jpg', 120, 120),
        ])));

    final backup = (await source.exportBackup()).encode();
    expect(backup, isNot(contains('private-cover')));
    expect(backup, isNot(contains('#hidden')));
    await target.restoreBackup(UserBackup.parse(backup));

    final restored = target.getHistoryVideoByVideoId(id)!.musicMetadata!;
    expect(restored.title, 'Song');
    expect(restored.thumbnails.map((image) => image.url), [cover]);
  });

  test('portable video artwork resolves against the restored profile server',
      () async {
    const fallback = '/vi/$id/default.jpg';
    const rawFallback = '$fallback?token=private-art#hidden';
    const server = Server(url: 'https://target.example/invidious');
    await source.upsertHistoryVideo(HistoryVideoCache(
      id,
      'Saved song',
      'Artist',
      rawFallback,
      musicMetadata: const MusicMetadata(title: 'Saved song', artist: 'Artist'),
    ));
    final playlist = Playlist(
      playlistId: 'local:artwork',
      title: 'Artwork',
      author: '',
      videoCount: 1,
      videos: [
        Video(
          videoId: id,
          videoThumbnails: [
            ImageObject('default', rawFallback, 120, 90),
            ImageObject(null, '//other.example$fallback', 120, 90),
            ImageObject(null, '/api/v1/private$fallback', 120, 90),
            ImageObject(null, '/ggpht/%2Fapi%2Fv1%2Fprivate', 120, 90),
          ],
        ),
      ],
    );
    await source.saveSetting(
        SettingsValue(localPlaylistsSetting, jsonEncode([playlist.toJson()])));

    final backup = (await source.exportBackup()).encode();
    expect(backup, isNot(contains('private')));
    expect(backup, isNot(contains('other.example')));
    await target.restoreBackup(UserBackup.parse(backup));

    final history = target.getHistoryVideoByVideoId(id)!;
    final restored = Playlist.fromJson(
        (jsonDecode(target.getSettings(localPlaylistsSetting)!.value) as List)
            .single as Map<String, dynamic>);
    expect(history.musicMetadata?.thumbnails, isEmpty);
    expect(history.thumbnail, fallback);
    expect(restored.videos.single.videoThumbnails.single.url, fallback);
    expect(invidiousImageUrl(history.thumbnail, server),
        'https://target.example/invidious$fallback');
    expect((await target.exportBackup()).encode(), backup);
  });

  test('old Music backups restore songs with instance artwork', () async {
    // A v1 backup created before artwork source was saved.
    final setting = SettingsValue(
        musicLibrarySettingName,
        jsonEncode({
          'version': 1,
          'entries': [
            {
              'kind': 'song',
              'id': id,
              'title': 'Saved song',
              'subtitle': 'Artist',
              'thumbnails': [
                ImageObject(null, 'https://instance.example/vi/$id/default.jpg',
                        120, 90)
                    .toJson()
              ],
            },
          ],
          'playlists': [],
        }));
    final backup = jsonDecode((await source.exportBackup()).encode()) as Map;

    await target.restoreBackup(UserBackup.parse(jsonEncode({
      ...backup,
      'settings': [setting.toJson()],
    })));

    final restored =
        MusicLibraryService.forProfile(target, target.profileId).entries.single;
    expect(restored.id, id);
    expect(restored.usesVideoThumbnails, isTrue);
    expect(restored.toVideo().musicMetadata!.thumbnails, isEmpty);
    expect(restored.toVideo().videoThumbnails.single.url,
        'https://instance.example/vi/$id/default.jpg');
  });

  test('Music backup rejects unknown fields, invalid IDs and unsafe artwork',
      () async {
    const entry = MusicLibraryEntry(
        kind: MusicLibraryKind.song, id: id, title: 'Saved song');
    final row = entry.toJson();
    final valid = {
      'version': 1,
      'entries': [row],
      'playlists': ['local:music'],
    };
    final invalidRows = [
      {...row, 'usesVideoThumbnails': 'true'},
      {...row, 'dashUrl': 'https://stream.example/private'},
      {...row, 'authToken': 'private'},
      {...row, 'id': '../file'},
      {...row, 'title': 42},
      {...row, 'durationSeconds': -1},
      {
        ...row,
        'thumbnails': [
          ImageObject(null, 'https://user:secret@example.com/cover', 1, 1)
              .toJson()
        ],
      },
      {
        ...row,
        'thumbnails': [
          ImageObject(null, 'https://images.example/cover?token=secret', 1, 1)
              .toJson()
        ],
      },
      {
        ...row,
        'thumbnails': [
          ImageObject(null, 'file:///private/cover', 1, 1).toJson()
        ],
      },
      {
        ...row,
        'thumbnails': [
          {
            'quality': null,
            'url': 'https://images.example/cover',
            'width': 0.0,
            'height': 0,
          },
        ],
      },
    ];
    final data = jsonDecode((await source.exportBackup()).encode()) as Map;
    for (final invalid in [
      for (final invalidRow in invalidRows)
        {
          ...valid,
          'entries': [invalidRow]
        },
      {...valid, 'stream': 'private'},
      {...valid, 'version': 2},
      {...valid, 'version': 1.0},
      {
        ...valid,
        'playlists': ['remote']
      },
      {
        ...valid,
        'entries': [row, row]
      },
    ]) {
      final setting =
          SettingsValue(musicLibrarySettingName, jsonEncode(invalid));
      expect(UserBackup.validSetting(setting), isFalse);
      expect(
          () => UserBackup.parse(jsonEncode({
                ...data,
                'settings': [setting.toJson()],
              })),
          throwsFormatException);
    }
    expect(
        UserBackup.validSetting(
            SettingsValue(musicLibrarySettingName, jsonEncode(valid))),
        isTrue);
    expect(target.getSettings(musicLibrarySettingName), isNull);
  });

  test('Music backup rejects values beyond its explicit size and count bounds',
      () {
    SettingsValue setting(Object value) =>
        SettingsValue(musicLibrarySettingName, jsonEncode(value));
    expect(
        UserBackup.validSetting(setting({
          'version': 1,
          'entries': List.filled(musicLibraryMaximumEntries + 1, {}),
          'playlists': [],
        })),
        isFalse);
    expect(
        UserBackup.validSetting(setting({
          'version': 1,
          'entries': [],
          'playlists':
              List.filled(musicLibraryMaximumEntries + 1, 'local:music'),
        })),
        isFalse);
    expect(
        UserBackup.validSetting(SettingsValue(
            musicLibrarySettingName, ' ' * (musicLibraryMaximumBytes + 1))),
        isFalse);
  });

  test('backup restores motion choices and rejects invalid values', () async {
    for (final value in ['system', 'reduced', 'off']) {
      await source
          .saveSetting(SettingsValue(motionPreferenceSettingName, value));
      await target.restoreBackup(
          UserBackup.parse((await source.exportBackup()).encode()),
          replace: true);
      expect(target.getSettings(motionPreferenceSettingName)?.value, value);
    }
    expect(
        UserBackup.validSetting(
            SettingsValue(motionPreferenceSettingName, 'invalid')),
        isFalse);
  });

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

  test('quality preference and opt-out survive backup restore', () async {
    await source
        .saveSetting(SettingsValue(rememberVideoQualitySettingName, 'false'));
    await source
        .saveSetting(SettingsValue(lastVideoQualitySettingName, '1080'));
    await target.restoreBackup(
        UserBackup.parse((await source.exportBackup()).encode()));
    expect(target.getSettings(rememberVideoQualitySettingName)?.value, 'false');
    expect(target.getSettings(lastVideoQualitySettingName)?.value, '1080');
    expect(
        UserBackup.validSetting(
            SettingsValue(lastVideoQualitySettingName, '0')),
        isTrue);
    expect(
        UserBackup.validSetting(
            SettingsValue(lastVideoQualitySettingName, '-1')),
        isFalse);
    expect(
        UserBackup.validSetting(
            SettingsValue(lastVideoQualitySettingName, '99999')),
        isFalse);
  });

  test(
      'queue autoplay opt-out survives backup without accepting invalid values',
      () async {
    await source.saveSetting(SettingsValue(playerAutoplayQueue, 'false'));
    await target.restoreBackup(
        UserBackup.parse((await source.exportBackup()).encode()));
    expect(target.getSettings(playerAutoplayQueue)?.value, 'false');
    expect(UserBackup.validSetting(SettingsValue(playerAutoplayQueue, 'yes')),
        isFalse);
  });

  test('phone navigation placement and startup survive backup restore',
      () async {
    final layout = PhoneNavigation.defaults()
        .move(PhoneNavigationItem.playlist, NavigationArea.bottom)!
        .startAt(PhoneNavigationItem.playlist);
    await source.saveSetting(
        SettingsValue(phoneNavigationSettingName, layout.encode()));
    await target.restoreBackup(
        UserBackup.parse((await source.exportBackup()).encode()));
    expect(
        target.getSettings(phoneNavigationSettingName)?.value, layout.encode());
  });

  test('TV history opt-out and empty layout survive backup restore', () async {
    for (final layout in ['search,playlist,trending', 'history,search', '']) {
      await source.saveSetting(SettingsValue(tvAppLayoutSettingName, layout));
      await target.restoreBackup(
          UserBackup.parse((await source.exportBackup()).encode()),
          replace: true);
      expect(target.getSettings(tvAppLayoutSettingName)?.value, layout);
    }
    for (final invalid in ['history,history', 'search,unknown', 'home', ',']) {
      expect(
          UserBackup.validSetting(
              SettingsValue(tvAppLayoutSettingName, invalid)),
          isFalse);
    }
  });

  test('watched subscription visibility survives backup restore', () async {
    for (final value in ['true', 'false']) {
      await source.saveSetting(
          SettingsValue(hideWatchedSubscriptionsSettingName, value));
      await target.restoreBackup(await source.exportBackup(), replace: true);
      expect(target.getSettings(hideWatchedSubscriptionsSettingName)?.value,
          value);
    }
    expect(
        UserBackup.validSetting(
            SettingsValue(hideWatchedSubscriptionsSettingName, 'invalid')),
        isFalse);
  });

  test('download folder grants stay on their device during backup and restore',
      () async {
    await source.saveSetting(SettingsValue(
        downloadFolderSetting,
        jsonEncode(
            const DownloadFolder('content://source/tree/folder', 'Source')
                .toJson())));
    await target.saveSetting(SettingsValue(
        downloadFolderSetting,
        jsonEncode(
            const DownloadFolder('content://target/tree/folder', 'Target')
                .toJson())));
    final backup = await source.exportBackup();
    expect(backup.encode(), isNot(contains('content://source')));
    for (final replace in [false, true]) {
      await target.restoreBackup(backup, replace: replace);
      expect(target.getSettings(downloadFolderSetting)!.value,
          contains('content://target'));
    }
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

  test('Music playlist export and restore retains sanitized catalog metadata',
      () async {
    final cover =
        ImageObject(null, 'https://lh3.googleusercontent.com/cover', 512, 512);
    final music = MusicMetadata(
        title: 'Catalog song',
        artist: 'Catalog artist',
        album: 'Catalog album',
        thumbnails: [
          cover,
          ImageObject(
              null, 'https://user:music-secret@example.com/cover', 512, 512),
          ImageObject(null, 'file:///private/cover.jpg', 512, 512),
          ImageObject(null, 'https:/missing-host.jpg', 512, 512),
        ]);
    final song = Video(
        videoId: id,
        title: 'Upload title',
        author: 'Upload author',
        lengthSeconds: 180,
        musicMetadata: music);
    const ordinary = Video(videoId: '12345678901', title: 'Ordinary video');
    final playlist = Playlist(
        playlistId: 'local:music',
        title: 'Mixed library',
        author: '',
        videoCount: 2,
        videos: [song, ordinary]);
    await source.saveSetting(SettingsValue(
        localPlaylistsSetting,
        jsonEncode([
          {
            ...playlist.toJson(),
            'videos': [
              {
                ...song.toJson(),
                'dashUrl': 'https://private-stream.invalid/media',
                'musicMetadata': {
                  ...music.toJson(),
                  'accountId': 'private-music-account',
                  'authToken': 'private-music-token',
                },
              },
              ordinary.toJson(),
            ],
          },
        ])));

    final encoded = (await source.exportBackup()).encode();
    await target.restoreBackup(UserBackup.parse(encoded));
    final restored = Playlist.fromJson(
        (jsonDecode(target.getSettings(localPlaylistsSetting)!.value) as List)
            .single);

    final restoredMusic = restored.videos.first.musicMetadata;
    expect(restoredMusic, isNotNull);
    expect(restoredMusic!.toJson(), {
      'title': music.title,
      'artist': music.artist,
      'album': music.album,
      'thumbnails': [cover.toJson()],
    });
    expect(restored.videos.first.lengthSeconds, 180);
    expect(restored.videos.last.musicMetadata, isNull);
    expect(restored.videos.map((video) => video.videoId),
        [song.videoId, ordinary.videoId]);
    for (final private in [
      'music-secret',
      'private-music-account',
      'private-music-token',
      'private-stream',
      'file:///',
      'https:/missing-host',
    ]) {
      expect(encoded, isNot(contains(private)));
    }
  });
}
