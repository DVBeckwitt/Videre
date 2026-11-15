import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/caption.dart';
import 'package:flutter_test/flutter_test.dart';

AdaptiveFormat _audio(String id,
        {String bitrate = '128000',
        bool mp4 = false,
        bool isDefault = false}) =>
    AdaptiveFormat(
        null,
        bitrate,
        null,
        'https://instance.test/media',
        mp4 ? '140' : '251',
        mp4 ? 'audio/mp4' : 'audio/webm',
        '8',
        '1',
        '',
        null,
        mp4 ? 'aac' : 'opus',
        null,
        null,
        audioTrack:
            AudioTrack(id: id, displayName: id, audioIsDefault: isDefault));

void main() {
  test('audio selection preserves language before comparing bitrate', () {
    final spanish = _audio('es', bitrate: '256000');
    final english = _audio('en', isDefault: true);
    final formats = [spanish, english, _audio('en', bitrate: '64000')];
    expect(DownloadFormats(formats).audioFor(DownloadContainer.webm), english);
    expect(
        DownloadFormats(formats, audioTrackId: 'es')
            .audioFor(DownloadContainer.webm),
        spanish);
    expect(DownloadFormats(formats, audioTrackId: 'fr').audioContainer, isNull);
    expect(DownloadFormats(formats).audioTracks.map((track) => track.id),
        ['es', 'en']);
  });

  test('explicit container cannot silently select another audio language', () {
    final formats = DownloadFormats([_audio('en'), _audio('es', mp4: true)],
        audioTrackId: 'en');
    expect(formats.audioFor(DownloadContainer.webm), isNotNull);
    expect(formats.audioFor(DownloadContainer.mp4), isNull);
  });

  test('DASH discovery preserves the original untagged default audio', () {
    final original = _audio('en')..audioTrack = null;
    final dash = _audio('dash:en:main:English', mp4: true, isDefault: true);
    final formats = DownloadFormats([original, dash]);
    expect(formats.audioFor(DownloadContainer.webm), original);
    expect(formats.audioFor(DownloadContainer.mp4), isNull);
    expect(
        DownloadFormats([original, dash], audioTrackId: dash.audioTrack!.id)
            .audioFor(DownloadContainer.mp4),
        dash);
  });

  test('old saved downloads retain WebM and new options survive persistence',
      () {
    final old = DownloadedVideo.fromJson({
      'videoId': 'abc',
      'title': 'Video',
      'lengthSeconds': 1,
      'quality': '720p',
      'audioOnly': true,
    });
    expect(old.extension, 'webm');
    expect(old.audioTrackId, isNull);
    expect(old.captionLabel, isNull);
    final selected = old.copyWith(
        container: DownloadContainer.mp4,
        audioTrackId: 'es',
        captionLabel: 'Spanish');
    final restored = DownloadedVideo.fromJson(selected.toJson());
    expect(restored, selected);
    expect(restored.extension, 'm4a');
    expect(restored.mimeType, 'audio/mp4');
  });

  test('Invidious caption language keys and optional audio metadata parse', () {
    expect(
        Caption.fromJson({
          'label': 'Spanish',
          'language_code': 'es',
          'url': '/api/v1/captions/abc'
        }).languageCode,
        'es');
    expect(
        Caption.fromJson({
          'label': 'Spanish',
          'languageCode': 'es',
          'url': '/api/v1/captions/abc'
        }).languageCode,
        'es');
    final format = _audio('es');
    expect(AdaptiveFormat.fromJson(format.toJson()).audioTrack?.id, 'es');
    expect(AudioTrack.fromJson({'id': 3}), isNull);
    expect(AudioTrack.fromJson({'id': ''}), isNull);
  });
}
