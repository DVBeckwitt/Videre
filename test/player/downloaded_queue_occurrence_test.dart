import 'dart:convert';

import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/models/playback_session.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const song = DownloadedVideo(
      videoId: 'saved-song',
      title: 'Song',
      lengthSeconds: 90,
      quality: 'audio',
      audioOnly: true,
      downloadComplete: true);

  test('only canonical saved occurrence keys resolve to a download source', () {
    for (final key in ['saved-song', 'saved-song#1', 'saved-song#120']) {
      expect(savedDownloadSourceId(key), 'saved-song');
    }
    for (final key in [
      '',
      '../saved',
      'device:abc',
      'device:abc#1',
      '#1',
      'x#0',
      'x#01',
      'x#+1',
      'x#-1',
      'x#1#2',
      'x#1\n',
      'x#１',
      '${'a' * 129}#1'
    ]) {
      expect(savedDownloadSourceId(key), isNull, reason: key);
    }
  });

  test('saved copies reserve existing keys and never change download JSON', () {
    final reserved = song.copyWith(queueEntryId: 'saved-song#1');
    final source = [song, song, reserved, reserved];
    final queue = assignDownloadedQueueIds(source);
    final ids = queue.map(playbackQueueId).toList();
    expect(ids, ['saved-song', 'saved-song#2', 'saved-song#1', 'saved-song#3']);
    expect(queue.map((entry) => entry.videoId).toSet(), {song.videoId});
    expect(source[1].queueEntryId, isNull);
    expect(identical(queue[2], reserved), isTrue);
    expect(assignDownloadedQueueIds(queue.reversed).map(playbackQueueId),
        ids.reversed);
    expect(queue[1].toJson(), song.toJson());
    expect(
        DownloadedVideo.fromJson({...song.toJson(), 'queueEntryId': 'forged'})
            .queueEntryId,
        isNull);
    final invalid = song.copyWith(queueEntryId: 'other#1');
    expect(playbackQueueId(invalid), song.videoId);
    expect(assignDownloadedQueueIds([invalid]).single.queueEntryId, isNull);
    final device = song.copyWith(videoId: 'device:local#2');
    expect(assignDownloadedQueueIds([device]).single, same(device));
    expect(playbackQueueId(device), device.videoId);
  });

  test('version 3 preserves a saved occurrence after its original is removed',
      () {
    const session = PlaybackSession(
        offlineIds: ['other', 'saved-song#2', 'saved-song#1'],
        currentId: 'saved-song#2',
        played: ['other'],
        next: ['saved-song#1'],
        musicHistoryEntries: {'saved-song#2'},
        audio: true,
        seconds: 35);
    final json = jsonDecode(session.encode()) as Map<String, dynamic>;
    expect(json['version'], 3);
    final restored = PlaybackSession.decode(session.encode())!;
    expect(restored.offlineIds, session.offlineIds);
    expect(restored.currentSavedDownloadId, 'saved-song');
    expect(restored.played, ['other']);
    expect(restored.next, ['saved-song#1']);
    expect(restored.musicHistoryEntries, {'saved-song#2'});
    expect(restored.seconds, 35);
    for (final bad in <Map<String, dynamic>>[
      {'version': 2},
      {
        'offlineIds': ['saved-song#2', 'saved-song#2']
      },
      {
        'offlineIds': ['device:local', ...session.offlineIds]
      },
      {
        'offlineIds': ['song#01', ...session.offlineIds]
      },
      {
        'videos': [
          {'videoId': 'other'}
        ]
      },
      {
        'playlistEntries': [
          {'videoId': 'other'}
        ]
      },
      {'currentId': 'saved-song#3'},
      {
        'next': ['saved-song#3']
      },
      {
        'played': ['unknown']
      },
    ]) {
      expect(PlaybackSession.decode(jsonEncode({...json, ...bad})), isNull,
          reason: bad.toString());
    }
  });

  test('legacy bare saved, device and online identities remain distinct', () {
    const saved = PlaybackSession(
        offlineIds: ['saved-song'], currentId: 'saved-song', seconds: 5);
    const device = PlaybackSession(
        offlineIds: ['device:file', 'device:file#1'],
        currentId: 'device:file#1',
        seconds: 4);
    const online = PlaybackSession(
        videos: [Video(videoId: 'song', queueEntryId: 'song#1')],
        currentId: 'song#1',
        seconds: 3);
    for (final session in [saved, device, online]) {
      final json = jsonDecode(session.encode()) as Map<String, dynamic>;
      expect(json['version'], 2);
      for (final version in [1, 2]) {
        final restored =
            PlaybackSession.decode(jsonEncode({...json, 'version': version}))!;
        expect(restored.currentId, session.currentId);
        expect(restored.currentSavedDownloadId,
            session == saved ? 'saved-song' : null);
      }
    }
  });

  test('explicit offline files pin only the selected occurrences', () {
    final firstDigest = 'a0' * 32;
    final secondDigest = 'b1' * 32;
    final device = 'device:${'a' * 64}';
    for (final withDevice in [false, true]) {
      final pins = {'saved-song': firstDigest, 'saved-song#2': secondDigest};
      final session = PlaybackSession(
          offlineIds: [
            'saved-song',
            'saved-song#1',
            'saved-song#2',
            if (withDevice) device
          ],
          offlineFingerprints: pins,
          currentId: 'saved-song#2',
          seconds: 12,
          audio: true,
          localSelectionId: withDevice ? 'approval-1' : null);
      final json = jsonDecode(session.encode()) as Map<String, dynamic>;
      expect(json['version'], 4);
      expect(json['offlineFingerprints'], pins);
      expect(json.containsKey('localSelectionId'), withDevice);
      expect(json['videos'], isEmpty);
      final restored = PlaybackSession.decode(session.encode())!;
      expect(restored.offlineFingerprints, pins);
      expect(restored.offlineFingerprints['saved-song#1'], isNull);
      expect(restored.currentSavedDownloadId, 'saved-song');
      expect(restored.hasDeviceEntries, withDevice);

      for (final bad in <Map<String, dynamic>>[
        {'version': 1},
        {'version': 2},
        {'version': 3},
        {
          'offlineIds': [...session.offlineIds, 'saved-song']
        },
        {'offlineFingerprints': null},
        {'offlineFingerprints': []},
        {'offlineFingerprints': {}},
        {
          'offlineFingerprints': {'saved-song#3': firstDigest}
        },
        {
          'offlineFingerprints': {device: firstDigest}
        },
        {
          'offlineIds': [...session.offlineIds, 'saved-song#01'],
          'offlineFingerprints': {'saved-song#01': firstDigest}
        },
        {
          'offlineFingerprints': {'saved-song#2': null}
        },
        {
          'offlineFingerprints': {'saved-song#2': 'content://private'}
        },
        {
          'offlineFingerprints': {'saved-song#2': 'F' * 64}
        },
        {
          'offlineFingerprints': {'saved-song#2': '$firstDigest\n'}
        },
        {
          'playlistReference': {
            'kind': 'public',
            'playlistId': 'PLx',
            'profileId': 'owner'
          }
        },
      ]) {
        expect(PlaybackSession.decode(jsonEncode({...json, ...bad})), isNull,
            reason: bad.toString());
      }
    }
    const bare = PlaybackSession(
        offlineIds: ['saved-song'],
        currentId: 'saved-song',
        audio: true,
        seconds: 0);
    final json = jsonDecode(bare.encode()) as Map<String, dynamic>;
    expect(json['version'], 2);
    expect(json.containsKey('offlineFingerprints'), isFalse);
    expect(PlaybackSession.decode(bare.encode())!.offlineFingerprints, isEmpty);
    json['version'] = 4;
    json['offlineFingerprints'] = {'saved-song': firstDigest};
    expect(PlaybackSession.decode(jsonEncode(json))!.offlineFingerprints,
        {'saved-song': firstDigest});
  });

  test(
      'mixed offline checkpoints keep the device grant with either current source',
      () {
    final device = 'device:${'a' * 64}#1';
    for (final grant in [null, 'approval-1']) {
      for (final current in [device, 'saved-song#2']) {
        final session = PlaybackSession(
            offlineIds: [device, 'saved-song#2'],
            currentId: current,
            localSelectionId: grant,
            audio: true,
            seconds: 23,
            next: [current == device ? 'saved-song#2' : device],
            musicHistoryEntries: const {'saved-song#2'});
        final json = jsonDecode(session.encode()) as Map<String, dynamic>;
        expect(json['version'], 4);
        expect(json.containsKey('localSelectionId'), isTrue);
        final restored = PlaybackSession.decode(session.encode())!;
        expect(restored.hasDeviceEntries, isTrue);
        expect(restored.currentSavedDownloadId,
            current == device ? null : 'saved-song');
        expect(restored.localSelectionId, grant);
        expect(restored.next, session.next);
        expect(restored.musicHistoryEntries, session.musicHistoryEntries);
        expect(restored.seconds, 23);
        for (final bad in <Map<String, dynamic>>[
          {'version': 2},
          {'version': 3},
          {'audio': false},
          {'localSelectionId': 'content://folder/private'},
          {'localSelectionId': 23},
          {
            'offlineIds': [device, device, 'saved-song#2']
          },
          {
            'offlineIds': [device, 'saved-song#2', 'device:content://foo']
          },
          {
            'offlineIds': [device, 'saved-song#2', 'device:${'a' * 64}#01']
          },
          {
            'offlineIds': [device, 'saved-song#2', '../private']
          },
          {
            'next': ['saved-song#3']
          },
          {'currentId': 'saved-song'},
          {
            'musicHistoryEntries': ['unknown']
          },
          {
            'playlistReference': {
              'kind': 'public',
              'playlistId': 'PLx',
              'profileId': 'owner'
            }
          },
          {
            'videos': [
              {'videoId': 'catalog'}
            ]
          },
        ]) {
          expect(PlaybackSession.decode(jsonEncode({...json, ...bad})), isNull,
              reason: bad.toString());
        }
        json.remove('localSelectionId');
        expect(PlaybackSession.decode(jsonEncode(json)), isNull);
      }
    }
  });

  test(
      'marked catalog copies persist file identity independently of playlist membership',
      () {
    final fingerprint = 'a9' * 32;
    const source = Video(videoId: 'same-song', queueEntryId: 'playlist:source');
    final marked = Video(
        videoId: 'same-song',
        queueEntryId: 'same-song#1',
        explicitMusicDownload: fingerprint,
        dashUrl: 'https://secret stream',
        videoThumbnails: [ImageObject(null, 'content://private/song', 50, 50)],
        musicMetadata:
            MusicMetadata(title: 'Same Song', artist: '', thumbnails: [
          ImageObject(null, 'https://example.com/cover?secret-token', 50, 50),
          ImageObject(null, 'https://user:pass@example.com/art', 50, 50),
        ]));
    const reference = PlaylistReference(
        kind: PlaylistSourceKind.public,
        playlistId: 'PL01',
        profileId: 'owner');
    final session = PlaybackSession(
        videos: [source, marked],
        currentId: 'same-song#1',
        played: const ['playlist:source'],
        musicHistoryEntries: const {'same-song#1'},
        playlistReference: reference,
        playlistEntries: [
          source,
          marked,
          const Video(videoId: 'removed-source-song')
        ],
        audio: true,
        seconds: 12);
    final encoded = session.encode();
    final json = jsonDecode(encoded) as Map<String, dynamic>;
    expect(json['version'], 4);
    expect(json.containsKey('localSelectionId'), isFalse);
    for (final secret in [
      'content://private',
      'secret',
      'user:pass',
      'dashUrl'
    ]) {
      expect(encoded, isNot(contains(secret)));
    }
    final restored = PlaybackSession.decode(encoded)!;
    expect(restored.hasDeviceEntries, isFalse);
    expect(restored.currentId, 'same-song#1');
    expect(restored.playlistReference, reference);
    expect(restored.playlistEntries.map(playbackQueueId),
        ['playlist:source', 'removed-source-song']);
    expect(restored.videos.first.explicitMusicDownload, isNull);
    expect(restored.videos.last.explicitMusicDownload, fingerprint);
    expect(restored.videos.last.musicMetadata!.thumbnails.single.url,
        'https://example.com/cover');
    expect(restored.videos.last.videoThumbnails, isEmpty);
    expect(marked.toJson().containsKey('explicitMusicDownload'), isFalse);
    final original = json['videos'].first;
    final file = json['videos'].last as Map<String, dynamic>;
    final injected = PlaybackSession.decode(jsonEncode({
      ...json,
      'videos': [
        original,
        {...file, 'dashUrl': 'content://private', 'hlsUrl': 'https://expired'}
      ]
    }))!;
    expect(injected.videos.last.dashUrl, isNull);
    expect(injected.videos.last.hlsUrl, isNull);

    Map<String, dynamic> replaceFile(Map<String, dynamic> changes) => {
          'videos': [
            original,
            {...file, ...changes}
          ]
        };
    for (final bad in <Map<String, dynamic>>[
      {'version': 2},
      {'version': 3},
      {'audio': false},
      {'localSelectionId': null},
      {
        'videos': [original, original, file]
      },
      {
        'playlistEntries': [file]
      },
      {
        'playlistEntries': [
          {'videoId': 'same-song', 'queueEntryId': 'same-song#1'}
        ]
      },
      {
        'playlistEntries': [original, original]
      },
      {'playlistReference': null},
      {
        'played': ['deleted']
      },
      {
        'next': ['missing']
      },
      {'currentId': 'same-song'},
      replaceFile({'videoId': '../unsafe'}),
      replaceFile({'videoId': 'device:${'e' * 64}'}),
      replaceFile({'queueEntryId': 'other#1'}),
      replaceFile({'musicMetadata': null}),
      replaceFile({
        'musicMetadata': {'title': '  ', 'artist': ''}
      }),
      for (final marker in [
        null,
        false,
        'A' * 64,
        '1' * 63,
        '${'a' * 64}\n',
        'content://file'
      ])
        replaceFile({'explicitMusicDownload': marker}),
    ]) {
      expect(PlaybackSession.decode(jsonEncode({...json, ...bad})), isNull,
          reason: bad.toString());
    }
  });
}
