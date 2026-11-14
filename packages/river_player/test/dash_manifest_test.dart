import 'package:flutter_test/flutter_test.dart';
import 'package:river_player/src/dash/better_player_dash_utils.dart';

void main() {
  const source = 'https://instance.example/api/manifest/dash/id/video';

  test('fractional frame rates retain every quality and later audio groups',
      () async {
    final result = await BetterPlayerDashUtils.parse('''
      <MPD><Period>
        <AdaptationSet mimeType="video/mp4">
          <Representation id="18" width="640" height="360"
            bandwidth="500000" frameRate="30000/1001" codecs="avc1.4d401e"/>
          <Representation id="22" width="1280" height="720"
            bandwidth="1500000" frameRate="60000/1001" codecs="avc1.4d401f"/>
        </AdaptationSet>
        <AdaptationSet mimeType="video/webm">
          <Representation id="248" width="1920" height="1080"
            bandwidth="2500000" frameRate="24" codecs="vp9"/>
        </AdaptationSet>
        <AdaptationSet mimeType="audio/mp4" lang="en" label="English"/>
      </Period></MPD>
    ''', source);

    expect(result.tracks!.map((track) => track.height), [360, 720, 1080]);
    expect(result.tracks!.map((track) => track.frameRate), [30, 60, 24]);
    expect(result.audios, hasLength(1));
    expect(result.audios!.single.label, 'English');
  });

  test('contentType identifies video with representation MIME metadata',
      () async {
    final result = await BetterPlayerDashUtils.parse('''
      <MPD><Period><AdaptationSet contentType="video">
        <Representation id="137" mimeType="video/mp4" codecs="avc1.640028"
          width="1920" height="1080" bandwidth="2500000" frameRate="30"/>
      </AdaptationSet></Period></MPD>
    ''', source);

    final track = result.tracks!.single;
    expect(track.height, 1080);
    expect(track.mimeType, 'video/avc');
  });

  test('representation MIME metadata identifies video and audio groups',
      () async {
    final result = await BetterPlayerDashUtils.parse('''
      <MPD><Period>
        <AdaptationSet>
          <Representation id="136" mimeType="video/mp4"
            width="1280" height="720" bandwidth="1500000"/>
        </AdaptationSet>
        <AdaptationSet lang="fr" label="French">
          <Representation id="140" mimeType="audio/mp4"/>
        </AdaptationSet>
      </Period></MPD>
    ''', source);

    expect(result.tracks!.single.height, 720);
    expect(result.audios!.single.language, 'fr');
    expect(result.audios!.single.mimeType, 'audio/mp4');
  });

  test('subtitle discovery retains adaptation-level text MIME requirements',
      () async {
    final result = await BetterPlayerDashUtils.parse(r'''
      <MPD><Period>
        <AdaptationSet contentType="text" mimeType="application/mp4" lang="en">
          <Representation id="segmented-captions" bandwidth="1000" codecs="stpp">
            <SegmentTemplate timescale="1000" duration="2000"
              initialization="captions-init.mp4" media="captions-$Number$.m4s"/>
          </Representation>
        </AdaptationSet>
        <AdaptationSet contentType="text" mimeType="application/ttml+xml"
          lang="fr">
          <Representation id="ttml-captions" bandwidth="1000">
            <BaseURL>https://instance.example/captions.ttml</BaseURL>
          </Representation>
        </AdaptationSet>
        <AdaptationSet lang="en" label="Representation captions">
          <Representation id="vtt-captions" mimeType="text/vtt">
            <BaseURL>https://instance.example/captions.vtt</BaseURL>
          </Representation>
        </AdaptationSet>
        <AdaptationSet mimeType="audio/mp4" lang="en" label="English"/>
        <AdaptationSet mimeType="video/mp4">
          <Representation id="136" width="1280" height="720"
            bandwidth="1500000" frameRate="30" codecs="avc1.4d401f"/>
        </AdaptationSet>
      </Period></MPD>
    ''', source);

    expect(result.subtitles, isEmpty);
    expect(result.audios!.single.id, 0);
    expect(result.audios!.single.label, 'English');
    expect(result.tracks!.single.height, 720);
  });

  test('video attributes inherit from the adaptation set with local overrides',
      () async {
    final result = await BetterPlayerDashUtils.parse('''
      <MPD><Period><AdaptationSet contentType="video" width="1280"
        height="720" frameRate="30000/1001" codecs="avc1.4d401f">
        <Representation id="136" bandwidth="1500000"/>
        <Representation id="137" width="1920" height="1080"
          bandwidth="2500000" frameRate="60" codecs="avc1.640028"/>
      </AdaptationSet></Period></MPD>
    ''', source);

    expect(result.tracks!.map((track) => track.width), [1280, 1920]);
    expect(result.tracks!.map((track) => track.height), [720, 1080]);
    expect(result.tracks!.map((track) => track.frameRate), [30, 60]);
    expect(result.tracks!.map((track) => track.codecs),
        ['avc1.4d401f', 'avc1.640028']);
    expect(result.tracks!.map((track) => track.mimeType),
        ['video/avc', 'video/avc']);
  });

  for (final frameRate in ['unknown', '0/0', '30/0', '30/1/1']) {
    test('invalid frame rate $frameRate does not hide other tracks', () async {
      final result = await BetterPlayerDashUtils.parse('''
        <MPD><Period><AdaptationSet mimeType="video/mp4">
          <Representation id="18" width="unknown" height="360"
            bandwidth="unknown" frameRate="$frameRate"/>
          <Representation id="136" width="1280" height="720"
            bandwidth="1500000" frameRate="30"/>
        </AdaptationSet></Period></MPD>
      ''', source);

      expect(result.tracks!.map((track) => track.height), [360, 720]);
      expect(result.tracks!.map((track) => track.frameRate), [0, 30]);
      expect(result.tracks!.first.width, 0);
      expect(result.tracks!.first.bitrate, 0);
    });
  }

  test('existing audio and subtitle labels and alignment remain available',
      () async {
    final result = await BetterPlayerDashUtils.parse('''
      <MPD><Period>
        <AdaptationSet mimeType="audio/mp4" lang="en" label="English"
          segmentAlignment="true"/>
        <AdaptationSet mimeType="text/vtt" lang="en" label="Captions"
          segmentAlignment="true"/>
      </Period></MPD>
    ''', source);

    expect(result.audios!.single.id, 0);
    expect(result.audios!.single.label, 'English');
    expect(result.audios!.single.language, 'en');
    expect(result.audios!.single.segmentAlignment, isTrue);
    expect(result.subtitles!.single.name, 'Captions');
    expect(result.subtitles!.single.language, 'en');
    expect(result.subtitles!.single.segmentAlignment, isTrue);
  });
}
