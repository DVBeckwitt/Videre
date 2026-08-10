import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
