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

  test('playback fills a saved song ID and missing artist with upload details',
      () {
    const id = 'abcdefghijk';
    const queued = Video(
      videoId: id,
      queueEntryId: 'song#2',
      musicMetadata: MusicMetadata(title: id, artist: '', album: 'Saved album'),
    );
    final artwork = ImageObject(null, '/vi/$id/mqdefault.jpg', 320, 180);
    final response = Video(
      videoId: id,
      title: 'Song title',
      author: 'Uploader',
      authorId: 'UC1234567890123456789012',
      videoThumbnails: [artwork],
    );
    final resolved = response.preservingMusicMetadataFrom(queued);
    expect(resolved.title, 'Song title');
    expect(resolved.author, 'Uploader');
    expect(resolved.musicMetadata?.title, 'Song title');
    expect(resolved.musicMetadata?.artist, 'Uploader');
    expect(resolved.musicMetadata!.artistCredits.single.id,
        'UC1234567890123456789012');
    final otherArtist = queued.copyWith(
        musicMetadata: const MusicMetadata(title: id, artist: 'Performer'));
    expect(
        response
            .preservingMusicMetadataFrom(otherArtist)
            .musicMetadata!
            .artistCredits,
        isEmpty);
    expect(resolved.musicMetadata?.album, 'Saved album');
    expect(resolved.videoThumbnails.single, artwork);
    expect(resolved.queueEntryId, 'song#2');
  });

  test(
      'Music hydration retains a usable queued frame when fresh images do not match',
      () {
    const id = 'abcdefghijk';
    final queuedFrame = ImageObject('medium',
        'https://old.example/vi/$id/mqdefault.jpg?expired=1', 320, 180);
    final freshFrame = ImageObject('high', '/vi/$id/hqdefault.jpg', 480, 360);
    final wrongFrame =
        ImageObject('high', '/vi/otherSong01/hqdefault.jpg', 480, 360);
    final queued = Video(
        videoId: id,
        queueEntryId: 'second',
        videoThumbnails: [queuedFrame],
        musicMetadata: const MusicMetadata(title: 'Song', artist: 'Singer'));
    final response =
        Video(videoId: id, genre: 'Music', videoThumbnails: [wrongFrame]);
    final resolved = response.preservingMusicMetadataFrom(queued);
    expect(resolved.videoThumbnails.single.url, '/vi/$id/mqdefault.jpg');
    expect(resolved.musicMetadata!.thumbnails, isEmpty);
    expect(resolved.queueEntryId, queued.queueEntryId);
    expect(resolved.genre, response.genre);
    expect(
        response
            .copyWith(videoThumbnails: [freshFrame])
            .preservingMusicMetadataFrom(queued)
            .videoThumbnails
            .single,
        same(freshFrame));
    expect(
        response
            .preservingMusicMetadataFrom(queued.copyWith(musicMetadata: null))
            .videoThumbnails
            .single,
        same(wrongFrame));
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
