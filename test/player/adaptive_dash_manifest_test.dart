import 'package:clipious/player/adaptive_dash_manifest.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river_player/river_player.dart';

const _videoUrl = 'https://rr1.googlevideo.com/videoplayback?a=1&b=2';
const _audioUrl = 'https://rr1.googlevideo.com/audio';

AdaptiveFormat _format({
  required String itag,
  required String type,
  required String url,
  Object? size,
  Object? fps,
  String index = '741-1192',
}) =>
    AdaptiveFormat.fromJson({
      'itag': itag,
      'type': type,
      'url': url,
      'index': index,
      'init': '0-740',
      'bitrate': '3457375',
      'clen': '51194259',
      'lmt': '123',
      'projectionType': 'RECTANGULAR',
      'size': size,
      'fps': fps,
    });

void main() {
  final video = _format(
      itag: '137',
      type: 'video/mp4; codecs="avc1.640028"',
      url: _videoUrl,
      size: '1920x1080',
      fps: 30);
  final audio = _format(
      itag: '140', type: 'audio/mp4; codecs="mp4a.40.2"', url: _audioUrl);

  String? manifest(
    List<AdaptiveFormat> formats, {
    String? Function(String)? resolve,
  }) =>
      buildAdaptiveDashManifest(
        formats: formats,
        duration: const Duration(seconds: 183),
        resolveMediaUrl: resolve ?? (url) => url,
      );

  test('makes a static DASH source the player can list at 1080p', () async {
    final source = manifest([audio, video, video])!;
    expect(source, contains('mediaPresentationDuration="PT183.0S"'));
    expect(source, contains('indexRange="741-1192"'));
    expect(source, contains('<Initialization range="0-740"/>'));
    expect(
        source,
        contains('<BaseURL>https://rr1.googlevideo.com/'
            'videoplayback?a=1&amp;b=2</BaseURL>'));

    final parsed = await BetterPlayerAsmsUtils.parse(
        source, 'https://instance.example/dash');
    final track = parsed.tracks!.single;
    expect(track.id, '137');
    expect(track.width, 1920);
    expect(track.height, 1080);
    expect(track.frameRate, 30);
    expect(parsed.audios, hasLength(1));
  });

  test('skips incompatible or unsafe tracks and needs both media types', () {
    final badRange = _format(
        itag: '399',
        type: 'video/mp4; codecs="av01.0.09M.08"',
        url: _videoUrl,
        size: '1920x1080',
        index: '739-51194259');
    final unknownSize = _format(
        itag: '135', type: video.type, url: _videoUrl, size: 480, fps: []);
    expect(unknownSize.size, isNull);
    expect(unknownSize.fps, isNull);
    expect(manifest([video]), isNull);
    expect(manifest([audio, badRange, unknownSize]), isNull);
    expect(
        manifest([audio, video], resolve: (url) {
          return url == _videoUrl ? null : url;
        }),
        isNull);
  });
}
