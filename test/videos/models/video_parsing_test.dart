import 'dart:convert';

import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('queue occurrence survives hydration but stays out of API metadata', () {
    const queued = Video(videoId: 'song', queueEntryId: 'song#1');
    const response = Video(videoId: 'song', title: 'Fresh upload');
    final hydrated = response.preservingMusicMetadataFrom(queued);
    expect(hydrated.queueEntryId, 'song#1');
    expect(hydrated.videoId, 'song');
    expect(hydrated.title, 'Fresh upload');
    expect(response.preservingMusicMetadataFrom(const Video(videoId: 'song')),
        same(response));
    expect(hydrated.toJson().containsKey('queueEntryId'), isFalse);
    expect(
        Video.fromJson({'videoId': 'song', 'queueEntryId': 'untrusted'})
            .queueEntryId,
        isNull);
  });

  test('music catalog metadata round trips while older videos stay compatible',
      () {
    final music = MusicMetadata(
        title: 'Song',
        artist: 'Artist',
        album: 'Album',
        thumbnails: [
          ImageObject(null, 'https://image.example/cover', 500, 500)
        ]);
    final video = Video(videoId: 'song', musicMetadata: music);
    final restored = Video.fromJson(jsonDecode(jsonEncode(video)));
    expect(restored.musicMetadata!.toJson(), music.toJson());
    expect(Video.fromJson({'videoId': 'old'}).musicMetadata, isNull);

    const response = Video(videoId: 'song', title: 'Upload', author: 'Channel');
    final hydrated = response.preservingMusicMetadataFrom(video);
    expect(hydrated.title, 'Song');
    expect(hydrated.author, 'Artist');
    expect(hydrated.videoThumbnails.single.url, music.thumbnails.single.url);
    expect(hydrated.musicMetadata!.album, 'Album');
    expect(
        const Video(videoId: 'different')
            .preservingMusicMetadataFrom(video)
            .musicMetadata,
        isNull);
  });

  test('accepts optional progressive fields and skips malformed streams', () {
    final video = Video.fromJson({
      'videoId': 'video-id',
      'formatStreams': [
        {
          'url': 'https://r1.googlevideo.com/video.mp4',
          'itag': '18',
          'type': 'video/mp4',
          'quality': 'medium',
        },
        {'url': 42},
      ],
      'adaptiveFormats': [
        {
          'url': 'https://r1.googlevideo.com/audio.mp4',
          'itag': '140',
          'type': 'audio/mp4',
          'clen': '1234',
          'lmt': '1',
          'projectionType': 'RECTANGULAR',
        },
        {'url': false},
      ],
    });

    expect(video.formatStreams, hasLength(1));
    expect(video.formatStreams!.single.container, isNull);
    expect(video.formatStreams!.single.qualityLabel, isNull);
    expect(video.adaptiveFormats, hasLength(1));
  });
}
